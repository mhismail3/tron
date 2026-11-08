#!/usr/bin/env node
// Purpose: differential oracle for block schedule/occurrence: the compiled core (Dafny-emitted JS) against the
// shipped TypeScript it models, packages/gateway/src/automations/schedule.ts (nextAutomationOccurrence,
// firstAutomationOccurrence, classifyDueOccurrence): on seeded generated inputs, or, with --replay, on recorded
// Debug traffic (tron-proof-traffic/1 records: the TypeScript's own inputs and outputs, tools/proof/README.md).
// Usage: node tools/proof/oracles/schedule-occurrence.mjs <compiled core.js> [count=20000] [seed=7]
//        node tools/proof/oracles/schedule-occurrence.mjs <compiled core.js> --replay <corpus.jsonl>...
// Prints {requests, agree, diffs (first 5)}; exit 0 iff every request agrees, 1 on a mismatch, 2 on a corpus
// it cannot read (malformed line, other schema, block or seam).
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const oracle = await import(join(REPO, "packages/gateway/src/automations/schedule.ts"));
const [corePath, countArg, seedArg, ...replayFiles] = process.argv.slice(2);
if (!corePath) { console.error("usage: schedule-occurrence.mjs <compiled core.js> [count] [seed] | --replay <corpus.jsonl>..."); process.exit(2); }
const replay = countArg === "--replay";
const count = Number(countArg ?? 20000);
let seed = Number(seedArg ?? 7);

// The compiled core under test, called through its generated façade with requests in the core's own shapes.
const { load } = await import(join(REPO, "packages/core/dist/schedule/occurrence/facade.ts"));
const core = load(resolve(corePath));
function candidate(q) {
  if (q.op === "next") return core.Next(q.trigger, q.after);
  if (q.op === "first") return core.First(q.trigger, q.now);
  return core.Classify(q.trigger, q.next, q.now, q.policy);
}

// The core's shapes of the shipped TypeScript's values.
const fromTs = (t) => (t.kind === "once" ? { $: "Once", at: Date.parse(t.at) }
  : t.kind === "interval" ? { $: "Interval", anchor: Date.parse(t.anchorAt), every: t.everySeconds * 1000 } : null);
const ms = (s) => (s === undefined || s === null ? { $: "None" } : { $: "Some", v: Date.parse(s) });

if (replay) {
  // Recorded calls: the recorded TypeScript output is the expectation; the core gets the same inputs.
  const files = [seedArg, ...replayFiles].filter(Boolean);
  const requests = [];
  for (const file of files) {
    readFileSync(file, "utf8").split("\n").forEach((line, i) => {
      if (!line) return;
      let r; try { r = JSON.parse(line); } catch { console.error(`${file}:${i + 1}: not JSON`); process.exit(2); }
      if (r.schema !== "tron-proof-traffic/1" || r.block !== "schedule/occurrence" || !["next", "first", "classify"].includes(r.seam) || !fromTs(r.input?.trigger ?? {})) {
        console.error(`${file}:${i + 1}: not a schedule/occurrence tron-proof-traffic/1 record`); process.exit(2);
      }
      requests.push({ where: `${file}:${i + 1}`, record: r });
    });
  }
  let agree = 0; const diffs = [];
  for (const { where, record } of requests) {
    const { seam, input, output } = record;
    const t = fromTs(input.trigger);
    const got = seam === "next" ? core.Next(t, input.afterMs) : seam === "first" ? core.First(t, input.nowMs)
      : core.Classify(t, Date.parse(input.nextOccurrenceAt), input.nowMs, input.policy === "latest" ? "Latest" : "Skip");
    if (seam === "classify" && (output?.skipped ?? []).length > 1) { console.error(`${where}: more than one skipped occurrence`); process.exit(2); }
    const want = seam === "classify" ? { dispatchAt: ms(output?.dispatchAt), next: ms(output?.nextOccurrenceAt), skipped: ms(output?.skipped?.[0]) } : ms(output);
    if (JSON.stringify(want) === JSON.stringify(got)) agree++;
    else if (diffs.length < 5) diffs.push({ where, seam, input, want, got });
  }
  console.log(JSON.stringify({ requests: requests.length, agree, diffs }, null, 1));
  process.exit(requests.length > 0 && agree === requests.length ? 0 : 1);
}

// Inputs: triggers near and far from their reference time, periods from 1 s to a week (including odd ones),
// stored next occurrences that are usually real occurrences and sometimes arbitrary.
const rnd = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
const int = (lo, hi) => lo + Math.floor(rnd() * (hi - lo + 1));
const BASE = 1_600_000_000_000;
function generated() {
  if (rnd() < 0.3) return { $: "Once", at: BASE + int(0, 4e9) };
  return { $: "Interval", anchor: BASE + int(0, 4e9), every: 1000 * [1, 60, 3600, 86400, 7, 13, 604800][int(0, 6)] };
}
const requests = [];
for (let i = 0; i < count; i++) {
  const t = generated();
  const ref = t.$ === "Once" ? t.at : t.anchor;
  const near = ref + int(-3, 3) * (t.every ?? 1000) + int(-2, 2);
  const after = rnd() < 0.5 ? near : BASE + int(0, 5e9);
  const r = rnd();
  if (r < 0.35) requests.push({ op: "next", trigger: t, after });
  else if (r < 0.5) requests.push({ op: "first", trigger: t, now: after });
  else {
    let nxt = t.$ === "Once" ? t.at : t.anchor + int(0, 50) * t.every;
    if (rnd() < 0.1) nxt += int(1, 999);
    const now = rnd() < 0.2 ? nxt - int(1, 5000) : nxt + int(0, 200) * (t.every ?? 1000) + int(0, 999);
    requests.push({ op: "classify", trigger: t, next: nxt, now, policy: rnd() < 0.5 ? "Latest" : "Skip" });
  }
}
// The shipped TypeScript's shapes (ISO timestamps, seconds, lowercase policies), and its results in the core's.
const toOracle = (t) => (t.$ === "Once" ? { kind: "once", at: new Date(t.at).toISOString() }
  : { kind: "interval", anchorAt: new Date(t.anchor).toISOString(), everySeconds: t.every / 1000 });
const opt = ms;
function expected(q) {
  const t = toOracle(q.trigger);
  if (q.op === "next") return opt(oracle.nextAutomationOccurrence(t, q.after));
  if (q.op === "first") return opt(oracle.firstAutomationOccurrence(t, q.now));
  const r = oracle.classifyDueOccurrence(t, new Date(q.next).toISOString(), q.now, q.policy.toLowerCase());
  if (r.skipped.length > 1) throw new Error("oracle skipped more than one occurrence");
  return { dispatchAt: opt(r.dispatchAt), next: opt(r.nextOccurrenceAt), skipped: opt(r.skipped[0]) };
}
let agree = 0; const diffs = [];
for (const q of requests) {
  const want = expected(q), got = candidate(q);
  if (JSON.stringify(want) === JSON.stringify(got)) agree++;
  else if (diffs.length < 5) diffs.push({ req: q, want, got });
}
console.log(JSON.stringify({ requests: requests.length, agree, diffs }, null, 1));
process.exitCode = agree === requests.length ? 0 : 1;
