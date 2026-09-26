# Exploration: Streaming Payments / Payroll

> Status: **Exploring** (pre-triage). Working design log, not a spec. Written against the deliverables of #39; triage is the team's.
>
> **Sibling:** Linear Vesting (#3, [`docs/vesting/spec.md`](https://github.com/input-output-hk/contracts-library/blob/main/docs/vesting/spec.md)). The main finding is that a stream is #3 plus one flag and one action, so this document reuses #3's names (`beneficiary`, `locker`, `vested`, `required`, `k`) throughout.

## 1. Use case

A **sender** commits funds to a **recipient**, and the funds accrue continuously over a period. The recipient withdraws whatever has accrued, as often as they like. If the stream is stoppable, the sender can stop it and take back only what has not accrued yet.

Payroll is many streams at once, typically one per recipient per funding period. Grants and contributor pay have the same shape, with a DAO (#12) or a multisig (#11) as the sender.

Lifecycle:

1. **Create:** the sender locks the funds.
2. **Accrue:** funds accrue from `start` to `end`. Nothing is withdrawable before an optional `cliff`.
3. **Withdraw:** the recipient withdraws any amount up to the accrued total, any number of times.
4. **Finish:** either `end` passes and the recipient takes the rest, or the sender stops the stream. On a stop, the accrued part stays the recipient's and the rest returns to the sender.

**Category:** DeFi.

## 2. Core framing: three concerns, three different answers

| Concern | Question | On eUTxO |
|---|---|---|
| **Accrual and partial withdrawal** | How much is withdrawable now, across repeated withdrawals? | #3 already solves this without any counter (§3.1). **Reuse.** |
| **Termination** | How is a stream stopped mid-way and split fairly? | #3 deliberately has no such power ("no clawback of *unvested* funds", spec §7). This is the one new mechanism, and it has two traps (§3.2, §3.3). **New, but small.** |
| **Funding** | Escrow per stream (Sablier Lockup, Streamflow), or a balance that streams draw on lazily and that can run into debt (LlamaPay, Sablier Flow) or be liquidated (Superfluid)? | Only escrow fits eUTxO (§3.4). **Escrow; decline the rest.** |

## 3. Mechanism

### 3.1 Accrual and partial withdrawal: #3's remainder rule, unchanged

The datum holds the original terms and a claim never rewrites it; the UTxO's value is the state. A claim at `now` (the validity range's lower bound) is valid when each continuation holds at least `required = T − vested(T, start, end, now)` of every streamed asset. #3's count-preserving rule against merging (spec §5.1) applies unchanged.

The amount withdrawn so far is implicit: it is `T − value`. Partial withdrawals of any size, any number of times, are just claims.

EVM designs keep a withdrawn counter instead. Sablier stores the deposited, withdrawn and refunded amounts per stream, and OpenZeppelin's `VestingWallet` has `released()`. On eUTxO a counter would make every claim rewrite the datum. Continuations could then no longer be matched by a byte-identical datum, and #3's double-satisfaction argument would have to be replaced by output tagging. The counter would also record nothing that the value does not already record.

A cliff is additive: `vested = 0` while `now < cliff`, and #3's formula after that. #3's spec already anticipates this change. It matches Sablier's "Cliff" shapes and OpenZeppelin's `VestingWalletCliff`.

### 3.2 Stop, trap 1: read the sender's `now` from the upper bound

This document calls the new action **`Stop`** (Sablier's *cancel*), because #3's `Cancel` redeemer already names recovery.

#3 reads `now` from the lower bound. That is right for a claim. The claimer gains from a later `now`, and the ledger includes a transaction only at or after its lower bound, so `vested(lower) ≤ vested(actual)`.

A stop reverses the incentive: the sender gains from an *earlier* `now`. A lower bound may be set arbitrarily far in the past. A stop that reused the claim's time read would let the sender set it to `start` and take everything, the accrued part included.

The recipient's share must therefore be computed at the **upper** bound, which must be finite. The ledger includes the transaction strictly before its upper bound, so `vested(upper) ≥ vested(actual)`. A late upper bound only over-pays the recipient, at the sender's own expense.

The rule generalises: read each actor's `now` from the bound that works against them.

- Use the **lower** bound for whoever gains as time passes: a claim, or #3's recovery.
- Use the **upper** bound for whoever gains while time does not pass: a stop, or a pause.

SundaeSwap's treasury vendor contract (Intersect's treasury payouts) meets the same hazard differently. It reads maturity from the lower bound and caps each adjudication's validity interval at 36 hours (`interval_length_at_most`). Its oversight committee can therefore still pause a payout that matured less than 36 hours earlier and has not been withdrawn. That bounds the window rather than removing it, which may suit a dispute process. For a continuous stream, reading the upper bound removes the window without a cap.

### 3.3 Stop, trap 2: settle in place, and keep the rewrite injective

Where should the recipient's share go? There are two options:

- **Pay the recipient on the stop**, as Streamflow does. On Cardano this needs:
  - a payout `Address` in the datum, because a `Credential` is not an address;
  - a tag on the payout against double satisfaction (§3.5).

  A script recipient may also reject an unexpected datum.
- **Settle in place**, as Sablier does. The sender is refunded, and the streamed part stays in the stream until the recipient withdraws it.

Settling in place fits better. The stop leaves the recipient's share at the contract under a *settled* datum, and a claim on a settled instance needs no continuation. It works for key and script recipients alike, and needs no address.

The sketch:

- `settle(d, c)` is `d` with `stoppable := False` and `stopped_at := Some(c)`, where `c` is the upper bound.
- `Stop` applies only to a live, stoppable datum (`stoppable = True`, `stopped_at = None`).
- For each such datum `d`, with `k_d` inputs carrying it, and for every streamed asset:

> Σ value(outputs at this script carrying `settle(d, c)`) ≥ Σ value(inputs carrying `d`) − `k_d` · (T − vested(T, start, end, c))

Two properties carry the soundness argument. Both should be proof obligations, and the prototype runs both as tests (§8):

- **Aggregating across identical datums is safe here.** A byte-identical `d` means identical parties and terms. A settled instance has no schedule left to protect, so pooling the shares cannot move value between schedules, unlike under #3's claim rule.
- **`settle` must be injective.** The tempting alternative is to settle by rewriting the terms to `total := vested(c)` and `end := c`. That rewrite is not injective:
  - Take two streams between the same parties: 100 over [1000, 2000] and 50 over [1000, 1500].
  - If both are stopped at 1200, both become 20 over [1000, 1200].
  - One continuation of 20 then satisfies both stops, and the sender keeps 130 of the 150 instead of 110.

  Keeping the original terms and adding `stopped_at` makes distinct streams settle to distinct datums.

A settled datum never needs a continuation when claimed, so no other instance can share one with it. That is not true of every datum rewrite (see Q-RENOUNCE-1).

The stop is authorized by the `locker`, that is, the sender. A separate stop authority could send the refund wherever it liked, unless the datum also fixed a refund address. An oversight committee can hold the role by being the locker, as a script credential (#11, #12).

### 3.4 Funding: escrow per stream; tranches, not top-ups

The open-ended designs draw on a payer balance lazily:

- **LlamaPay** funds all of a payer's streams from one balance. The balance can run into debt, and payees can withdraw only what was covered.
- **Sablier Flow** tracks covered and uncovered debt, and either party can void an insolvent stream.
- **Superfluid** locks a buffer, four hours of flow on most mainnets per its docs. The buffer funds the reward for liquidating a stream whose sender reaches zero.

These designs avoid locking capital up front by relying on shared, mutable accounts.

On eUTxO a shared payer balance is a single UTxO that every recipient's withdrawal must touch, which serialises all claims. That is the shared state the catalog's no-shared-state contention pattern (#8, #13, #14) exists to avoid.

More fundamentally, what a contract adds over paying salaries in an ordinary batch transaction is the escrow: accrued pay stays withdrawable even if the sender disappears. Debt-based streams give that guarantee up.

So each stream is escrowed. A payroll that should not lock a year of salaries up front uses **tranches** rather than top-ups: a new stream per recipient per funding period, created in one batch transaction. A top-up would rewrite the datum, and with it §3.1's matching. Sablier Lockup has no top-ups either.

### 3.5 Payroll: many streams

- **Creation** runs no script (as in #3), so a payroll run is one transaction. Roughly 56–62 token streams (depending on the address), or about 92 ADA streams, fit in one 16,384-byte transaction (§7).
- **Batch claims and stops** run the validator once per stream input, and each run scans all the inputs and outputs (#3's `k` and continuation checks). The cost of a transaction therefore grows with the square of its streams. Measured in the prototype (§8), against mainnet's per-transaction budget of 16.5M memory units and 10B steps:
  - stopping 10 streams takes about 31% of the budget, and 20 exceed the CPU limit (104%);
  - claiming is similar, and so is #3's own `validate_claim`, run unchanged: 21% for 10 instances, 68% of CPU for 20, 254% for 40.

  The budget runs out at about 19 stops or 24 #3 claims per transaction, and a deployed validator's own overhead lowers that. A payroll run can therefore create about 56–62 streams per transaction but stop or claim only 15–20. Larger batches need the withdraw-zero stake-validator pattern from Anastasia Labs' design-patterns, which validates once per transaction (Q-BATCH-1).
- **Push payouts** let a third party pay the recipient:
  - LlamaPay lets anyone trigger a withdrawal to the payee, so that payees on exchange addresses get paid.
  - OpenZeppelin's `release()` and Streamflow's optional `automaticWithdrawal` do the same.

  #3's pull model cannot do this, because a claim needs the recipient's authorization. A push variant needs:
  - a payout `Address` in the datum;
  - the stream input's out-ref as an inline datum on each payout, so that one output cannot settle two streams (the idea behind cardano-swaps' `prev_input`, #30).

  Each pushed token payout also needs its own min-UTxO: 1.17 ADA untagged, or 1.38 ADA tagged (§7). That argues for infrequent pushes.

### 3.6 Prior art at a glance

| Design | Funding | Accrual | Stop | Who withdraws |
|---|---|---|---|---|
| Sablier Lockup (EVM) | Escrow per stream | Linear (+ cliff, initial unlock), dynamic, tranched | Sender, if cancelable. Cancelability can be renounced, never re-enabled. Unstreamed part goes to the sender; streamed part stays withdrawable | Stream NFT holder (transferable unless disabled) |
| Sablier Flow (EVM) | Open balance; anyone tops up | Rate per second, with debt | Pause and restart; voiding forfeits uncovered debt | Recipient, to any address |
| LlamaPay (EVM) | One payer balance for all streams | `amountPerSec` (20-decimal fixed point), with debt | Payer | Anyone, to the payee |
| Superfluid CFA (EVM) | Sender's live balance plus a buffer | Flow rate | Sender; sentinels liquidate at zero | No withdrawal step: balances update in real time |
| OpenZeppelin `VestingWallet` | Escrow; later deposits vest "as if they were locked from the beginning" | Linear (+ cliff extension) | None | Anyone calls `release()`, which pays the owner (transferable) |
| Streamflow (Solana) | Escrow per stream | Linear, cliff, periodic | `cancelableBySender` / `cancelableByRecipient`; unlocked part goes to the recipient | Recipient; optional automatic withdrawal |
| Sundae treasury vendor (Cardano; Intersect) | Escrow per project | Discrete dated milestones | Committee pauses or resumes a milestone; restructuring needs both vendor and committee | Vendor (multisig), one vendor input per transaction |
| Anastasia Labs linear-vesting (Cardano, Plutarch) | Escrow | Linear, in equal installments | None | Beneficiary, exact installment amounts, one script input per transaction |
| Mesh vesting (Cardano template) | Escrow | One-shot at `lock_until` | Owner can take everything at any time, even after unlock | Beneficiary, after `lock_until` |
| contracts-library #3 | Escrow | Linear, floored | None; the locker recovers after `recovery_time` | Beneficiary (`Credential`), any number of instances per transaction |
| **This sketch** | Escrow; tranches | #3, plus an optional cliff | If `stoppable`, the locker; share read at the upper bound and settled in place | Recipient (`Credential`); push is a later variant |

A search on 2026-09-26 found no continuous-streaming payroll protocol live on Cardano. The Cardano contracts found fall into four kinds:

- lock-until (Mesh);
- installment (Anastasia Labs);
- milestone (Intersect's vendor contract);
- linear without a stop (#3).

None of them offers a fair mid-stream stop.

### 3.7 Downsides

- **Capital:** escrow locks each tranche up front, which is the cost pooled designs avoid.
- **Min-UTxO per stream** (§7): about 1.8 ADA per token stream and 1.44 ADA per ADA stream. Under #3's surplus rule this ends up with the recipient (Q-MINADA-1).
- **ADA streams keep a tail:** the last ~1.44 ADA becomes withdrawable only at `end`, because a continuation must exist until then. The exception is if the sender funds that amount as surplus.
- **Pull-only v1:** recipients must sign, or run a script, to get paid. Payees on exchange addresses need the push variant.
- **Batch size:** with #3-style checks, about 15–20 stops or claims fit in one transaction (§3.5).
- **Contention:** the sender and the recipient act on the same UTxO. If a claim and a stop land in the same block, one of them fails. This is benign: the losing party re-reads and retries.

## 4. Relationship check: Linear Vesting (#3) and Event-Triggered Assets (#28)

**#3 is the same mechanism: a stream is a configuration plus one action.** With `stoppable = False` and no cliff, the sketched stream *is* #3, with the same fields, the same `vested`, the same claim rule and the same recovery. The candidate adds:

- a `stoppable` flag;
- a `Stop` action (§3.2–3.3);
- a `stopped_at` field, which only `Stop` sets;
- an optional `cliff`.

It belongs in `lib/vesting` as a stoppable profile of #3, sharing `vested_quantity` and the remainder rule. The proofs in `formal/Formal/Vesting/Linear` would then be extended rather than redone.

#3's spec promises that the schedule "is fixed at lock time and never changes". The profile keeps that promise visible, because `stoppable` is part of the byte-identical datum. A recipient can read it before relying on the stream.

**#28 is complementary, but not the mechanism for the drip.** #28 lists streaming vesting and payroll as a P2 (time) + P3 use case. But it frames P2 as discrete events, "not continuous rebalancing". A linear drip has no discrete event to hook, so expressing it through P2 would take a keeper transaction per accrual step.

The genuine overlap is **stepped** schedules, such as Sablier's tranched shapes or Intersect's milestones. Those are discrete and time-triggered. A list of dated tranches in a vesting-style datum expresses them without a token standard, as Sundae's `payouts` list does. A tokenized, transferable stream position (Sablier's NFT) does not need #28 either (§5).

## 5. Authorization via `Credential`; transferability

The sender (`locker`) and the recipient (`beneficiary`) are `Credential`s, checked by `authorization.is_authorized` exactly as in #3. A DAO (#12), a multisig (#11) or an oversight committee can be the sender, and a splitter (#38) can be the recipient, each as a script credential via withdraw-0.

Transferability (Sablier's ERC-721, Streamflow's `transferableByRecipient`) can use the same interface without a new action. The recipient credential can be a withdraw-0 script that passes when the transaction spends a UTxO holding a given NFT, so whoever holds the NFT can claim.

Each such authorizer is its own script, so each needs a one-time stake registration, a 2 ADA refundable deposit on mainnet today. That is heavier than an ERC-721 transfer. The alternative is a first-class `Transfer` action. That action is a datum rewrite, so it needs the same care as Q-RENOUNCE-1.

Either way, transferability is later scope (Q-TRANSFER-1), and the plug-in path is #11's L3 territory.

## 6. Cross-cutting security must-fixes

- **Per-actor time reads** (§3.2): a claim reads the lower bound; a `Stop` reads the upper bound, which must be finite.
- **Stop soundness** (§3.3):
  - `Stop` applies only to live, stoppable datums;
  - `settle` is injective;
  - the check aggregates per datum;
  - `settle` clears `stoppable`, so a stream cannot be stopped twice.
- **Every datum rewrite needs the same care.** Settle, renounce, transfer and top-up must each be injective onto datums that no other live instance can carry, or aggregate over their preimage.
- **Claim soundness** is #3's, unchanged.
- **Cliff:** a stop before `cliff` leaves the recipient nothing, as in Sablier. Payroll UIs should say so.
- **Recipient-side verification:** creating a stream runs no script, as in #3. A recipient or payroll UI must check a stream's value against its datum, and check its `stoppable` flag, before treating it as pay. This is the same check a Subbit channel's provider must make, because opening a channel runs no validator either.
- **Push variant (if any):** the payout address is fixed in the datum, and each payout is tagged with the stream input's out-ref.

## 7. Implementation notes

**How the sizes were computed.** The sizes below were computed by [`sizing/stream-sizing.mjs`](sizing/stream-sizing.mjs) with evolution-sdk 0.5.14's CBOR encoder, using mainnet parameters read from Koios on 2026-09-26: 4,310 lovelace per UTxO byte and 16,384-byte transactions. The inputs to the calculation:

- Credentials are key hashes.
- The token has a 28-byte policy and an 8-byte CIP-67 name.
- Times are POSIX milliseconds, which take CBOR's 9-byte integer form.
- The stream datum is #3's fields plus `cliff`, `stoppable` and `stopped_at`.
- "Streams per tx" allows ~400 bytes for inputs, change and one signature.

| Output | Datum | Output | Min-UTxO | Streams per tx |
|---|---:|---:|---:|---:|
| #3 datum, ADA, enterprise script address | 112 B | 158 B | 1.371 ADA | ~101 |
| #3 datum, one token | 149 B | 242 B | 1.733 ADA | ~66 |
| Stream datum, live, ADA | 127 B | 173 B | 1.435 ADA | ~92 |
| Stream datum, live, one token | 164 B | 257 B | 1.797 ADA | ~62 |
| Same, at a base (script + stake) address | 164 B | 285 B | 1.918 ADA | ~56 |
| Same, settled (`stopped_at` set) | 174 B | 267 B | 1.840 ADA | — |
| Push payout to a base key address, one token, untagged | — | 112 B | 1.172 ADA | — |
| Same, tagged with the stream's out-ref | — | 160 B | 1.379 ADA | — |

**What the numbers mean.**

- A 50-person monthly payroll paid in a token locks about 90 ADA of min-UTxO while each tranche runs.
- A settled output is slightly larger than a live one, so a stop adds a few hundredths of an ADA.
- Builders must size the continuation they are about to create, not reuse the input's ADA.

**Off-chain notes.** These come from preprod runs of a channel contract with the same access pattern: one UTxO that both parties spend, re-created at each step (subbit-x402; see Prior art).

- **Follow your own continuation.** After a claim or a stop, the next action should spend the output your own transaction created (tx hash plus index), rather than re-query an indexer. We measured Blockfrost's index trailing a block by about 20 s. A builder that re-read state inside that window saw a spent UTxO as live; in our case it built a duplicate top-up.
- **Treat "input already spent" as a state change, not an error.** A racing claim or stop won. Re-read, re-plan and retry.

## 8. Prototype, scope and audit tractability

- **Prototype.** A prototype on the library's toolchain (Aiken v1.1.22, stdlib v3.1.0, fuzz v2) reuses #3's `authorization.ak`, `vesting/types.ak` and `vesting/linear.ak` unchanged. It adds the profile: `StreamDatum`, and `Claim`, `Recover` and `Stop`. All 43 tests pass (`aiken check --max-success 1000`):
  - **Both traps as the concrete counterexamples** of §3.2 and §3.3.
  - **Both traps as properties, over 1,000 random cases each:**
    - every same-rate pair loses a recipient share under the rewrite, and none under `settle`;
    - for every stream with something vested, the lower-bound read lets the sender take it and the upper-bound read refuses.
  - **The stop rule exactly:** over 1,000 random streams, stop times and amounts, a stop passes if and only if it leaves at least `vested(c)`.
  - **The batch costs in §3.5.**

  Swapping in either tempting variant makes 12 and 3 of the 43 tests fail, respectively. The reference validator compiles to 2,507 bytes, against 1,404 for #3's `linear_vesting` on the same compiler; the prototype is not optimised.
- **v1, if selected:** #3 plus the following, pull-only, with escrow per stream and payroll as batch-created tranches:
  - `stoppable`;
  - `Stop` (read at the upper bound, settled in place);
  - `stopped_at`;
  - an optional `cliff`.
- **Later variants:**
  - push payouts (Q-PUSH-1);
  - transferable positions (Q-TRANSFER-1);
  - renouncing the stop right (Q-RENOUNCE-1);
  - stepped schedules (Q-STEPS-1).
- **Out of scope:**
  - Pooled payer balances, debt and liquidation (§3.4).
  - Metered pay-per-use streams. These are a payment-channel primitive (off-chain vouchers, on-chain batch redemption), and Subbit.xyz is Cardano prior art for them.
- **Proof delta over #3:** one action and four obligations.
  - **B4, the upper-bound read:** `vested(upper) ≥ vested(actual)`.
  - **Stop completeness.**
  - **Stop soundness:** the sender takes at most `k_d · (T − vested(actual))` per datum.
  - **`settle` injectivity.**

  The claim side is #3's, with `required = 0` for settled datums. The concrete-instance approach in `formal/Formal/Vesting/Linear` should cover it. That includes a two-input stop (as `claim_accept_two_inputs` does for claims), with §3.3's collision as a robustness theorem.

## 9. Open questions

| ID | Question | Current leaning | Status |
|----|----------|-----------------|--------|
| Q-SHAPE-1 | A separate contract, or a stoppable profile of #3's `lib/vesting`? | Profile of #3 | Open |
| Q-TIME-1 | Confirm the per-actor time reads: claim at the lower bound, stop at the upper bound (finite, no interval cap). | Yes | Open |
| Q-SETTLE-1 | Settle in place, or pay out on the stop? | Settle in place | Open |
| Q-CLIFF-1 | A cliff in v1, with "a stop before the cliff pays nothing" documented? | Yes | Open |
| Q-MINADA-1 | Who gets a stream's min-UTxO back: the recipient (as #3's surplus) or the sender (which needs a refund address and a tagged output)? | The recipient in v1; document the cost | Open |
| Q-RECOVERY-1 | Keep #3's `recovery_time` for streams? It lets the sender reclaim earned but unclaimed pay after the grace period. | Keep it, for lost keys, and surface it in UIs | Open |
| Q-PUSH-1 | Permissionless push to a fixed payout address (LlamaPay, OpenZeppelin, Streamflow)? | A later variant, with out-ref-tagged payouts | Open |
| Q-TRANSFER-1 | Transferable positions: a `Credential` plug-in or a `Transfer` action? | Later; the plug-in first | Open |
| Q-RENOUNCE-1 | Let the sender renounce the stop right (Sablier allows it, never the reverse)? The rewritten datum is live and may equal another instance's, so #3's count rule must hold across both actions. | Later | Open |
| Q-STEPS-1 | Stepped schedules (tranches, milestones) as another `vested` shape? | Later; the same remainder rule | Open |
| Q-BATCH-1 | Batches past ~20 stops or claims per transaction (§3.5): coupled withdraw-zero validation, for this profile and for #3's claims? | Needed for payroll-scale batches; design it with #3 | Open |

## 10. Recommendation

**Selected: Later, as a stoppable profile of Linear Vesting (#3) rather than a separate contract. Decline the pooled and open-ended designs.**

- **Not Now.** The tracker already lists five *Selected: Now* candidates (#11, #12, #20, #21, #28), against the roadmap's five contracts. Everything here except `Stop` is #3, so the profile should follow #3 to Ready-to-audit rather than compete with it.
- **Not Never.** Payroll, grants and contributor pay are the treasury needs that #39 names, and none of the Cardano contracts surveyed offers a fair mid-stream stop (§3.6). The delta is small and audit-tractable: one action and four proof obligations, and a prototype that reuses #3's code unchanged already passes both traps' tests (§8).
- **Cheap to do now:**
  - Keep `lib/vesting` reusable for a second profile. For example, a `vested_quantity` that takes an optional cliff, and a remainder rule that takes `required(now)`.
  - Record §3.2's time read and §3.3's injectivity trap in #3's spec, so that a later profile does not have to rediscover them.
  - Note #3's batch-claim ceiling (about 24 instances per transaction for its current checks, §3.5) in its spec or usage guide.
- **Declined within this candidate:** pooled balances, debt and liquidation (LlamaPay, Sablier Flow, Superfluid), for the contention and escrow reasons in §3.4.

## 11. Dependency map

- **Linear Vesting (#3):** the library code, spec and proofs that this extends.
- **Multisig / Smart Wallet (#11):** script senders and recipients, and the NFT-holder authorizer for transfers (§5).
- **DAO (#12):** treasury grants as streams; a natural first consumer.
- **Event-Triggered Assets (#28):** not required; it overlaps only on stepped schedules (§4).
- **DeFi Kernel (#30):** the out-ref tag for push payouts.
- **Revenue / Payment Splitter (#38):** a splitter script as a stream's recipient.

## 12. Prior art (sources)

- **EVM:**
  - Sablier Lockup: [overview](https://docs.sablier.com/concepts/lockup/overview), [shapes](https://docs.sablier.com/concepts/lockup/stream-shapes), [cancelability](https://docs.sablier.com/concepts/cancelability), [NFTs](https://docs.sablier.com/concepts/nft), [`SablierLockup`](https://docs.sablier.com/reference/lockup/contracts/contract.SablierLockup).
  - Sablier Flow: [overview](https://docs.sablier.com/concepts/flow/overview).
  - LlamaPay: [contract](https://github.com/LlamaPay/llamapay/blob/master/contracts/LlamaPay.sol), [README](https://github.com/LlamaPay/llamapay), [debt](https://docs.llamapay.io/outgoing-payments/features/debt).
  - Superfluid: [liquidations](https://docs.superfluid.org/docs/protocol/advanced-topics/solvency/liquidations-and-toga), [glossary](https://docs.superfluid.org/docs/concepts/glossary).
  - OpenZeppelin: [`VestingWallet`](https://docs.openzeppelin.com/contracts/5.x/api/finance).
- **Solana:**
  - Streamflow: [SDK](https://www.npmjs.com/package/@streamflow/stream).
- **Cardano:**
  - contracts-library Linear Vesting: [spec](https://github.com/input-output-hk/contracts-library/blob/main/docs/vesting/spec.md).
  - SundaeSwap [treasury-contracts](https://github.com/SundaeSwap-finance/treasury-contracts), which hold Intersect's treasury payouts (audited by TxPipe and MLabs, per its README). See `lib/logic/vendor/adjudicate.ak` for the 36-hour cap and `withdraw.ak` for the single vendor input.
  - Anastasia Labs: [linear-vesting](https://github.com/Anastasia-Labs/linear-vesting) (`pcountInputsAtScript == 1`) and [design-patterns](https://github.com/Anastasia-Labs/design-patterns).
  - Mesh: [vesting](https://github.com/MeshJS/mesh/tree/main/packages/mesh-contract/src/vesting).
  - fallen-icarus: [cardano-swaps](https://github.com/fallen-icarus/cardano-swaps).
  - Cardano Foundation: [21 common use cases](https://github.com/cardano-foundation/cardano-template-and-ecosystem-monitoring). It lists Vesting and Payment splitter, but no streaming or payroll entry.
  - Kompact.io: [Subbit.xyz](https://github.com/kompact-io/subbit-xyz), usage-metered channels, which are a different primitive. §7's off-chain notes come from preprod runs of [subbit-x402](https://github.com/loveaihq/subbit-x402), which the author maintains.

---

*Written with AI assistance (Claude). §7's sizes come from [`sizing/stream-sizing.mjs`](sizing/stream-sizing.mjs), and §3.5's and §8's results from the prototype's `aiken check --max-success 1000 --seed 39`, both in this repository. Every prior-art claim links its source.*
