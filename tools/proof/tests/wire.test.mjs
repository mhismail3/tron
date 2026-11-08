// Integration test for `scripts/tron proof wire` (tools/proof/README.md "Wire").
// 1. Inventory: every export of packages/gateway/src/protocol/types.ts is classified from the pinned
//    compiler's expansion, the parser's reading of every expansion is confirmed equal by that compiler,
//    and at least 95% of the protocol types are expressible (the H5 kill criterion), with numbers as float64.
// 2. Codecs: the generator's TypeScript and Swift codecs for the fixture wire source (one datatype per shape
//    the protocol uses) round trip 2,000 seeded random frames and the edge values byte for byte, agree with
//    each other byte for byte (Swift re-encodes what TypeScript encoded, and both normalise the same
//    non-canonical inputs identically), and reject the same malformed inputs at the same JSON path.
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { test } from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const FIXTURE = join(ROOT, "tools/proof/tests/fixtures/wire/Wire.dfy");

test("protocol inventory: compiler-confirmed and at least 95% expressible", () => {
  const exportLines = execFileSync("grep", ["-cE", "^export (interface|type|const) ", join(ROOT, "packages/gateway/src/protocol/types.ts")], { encoding: "utf8" }).trim();
  const run = spawnSync(join(ROOT, "scripts/tron"), ["proof", "wire", "--inventory", "--json"], { encoding: "utf8", maxBuffer: 1 << 26 });
  assert.equal(run.status, 0, run.stderr);
  const { summary, rows } = JSON.parse(run.stdout);
  assert.equal(rows.length, Number(exportLines));
  assert.equal(summary.types + summary.consts, rows.length);
  assert.deepEqual(summary.unfaithful, []);
  for (const row of rows) assert.ok(row.expressible || row.reason, `${row.name} has no reason`);
  assert.ok(summary.share >= 0.95, `only ${summary.expressible}/${summary.types} expressible`);
  // Integer-only numbers would not be faithful to today's wire: reported, not gated.
  const integer = JSON.parse(execFileSync(join(ROOT, "scripts/tron"), ["proof", "wire", "--inventory", "--json", "--numbers", "integer"], { encoding: "utf8", maxBuffer: 1 << 26 })).summary;
  assert.ok(integer.expressible < summary.expressible);
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
    label: pick(STRINGS), count: nat(), delta: int(), ratio: double(), on: rnd() < 0.5, phase: pick(["idle", "running", "slot-admission"]),
    tags: list(() => pick(STRINGS)), models: list(model), limits: map(double),
    ...opt(() => ({ note: pick(STRINGS) })), parent: rnd() < 0.5 ? null : pick(STRINGS), ...opt(() => ({ extra: json() })), ...opt(() => ({ owner: model() })),
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
  ].join("\n"));
  execFileSync("swiftc", ["-O", join(dir, "Wire.swift"), join(dir, "main.swift"), "-o", join(dir, "roundtrip")], { stdio: "pipe" });
  const swift = execFileSync(join(dir, "roundtrip"), [join(dir, "corpus.jsonl")], { encoding: "utf8", maxBuffer: 1 << 28 }).split("\n").slice(0, corpus.length);
  const ts = corpus.map(tsOut);
  const differ = ts.map((line, i) => [i, line, swift[i]]).filter(([, a, b]) => a !== b);
  assert.deepEqual(differ.slice(0, 3), [], `${differ.length} of ${corpus.length} lines differ between TypeScript and Swift`);
  assert.deepEqual(ts.slice(lines.length, lines.length + reorder.length).map((l) => l.startsWith("ERR")), [false, false, false, false]);
  assert.equal(ts[lines.length + 1].includes('"arguments":{"0":[1.5,2000],"1":2,"b":1,"a":{"0":1,"z":0}}'), true, ts[lines.length + 1]);
  assert.ok(ts.slice(lines.length + reorder.length).every((l) => l.startsWith("ERR $")), ts.slice(-bad.length).join("\n"));
});
