#!/usr/bin/env node
// Purpose: differential oracle for block schedule/occurrence: the compiled core (Dafny-emitted JS) against the
// shipped TypeScript it models, packages/gateway/src/automations/schedule.ts (nextAutomationOccurrence,
// firstAutomationOccurrence, classifyDueOccurrence), on seeded generated inputs (not real traffic).
// Usage: node tools/proof/oracles/schedule-occurrence.mjs <compiled core.js> [count=20000] [seed=7]
// Prints {requests, agree, diffs (first 5)}; exit 0 iff every request agrees.
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const oracle = await import(join(REPO, "packages/gateway/src/automations/schedule.ts"));
const [corePath, countArg, seedArg] = process.argv.slice(2);
if (!corePath) { console.error("usage: schedule-occurrence.mjs <compiled core.js> [count] [seed]"); process.exit(2); }
const count = Number(countArg ?? 20000);
let seed = Number(seedArg ?? 7);

// Marshalling between the TS shapes and the emitted datatypes (BigNumber integers). The generated façade
// (#2345) replaces this.
const require = createRequire(join(REPO, "packages/core/package.json"));
const { ScheduleOccurrence: Core, BigNumber } = new Function("require", `${readFileSync(resolve(corePath), "utf8")}\nreturn { ScheduleOccurrence, BigNumber };`)(require);
const B = (n) => new BigNumber(n);
const opt = (o) => (o.is_Some ? o.dtor_v.toNumber() : null);
const trigger = (t) => (t.kind === "once" ? Core.Trigger.create_Once(B(t.at)) : Core.Trigger.create_Interval(B(t.anchor), B(t.every)));
const policy = (p) => (p === "latest" ? Core.Policy.create_Latest() : Core.Policy.create_Skip());
function candidate(q) {
  if (q.op === "next") return opt(Core.__default.Next(trigger(q.trigger), B(q.after)));
  if (q.op === "first") return opt(Core.__default.First(trigger(q.trigger), B(q.now)));
  const r = Core.__default.Classify(trigger(q.trigger), B(q.next), B(q.now), policy(q.policy));
  return { dispatchAt: opt(r.dtor_dispatchAt), next: opt(r.dtor_next), skipped: opt(r.dtor_skipped) };
}

// Inputs: triggers near and far from their reference time, periods from 1 s to a week (including odd ones),
// stored next occurrences that are usually real occurrences and sometimes arbitrary.
const rnd = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
const int = (lo, hi) => lo + Math.floor(rnd() * (hi - lo + 1));
const BASE = 1_600_000_000_000;
function generated() {
  if (rnd() < 0.3) return { kind: "once", at: BASE + int(0, 4e9) };
  return { kind: "interval", anchor: BASE + int(0, 4e9), every: 1000 * [1, 60, 3600, 86400, 7, 13, 604800][int(0, 6)] };
}
const requests = [];
for (let i = 0; i < count; i++) {
  const t = generated();
  const ref = t.kind === "once" ? t.at : t.anchor;
  const near = ref + int(-3, 3) * (t.every ?? 1000) + int(-2, 2);
  const after = rnd() < 0.5 ? near : BASE + int(0, 5e9);
  const r = rnd();
  if (r < 0.35) requests.push({ op: "next", trigger: t, after });
  else if (r < 0.5) requests.push({ op: "first", trigger: t, now: after });
  else {
    let nxt = t.kind === "once" ? t.at : t.anchor + int(0, 50) * t.every;
    if (rnd() < 0.1) nxt += int(1, 999);
    const now = rnd() < 0.2 ? nxt - int(1, 5000) : nxt + int(0, 200) * (t.every ?? 1000) + int(0, 999);
    requests.push({ op: "classify", trigger: t, next: nxt, now, policy: rnd() < 0.5 ? "latest" : "skip" });
  }
}
const toOracle = (t) => (t.kind === "once" ? { kind: "once", at: new Date(t.at).toISOString() }
  : { kind: "interval", anchorAt: new Date(t.anchor).toISOString(), everySeconds: t.every / 1000 });
const iso = (s) => (s === undefined ? null : Date.parse(s));
function expected(q) {
  const t = toOracle(q.trigger);
  if (q.op === "next") return iso(oracle.nextAutomationOccurrence(t, q.after));
  if (q.op === "first") return iso(oracle.firstAutomationOccurrence(t, q.now));
  const r = oracle.classifyDueOccurrence(t, new Date(q.next).toISOString(), q.now, q.policy);
  if (r.skipped.length > 1) throw new Error("oracle skipped more than one occurrence");
  return { dispatchAt: iso(r.dispatchAt), next: iso(r.nextOccurrenceAt), skipped: r.skipped.length ? Date.parse(r.skipped[0]) : null };
}
let agree = 0; const diffs = [];
for (const q of requests) {
  const want = expected(q), got = candidate(q);
  if (JSON.stringify(want) === JSON.stringify(got)) agree++;
  else if (diffs.length < 5) diffs.push({ req: q, want, got });
}
console.log(JSON.stringify({ requests: requests.length, agree, diffs }, null, 1));
process.exitCode = agree === requests.length ? 0 : 1;
