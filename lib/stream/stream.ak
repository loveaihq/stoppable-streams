//// A stoppable profile of linear vesting, as sketched in the #39 exploration:
//// #3's claim rule, #3's recovery, and a `Stop` action. `vested_quantity` is
//// contracts-library's own (`vesting/linear.ak`, copied unchanged).

use aiken/collection/list
use aiken/interval.{Finite, is_entirely_after}
use authorization
use cardano/address.{Credential}
use cardano/assets.{Value}
use cardano/transaction.{Datum, InlineDatum, Output, Transaction}
use stream/types.{StreamDatum}
use vesting/linear.{vested_quantity}

/// #3's vesting function behind an optional cliff: nothing before
/// `cliff_time`, then the linear schedule from `start_time`.
pub fn vested(total: Int, d: StreamDatum, now: Int) -> Int {
  if now < d.cliff_time {
    0
  } else {
    vested_quantity(total, d.start_time, d.end_time, now)
  }
}

/// What a stop leaves behind: the original terms, no longer stoppable, and the
/// time the stop was read at. Keeping the original terms is what makes it
/// injective (exploration §3.3).
pub fn settle(d: StreamDatum, c: Int) -> StreamDatum {
  StreamDatum { ..d, stoppable: False, stopped_at: Some(c) }
}

/// A claim's `now`: the lower bound. The ledger includes a transaction only at
/// or after it, so the claimer never reads more vested than has vested.
pub fn lower_bound(tx: Transaction) -> Int {
  expect Finite(t) = tx.validity_range.lower_bound.bound_type
  t
}

/// A stop's `now`: the upper bound. The ledger includes a transaction only
/// before it, so the sender never reads less vested than has vested (§3.2).
pub fn upper_bound(tx: Transaction) -> Int {
  expect Finite(t) = tx.validity_range.upper_bound.bound_type
  t
}

/// The beneficiary withdraws. A live stream keeps #3's count-preserving
/// remainder rule; a settled one is the beneficiary's to take in full.
pub fn validate_claim(
  datum: StreamDatum,
  own_input: Output,
  tx: Transaction,
) -> Bool {
  expect
    authorization.is_authorized(
      datum.beneficiary,
      tx.extra_signatories,
      tx.withdrawals,
    )
  expect InlineDatum(_) = own_input.datum
  when datum.stopped_at is {
    Some(_) -> True
    None -> {
      expect well_formed(datum)
      remainders_preserved(datum, own_input, tx, lower_bound(tx))
    }
  }
}

/// #3's `Cancel`: after `recovery_time`, the locker takes what is left.
pub fn validate_recover(datum: StreamDatum, tx: Transaction) -> Bool {
  expect
    authorization.is_authorized(
      datum.locker,
      tx.extra_signatories,
      tx.withdrawals,
    )
  expect well_formed(datum)
  expect datum.end_time < datum.recovery_time
  is_entirely_after(tx.validity_range, datum.recovery_time)
}

/// The locker stops a live, stoppable stream: the recipient's share is read at
/// the upper bound and stays at the script under `settle(datum, c)`.
pub fn validate_stop(
  datum: StreamDatum,
  own_input: Output,
  tx: Transaction,
) -> Bool {
  stop_with(datum, own_input, tx, upper_bound, settle)
}

/// The stop rule with its two design choices as parameters, so that a test can
/// swap one and keep the other: when `now` is read, and what a stop leaves.
///
/// Per datum `d` spent under it, with `k` inputs at this script carrying `d`,
/// for every asset in `d.vesting`:
///
///   value(outputs here carrying settled(d, c)) >= value(inputs carrying d) - k * unvested(c)
///
/// Identical datums pool their shares: they have the same parties and terms,
/// and a settled instance has no schedule left to protect.
pub fn stop_with(
  datum: StreamDatum,
  own_input: Output,
  tx: Transaction,
  read_time: fn(Transaction) -> Int,
  settled_with: fn(StreamDatum, Int) -> StreamDatum,
) -> Bool {
  expect
    authorization.is_authorized(
      datum.locker,
      tx.extra_signatories,
      tx.withdrawals,
    )
  expect datum.stoppable
  expect None = datum.stopped_at
  expect well_formed(datum)
  expect InlineDatum(_) = own_input.datum
  let c = read_time(tx)
  let own = own_input.address.payment_credential
  let spent_outputs = list.map(tx.inputs, fn(input) { input.output })
  let k = count_at(spent_outputs, own, own_input.datum)
  let spent = value_at(spent_outputs, own, own_input.datum)
  let settled: Datum = InlineDatum(settled_with(datum, c))
  let left = value_at(tx.outputs, own, settled)
  list.all(
    datum.vesting,
    fn(asset) {
      let unvested = asset.total - vested(asset.total, datum, c)
      assets.quantity_of(left, asset.policy, asset.name) >= assets.quantity_of(
        spent,
        asset.policy,
        asset.name,
      ) - k * unvested
    },
  )
}

fn well_formed(d: StreamDatum) -> Bool {
  and {
    d.start_time < d.end_time,
    d.start_time <= d.cliff_time,
    d.cliff_time <= d.end_time,
  }
}

fn at(output: Output, credential: Credential, datum: Datum) -> Bool {
  output.address.payment_credential == credential && output.datum == datum
}

fn count_at(outputs: List<Output>, credential: Credential, datum: Datum) -> Int {
  list.count(outputs, fn(output) { at(output, credential, datum) })
}

fn value_at(
  outputs: List<Output>,
  credential: Credential,
  datum: Datum,
) -> Value {
  list.foldl(
    outputs,
    assets.zero,
    fn(output, sum) {
      if at(output, credential, datum) {
        assets.merge(sum, output.value)
      } else {
        sum
      }
    },
  )
}

/// #3's rule (spec §5.1) with the cliff: at least `k` continuations carrying
/// the datum, each holding the full remainder of every asset.
fn remainders_preserved(
  datum: StreamDatum,
  own_input: Output,
  tx: Transaction,
  now: Int,
) -> Bool {
  if now >= datum.end_time {
    True
  } else {
    let own = own_input.address.payment_credential
    let k = count_at(
      list.map(tx.inputs, fn(input) { input.output }),
      own,
      own_input.datum,
    )
    let continuations = list.filter(
      tx.outputs,
      fn(output) { at(output, own, own_input.datum) },
    )
    list.length(continuations) >= k && list.all(
      continuations,
      fn(output) {
        list.all(
          datum.vesting,
          fn(asset) {
            assets.quantity_of(output.value, asset.policy, asset.name) >= asset.total - vested(
              asset.total,
              datum,
              now,
            )
          },
        )
      },
    )
  }
}
