// Integration test for `scripts/tron proof wire` (tools/proof/README.md "Wire").
// 1. Protocol: packages/gateway/src/protocol/types.ts is exactly what packages/core/wire/Protocol.dfy generates,
//    and the protocol's own TypeScript and Swift codecs agree byte for byte on a seeded corpus of values of
//    every datatype (TypeScript encodes, each side decodes and re-encodes), the TypeScript encoder writes what
//    JSON.stringify writes for a value built in declaration order (how the Gateway builds frames); on malformed
//    values TypeScript (strict, the Gateway's validators) refuses at a JSON path and Swift (tolerant, the iOS
//    decoding policy) reads defaults or refuses as stated.
// 2. Codecs: the generator's TypeScript and Swift codecs for the fixture wire source (one datatype per shape
//    the protocol uses) round trip 2,000 seeded random frames and the edge values byte for byte, agree with
//    each other byte for byte (Swift re-encodes what TypeScript encoded, and both normalise the same
//    non-canonical inputs identically; a map built in Swift encodes in JavaScript order); TypeScript rejects
//    malformed inputs at their JSON path and tolerant Swift reads or rejects each as stated.
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { test } from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";
import { parseWire } from "../dafny2wire/dafny2wire.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const FIXTURE = join(ROOT, "tools/proof/tests/fixtures/wire/Wire.dfy");
const PROTOCOL = join(ROOT, "packages/core/wire/Protocol.dfy");

test("protocol: types.ts is generated, and its TypeScript and tolerant Swift codecs agree byte for byte", async (t) => {
  const check = spawnSync(join(ROOT, "scripts/tron"), ["proof", "wire", "--protocol", "--check"], { encoding: "utf8" });
  assert.equal(check.status, 0, check.stderr);
  const dir = mkdtempSync(join(tmpdir(), "tron-proof-protocol-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const gen = spawnSync(join(ROOT, "scripts/tron"), ["proof", "wire", "--generate", PROTOCOL, dir], { encoding: "utf8" });
  assert.equal(gen.status, 0, gen.stderr);
  const W = await import(pathToFileURL(join(dir, "wire.ts")).href);
  const types = parseWire(readFileSync(PROTOCOL, "utf8"));
  const byName = new Map(types.map((ty) => [ty.name, ty]));

  let seed = 23;
  const rnd = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
  const pick = (xs) => xs[Math.floor(rnd() * xs.length)];
  const STRINGS = ["", "a", 'q"uote', "back\\slash", "line\nbreak", "\u0001ctl", "é ✓ 😀", "2026-11-09T09:00:00.000Z"];
  const DOUBLES = [0, 1, 7, 100, 0.5, 1 / 3, 1e21, 5e-324, -2, 1700000000000];
  // A random value of field type ft, in declaration order; depth bounds the recursive types.
  const value = (ft, depth) => {
    switch (ft.kind) {
      case "string": return pick(STRINGS);
      case "bool": return rnd() < 0.5;
      case "real": case "int": case "nat": return pick(DOUBLES);
      case "seq": return depth > 3 ? [] : Array.from({ length: Math.floor(rnd() * 3) }, () => value(ft.arg, depth + 1));
      case "map": {
        const keys = ft.key.kind === "string" ? ["a", "b", "1", "z"] : byName.get(ft.key.kind).ctors.map((c) => c.wire);
        return depth > 3 ? {} : Object.fromEntries(keys.filter(() => rnd() < 0.4).map((k) => [k, value(ft.arg, depth + 1)]));
      }
      case "Nullable": return rnd() < 0.3 ? null : value(ft.arg, depth);
      default: return datatype(byName.get(ft.kind), depth + 1);
    }
  };
  const fields = (c, depth, out) => {
    for (const f of c.fields) {
      if (f.type.kind === "Absent" || (f.type.kind === "Option" && (depth > 3 || rnd() < 0.4))) continue;
      out[f.wire] = value(f.type.kind === "Option" ? f.type.arg : f.type, depth);
    }
    return out;
  };
  const datatype = (ty, depth) => {
    if (ty.kind === "enum") return pick(ty.ctors).wire;
    if (ty.kind === "record") return fields(ty.ctors[0], depth, {});
    if (ty.kind === "tagged") { const c = pick(ty.ctors); return fields(c, depth, { [ty.tag]: c.wire }); }
    // bykind: deep values are scalars.
    const ctors = depth > 3 ? ty.ctors.filter((c) => !c.fields.length || ["string", "real", "bool"].includes(c.fields[0].type.kind)) : ty.ctors;
    const c = pick(ctors);
    return c.fields.length ? value(c.fields[0].type, depth) : null;
  };

  const lines = [];
  for (const ty of types) for (let i = 0; i < 12; i++) {
    const v = datatype(ty, 0);
    const encoded = W[`encode${ty.name}`](v);
    assert.equal(encoded, JSON.stringify(v), `${ty.name}: the generated encoder writes what JSON.stringify writes`);
    assert.equal(W[`encode${ty.name}`](W[`decode${ty.name}`](JSON.parse(encoded))), encoded, `${ty.name} round trip`);
    lines.push(`${ty.name}\t${encoded}`);
  }
  const bad = [
    'AdministrativeDrainSnapshot\t{"drainId":"d","revision":1,"phase":"idle","blockerCount":0,"blockerCounts":{"nope":1},"blockers":[],"omittedCount":0,"suspectProjectionCount":0}',
    'HomeStatusTaskRecovery\t{"available":"yes"}',
    'HomeStatusTaskRecovery\t{"available":true,"reason":"x"}',
    'SessionCreationOrigin\t{"kind":"automation","automationId":"a","extra":1}',
    'ModelRef\t{"provider":"p"}',
    'JsonValue\t{"a":[1,{"b":1e400}]}',
    'ChatSemanticKind\t"brandNew"',
    'ModelRef\t{"provider":null,"id":"x"}',
  ];
  const corpus = [...lines, ...bad];
  const tsOut = (line) => {
    const [name, json] = line.split("\t");
    try { return W[`encode${name}`](W[`decode${name}`](JSON.parse(json))); }
    catch (error) { if (!(error instanceof W.WireError)) throw error; return `ERR ${error.path}`; }
  };
  writeFileSync(join(dir, "corpus.txt"), `${corpus.join("\n")}\n`);
  writeFileSync(join(dir, "main.swift"), [
    "import Foundation",
    "func roundTrip(_ name: Substring, _ v: WireJSON) throws -> String {",
    "  switch name {",
    ...types.map((ty) => `  case "${ty.name}": return try ${ty.name}.decode(v).encode()`),
    '  default: return "NO TYPE"',
    "  }",
    "}",
    "let text = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)",
    'for line in text.split(separator: "\\n") {',
    '  let parts = line.split(separator: "\\t", maxSplits: 1)',
    '  do { print(try roundTrip(parts[0], try wParse(String(parts[1])))) } catch let e as WireError { print("ERR \\(e.path)") } catch { print("ERR ?") }',
    "}",
  ].join("\n"));
  execFileSync("swiftc", ["-O", join(dir, "Wire.swift"), join(dir, "main.swift"), "-o", join(dir, "roundtrip")], { stdio: "pipe" });
  const swift = execFileSync(join(dir, "roundtrip"), [join(dir, "corpus.txt")], { encoding: "utf8", maxBuffer: 1 << 28 }).split("\n").slice(0, corpus.length);
  const ts = corpus.map(tsOut);
  const differ = lines.map((line, i) => [line.split("\t")[0], ts[i], swift[i]]).filter(([, a, b]) => a !== b);
  assert.deepEqual(differ.slice(0, 3), [], `${differ.length} of ${lines.length} values differ between TypeScript and Swift`);
  // TypeScript (the Gateway's validators) is strict; Swift is tolerant, as the iOS app decodes: an unknown field
  // is ignored, an absent or null field takes its default, an unknown value of an enum with an `unknown` value
  // is `unknown`; a wrong kind, an unknown enum map key or tag, and an overflowing number are still refused.
  assert.deepEqual(ts.slice(lines.length), [
    'ERR $.blockerCounts["nope"]', "ERR $.available", "ERR $", "ERR $", "ERR $.id", "ERR $[\"a\"][1][\"b\"]", "ERR $", "ERR $.provider",
  ]);
  assert.deepEqual(swift.slice(lines.length), [
    'ERR $.blockerCounts["nope"]', "ERR $.available", '{"available":true}', '{"kind":"automation","automationId":"a"}',
    '{"provider":"p","id":""}', "ERR $[\"a\"][1][\"b\"]", '"unknown"', '{"provider":"","id":"x"}',
  ]);
  assert.equal(lines.length, types.length * 12);
});

test("generated TypeScript and Swift codecs agree byte for byte", async (t) => {
  const dir = mkdtempSync(join(tmpdir(), "tron-proof-wire-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const gen = spawnSync(join(ROOT, "scripts/tron"), ["proof", "wire", "--generate", FIXTURE, dir], { encoding: "utf8" });
  assert.equal(gen.status, 0, gen.stderr);
  const W = await import(pathToFileURL(join(dir, "wire.ts")).href);

  let seed = 11;
  const rnd = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
  const pick = (xs) => xs[Math.floor(rnd() * xs.length)];
  const STRINGS = ["", "a", 'quote"q', "back\\slash", "new\nline", "tab\t\r", "\u0001\u001f ctl", "é ✓ 😀 中", "/slash", "\u2028sep"];
  const KEYS = ["a", "b", "0", "1", "10", "01", "4294967294", "4294967295", "__proto__", "constructor", "-1", "z"];
  const EDGE = [0, -0, 1, -1, 0.1, 0.5, 4.35, 100, 1e20, 1e21, 1e-6, 1e-7, 123e-20, 5e-324, 1.7976931348623157e308, 2 ** 53, -(2 ** 53), 123456789012345680000, 1 / 3];
  const bits = new DataView(new ArrayBuffer(8));
  const double = () => {
    if (rnd() < 0.3) return pick(EDGE);
    if (rnd() < 0.5) { bits.setUint32(0, Math.floor(rnd() * 2 ** 32)); bits.setUint32(4, Math.floor(rnd() * 2 ** 32)); const d = bits.getFloat64(0); return Number.isFinite(d) ? d : 2.5; }
    return Math.round((rnd() - 0.5) * 1e6) / [1, 10, 100, 1000][Math.floor(rnd() * 4)];
  };
  const int = () => Math.floor((rnd() - 0.5) * 2 ** 54) % Number.MAX_SAFE_INTEGER;
  const nat = () => Math.floor(rnd() * 2 ** 53);
  const list = (f, n = 3) => Array.from({ length: Math.floor(rnd() * n) }, f);
  const map = (f) => Object.fromEntries(list(() => [pick(KEYS), f()], 5));
  const json = (depth = 0) => {
    const r = rnd();
    if (depth > 2 || r < 0.4) return pick([null, true, false, double(), pick(STRINGS)]);
    return r < 0.7 ? list(() => json(depth + 1)) : map(() => json(depth + 1));
  };
  const opt = (f) => (rnd() < 0.5 ? {} : f());
  const model = () => ({ provider: pick(STRINGS), id: pick(STRINGS) });
  const sample = () => ({
    version: 1, label: pick(STRINGS), count: nat(), delta: int(), ratio: double(), on: rnd() < 0.5, phase: pick(["idle", "running", "slot-admission"]), level: pick([0, 2, false]),
    tags: list(() => pick(STRINGS)), models: list(model), limits: map(double),
    ...opt(() => ({ note: pick(STRINGS) })), parent: rnd() < 0.5 ? null : pick(STRINGS), ...opt(() => ({ extra: json() })), ...opt(() => ({ owner: model() })), ...opt(() => ({ bold: true })),
  });
  const event = () => pick([() => ({ type: "session.started", sample: sample() }), () => ({ type: "Stopped" }), () => ({ type: "chunk", text: pick(STRINGS), at: nat() })])();
  const part = () => (rnd() < 0.5 ? { kind: "Text", text: pick(STRINGS) } : { kind: "Tool", name: pick(STRINGS), arguments: map(() => json()) });
  const frame = () => ({ seq: nat(), events: list(event, 4), parts: list(part, 3) });

  const lines = Array.from({ length: 2000 }, () => W.encodeFrame(frame()));
  for (const line of lines) assert.equal(W.encodeFrame(W.decodeFrame(JSON.parse(line))), line);
  assert.ok(lines.some((l) => l.includes("1e+21")) && lines.some((l) => l.includes("5e-324")) && lines.some((l) => l.includes("1e-7")));
  // Non-canonical inputs both decoders must normalise the same way: JS property order and whitespace.
  const reorder = [
    ' { "parts" : [ ] , "events" : [ ] , "seq" : 7 } ',
    '{"seq":1,"events":[],"parts":[{"kind":"Tool","name":"n","arguments":{"b":1,"1":2,"a":{"z":0,"0":1},"0":[1.50,2e3]}}]}',
    '{"seq":1,"events":[],"parts":[{"kind":"Tool","name":"n","arguments":{"a":1,"b":2,"a":3}}]}',
    '{"seq":1,"events":[{"type":"chunk","text":"\\u00e9\\ud83d\\ude00\\/","at":0}],"parts":[]}',
  ];
  const bad = [
    '{"seq":-1,"events":[],"parts":[]}', '{"seq":1.5,"events":[],"parts":[]}', '{"seq":9007199254740992,"events":[],"parts":[]}',
    '{"seq":1,"events":[{"type":"nope"}],"parts":[]}', '{"seq":1,"events":[{"type":"chunk","text":3,"at":0}],"parts":[]}',
    '{"seq":1,"events":[],"parts":[],"x":1}', '{"seq":1,"events":[{"type":"Stopped","at":1}],"parts":[]}', '{"events":[],"parts":[]}',
    '{"seq":1,"events":[{"type":"session.started","sample":{"label":"l","count":1,"delta":1,"ratio":1,"on":true,"phase":"paused","tags":[],"models":[],"limits":{},"parent":null}}],"parts":[]}',
    '{"seq":1,"events":[],"parts":[{"kind":"Tool","name":"n","arguments":{"k":{"x":[1,"a",{"y":"z"}],"w":true}}},{"kind":"Text"}]}',
    '{"seq":1,"events":[],"parts":[{"kind":"Tool","name":"n","arguments":{"k":[1,1e400]}}]}',
    '{"seq":1,"events":[{"type":"Stopped","reason":"x"}],"parts":[]}', '{"seq":1,"events":[],"parts":[{"kind":"Text","text":"t","arguments":{}}]}',
    `{"seq":1,"events":[{"type":"session.started","sample":${JSON.stringify({ ...JSON.parse(W.encodeFrame({ seq: 0, events: [{ type: "session.started", sample: { version: 1, label: "l", count: 1, delta: 1, ratio: 1, on: true, phase: "idle", level: 0, tags: [], models: [], limits: {}, parent: null } }], parts: [] })).events[0].sample, version: 2 })}}],"parts":[]}`,
    '{"seq":1,"events":[{"type":"session.started","sample":{"version":1,"label":"l","count":1,"delta":1,"ratio":1,"on":true,"phase":"idle","level":1,"tags":[],"models":[],"limits":{},"parent":null}}],"parts":[]}',
    '{"seq":1,"events":[{"type":"session.started","sample":{"version":1,"label":"l","count":1,"delta":1,"ratio":1,"on":true,"phase":"idle","level":0,"tags":[],"models":[],"limits":{},"parent":null,"bold":false}}],"parts":[]}',
  ];
  const tsOut = (line) => { try { return W.encodeFrame(W.decodeFrame(JSON.parse(line))); } catch (error) { if (!(error instanceof W.WireError)) throw error; return `ERR ${error.path}`; } };
  const corpus = [...lines, ...reorder, ...bad];
  writeFileSync(join(dir, "corpus.jsonl"), `${corpus.join("\n")}\n`);
  writeFileSync(join(dir, "main.swift"), [
    "import Foundation",
    "let text = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)",
    'for line in text.split(separator: "\\n", omittingEmptySubsequences: false).dropLast() {',
    '  do { print(try Frame.decode(try wParse(String(line))).encode()) } catch let e as WireError { print("ERR \\(e.path)") } catch { print("ERR ?") }',
    "}",
    // A map built in Swift, in non-JavaScript order, still encodes in JavaScript's property order.
    'print(WireMap<Int>([("b", 1), ("1", 2), ("a", 3), ("0", 4), ("b", 5)]).encode { String($0) })',
  ].join("\n"));
  execFileSync("swiftc", ["-O", join(dir, "Wire.swift"), join(dir, "main.swift"), "-o", join(dir, "roundtrip")], { stdio: "pipe" });
  const swiftLines = execFileSync(join(dir, "roundtrip"), [join(dir, "corpus.jsonl")], { encoding: "utf8", maxBuffer: 1 << 28 }).split("\n");
  const swift = swiftLines.slice(0, corpus.length);
  const built = { b: 1, 1: 2, a: 3, 0: 4 }; built.b = 5;
  assert.equal(swiftLines[corpus.length], JSON.stringify(built));
  const ts = corpus.map(tsOut);
  const valid = lines.length + reorder.length;
  const differ = ts.slice(0, valid).map((line, i) => [i, line, swift[i]]).filter(([, a, b]) => a !== b);
  assert.deepEqual(differ.slice(0, 3), [], `${differ.length} of ${valid} lines differ between TypeScript and Swift`);
  assert.deepEqual(ts.slice(lines.length, lines.length + reorder.length).map((l) => l.startsWith("ERR")), [false, false, false, false]);
  assert.equal(ts[lines.length + 1].includes('"arguments":{"0":[1.5,2000],"1":2,"b":1,"a":{"0":1,"z":0}}'), true, ts[lines.length + 1]);
  assert.deepEqual(ts.slice(lines.length + reorder.length), [
    "ERR $.seq", "ERR $.seq", "ERR $.seq", "ERR $.events[0].type", "ERR $.events[0].text", "ERR $", "ERR $.events[0]", "ERR $.seq",
    "ERR $.events[0].sample.version", "ERR $.parts[1].text", 'ERR $.parts[0].arguments["k"][1]', "ERR $.events[0]", "ERR $.parts[0]",
    "ERR $.events[0].sample.version", "ERR $.events[0].sample.level", "ERR $.events[0].sample.bold",
  ]);
  // Swift decodes tolerantly (see the protocol test): what it still refuses, and what it reads instead.
  assert.deepEqual(swift.slice(valid), [
    "ERR $.seq", "ERR $.seq", "ERR $.seq", "ERR $.events[0].type", "ERR $.events[0].text",
    '{"seq":1,"events":[],"parts":[]}', '{"seq":1,"events":[{"type":"Stopped"}],"parts":[]}', '{"seq":0,"events":[],"parts":[]}',
    "ERR $.events[0].sample.phase", '{"seq":1,"events":[],"parts":[{"kind":"Tool","name":"n","arguments":{"k":{"x":[1,"a",{"y":"z"}],"w":true}}},{"kind":"Text","text":""}]}',
    'ERR $.parts[0].arguments["k"][1]', '{"seq":1,"events":[{"type":"Stopped"}],"parts":[]}', '{"seq":1,"events":[],"parts":[{"kind":"Text","text":"t"}]}',
    "ERR $.events[0].sample.version", "ERR $.events[0].sample.level", "ERR $.events[0].sample.bold",
  ]);
});
