#!/usr/bin/env node
// Purpose: differential oracle for block receipts/invocation-lifecycle. It compares the compiled core (Dafny-emitted JS)
// with the shipped TypeScript it models, packages/gateway/src/kernel/receipts/invocation-receipts.ts
// (invocationProjection), on seeded generated receipt histories or, with --replay, on recorded Debug traffic
// (tron-proof-traffic/1 records of block receipts/invocation-lifecycle). Generated histories hold a few
// invocations whose receipts are mostly legal moves, with duplicate and contradictory terminals, receipts before
// their start, foreign operations, renamed resources, changed origins and repeated bindings mixed in; every receipt
// is one makeInvocationReceipt accepts. The core gets the facts the shell's own invocationLifecycleFacts builds
// (the seam's record), and its invocations are put in the TypeScript's order (by start sequence, stable), which
// the shell owns (block Assumption A2).
// Usage: node tools/proof/oracles/receipts-invocation-lifecycle.mjs <compiled core.js> [count=5000] [seed=9]
//        node tools/proof/oracles/receipts-invocation-lifecycle.mjs <compiled core.js> --replay <corpus.jsonl>...
// Prints {requests, agree, refused, diffs (first 5)}; exit 0 iff every request agrees, 1 on a mismatch, 2 on a
// corpus it cannot read.
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { importGatewaySource } from "./gateway-source.mjs";

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
// The receipts seam records on an opted-in Debug Gateway; an oracle run must never add its own calls to that corpus.
delete process.env.TRON_PROOF_TRAFFIC;
const { invocationProjection, invocationLifecycleFacts, invocationRefusalCode, makeInvocationReceipt } = await importGatewaySource("kernel/receipts/invocation-receipts.ts");
const [corePath, countArg, seedArg] = process.argv.slice(2);
if (!corePath) { console.error("usage: receipts-invocation-lifecycle.mjs <compiled core.js> [count] [seed] | --replay <corpus.jsonl>..."); process.exit(2); }
const replay = countArg === "--replay";

const { load } = await import(join(REPO, "packages/core/dist/receipts/invocation-lifecycle/facade.ts"));
const core = load(resolve(corePath));

const SOURCES = ["plain", "skill", "prompt", "extension", "subagentWake", "homeWake"];
const KINDS = ["start", "transition", "terminal", "binding"];
const LIVES = ["staged", "accepted", "queued", "running", "waitingForInput", "retrying", "settling", "completed", "failed", "interrupted", "outcomeUnknown"];
const up = (s) => s[0].toUpperCase() + s.slice(1);
const opt = (t) => (t === null ? { $: "None" } : { $: "Some", v: t });
const toCore = (r) => ({ inv: r.inv, op: r.op, src: SOURCES.indexOf(r.src), kind: up(r.kind), life: r.life === null ? { $: "NoLife" } : { $: "LifeOf", l: up(r.life) },
  name: opt(r.name), origin: opt(r.origin), entry: opt(r.entry), retryable: r.retryable === null ? { $: "NoFlag" } : { $: "FlagOf", b: r.retryable },
  sequence: r.sequence, at: r.at });
const fromOpt = (o) => (o.$ === "None" ? null : o.v);
// shift moves every invocation, operation and entry token (an order-preserving renaming, so the result is the same
// up to the shift): sparse tokens and tokens past the core's array limit take its other paths.
function result(input, shift = 0) {
  const moved = (t) => (t === null ? null : t + shift);
  const outcome = core.Project(input.map((r) => toCore({ ...r, inv: r.inv + shift, op: r.op + shift, entry: moved(r.entry) })));
  if (outcome.$ === "Rejected") return { refused: outcome.why };
  const projections = outcome.projs.map((p, i) => ({ p, i })).sort((a, b) => a.p.sequence - b.p.sequence || a.i - b.i).map(({ p }) => ({
    inv: p.inv - shift, op: p.op - shift, src: SOURCES[p.src], name: fromOpt(p.name), origin: fromOpt(p.origin), life: p.life[0].toLowerCase() + p.life.slice(1),
    entry: p.entry.$ === "None" ? null : p.entry.v - shift, retryable: p.retryable.$ === "NoFlag" ? null : p.retryable.b, sequence: p.sequence, updated: p.updated }));
  return { projections };
}

let requests = 0, agree = 0, refused = 0; const diffs = [];
const compare = (where, input, want, got) => {
  requests++;
  if ("refused" in want) refused++;
  if (JSON.stringify(want) === JSON.stringify(got)) agree++;
  else if (diffs.length < 5) diffs.push({ where, input, want, got });
};

if (replay) {
  const token = (v) => Number.isSafeInteger(v) && v >= 0;
  const optToken = (v) => v === null || token(v);
  const okReceipt = (r) => r && token(r.inv) && token(r.op) && SOURCES.includes(r.src) && KINDS.includes(r.kind)
    && (r.life === null || LIVES.includes(r.life)) && optToken(r.name) && optToken(r.origin) && optToken(r.entry)
    && (r.retryable === null || typeof r.retryable === "boolean") && Number.isSafeInteger(r.sequence) && token(r.at) && Object.keys(r).length === 11;
  const okProjection = (p) => p && token(p.inv) && token(p.op) && SOURCES.includes(p.src) && optToken(p.name) && optToken(p.origin)
    && LIVES.includes(p.life) && optToken(p.entry) && (p.retryable === null || typeof p.retryable === "boolean")
    && Number.isSafeInteger(p.sequence) && token(p.updated) && Object.keys(p).length === 10;
  const okOutput = (o) => o && ((typeof o.refused === "string" && Object.keys(o).length === 1)
    || (Array.isArray(o.projections) && o.projections.every(okProjection) && Object.keys(o).length === 1));
  for (const file of process.argv.slice(4)) {
    const day = /(\d{4}-\d{2}-\d{2})\.jsonl$/.exec(file)?.[1];
    let text;
    try { text = readFileSync(file, "utf8"); } catch (error) { console.error(`${file}: ${error.message}`); process.exit(2); }
    text.split("\n").forEach((line, n) => {
      if (!line) return;
      const refuse = (why) => { console.error(`${file}:${n + 1}: ${why}`); process.exit(2); };
      let r; try { r = JSON.parse(line); } catch { refuse("not JSON"); }
      if (r?.schema !== "tron-proof-traffic/1" || r.block !== "receipts/invocation-lifecycle" || r.seam !== "project") refuse("not a receipts/invocation-lifecycle tron-proof-traffic/1 record");
      if (!Number.isSafeInteger(r.seq) || typeof r.at !== "string" || Number.isNaN(Date.parse(r.at)) || new Date(Date.parse(r.at)).toISOString() !== r.at
        || (day && r.at.slice(0, 10) !== day) || !("output" in r)) refuse("seq, at (on the file's day) or output missing or malformed");
      if (!Array.isArray(r.input) || !r.input.every(okReceipt) || !okOutput(r.output)) refuse("input or output is not what the seam records");
      compare(`${file}:${n + 1}`, r.input, r.output, result(r.input));
    });
  }
} else {
  const count = Number(countArg ?? 5000);
  let seed = Number(seedArg ?? 9);
  // mulberry32: exact 32-bit integer steps (a floating-point LCG loses precision and falls into a short cycle).
  const rnd = () => { seed = (seed + 0x6d2b79f5) | 0; let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
  const int = (lo, hi) => lo + Math.floor(rnd() * (hi - lo + 1));
  const pick = (xs) => xs[int(0, xs.length - 1)];
  const NEXT = { staged: ["accepted", "running", "queued"], accepted: ["queued", "running"], queued: ["running", "settling"], running: ["waitingForInput", "retrying", "settling"],
    waitingForInput: ["running"], retrying: ["running"], settling: ["settling"] };
  const TERMINALS = ["completed", "failed", "interrupted", "outcomeUnknown"];
  const ORIGINS = [{ kind: "user", confidence: "receipt" }, { kind: "extension", confidence: "receipt" }, { confidence: "receipt", kind: "user" }];
  for (let i = 0; i < count; i++) {
    let n = 0;
    const invs = Array.from({ length: int(1, 3) }, (_, k) => ({ id: `i${k}`, op: `o${k}`, src: pick(SOURCES), life: "staged", started: false, done: false, seq: int(0, 2) }));
    const receipts = [];
    const make = (inv, fields) => {
      const named = !["plain", "subagentWake", "homeWake"].includes(inv.src);
      const base = { receiptId: `r${n}`, version: 1, invocationId: inv.id, operationId: rnd() < 0.03 ? "foreign" : inv.op, sessionId: "s",
        source: rnd() < 0.02 ? pick(SOURCES) : inv.src, sequence: inv.seq, createdAt: new Date(1_800_000_000_000 + int(0, 3) * 1000).toISOString() };
      n++;
      try { receipts.push(makeInvocationReceipt({ ...base, ...fields(named) })); } catch { /* a shape the grammar refuses is not a receipt */ }
    };
    for (let step = 0; step < int(1, 10); step++) {
      const inv = pick(invs);
      const r = rnd();
      if (!inv.started || r < 0.05) {
        if (rnd() < 0.1 && !inv.started) { make(inv, () => ({ receiptKind: "transition", lifecycle: "running" })); continue; }
        inv.started = true;
        make(inv, (named) => ({ receiptKind: "start", lifecycle: "staged", origin: pick(ORIGINS), ...(named ? { name: "tool" } : {}) }));
      } else if (r < 0.5) {
        const to = rnd() < 0.85 ? pick(NEXT[inv.life] ?? ["running"]) : pick(LIVES.slice(1, 7));
        if (rnd() < 0.85 || inv.done) inv.life = to;
        make(inv, () => ({ receiptKind: "transition", lifecycle: to }));
      } else if (r < 0.75) {
        const to = inv.done && rnd() < 0.6 ? inv.life : pick(TERMINALS);
        inv.life = to; inv.done = true;
        make(inv, (named) => ({ receiptKind: "terminal", lifecycle: to, ...(rnd() < 0.5 ? { retryable: rnd() < 0.5 } : {}),
          ...(rnd() < 0.2 ? { origin: pick(ORIGINS) } : {}), ...(named && rnd() < 0.3 ? { name: rnd() < 0.8 ? "tool" : "other" } : {}) }));
      } else {
        make(inv, () => ({ receiptKind: "binding", canonicalEntryId: pick(["e0", "e1", "e2"]) }));
      }
    }
    let ts;
    try { ts = { projections: invocationProjection(receipts) }; } catch (error) { ts = { refused: error }; }
    const facts = invocationLifecycleFacts(receipts, "refused" in ts ? { refused: invocationRefusalCode(ts.refused) } : ts);
    // Most histories use the shell's dense tokens; some are shifted sparse (below the core's array limit) or past it.
    compare(`generated ${i}`, facts.input, facts.output, result(facts.input, i % 20 === 7 ? 50_000 : i % 20 === 13 ? 1_048_576 : 0));
  }
}
console.log(JSON.stringify({ requests, agree, refused, diffs }, null, 1));
process.exitCode = requests > 0 && agree === requests ? 0 : 1;
