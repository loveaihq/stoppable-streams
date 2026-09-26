//// How the cost of one transaction grows with the number of streams it stops
//// or claims. Each test runs the check once per stream input, as the ledger
//// runs the validator once per input; the execution units the test runner
//// reports also count building the test transaction.

use aiken/collection/list
use aiken/interval
use cardano/address.{VerificationKey, from_script}
use cardano/assets
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction, placeholder,
}
use stream/stream.{settle, validate_claim, validate_stop, vested}
use stream/types.{StreamDatum}
use vesting/linear.{vested_quantity}
use vesting/types.{VestedAsset, VestingDatum} as vesting_types

const own_script = #"99999999999999999999999999999999999999999999999999999999"

const recipient_key =
  #"11111111111111111111111111111111111111111111111111111111"

const sender_key = #"44444444444444444444444444444444444444444444444444444444"

const tx_id =
  #"0000000000000000000000000000000000000000000000000000000000000000"

/// The `i`th stream of a payroll: distinct totals, so distinct datums.
fn stream_i(i: Int) -> StreamDatum {
  StreamDatum {
    beneficiary: VerificationKey(recipient_key),
    locker: VerificationKey(sender_key),
    vesting: [VestedAsset { policy: "", name: "", total: 1_000_000 + i }],
    start_time: 1000,
    cliff_time: 1000,
    end_time: 2000,
    recovery_time: 3000,
    stoppable: True,
    stopped_at: None,
  }
}

fn at_script(d: StreamDatum, lovelace: Int) -> Output {
  Output {
    address: from_script(own_script),
    value: assets.from_lovelace(lovelace),
    datum: InlineDatum(d),
    reference_script: None,
  }
}

fn inputs_of(n: Int) -> List<Input> {
  list.map(
    list.range(0, n - 1),
    fn(i) {
      Input {
        output_reference: OutputReference {
          transaction_id: tx_id,
          output_index: i,
        },
        output: at_script(stream_i(i), 1_000_000 + i),
      }
    },
  )
}

/// `n` streams stopped at 1200 in one transaction, each leaving its share.
fn batch_stop(n: Int) -> Bool {
  let settled = list.map(
    list.range(0, n - 1),
    fn(i) {
      let d = stream_i(i)
      at_script(settle(d, 1200), vested(1_000_000 + i, d, 1200))
    },
  )
  let inputs = inputs_of(n)
  let tx = Transaction {
    ..placeholder,
    inputs,
    outputs: settled,
    validity_range: interval.between(1100, 1200),
    extra_signatories: [sender_key],
  }
  list.all(
    list.zip(list.range(0, n - 1), inputs),
    fn(pair) {
      let (i, input) = pair
      validate_stop(stream_i(i), input.output, tx)
    },
  )
}

/// `n` streams claimed at 1500 in one transaction, each keeping its remainder.
fn batch_claim(n: Int) -> Bool {
  let kept = list.map(
    list.range(0, n - 1),
    fn(i) {
      let d = stream_i(i)
      at_script(d, 1_000_000 + i - vested(1_000_000 + i, d, 1500))
    },
  )
  let inputs = inputs_of(n)
  let tx = Transaction {
    ..placeholder,
    inputs,
    outputs: kept,
    validity_range: interval.after(1500),
    extra_signatories: [recipient_key],
  }
  list.all(
    list.zip(list.range(0, n - 1), inputs),
    fn(pair) {
      let (i, input) = pair
      validate_claim(stream_i(i), input.output, tx)
    },
  )
}

/// The same batch claim through contracts-library's own `validate_claim`
/// (#3, unchanged), on its own `VestingDatum`.
fn batch_claim_linear(n: Int) -> Bool {
  let datum_i = fn(i) {
    VestingDatum {
      beneficiary: VerificationKey(recipient_key),
      locker: VerificationKey(sender_key),
      vesting: [VestedAsset { policy: "", name: "", total: 1_000_000 + i }],
      start_time: 1000,
      end_time: 2000,
      recovery_time: 3000,
    }
  }
  let at_script_linear = fn(d: VestingDatum, lovelace: Int) {
    Output {
      address: from_script(own_script),
      value: assets.from_lovelace(lovelace),
      datum: InlineDatum(d),
      reference_script: None,
    }
  }
  let inputs = list.map(
    list.range(0, n - 1),
    fn(i) {
      Input {
        output_reference: OutputReference {
          transaction_id: tx_id,
          output_index: i,
        },
        output: at_script_linear(datum_i(i), 1_000_000 + i),
      }
    },
  )
  let kept = list.map(
    list.range(0, n - 1),
    fn(i) {
      at_script_linear(
        datum_i(i),
        1_000_000 + i - vested_quantity(1_000_000 + i, 1000, 2000, 1500),
      )
    },
  )
  let tx = Transaction {
    ..placeholder,
    inputs,
    outputs: kept,
    validity_range: interval.after(1500),
    extra_signatories: [recipient_key],
  }
  list.all(
    list.zip(list.range(0, n - 1), inputs),
    fn(pair) {
      let (i, input) = pair
      linear.validate_claim(datum_i(i), input.output, tx)
    },
  )
}

test batch_stop_1() {
  batch_stop(1)
}

test batch_stop_10() {
  batch_stop(10)
}

test batch_stop_20() {
  batch_stop(20)
}

test batch_stop_40() {
  batch_stop(40)
}

test batch_claim_1() {
  batch_claim(1)
}

test batch_claim_10() {
  batch_claim(10)
}

test batch_claim_20() {
  batch_claim(20)
}

test batch_claim_40() {
  batch_claim(40)
}

test batch_claim_linear_1() {
  batch_claim_linear(1)
}

test batch_claim_linear_10() {
  batch_claim_linear(10)
}

test batch_claim_linear_20() {
  batch_claim_linear(20)
}

test batch_claim_linear_40() {
  batch_claim_linear(40)
}
