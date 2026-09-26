//// Tests for the stoppable-stream prototype. Each of the #39 exploration's two
//// traps runs twice: as the concrete counterexample from §3.2 / §3.3, and as a
//// property over every stream of that shape.

use aiken/fuzz
use aiken/interval
use cardano/address.{VerificationKey, from_script}
use cardano/assets
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction, placeholder,
}
use stream/naive.{
  settle_by_rewriting, validate_stop_reading_lower_bound,
  validate_stop_settling_by_rewriting,
}
use stream/stream.{
  settle, validate_claim, validate_recover, validate_stop, vested,
}
use stream/types.{StreamDatum}
use vesting/types.{VestedAsset} as vesting_types

// ----------------------------------------------------------------- fixtures
// The same key and script hashes as contracts-library's linear.test.ak.

const own_script = #"99999999999999999999999999999999999999999999999999999999"

const recipient_key =
  #"11111111111111111111111111111111111111111111111111111111"

const sender_key = #"44444444444444444444444444444444444444444444444444444444"

const tx_id =
  #"0000000000000000000000000000000000000000000000000000000000000000"

/// `total` lovelace streamed from 1000 to `end`: stoppable, no cliff.
fn stream_of(total: Int, end: Int, recovery: Int) -> StreamDatum {
  StreamDatum {
    beneficiary: VerificationKey(recipient_key),
    locker: VerificationKey(sender_key),
    vesting: [VestedAsset { policy: "", name: "", total }],
    start_time: 1000,
    cliff_time: 1000,
    end_time: end,
    recovery_time: recovery,
    stoppable: True,
    stopped_at: None,
  }
}

/// Stream A: 100 over [1000, 2000].
fn stream_a() -> StreamDatum {
  stream_of(100, 2000, 3000)
}

/// Stream B: 50 over [1000, 1500]. The same parties, start and rate as A, so
/// at 1200 each has vested 20.
fn stream_b() -> StreamDatum {
  stream_of(50, 1500, 3000)
}

fn output_with(d: StreamDatum, lovelace: Int) -> Output {
  Output {
    address: from_script(own_script),
    value: assets.from_lovelace(lovelace),
    datum: InlineDatum(d),
    reference_script: None,
  }
}

fn input_with(d: StreamDatum, lovelace: Int, index: Int) -> Input {
  Input {
    output_reference: OutputReference {
      transaction_id: tx_id,
      output_index: index,
    },
    output: output_with(d, lovelace),
  }
}

/// A transaction valid from `lower` to `upper`, signed by `signer`.
fn tx_between(
  lower: Int,
  upper: Int,
  inputs: List<Input>,
  outputs: List<Output>,
  signer: ByteArray,
) -> Transaction {
  Transaction {
    ..placeholder,
    inputs,
    outputs,
    validity_range: interval.between(lower, upper),
    extra_signatories: [signer],
  }
}

/// The sender's stop, valid from `lower` to `upper`.
fn stop_tx(
  lower: Int,
  upper: Int,
  inputs: List<Input>,
  outputs: List<Output>,
) -> Transaction {
  tx_between(lower, upper, inputs, outputs, sender_key)
}

/// A transaction valid from `now` on, signed by `signer`.
fn tx_after(
  now: Int,
  inputs: List<Input>,
  outputs: List<Output>,
  signer: ByteArray,
) -> Transaction {
  Transaction {
    ..placeholder,
    inputs,
    outputs,
    validity_range: interval.after(now),
    extra_signatories: [signer],
  }
}

// ------------------------------------------ trap 2: the settled datum (§3.3)

test rewrite_settles_two_streams_to_one_datum() {
  // Stopped at 1200, 100 over [1000, 2000] and 50 over [1000, 1500] both
  // rewrite to 20 over [1000, 1200].
  settle_by_rewriting(stream_a(), 1200) == settle_by_rewriting(stream_b(), 1200)
}

test rewrite_lets_one_output_settle_two_stops() {
  // The sender stops A and B and leaves ONE output of 20 under the shared
  // rewritten datum. Both stops pass: the sender keeps 150 - 20 = 130 instead
  // of 150 - 40 = 110, and one recipient share of 20 is gone.
  let a = input_with(stream_a(), 100, 0)
  let b = input_with(stream_b(), 50, 1)
  let theft = stop_tx(
    1100,
    1200,
    [a, b],
    [output_with(settle_by_rewriting(stream_a(), 1200), 20)],
  )
  and {
    validate_stop_settling_by_rewriting(stream_a(), a.output, theft),
    validate_stop_settling_by_rewriting(stream_b(), b.output, theft),
  }
}

test settle_refuses_one_output_under_a() fail {
  // The same theft against the sketch, the one output under A's settled
  // datum: B's stop finds nothing under its own.
  let a = input_with(stream_a(), 100, 0)
  let b = input_with(stream_b(), 50, 1)
  let theft = stop_tx(
    1100,
    1200,
    [a, b],
    [output_with(settle(stream_a(), 1200), 20)],
  )
  and {
    validate_stop(stream_a(), a.output, theft),
    validate_stop(stream_b(), b.output, theft),
  }
}

test settle_refuses_one_output_under_b() fail {
  let a = input_with(stream_a(), 100, 0)
  let b = input_with(stream_b(), 50, 1)
  let theft = stop_tx(
    1100,
    1200,
    [a, b],
    [output_with(settle(stream_b(), 1200), 20)],
  )
  and {
    validate_stop(stream_a(), a.output, theft),
    validate_stop(stream_b(), b.output, theft),
  }
}

test settle_accepts_both_shares() {
  // The honest stop: 20 under each settled datum, and the sender keeps 110.
  let a = input_with(stream_a(), 100, 0)
  let b = input_with(stream_b(), 50, 1)
  let honest = stop_tx(
    1100,
    1200,
    [a, b],
    [
      output_with(settle(stream_a(), 1200), 20),
      output_with(settle(stream_b(), 1200), 20),
    ],
  )
  and {
    validate_stop(stream_a(), a.output, honest),
    validate_stop(stream_b(), b.output, honest),
  }
}

/// A stream of `total` over `length` from 1000, a second one streaming `m`
/// times as much over `m` times as long (the same rate), and a stop time
/// within the first: `(total, length, m, c)`.
fn same_rate_pair() -> Fuzzer<(Int, Int, Int, Int)> {
  fuzz.int_between(1, 1_000_000_000)
    |> fuzz.and_then(
        fn(total) {
          fuzz.int_between(1, 1_000_000)
            |> fuzz.and_then(
                fn(length) {
                  fuzz.int_between(2, 10)
                    |> fuzz.and_then(
                        fn(m) {
                          fuzz.int_between(1000, 1000 + length)
                            |> fuzz.map(fn(c) { (total, length, m, c) })
                        },
                      )
                },
              )
        },
      )
}

fn pair_of(total: Int, length: Int, m: Int) -> (StreamDatum, StreamDatum) {
  let recovery = 1000 + m * length + 1
  (
    stream_of(total, 1000 + length, recovery),
    stream_of(m * total, 1000 + m * length, recovery),
  )
}

test prop_rewrite_loses_a_share_for_any_same_rate_pair(
  (total, length, m, c) via same_rate_pair(),
) {
  let (d1, d2) = pair_of(total, length, m)
  let share = vested(total, d1, c)
  let in1 = input_with(d1, total, 0)
  let in2 = input_with(d2, m * total, 1)
  let theft = stop_tx(
    1000,
    c,
    [in1, in2],
    [output_with(settle_by_rewriting(d1, c), share)],
  )
  // With nothing vested there is no share to lose; otherwise both stops pass
  // with one share left for two.
  share == 0 || and {
    validate_stop_settling_by_rewriting(d1, in1.output, theft),
    validate_stop_settling_by_rewriting(d2, in2.output, theft),
  }
}

test prop_settle_keeps_both_shares_for_any_same_rate_pair(
  (total, length, m, c) via same_rate_pair(),
) {
  let (d1, d2) = pair_of(total, length, m)
  let share = vested(total, d1, c)
  let in1 = input_with(d1, total, 0)
  let in2 = input_with(d2, m * total, 1)
  let theft = stop_tx(1000, c, [in1, in2], [output_with(settle(d1, c), share)])
  let honest = stop_tx(
    1000,
    c,
    [in1, in2],
    [output_with(settle(d1, c), share), output_with(settle(d2, c), share)],
  )
  share == 0 || and {
    !and {
      validate_stop(d1, in1.output, theft),
      validate_stop(d2, in2.output, theft),
    },
    validate_stop(d1, in1.output, honest),
    validate_stop(d2, in2.output, honest),
  }
}

// ------------------------------------------ trap 1: the time read (§3.2)

test lower_bound_read_lets_the_sender_take_everything() {
  // A stop included at about 1200, its lower bound set back to the start.
  // Read at 1000 nothing has vested, so the sender takes all 100, the 20 that
  // had accrued included.
  let a = input_with(stream_a(), 100, 0)
  validate_stop_reading_lower_bound(
    stream_a(),
    a.output,
    stop_tx(1000, 1200, [a], []),
  )
}

test upper_bound_read_refuses_it() fail {
  let a = input_with(stream_a(), 100, 0)
  validate_stop(stream_a(), a.output, stop_tx(1000, 1200, [a], []))
}

test upper_bound_read_accepts_the_honest_stop() {
  let a = input_with(stream_a(), 100, 0)
  validate_stop(
    stream_a(),
    a.output,
    stop_tx(1000, 1200, [a], [output_with(settle(stream_a(), 1200), 20)]),
  )
}

test late_upper_bound_costs_only_the_sender() {
  // Read at 1500, the recipient is owed 50: more than had vested by
  // inclusion, paid by the sender who chose the bound.
  let a = input_with(stream_a(), 100, 0)
  validate_stop(
    stream_a(),
    a.output,
    stop_tx(1100, 1500, [a], [output_with(settle(stream_a(), 1500), 50)]),
  )
}

test late_upper_bound_still_binds_the_sender() fail {
  let a = input_with(stream_a(), 100, 0)
  validate_stop(
    stream_a(),
    a.output,
    stop_tx(1100, 1500, [a], [output_with(settle(stream_a(), 1500), 49)]),
  )
}

test stop_needs_a_finite_upper_bound() fail {
  let a = input_with(stream_a(), 100, 0)
  validate_stop(
    stream_a(),
    a.output,
    tx_after(1100, [a], [output_with(settle(stream_a(), 1200), 20)], sender_key),
  )
}

/// A stream of `total` over `length` from 1000, and a stop time within it.
fn stream_and_stop() -> Fuzzer<(Int, Int, Int)> {
  fuzz.int_between(1, 1_000_000_000)
    |> fuzz.and_then(
        fn(total) {
          fuzz.int_between(1, 1_000_000)
            |> fuzz.and_then(
                fn(length) {
                  fuzz.int_between(1000, 1000 + length)
                    |> fuzz.map(fn(c) { (total, length, c) })
                },
              )
        },
      )
}

test prop_lower_bound_read_takes_the_accrued_share(
  (total, length, c) via stream_and_stop(),
) {
  // Whenever something has vested by `c`, a stop valid from the start to `c`
  // that leaves the recipient nothing passes the lower-bound read and fails
  // the upper-bound one.
  let d = stream_of(total, 1000 + length, 1000 + length + 1)
  let s = input_with(d, total, 0)
  let theft = stop_tx(1000, c, [s], [])
  vested(total, d, c) == 0 || and {
    validate_stop_reading_lower_bound(d, s.output, theft),
    !validate_stop(d, s.output, theft),
  }
}

// ------------------------------------------ the stop rule, exactly

/// A stream of `total` over `length` from 1000, a stop time from before its
/// start to after its end, and what the sender leaves: `(total, length, c, left)`.
fn stop_scenario() -> Fuzzer<(Int, Int, Int, Int)> {
  fuzz.int_between(0, 1_000_000_000)
    |> fuzz.and_then(
        fn(total) {
          fuzz.int_between(1, 1_000_000)
            |> fuzz.and_then(
                fn(length) {
                  fuzz.int_between(900, 1100 + length)
                    |> fuzz.and_then(
                        fn(c) {
                          fuzz.int_between(0, total)
                            |> fuzz.map(fn(left) { (total, length, c, left) })
                        },
                      )
                },
              )
        },
      )
}

test prop_stop_leaves_exactly_the_vested_share(
  (total, length, c, left) via stop_scenario(),
) {
  // The sender may take anything down to the recipient's share read at the
  // upper bound, and nothing past it.
  let d = stream_of(total, 1000 + length, 1100 + length + 1)
  let s = input_with(d, total, 0)
  let stop = stop_tx(c - 100, c, [s], [output_with(settle(d, c), left)])
  validate_stop(d, s.output, stop) == ( left >= vested(total, d, c) )
}

test stop_needs_the_sender() fail {
  let a = input_with(stream_a(), 100, 0)
  validate_stop(
    stream_a(),
    a.output,
    tx_between(
      1100,
      1200,
      [a],
      [output_with(settle(stream_a(), 1200), 20)],
      recipient_key,
    ),
  )
}

test stop_refuses_a_stream_that_is_not_stoppable() fail {
  let fixed = StreamDatum { ..stream_a(), stoppable: False }
  let a = input_with(fixed, 100, 0)
  validate_stop(
    fixed,
    a.output,
    stop_tx(1100, 1200, [a], [output_with(settle(fixed, 1200), 20)]),
  )
}

test stop_refuses_a_settled_stream() fail {
  // No second stop: settling clears `stoppable`.
  let settled = settle(stream_a(), 1200)
  let a = input_with(settled, 20, 0)
  validate_stop(
    settled,
    a.output,
    stop_tx(1300, 1400, [a], [output_with(settle(settled, 1400), 20)]),
  )
}

test stop_refuses_a_stopped_stream_marked_stoppable() fail {
  // Nor on a datum carrying `stopped_at` but still marked stoppable, which a
  // locker could create directly: settling it would not be injective.
  let odd = StreamDatum { ..settle(stream_a(), 1200), stoppable: True }
  let a = input_with(odd, 100, 0)
  validate_stop(
    odd,
    a.output,
    stop_tx(1300, 1400, [a], [output_with(settle(odd, 1400), 40)]),
  )
}

test identical_streams_pool_their_shares() {
  // Two byte-identical streams stopped together: their shares (20 each) may sit
  // in one settled output, since the same recipient owns both and neither has
  // a schedule left.
  let a0 = input_with(stream_a(), 100, 0)
  let a1 = input_with(stream_a(), 100, 1)
  let stop = stop_tx(
    1100,
    1200,
    [a0, a1],
    [output_with(settle(stream_a(), 1200), 40)],
  )
  and {
    validate_stop(stream_a(), a0.output, stop),
    validate_stop(stream_a(), a1.output, stop),
  }
}

test identical_streams_still_owe_both_shares() fail {
  let a0 = input_with(stream_a(), 100, 0)
  let a1 = input_with(stream_a(), 100, 1)
  let stop = stop_tx(
    1100,
    1200,
    [a0, a1],
    [output_with(settle(stream_a(), 1200), 39)],
  )
  validate_stop(stream_a(), a0.output, stop)
}

test stop_after_a_partial_claim_owes_the_rest() {
  // 10 was claimed earlier, so A holds 90. At 1200 the recipient is owed
  // 20 - 10 = 10 more, and the sender takes the 80 that had not vested.
  let a = input_with(stream_a(), 90, 0)
  validate_stop(
    stream_a(),
    a.output,
    stop_tx(1100, 1200, [a], [output_with(settle(stream_a(), 1200), 10)]),
  )
}

test stop_after_a_partial_claim_cannot_take_more() fail {
  let a = input_with(stream_a(), 90, 0)
  validate_stop(
    stream_a(),
    a.output,
    stop_tx(1100, 1200, [a], [output_with(settle(stream_a(), 1200), 9)]),
  )
}

test stop_before_the_cliff_returns_everything() {
  // Nothing vests before the cliff, so a stop there leaves the recipient
  // nothing.
  let cliffed = StreamDatum { ..stream_a(), cliff_time: 1500 }
  let a = input_with(cliffed, 100, 0)
  validate_stop(cliffed, a.output, stop_tx(1100, 1200, [a], []))
}

// ------------------------------------------ claims (#3's rule) and recovery

test claim_on_a_settled_stream_takes_everything() {
  let settled = settle(stream_a(), 1200)
  let a = input_with(settled, 20, 0)
  validate_claim(settled, a.output, tx_after(1300, [a], [], recipient_key))
}

test claim_on_a_live_stream_keeps_the_remainder() {
  let a = input_with(stream_a(), 100, 0)
  validate_claim(
    stream_a(),
    a.output,
    tx_after(1500, [a], [output_with(stream_a(), 50)], recipient_key),
  )
}

test claim_on_a_live_stream_cannot_overclaim() fail {
  let a = input_with(stream_a(), 100, 0)
  validate_claim(
    stream_a(),
    a.output,
    tx_after(1500, [a], [output_with(stream_a(), 49)], recipient_key),
  )
}

test claim_before_the_cliff_keeps_everything() fail {
  let cliffed = StreamDatum { ..stream_a(), cliff_time: 1500 }
  let a = input_with(cliffed, 100, 0)
  validate_claim(
    cliffed,
    a.output,
    tx_after(1400, [a], [output_with(cliffed, 99)], recipient_key),
  )
}

test claim_after_the_cliff_follows_the_line() {
  // At 1600, 60 of 100 has vested: the line runs from the start, not the cliff.
  let cliffed = StreamDatum { ..stream_a(), cliff_time: 1500 }
  let a = input_with(cliffed, 100, 0)
  validate_claim(
    cliffed,
    a.output,
    tx_after(1600, [a], [output_with(cliffed, 40)], recipient_key),
  )
}

test recover_after_recovery_time_even_when_settled() {
  let settled = settle(stream_a(), 1200)
  let a = input_with(settled, 20, 0)
  validate_recover(settled, tx_after(3001, [a], [], sender_key))
}

test recover_before_recovery_time_fails() fail {
  let a = input_with(stream_a(), 100, 0)
  validate_recover(stream_a(), tx_after(3000, [a], [], sender_key))
}
