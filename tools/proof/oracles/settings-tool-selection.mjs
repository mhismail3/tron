#!/usr/bin/env node
// Purpose: differential oracle for block settings/tool-selection. It compares the compiled core (Dafny-emitted JS) with the
// shipped TypeScript it models, packages/gateway/src/kernel/settings/settings-types.ts (toolSelectionType().compose
// and .encode), on seeded generated inputs or, with --replay, on recorded Debug traffic (tron-proof-traffic/1
// records of block settings/tool-selection). Generated inputs mix plain names, +name/-name modifiers, repeats and
// the empty name over no selection below, a non-list below and lists below; the core gets the facts the shell's own
// toolSelectionFacts builds (the seam's record input).
// Usage: node tools/proof/oracles/settings-tool-selection.mjs <compiled core.js> [count=20000] [seed=5]
//        node tools/proof/oracles/settings-tool-selection.mjs <compiled core.js> --replay <corpus.jsonl>...
// Prints {requests, agree, diffs (first 5)}; exit 0 iff every request agrees, 1 on a mismatch, 2 on a corpus
// it cannot read.
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { importGatewaySource } from "./gateway-source.mjs";
import { mulberry32 } from "./random.mjs";

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
// The settings seams record on an opted-in Debug Gateway; an oracle run must never add its own calls to that corpus.
delete process.env.TRON_PROOF_TRAFFIC;
const { toolSelectionType, toolSelectionFacts } = await importGatewaySource("kernel/settings/settings-types.ts");
const [corePath, countArg, seedArg] = process.argv.slice(2);
if (!corePath) { console.error("usage: settings-tool-selection.mjs <compiled core.js> [count] [seed] | --replay <corpus.jsonl>..."); process.exit(2); }
const replay = countArg === "--replay";

const { load } = await import(join(REPO, "packages/core/dist/settings/tool-selection/facade.ts"));
const core = load(resolve(corePath));

const KIND = { plain: "Plain", plus: "Plus", minus: "Minus" };
const entry = (e) => ({ $: KIND[e.kind], n: e.name });
const below = (b) => (b === null ? { $: "NoBelow" } : { $: "Names", names: b });
const back = (e) => ({ kind: e.$.toLowerCase(), name: e.n });
function result(seam, f) {
  if (seam === "compose") return [...core.Compose(below(f.below), f.entries.map(entry), f.defaults)];
  const held = core.Encode(f.chosen.map(entry), below(f.below), f.current.map(entry), f.defaults);
  return held.$ === "Nothing" ? null : held.entries.map(back);
}

let requests = 0, agree = 0; const diffs = [];
const compare = (where, seam, input, want, got) => {
  requests++;
  if (JSON.stringify(want) === JSON.stringify(got)) agree++;
  else if (diffs.length < 5) diffs.push({ where, seam, input, want, got });
};

if (replay) {
  const token = (v) => Number.isSafeInteger(v) && v >= 0;
  const tokens = (v) => Array.isArray(v) && v.every(token);
  const entries = (v) => Array.isArray(v) && v.every((e) => e && Object.keys(KIND).includes(e.kind) && token(e.name) && Object.keys(e).length === 2);
  const okInput = (seam, i) => i && (i.below === null || tokens(i.below)) && tokens(i.defaults) && (seam === "compose"
    ? entries(i.entries) && Object.keys(i).length === 3
    : entries(i.chosen) && entries(i.current) && Object.keys(i).length === 4);
  const okOutput = (seam, o) => (seam === "compose" ? tokens(o) : o === null || entries(o));
  for (const file of process.argv.slice(4)) {
    const day = /(\d{4}-\d{2}-\d{2})\.jsonl$/.exec(file)?.[1];
    let text;
    try { text = readFileSync(file, "utf8"); } catch (error) { console.error(`${file}: ${error.message}`); process.exit(2); }
    text.split("\n").forEach((line, n) => {
      if (!line) return;
      const refuse = (why) => { console.error(`${file}:${n + 1}: ${why}`); process.exit(2); };
      let r; try { r = JSON.parse(line); } catch { refuse("not JSON"); }
      if (r?.schema !== "tron-proof-traffic/1" || r.block !== "settings/tool-selection" || !["compose", "encode"].includes(r.seam)) refuse("not a settings/tool-selection tron-proof-traffic/1 record");
      if (!Number.isSafeInteger(r.seq) || typeof r.at !== "string" || new Date(Date.parse(r.at)).toISOString() !== r.at
        || (day && r.at.slice(0, 10) !== day) || !("output" in r)) refuse("seq, at (on the file's day) or output missing or malformed");
      if (!okInput(r.seam, r.input) || !okOutput(r.seam, r.output)) refuse(`${r.seam} input or output is not what the seam records`);
      compare(`${file}:${n + 1}`, r.seam, r.input, r.output, result(r.seam, r.input));
    });
  }
} else {
  const count = Number(countArg ?? 20000);
  const rnd = mulberry32(Number(seedArg ?? 5));
  const int = (lo, hi) => lo + Math.floor(rnd() * (hi - lo + 1));
  const NAMES = ["read", "bash", "edit", "write", "web", "grep", "ls", "find", ""];
  const name = () => (rnd() < 0.03 ? "" : NAMES[int(0, NAMES.length - 2)]);
  const names = (max) => Array.from({ length: int(0, max) }, name);
  const entries = (pModifier) => Array.from({ length: int(0, 5) }, () => {
    const r = rnd();
    return r < pModifier / 2 ? `+${name()}` : r < pModifier ? `-${name()}` : name();
  });
  const belowValue = () => { const r = rnd(); return r < 0.2 ? undefined : r < 0.25 ? "not a list" : names(6); };
  const type = toolSelectionType();
  for (let i = 0; i < count; i++) {
    if (rnd() < 0.5) {
      const input = { below: belowValue(), entries: entries([0, 0.5, 1][int(0, 2)]) };
      const known = toolSelectionFacts("compose", input);
      compare(`generated ${i}`, "compose", input, known.names(type.compose(input.below, input.entries)), result("compose", known.facts));
    } else {
      const b = belowValue();
      const base = Array.isArray(b) ? b : ["read", "bash", "edit", "write"];
      // Choices near the base (reordered, with names added or removed), sometimes arbitrary or with modifiers.
      const r = rnd();
      const chosen = r < 0.4 ? [...base].filter(() => rnd() < 0.8).concat(rnd() < 0.5 ? [name()] : [])
        : r < 0.6 ? [...base].sort(() => rnd() - 0.5) : r < 0.9 ? names(6) : entries(0.5);
      const current = [undefined, [], entries(1), entries(0)][int(0, 3)];
      const input = { chosen, below: b, current };
      const known = toolSelectionFacts("encode", input);
      const output = type.encode(chosen, b, current);
      compare(`generated ${i}`, "encode", input, output === undefined ? null : known.entries(output), result("encode", known.facts));
    }
  }
}
console.log(JSON.stringify({ requests, agree, diffs }, null, 1));
process.exitCode = requests > 0 && agree === requests ? 0 : 1;
