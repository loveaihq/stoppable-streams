# Stoppable streams

An exploration of streaming payments and payroll for IOG's [contracts-library](https://github.com/input-output-hk/contracts-library), written against the deliverables of [#39](https://github.com/input-output-hk/contracts-library/issues/39), and an Aiken prototype that runs its findings as tests.

- **[`exploration.md`](exploration.md)** is the write-up. It covers:
  - prior art;
  - the relationship to Linear Vesting (#3) and Event-Triggered Assets (#28);
  - accrual accounting on eUTxO;
  - a design sketch;
  - a composability check;
  - a recommendation.
- **The prototype** (`lib/`, `validators/`) is a stoppable profile of #3, built on the library's own toolchain (Aiken v1.1.22, stdlib v3.1.0, fuzz v2). It reuses #3's code unchanged.

## Findings

1. **A stream is #3 plus one action.** #3's remainder rule already handles accrual and partial withdrawal, with no withdrawn counter. What payroll adds is a **stop**: the sender ends the stream, and the accrued part stays the recipient's. A stream that cannot be stopped and has no cliff behaves exactly like #3.
2. **The stop has two traps.** Both come from reusing #3's claim logic, and both hand the recipient's accrued funds to the sender.
   - **The time read.** A claim reads `now` from the validity range's lower bound. A stop must read the **upper** bound, because a lower bound can be set back to the stream's start, where nothing has vested.
   - **The settled datum.** Settling by rewriting the terms to what had vested (`total := vested(c)`, `end := c`) is not injective. Take 100 over [1000, 2000] and 50 over [1000, 1500], stopped at 1200: both become 20 over [1000, 1200]. One output of 20 then passes both stops, and the sender keeps 130 of the 150 instead of 110. Keeping the original terms and adding `stopped_at: Some(c)` keeps distinct streams apart.
3. **Batches are quadratic.** Each input's check scans every input and output. A transaction's CPU budget runs out at about 19 stops, or about 24 claims through #3's own `validate_claim`.

## Tests

`aiken check --max-success 1000 --seed 39` runs 43 tests, and all pass.

| What | Tests |
|---|---|
| Trap 2, the concrete case | These two show the flaw: `rewrite_settles_two_streams_to_one_datum`, `rewrite_lets_one_output_settle_two_stops`. These three show the fix: `settle_refuses_one_output_under_a` / `_b`, `settle_accepts_both_shares` |
| Trap 2, every case | `prop_rewrite_loses_a_share_for_any_same_rate_pair` and `prop_settle_keeps_both_shares_for_any_same_rate_pair`, over 1,000 random pairs in which the second stream pays `m` (2–10) times as much over `m` times as long |
| Trap 1 | `lower_bound_read_lets_the_sender_take_everything` and `upper_bound_read_refuses_it`, then `prop_lower_bound_read_takes_the_accrued_share` over 1,000 random streams and stop times |
| The stop rule, exactly | `prop_stop_leaves_exactly_the_vested_share`: over 1,000 random streams, stop times and amounts left, a stop passes if and only if the sender leaves at least `vested(c)` |
| Everything else | Authorization and a finite upper bound. No second stop. Byte-identical streams pooling their shares. Stops after partial claims and before the cliff. #3's claim rule with the cliff. Recovery |

The tests catch the bugs they target. With `validate_stop` reading the lower bound, 12 of the 43 fail. With `settle` rewriting the terms, 3 fail: trap 2's two refusal tests and its property.

## Batch cost

`lib/stream/batch.test.ak` stops or claims 1 to 40 streams in one transaction. It also claims as many #3 instances through contracts-library's own `validate_claim`.

| In one tx | Stop: memory / CPU | Claim: memory / CPU | #3's `validate_claim`: memory / CPU |
|---:|---:|---:|---:|
| 1 | 0.30M (1.8%) / 0.11B (1.1%) | 0.25M (1.5%) / 0.09B (0.9%) | 0.20M (1.2%) / 0.07B (0.7%) |
| 10 | 5.1M (31%) / 3.0B (30%) | 4.0M (24%) / 2.2B (22%) | 3.4M (21%) / 1.9B (19%) |
| 20 | 15.8M (96%) / 10.4B (**104%**) | 12.3M (75%) / 7.6B (76%) | 10.5M (64%) / 6.8B (68%) |
| 40 | 54.0M (**327%**) / 38.7B (**387%**) | 41.8M (**253%**) / 27.8B (**278%**) | 36.1M (**219%**) / 25.4B (**254%**) |

Percentages are of mainnet's per-transaction budget: 16.5M memory and 10B CPU. The ledger runs the validator once per input, and each run scans every input and output, so the cost grows with the square of the batch.

A quadratic through the CPU figures puts the limit at about 19 stops, 23 claims, or 24 claims through #3's `validate_claim`. These figures measure the checking logic in Aiken's test runner, and they also count building the test transaction; a deployed validator adds per-input overhead. Larger batches need the withdraw-zero stake-validator pattern, which validates once per transaction.

## Layout

| Path | What |
|---|---|
| `lib/authorization.ak`, `lib/vesting/types.ak`, `lib/vesting/linear.ak` | contracts-library's own, copied unchanged from [`d629dce`](https://github.com/input-output-hk/contracts-library/tree/d629dce7ef1a6af883215c076adc964bd37152a1/onchain/lib) (git blobs `f4feede`, `6929430`, `10839f2`) |
| `lib/stream/types.ak` | `StreamDatum`, which is #3's `VestingDatum` plus `cliff_time`, `stoppable` and `stopped_at`. Redeemers `Claim`, `Recover` (#3's `Cancel`) and `Stop` |
| `lib/stream/stream.ak` | The profile: `vested`, `settle`, and `validate_claim` / `validate_recover` / `validate_stop`. `stop_with` takes the two design choices as arguments: when `now` is read, and what a stop leaves behind |
| `lib/stream/naive.ak` | The two tempting variants, each one argument away from `validate_stop` |
| `lib/stream/stream.test.ak`, `lib/stream/batch.test.ak` | The tests |
| `validators/stream.ak` | The reference validator `stoppable_stream`: 2,507 bytes, against 1,404 for #3's `linear_vesting` on the same compiler. The prototype is not optimised |
| `sizing/` | The min-UTxO and transaction-size figures in the write-up's §7 |

## Running it

```
aiken check --max-success 1000 --seed 39
aiken build
cd sizing && npm install && node stream-sizing.mjs
```

CI (`.github/workflows/ci.yml`) runs all three on every push, with aiken 1.1.24, and checks that
the committed `plutus.json` holds the validators the source compiles to.

## Licence

Apache-2.0, as contracts-library. The three files under `lib/` named above are contracts-library's (Apache-2.0), unchanged. Written with AI assistance (Claude).
