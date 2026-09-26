//// On-chain state and actions for a stoppable stream: contracts-library's
//// `VestingDatum` (#3) plus `cliff_time`, `stoppable` and `stopped_at`.

use cardano/address.{Credential}
use vesting/types.{VestedAsset}

/// Written once at lock time. A claim reproduces it verbatim; a stop replaces
/// it with `settle(datum, c)` (see `stream/stream.ak`). Times are POSIX ms.
pub type StreamDatum {
  /// Who may claim. A key authorizes by signing; a script by being invoked.
  beneficiary: Credential,
  /// Who may stop the stream, and recover the remainder after `recovery_time`.
  locker: Credential,
  /// The original bundle and per-asset totals.
  vesting: List<VestedAsset>,
  start_time: Int,
  /// Nothing vests before this. `start_time` means no cliff.
  cliff_time: Int,
  end_time: Int,
  recovery_time: Int,
  /// Whether the locker may stop the stream. A stop clears it.
  stoppable: Bool,
  /// Set only by a stop: the upper bound the stop was read at.
  stopped_at: Option<Int>,
}

/// Actions on a stream UTxO.
pub type StreamRedeemer {
  /// The beneficiary withdraws up to what has vested (#3's `Claim`).
  Claim
  /// The locker recovers the remainder after `recovery_time` (#3's `Cancel`).
  Recover
  /// The locker stops a live, stoppable stream.
  Stop
}
