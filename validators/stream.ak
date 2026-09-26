//// Reference validator for stoppable streams: a thin wrapper that dispatches
//// on the redeemer, like contracts-library's `linear_vesting.ak`.

use cardano/transaction.{OutputReference, Transaction, find_input}
use stream/stream
use stream/types.{Claim, Recover, Stop, StreamDatum, StreamRedeemer}

validator stoppable_stream {
  spend(
    datum: Option<StreamDatum>,
    redeemer: StreamRedeemer,
    own_ref: OutputReference,
    self: Transaction,
  ) {
    expect Some(stream_datum) = datum
    when redeemer is {
      Claim -> {
        expect Some(own_input) = find_input(self.inputs, own_ref)
        stream.validate_claim(stream_datum, own_input.output, self)
      }
      Recover -> stream.validate_recover(stream_datum, self)
      Stop -> {
        expect Some(own_input) = find_input(self.inputs, own_ref)
        stream.validate_stop(stream_datum, own_input.output, self)
      }
    }
  }

  else(_) {
    fail
  }
}
