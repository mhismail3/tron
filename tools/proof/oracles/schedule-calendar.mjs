#!/usr/bin/env node
// Purpose: differential oracle for block schedule/calendar. It compares the compiled core (Dafny-emitted JS), fed the zone table
// that packages/gateway/src/automations/zone-table.ts builds from Intl, with the shipped calendar TypeScript in
// packages/gateway/src/automations/schedule.ts (nextAutomationOccurrence, firstAutomationOccurrence,
// classifyDueOccurrence for calendar triggers). It runs on seeded generated inputs (zones with and without
// daylight saving, half-hour and 45-minute offsets, times near offset changes, night-time local times), or,
// with --replay, on recorded Debug traffic (tron-proof-traffic/1 records of block schedule/calendar).
// Usage: node tools/proof/oracles/schedule-calendar.mjs <compiled core.js> [count=3000] [seed=11]
//        node tools/proof/oracles/schedule-calendar.mjs <compiled core.js> --replay <corpus.jsonl>...
// Prints {requests, agree, tsRefused, diffs (first 5)}. tsRefused counts generated requests the TypeScript
// throws on; those are not compared, because a throw is never recorded on real traffic.
// Exit 0 iff every compared request agrees, 1 on a mismatch, 2 on a corpus it cannot read.
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { importGatewaySource } from "./gateway-source.mjs";

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
// The schedule seams record on an opted-in Debug Gateway; an oracle run must never add its own calls to that corpus.
delete process.env.TRON_PROOF_TRAFFIC;
const oracle = await importGatewaySource("automations/schedule.ts");
const { zoneTable } = await importGatewaySource("automations/zone-table.ts");
const [corePath, countArg, seedArg] = process.argv.slice(2);
if (!corePath) { console.error("usage: schedule-calendar.mjs <compiled core.js> [count] [seed] | --replay <corpus.jsonl>..."); process.exit(2); }
const replay = countArg === "--replay";
const count = Number(countArg ?? 3000);
let seed = Number(seedArg ?? 11);

const { load } = await import(join(REPO, "packages/core/dist/schedule/calendar/facade.ts"));
const core = load(resolve(corePath));

// The core's shapes of the shipped TypeScript's values: the calendar (minute of day, weekdays), the zone
// around the instant asked about, and the results as optional instants.
const calendar = (t) => { const [h, m] = t.localTime.split(":").map(Number); return { minute: h * 60 + m, weekdays: [...t.weekdays] }; };
const ms = (s) => (s === undefined || s === null ? { $: "None" } : { $: "Some", v: Date.parse(s) });
function candidate(seam, trigger, input) {
  const c = calendar(trigger);
  if (seam === "next") return core.Next(zoneTable(trigger.timezone, input.afterMs), c, input.afterMs);
  if (seam === "first") return core.First(zoneTable(trigger.timezone, input.nowMs), c, input.nowMs);
  const policy = input.policy === "latest" ? "Latest" : "Skip";
  return core.Classify(zoneTable(trigger.timezone, input.nowMs), c, Date.parse(input.nextOccurrenceAt), input.nowMs, policy);
}
const want = (seam, output) => (seam === "classify"
  ? { dispatchAt: ms(output.dispatchAt), next: ms(output.nextOccurrenceAt), skipped: ms(output.skipped[0]) } : ms(output));

const requests = [];
if (replay) {
  const files = process.argv.slice(4);
  // Exactly the records the recorder writes for this block; anything else is refused (exit 2), never compared.
  const iso = (v) => typeof v === "string" && !Number.isNaN(Date.parse(v)) && new Date(Date.parse(v)).toISOString() === v;
  const integer = (v) => Number.isSafeInteger(v);
  // The calendar trigger shape the automation contract admits (automation-contract.ts admitsAutomationTrigger).
  const okTrigger = (t) => t?.kind === "calendar" && Object.keys(t).length === 4 && typeof t.timezone === "string"
    && typeof t.localTime === "string" && /^(?:[01]\d|2[0-3]):[0-5]\d$/u.test(t.localTime) && Array.isArray(t.weekdays)
    && t.weekdays.length > 0 && t.weekdays.every((d) => Number.isSafeInteger(d) && d >= 1 && d <= 7)
    && new Set(t.weekdays).size === t.weekdays.length;
  const okInput = (seam, i) => i && okTrigger(i.trigger) && (seam === "next" ? integer(i.afterMs) && Object.keys(i).length === 2
    : seam === "first" ? integer(i.nowMs) && Object.keys(i).length === 2
    : typeof i.nextOccurrenceAt === "string" && Number.isFinite(Date.parse(i.nextOccurrenceAt)) && integer(i.nowMs)
      && ["latest", "skip"].includes(i.policy) && Object.keys(i).length === 4);
  const okOutput = (seam, o) => (seam === "classify"
    ? o && typeof o === "object" && Array.isArray(o.skipped) && o.skipped.length <= 1 && o.skipped.every(iso)
      && (o.dispatchAt === undefined || iso(o.dispatchAt)) && (o.nextOccurrenceAt === undefined || iso(o.nextOccurrenceAt))
      && Object.keys(o).every((k) => ["dispatchAt", "nextOccurrenceAt", "skipped"].includes(k))
    : o === null || iso(o));
  for (const file of files) {
    const day = /(\d{4}-\d{2}-\d{2})\.jsonl$/.exec(file)?.[1];
    let text;
    try { text = readFileSync(file, "utf8"); } catch (error) { console.error(`${file}: ${error.message}`); process.exit(2); }
    text.split("\n").forEach((line, i) => {
      if (!line) return;
      const refuse = (why) => { console.error(`${file}:${i + 1}: ${why}`); process.exit(2); };
      let r; try { r = JSON.parse(line); } catch { refuse("not JSON"); }
      if (r?.schema !== "tron-proof-traffic/1" || r.block !== "schedule/calendar" || !["next", "first", "classify"].includes(r.seam)) refuse("not a schedule/calendar tron-proof-traffic/1 record");
      if (!integer(r.seq) || !iso(r.at) || (day && r.at.slice(0, 10) !== day) || !("output" in r)) refuse("seq, at (on the file's day) or output missing or malformed");
      if (!okInput(r.seam, r.input) || !okOutput(r.seam, r.output)) refuse(`${r.seam} input or output is not what the seam records`);
      requests.push({ where: `${file}:${i + 1}`, seam: r.seam, input: r.input, expected: want(r.seam, r.output) });
    });
  }
} else {
  // Generated: zones with daylight saving on both hemispheres, fractional offsets, a 30-minute DST (Lord Howe),
  // a +2 h DST (Troll), a skipped date (Apia, 2011-12-30) and fixed zones; instants across 1995-2040, half of
  // them within two days of one of the zone's offset changes; local times biased to the night, where changes are.
  const ZONES = ["America/New_York", "Europe/London", "Europe/Berlin", "Australia/Sydney", "Australia/Lord_Howe",
    "America/Santiago", "America/St_Johns", "Asia/Kathmandu", "Pacific/Chatham", "Antarctica/Troll", "Pacific/Apia",
    "Asia/Tokyo", "UTC", "America/Sao_Paulo", "Africa/Casablanca", "Asia/Tehran", "Pacific/Kiritimati", "America/Havana"];
  const rnd = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
  const int = (lo, hi) => lo + Math.floor(rnd() * (hi - lo + 1));
  const DAY = 86_400_000;
  const pad = (n) => String(n).padStart(2, "0");
  for (let i = 0; i < count; i++) {
    const timezone = ZONES[int(0, ZONES.length - 1)];
    const minute = rnd() < 0.5 ? int(0, 1439) : [int(0, 240), int(1380, 1439), int(110, 190)][int(0, 2)];
    const weekdays = [1, 2, 3, 4, 5, 6, 7].filter(() => rnd() < 0.4);
    if (weekdays.length === 0) weekdays.push(int(1, 7));
    const trigger = { kind: "calendar", timezone, localTime: `${pad(Math.floor(minute / 60))}:${pad(minute % 60)}`, weekdays };
    let at = Date.UTC(1995, 0, 1) + int(0, 45 * 365) * DAY + int(0, DAY - 1);
    if (timezone === "Pacific/Apia" && rnd() < 0.3) at = Date.UTC(2011, 11, 29) + int(-10, 10) * DAY + int(0, DAY - 1);
    if (rnd() < 0.5) {
      const changes = zoneTable(timezone, at).changes;
      if (changes.length) at = changes[int(0, changes.length - 1)].at + int(-2 * DAY, 2 * DAY);
    }
    if (rnd() < 0.3) at = Math.floor(at / 60_000) * 60_000 + [0, -1, 1][int(0, 2)];
    const r = rnd();
    if (r < 0.35) requests.push({ seam: "next", trigger, input: { trigger, afterMs: at } });
    else if (r < 0.5) requests.push({ seam: "first", trigger, input: { trigger, nowMs: at } });
    else {
      const nxt = at + int(-20 * DAY, 2 * DAY);
      requests.push({ seam: "classify", trigger, input: { trigger, nextOccurrenceAt: new Date(nxt).toISOString(), nowMs: at, policy: rnd() < 0.5 ? "latest" : "skip" } });
    }
  }
}

let agree = 0, tsRefused = 0; const diffs = [];
for (const q of requests) {
  const { seam, input } = q;
  let expected = q.expected;
  if (!replay) {
    try {
      expected = want(seam, seam === "next" ? oracle.nextAutomationOccurrence(input.trigger, input.afterMs)
        : seam === "first" ? oracle.firstAutomationOccurrence(input.trigger, input.nowMs)
        : oracle.classifyDueOccurrence(input.trigger, input.nextOccurrenceAt, input.nowMs, input.policy));
    } catch { tsRefused++; continue; }
  }
  const got = candidate(seam, input.trigger, input);
  if (JSON.stringify(expected) === JSON.stringify(got)) agree++;
  else if (diffs.length < 5) diffs.push({ where: q.where, seam, input, want: expected, got });
}
const compared = requests.length - tsRefused;
console.log(JSON.stringify({ requests: compared, agree, tsRefused, diffs }, null, 1));
process.exitCode = compared > 0 && agree === compared ? 0 : 1;
