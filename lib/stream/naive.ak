//// The two tempting variants of `Stop` that the #39 exploration warns against.
//// Each differs from `stream.validate_stop` in exactly one argument of
//// `stream.stop_with`, so a test that separates them isolates that choice.

use aiken/collection/list
use cardano/transaction.{Output, Transaction}
use stream/stream.{lower_bound, settle, stop_with, upper_bound, vested}
use stream/types.{StreamDatum}
use vesting/types.{VestedAsset} as vesting_types

/// Trap 1 (§3.2): read the stop's `now` from the lower bound, as a claim does.
pub fn validate_stop_reading_lower_bound(
  datum: StreamDatum,
  own_input: Output,
  tx: Transaction,
) -> Bool {
  stop_with(datum, own_input, tx, lower_bound, settle)
}

/// Trap 2 (§3.3): settle by rewriting the terms to what had vested by `c`.
/// Two streams with the same parties, start and rate rewrite to the same datum.
pub fn settle_by_rewriting(d: StreamDatum, c: Int) -> StreamDatum {
  StreamDatum {
    ..d,
    vesting: list.map(
      d.vesting,
      fn(asset) { VestedAsset { ..asset, total: vested(asset.total, d, c) } },
    ),
    end_time: c,
    stoppable: False,
  }
}

pub fn validate_stop_settling_by_rewriting(
  datum: StreamDatum,
  own_input: Output,
  tx: Transaction,
) -> Bool {
  stop_with(datum, own_input, tx, upper_bound, settle_by_rewriting)
}
