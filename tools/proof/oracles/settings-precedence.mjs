#!/usr/bin/env node
// Purpose: differential oracle for block settings/precedence: the compiled core (Dafny-emitted JS) against the
// shipped TypeScript it models, packages/gateway/src/kernel/settings/settings-resolver.ts (the value, layer and
// not-applied fold of resolveSettings, and composedBelow), on seeded generated inputs or, with --replay, on
// recorded Debug traffic (tron-proof-traffic/1 records of block settings/precedence).
// Generated inputs run the real resolveSettings over a synthetic schema (keys bound in every combination of
// layers, admitted or not, per-model or not, composing or not) and random stores and targets; a composing key's
// compose builds a term {c: [below, value]}, so the TypeScript's composition order is compared exactly. The core
// gets the facts the shell's own precedenceFacts builds (the seam's record input). The rows compared are
// resolveSettings' output, which names Home's layer as Session and does not say whether a shown value is the
// per-model one: generated mode checks those through the values; replay compares the raw store layers and the
// per-model flag the seam records.
// Usage: node tools/proof/oracles/settings-precedence.mjs <compiled core.js> [count=2000] [seed=3]
//        node tools/proof/oracles/settings-precedence.mjs <compiled core.js> --replay <corpus.jsonl>...
// Prints {requests, agree, diffs (first 5)}; exit 0 iff every request agrees, 1 on a mismatch, 2 on a corpus
// it cannot read.
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { importGatewaySource } from "./gateway-source.mjs";

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
// The settings seam records on an opted-in Debug Gateway; an oracle run must never add its own calls to that corpus.
delete process.env.TRON_PROOF_TRAFFIC;
const resolver = await importGatewaySource("kernel/settings/settings-resolver.ts");
const { keyForHome } = await importGatewaySource("kernel/settings/settings-schema.ts");
const { scopeForStore } = await importGatewaySource("kernel/settings/scope-resolution.ts");
const [corePath, countArg, seedArg] = process.argv.slice(2);
if (!corePath) { console.error("usage: settings-precedence.mjs <compiled core.js> [count] [seed] | --replay <corpus.jsonl>..."); process.exit(2); }
const replay = countArg === "--replay";

const { load } = await import(join(REPO, "packages/core/dist/settings/precedence/facade.ts"));
const core = load(resolve(corePath));

const LAYERS = ["global", "home", "session", "project"];
const cap = (layer) => layer[0].toUpperCase() + layer.slice(1);
const opt = (token) => (token === null ? { $: "None" } : { $: "Some", v: token });
const coreKey = (i) => ({ projectSettable: i.projectSettable, sessionOverridable: i.sessionOverridable, composes: i.composes });
const coreLayers = (i) => Object.fromEntries(LAYERS.map((l) => {
  const e = i.layers[l];
  return [l, { inTarget: e.inTarget, bound: e.bound, qualified: opt(e.qualified), unqualified: opt(e.unqualified), applied: e.applied }];
}));
const origin = (o) => (o.$ === "FromDefault" ? "default" : o.l.toLowerCase());
// The core's value term in token terms (a composing key's term has no recorded token).
const tokenOf = (v) => (v.$ === "Default" ? 0 : v.$ === "Tok" ? v.t : null);
const result = (input) => {
  const r = core.Resolve(coreKey(input), coreLayers(input));
  return { value: input.composes ? null : tokenOf(r.value), layer: origin(r.layer),
    notApplied: r.notApplied.$ === "AllApplied" ? null : r.notApplied.l.toLowerCase(),
    shown: r.shown.map((s) => ({ layer: s.layer.toLowerCase(), qualified: s.qualified, token: s.token, applied: s.applied })) };
};

let agree = 0; const diffs = []; let requests = 0;
const compare = (where, input, want, got) => {
  requests++;
  if (JSON.stringify(want) === JSON.stringify(got)) agree++;
  else if (diffs.length < 5) diffs.push({ where, input, want, got });
};

if (replay) {
  const files = process.argv.slice(4);
  const token = (v) => Number.isSafeInteger(v) && v >= 0;
  const optToken = (v) => v === null || token(v);
  const layerName = (v) => LAYERS.includes(v);
  const okEntry = (e) => e && typeof e.inTarget === "boolean" && typeof e.bound === "boolean" && optToken(e.qualified)
    && optToken(e.unqualified) && typeof e.applied === "boolean" && Object.keys(e).length === 5;
  const okInput = (i) => i && typeof i.key === "string" && typeof i.projectSettable === "boolean" && typeof i.sessionOverridable === "boolean"
    && typeof i.composes === "boolean" && i.layers && LAYERS.every((l) => okEntry(i.layers[l])) && Object.keys(i.layers).length === 4
    && Object.keys(i).length === 5;
  const okOutput = (i, o) => o && (i.composes ? o.value === null : token(o.value)) && (o.layer === "default" || layerName(o.layer))
    && (o.notApplied === null || layerName(o.notApplied)) && Array.isArray(o.shown)
    && o.shown.every((s) => s && layerName(s.layer) && typeof s.qualified === "boolean" && token(s.token) && typeof s.applied === "boolean" && Object.keys(s).length === 4)
    && Object.keys(o).length === 4;
  for (const file of files) {
    const day = /(\d{4}-\d{2}-\d{2})\.jsonl$/.exec(file)?.[1];
    let text;
    try { text = readFileSync(file, "utf8"); } catch (error) { console.error(`${file}: ${error.message}`); process.exit(2); }
    text.split("\n").forEach((line, n) => {
      if (!line) return;
      const refuse = (why) => { console.error(`${file}:${n + 1}: ${why}`); process.exit(2); };
      let r; try { r = JSON.parse(line); } catch { refuse("not JSON"); }
      if (r?.schema !== "tron-proof-traffic/1" || r.block !== "settings/precedence" || r.seam !== "resolve") refuse("not a settings/precedence tron-proof-traffic/1 record");
      if (!Number.isSafeInteger(r.seq) || typeof r.at !== "string" || new Date(Date.parse(r.at)).toISOString() !== r.at
        || (day && r.at.slice(0, 10) !== day) || !("output" in r)) refuse("seq, at (on the file's day) or output missing or malformed");
      if (!okInput(r.input) || !okOutput(r.input, r.output)) refuse("input or output is not what the seam records");
      compare(`${file}:${n + 1}`, r.input, r.output, result(r.input));
    });
  }
} else {
  const count = Number(countArg ?? 2000);
  let seed = Number(seedArg ?? 3);
  const rnd = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
  const int = (lo, hi) => lo + Math.floor(rnd() * (hi - lo + 1));
  const pick = (xs) => xs[int(0, xs.length - 1)];
  const MODELS = ["p/m1", "p/m2"];
  // A few small values, so equal values in different layers (one token) are common.
  const value = () => pick([0, 1, 2, "a", "b", [1], { x: 1 }]);
  // No synthetic key declares an optionsSource, so resolveSettings clamps nothing and its rows are the fold's result.
  const type = (composes) => ({ kind: "test", format: (v) => JSON.stringify(v) ?? "", validate: (v) => v,
    ...(composes ? { compose: (below, v) => ({ c: [below === undefined ? null : below, v] }) } : {}) });
  const chatKey = { id: "model.ref[role=chat]", group: "model", type: type(false), sessionOverridable: false, projectSettable: true,
    layers: { global: { store: "pi-model-ref" }, project: { store: "pi-model-ref" } } };
  for (let i = 0; i < count; i++) {
    const keys = Array.from({ length: 4 }, (_, n) => {
      const id = `k${n}`;
      const pi = { store: "pi", path: ["k", id], ...(rnd() < 0.5 ? { qualified: ["q", "{model}", id] } : {}) };
      const layers = {};
      if (rnd() < 0.8) layers.global = pi;
      if (rnd() < 0.7) layers.project = pi;
      if (rnd() < 0.7) layers.session = { store: "session-settings", path: ["k", id] };
      if (rnd() < 0.4) layers.home = { store: "home", path: ["k", id] };
      return { id, group: "test", type: type(rnd() < 0.4), sessionOverridable: rnd() < 0.7, projectSettable: rnd() < 0.6,
        ...(pi.qualified && rnd() < 0.8 ? { qualifier: "model" } : {}), ...(rnd() < 0.6 ? { defaultValue: value() } : {}), layers };
    });
    const schema = { KEYS: [chatKey, ...keys], schemaKey: (id) => [chatKey, ...keys].find((k) => k.id === id) };
    const doc = () => {
      const d = { k: {}, q: {} };
      for (const k of keys) {
        if (rnd() < 0.6) d.k[k.id] = value();
        for (const m of MODELS) if (rnd() < 0.3) (d.q[m] ??= {})[k.id] = value();
      }
      if (rnd() < 0.7) { const [provider, id] = pick(MODELS).split("/"); Object.assign(d, { defaultProvider: provider, defaultModel: id }); }
      return d;
    };
    const flat = () => { const d = { k: {} }; for (const k of keys) if (rnd() < 0.6) d.k[k.id] = value(); return d; };
    const target = pick([{ kind: "global" }, { kind: "project" }, { kind: "home" }, { kind: "session", sessionId: "s" }]);
    const home = target.kind === "home" || (target.kind === "session" && rnd() < 0.2);
    const hasProject = rnd() < 0.8;
    const stores = {
      layers: resolver.targetLayers(target, { home, project: hasProject }),
      global: doc(), gateway: {}, trust: {}, macTerminal: {},
      session: { settings: flat() }, home: flat(),
      ...(hasProject ? { project: { root: "/p", document: doc(), applied: rnd() < 0.6 } } : {}),
    };
    const options = { format: { modelName: () => undefined }, options: { clamp: (_s, _d, v) => v } };
    let resolution;
    try { resolution = resolver.resolveSettings(schema, target, stores, options); }
    catch (error) { diffs.length < 5 && diffs.push({ where: `generated ${i}`, error: String(error) }); requests++; continue; }
    for (const row of resolution.keys) {
      if (row.key === chatKey.id) continue;
      const key = keyForHome(schema.schemaKey(row.key), stores.layers.includes("home"));
      const qualifiers = row.qualifiers ?? {};
      const facts = resolver.precedenceFacts(stores, key, qualifiers);
      // Token -> value for every value this call can hold.
      const values = new Map();
      const note = (v) => { if (v !== undefined) values.set(facts.token(v), v); };
      note(key.defaultValue);
      for (const l of LAYERS) if (key.layers[l]) for (const q of [true, false]) note(resolver.readBinding(stores, l, key.layers[l], qualifiers, q, key.id));
      const term = (v) => (v.$ === "Default" ? key.defaultValue : v.$ === "Tok" ? values.get(v.t) : { c: [term(v.below) ?? null, values.get(v.t)] });
      const r = core.Resolve(coreKey(facts.input), coreLayers(facts.input));
      const label = { global: "Global", project: "Project", session: "Session" };
      const shownTs = row.layers.filter((l) => "value" in l).map((l) => ({ layer: l.layer, value: l.value, applied: l.applied }));
      const shownCore = [...r.shown].reverse().map((s) => ({ layer: scopeForStore(s.layer.toLowerCase()), value: values.get(s.token), applied: s.applied }));
      const unapplied = row.badges.find((b) => b.label === "Not applied (untrusted)");
      compare(`generated ${i} ${row.key}`, facts.input,
        { value: row.value, layer: row.layer, applied: row.applied, notApplied: unapplied?.detail.split(":")[0] ?? null, shown: shownTs },
        { value: term(r.value), layer: scopeForStore(origin(r.layer)), applied: r.notApplied.$ === "AllApplied",
          notApplied: r.notApplied.$ === "AllApplied" ? null : label[scopeForStore(r.notApplied.l.toLowerCase())], shown: shownCore });
      if (key.type.compose) for (const l of LAYERS) {
        compare(`generated ${i} ${row.key} below ${l}`, facts.input, resolver.composedBelow(stores, key, qualifiers, l),
          term(core.Below(coreKey(facts.input), coreLayers(facts.input), cap(l))));
      }
    }
  }
}
console.log(JSON.stringify({ requests, agree, diffs }, null, 1));
process.exitCode = requests > 0 && agree === requests ? 0 : 1;
