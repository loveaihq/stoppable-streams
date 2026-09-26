// Sizes stream UTxOs the way the ledger does, (160 + CBOR bytes of the output) x coinsPerUTxOByte:
// the figures in exploration.md §7. Offline, with evolution-sdk's encoder. Datums follow the Aiken
// encodings of lib/stream/types.ak and contracts-library's VestingDatum: records are Constr 0,
// Credential is Constr 0 (key) / 1 (script), Bool is Constr 0 (False) / 1 (True), and Option is
// Some = Constr 0 [x] / None = Constr 1 [].
import { Address, Assets, Data, InlineDatum, KeyHash, ScriptHash, TxOut } from "@evolution-sdk/evolution";

const CPB = 4310n; // mainnet coinsPerUTxOByte, read from Koios on 2026-09-26
const MAX_TX = 16384; // mainnet maxTxSize, the same day
const OVERHEAD = 400; // bytes left for inputs, change and one signature

const hex = (h) => Uint8Array.from(h.match(/../g).map((b) => parseInt(b, 16)));
const keyCred = (c) => Data.constr(0n, [hex(c.repeat(56))]);
const some = (x) => Data.constr(0n, [x]);
const none = () => Data.constr(1n, []);
const bool = (b) => Data.constr(b ? 1n : 0n, []);
const POLICY = "c48cbb3d5e57ed56e276bc45f99ab39abe94e6cd7ac39fb402da47ad"; // a 28-byte policy id
const NAME = "0014df105553444d"; // CIP-67 (333) "USDM": 8 bytes
const T0 = 1790000000000n; // September 2026 in POSIX ms: CBOR's 9-byte integer form

const asset = (token, total) => Data.constr(0n, [token ? hex(POLICY) : new Uint8Array(), token ? hex(NAME) : new Uint8Array(), total]);
// contracts-library's VestingDatum (#3): beneficiary, locker, vesting, start, end, recovery.
const vestingDatum = (token, total) => Data.constr(0n, [keyCred("a"), keyCred("b"), Data.list([asset(token, total)]), T0, T0 + 2_592_000_000n, T0 + 5_184_000_000n]);
// StreamDatum: beneficiary, locker, vesting, start, cliff, end, recovery, stoppable, stopped_at.
const streamDatum = (token, total, stoppedAt) =>
  Data.constr(0n, [keyCred("a"), keyCred("b"), Data.list([asset(token, total)]), T0, T0, T0 + 2_592_000_000n, T0 + 5_184_000_000n, bool(stoppedAt === undefined), stoppedAt === undefined ? none() : some(stoppedAt)]);

const script = ScriptHash.fromHex("5c".repeat(28));
const scriptAddress = (withStake) => new Address.Address({ networkId: 1, paymentCredential: script, ...(withStake ? { stakingCredential: ScriptHash.fromHex("5e".repeat(28)) } : {}) });
const ada = (l) => (Number(l) / 1e6).toFixed(3);

/** The output's size and min-UTxO. Iterates, since the output's own lovelace is part of its size. */
function sized(address, value, datum) {
  let lovelace = 1_000_000n;
  for (let i = 0; i < 5; i++) {
    const out = new TxOut.TransactionOutput({ address, assets: value(lovelace), ...(datum ? { datumOption: new InlineDatum.InlineDatum({ data: datum }) } : {}) });
    const bytes = TxOut.toCBORBytes(out).length;
    const min = CPB * (160n + BigInt(bytes));
    if (min === lovelace) return { bytes, min };
    lovelace = min;
  }
  throw new Error("did not converge");
}

const adaStream = (amount) => (lovelace) => Assets.fromLovelace(amount > lovelace ? amount : lovelace);
const tokenStream = (amount) => (lovelace) => Assets.fromHexStrings(POLICY, NAME, amount, lovelace);
const rows = [
  ["#3 datum, ADA, enterprise script address", scriptAddress(false), adaStream(100_000_000n), vestingDatum(false, 100_000_000n)],
  ["#3 datum, one token", scriptAddress(false), tokenStream(1_000_000_000n), vestingDatum(true, 1_000_000_000n)],
  ["Stream datum, live, ADA", scriptAddress(false), adaStream(100_000_000n), streamDatum(false, 100_000_000n)],
  ["Stream datum, live, one token", scriptAddress(false), tokenStream(1_000_000_000n), streamDatum(true, 1_000_000_000n)],
  ["Same, at a base (script + stake) address", scriptAddress(true), tokenStream(1_000_000_000n), streamDatum(true, 1_000_000_000n)],
  ["Same, settled (stopped_at set)", scriptAddress(false), tokenStream(1_000_000_000n), streamDatum(true, 1_000_000_000n, T0 + 1_000_000_000n)],
];
console.log("| Output | Datum | Output | Min-UTxO | Streams per tx |");
console.log("|---|---:|---:|---:|---:|");
for (const [what, address, value, datum] of rows) {
  const { bytes, min } = sized(address, value, datum);
  // A payroll run creates live streams; settled ones only come out of stops.
  const perTx = what.includes("settled") ? "—" : `~${Math.floor((MAX_TX - OVERHEAD) / bytes)}`;
  console.log(`| ${what} | ${Data.toCBORBytes(datum).length} B | ${bytes} B | ${ada(min)} ADA | ${perTx} |`);
}

// Push payouts: an output at the recipient's own address, optionally tagged with the stream's out-ref.
const payee = new Address.Address({ networkId: 1, paymentCredential: KeyHash.fromHex("ab".repeat(28)), stakingCredential: KeyHash.fromHex("cd".repeat(28)) });
const outRef = Data.constr(0n, [hex("ef".repeat(32)), 0n]);
for (const [what, datum] of [["Push payout to a base key address, one token, untagged", undefined], ["Same, tagged with the stream's out-ref", outRef]]) {
  const { bytes, min } = sized(payee, tokenStream(50_000_000n), datum);
  console.log(`| ${what} | — | ${bytes} B | ${ada(min)} ADA | — |`);
}
