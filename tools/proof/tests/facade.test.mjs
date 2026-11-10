// Integration test for `scripts/tron proof facade` (tools/proof/dafny2wire/README.md "Façade") on a copy of the fixture
// block demo/counter (tests/fixtures/facade; test input, not a core block): the generated façade exposes
// exactly the compiled declarations of the laws (a multi-line datatype in full, an opaque function, not a
// ghost function or a commented-out one), marshals values both ways (sequences as arrays, also nested and as
// datatype fields), refuses unknown constructors,
// non-integers, negative naturals and a broken precondition before calling the core, and a result outside
// the safe integers after it; --check fails on a
// hand edit of either file; and laws the façade cannot translate faithfully are refused.
// A block a shell runs (fixture demo/meter, block.json "shell") is generated into the shell's directory as a
// module with no import: the compiler's module-only output byte for byte, plus the one closed runtime helper it
// calls; its numbers cross as numbers of their newtype's range; a linked list crosses as an array, of any
// length; and a block that would need the Dafny runtime is refused, naming the function.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { test } from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");

test("the generated façade is complete, faithful and refuses what it cannot carry", async (t) => {
  const base = mkdtempSync(join(tmpdir(), "tron-proof-facade-"));
  t.after(() => rmSync(base, { recursive: true, force: true }));
  const root = join(base, "packages/core");
  cpSync(join(ROOT, "tools/proof/tests/fixtures/facade"), root, { recursive: true });
  cpSync(join(ROOT, "packages/core/package.json"), join(root, "package.json"));
  symlinkSync(join(ROOT, "packages/core/node_modules"), join(root, "node_modules"));
  const facade = (...args) => spawnSync(join(ROOT, "scripts/tron"), ["proof", "facade", "demo/counter", "--root", root, ...args], { encoding: "utf8" });

  assert.equal(facade().status, 0);
  const source = readFileSync(join(root, "dist/demo/counter/facade.ts"), "utf8");
  assert.match(source, /export type Color = "Red" \| "Green" \| "Blue";/);
  assert.match(source, /^export interface Core \{\n  Valid\(b: Box\): boolean;\n  Apply\(b: Box, s: Step\): Box;\n  Shade\(c: Color\): Color;\n  Delta\(a: number, b: number\): number;\n  Counts\(bs: readonly Box\[\]\): readonly number\[\];\n  Echo\(r: Run\): Run;\n\}$/m);
  assert.match(source, /^export interface Run \{ readonly steps: readonly Step\[\]; readonly marks: readonly \(readonly number\[\]\)\[\] \}$/m);
  const { core } = await import(pathToFileURL(join(root, "dist/demo/counter/facade.ts")).href);
  assert.deepEqual(core.Apply({ count: 3, color: "Blue" }, { $: "Inc", amount: 4 }), { count: 7, color: "Blue" });
  assert.deepEqual(core.Apply({ count: 3, color: "Red" }, { $: "Reset" }), { count: 0, color: "Red" });
  assert.deepEqual(["Red", "Green", "Blue"].map((c) => core.Shade(c)), ["Green", "Blue", "Red"]);
  assert.equal(core.Delta(-(2 ** 52), 2 ** 52 - 1), -(2 ** 53) + 1);
  assert.throws(() => core.Delta(-(2 ** 52), 2 ** 52), { name: "RangeError", message: "core returned an integer outside the safe range" });
  assert.equal(core.Valid({ count: 101, color: "Red" }), false);
  assert.deepEqual(core.Counts([{ count: 3, color: "Red" }, { count: 0, color: "Blue" }]), [3, 0]);
  assert.deepEqual(core.Counts([]), []);
  const run = { steps: [{ $: "Inc", amount: 2 }, { $: "Reset" }], marks: [[1, -2], [], [2 ** 53 - 1]] };
  assert.deepEqual(core.Echo(run), run);
  assert.throws(() => core.Counts({ count: 1, color: "Red" }), { name: "TypeError", message: 'not an array: {"count":1,"color":"Red"}' });
  assert.throws(() => core.Echo({ steps: [], marks: [[1.5]] }), { name: "RangeError", message: "not a safe integer: 1.5" });
  assert.throws(() => core.Counts([{ count: -1, color: "Red" }]), { name: "RangeError", message: "not a natural number: -1" });
  assert.throws(() => core.Shade("Purple"), { name: "TypeError", message: 'not a Color: "Purple"' });
  assert.throws(() => core.Apply({ count: 1, color: "Red" }, { $: "Double" }), { name: "TypeError", message: 'not a Step: {"$":"Double"}' });
  assert.throws(() => core.Apply({ count: -1, color: "Red" }, { $: "Reset" }), { name: "RangeError", message: "not a natural number: -1" });
  assert.throws(() => core.Delta(1.5, 0), { name: "RangeError", message: "not a safe integer: 1.5" });
  assert.throws(() => core.Apply({ count: 101, color: "Red" }, { $: "Reset" }), { name: "RangeError", message: "precondition Valid(b) of Apply does not hold" });

  assert.equal(facade("--check").status, 0);
  for (const file of ["facade.ts", "core.js"]) {
    const path = join(root, "dist/demo/counter", file);
    const text = readFileSync(path, "utf8");
    writeFileSync(path, `${text}// hand edit\n`);
    const stale = facade("--check");
    assert.equal(stale.status, 1);
    assert.match(stale.stderr, new RegExp(`${file.replace(".", "\\.")} in .* differ from the sources`));
    writeFileSync(path, text);
  }

  const laws = join(root, "laws/demo/Counter.dfy");
  const original = readFileSync(laws, "utf8");
  for (const [from, to, message] of [
    ["  function Shade(c: Color): Color", "  function method Shade(c: Color): Color", /'function method' is not Dafny 4 syntax/],
    ["    requires Valid(b)", "    requires b.count < 50", /precondition 'b.count < 50' cannot be checked by the façade/],
    ["  function Delta(a: int, b: int): int", "  function Delta(a: int, b: real): int", /unsupported Dafny type real/],
    ["  function Echo(r: Run): Run", "  function Echo(r: Run): Run\n  method Sweep(marks: seq<int>, seen: array<bool>) returns (n: int)\n    requires seen.Length == |marks|\n    modifies seen", /Sweep: a compiled method needs a block a shell runs/],
  ]) {
    writeFileSync(laws, original.replace(from, to));
    const refused = facade();
    assert.equal(refused.status, 2, refused.stderr);
    assert.match(refused.stderr, message);
  }
});

test("a block a shell runs compiles to a module that needs no Dafny runtime", async (t) => {
  const base = mkdtempSync(join(tmpdir(), "tron-proof-facade-"));
  t.after(() => rmSync(base, { recursive: true, force: true }));
  const root = join(base, "packages/core");
  cpSync(join(ROOT, "tools/proof/tests/fixtures/facade"), root, { recursive: true });
  const shell = join(base, "packages/shell/meter");
  const facade = (...args) => spawnSync(join(ROOT, "scripts/tron"), ["proof", "facade", "demo/meter", "--root", root, ...args], { encoding: "utf8" });

  const written = facade();
  assert.equal(written.status, 0, written.stderr);
  assert.equal(existsSync(join(root, "dist")), false);
  const core = readFileSync(join(shell, "core.mjs"), "utf8");
  // No package and no runtime: nothing is imported, and the only runtime code is the helper the block calls.
  assert.doesNotMatch(core, /\brequire\s*\(|^\s*import\b/m);
  assert.match(core, /^const _dafny = Object\.freeze\(\{\n  EuclideanDivisionNumber: function\(a, b\) \{$/m);
  assert.equal(core.match(/^  \w+: function\(/gm).length, 1);
  assert.ok(core.endsWith("export { Meter as compiled };\n"));
  // The module is the compiler's own output, unedited.
  const dafny = join(process.env.XDG_CACHE_HOME || join(homedir(), "Library/Caches"), "tron-proof/bin/dafny");
  assert.equal(spawnSync(dafny, ["translate", "js", "--no-verify", "blocks/demo/meter/Block.dfy", "-o", join(base, "plain")], { cwd: root }).status, 0);
  assert.ok(core.includes(readFileSync(join(base, "plain.js"), "utf8")));

  const source = readFileSync(join(shell, "facade.ts"), "utf8");
  assert.match(source, /^export interface Core \{\n  Recent\(at: number\): boolean;\n  Period\(every: number\): boolean;\n  Slot\(at: number, every: number\): number;\n  Compare\(a: Reading, b: Reading\): Trend;\n  Grain\(s: Scale\): number;\n  Levels\(s: Series\): readonly number\[\];\n  Firsts\(order: readonly number\[\]\): readonly number\[\];\n\}$/m);
  assert.match(source, /^export interface Series \{ readonly name: number; readonly readings: readonly Reading\[\] \}$/m);
  // Loaded from a directory with no node_modules anywhere above it.
  const { core: meter } = await import(pathToFileURL(join(shell, "facade.ts")).href);
  assert.deepEqual([meter.Slot(7, 2), meter.Slot(-7, 2), meter.Slot(999, 999), meter.Slot(-999, 1)], [3, -4, 1, -999]);
  assert.deepEqual(meter.Compare({ at: 1, level: 20 }, { at: 2, level: 65 }), { $: "Rising", step: 45 });
  assert.deepEqual(meter.Compare({ at: 1, level: 100 }, { at: 2, level: 0 }), { $: "Falling", step: 100 });
  assert.deepEqual(meter.Compare({ at: -(2 ** 53) + 1, level: 7 }, { at: 2 ** 53 - 1, level: 7 }), { $: "Flat" });
  // A linked list crosses as an array, in order, also as a datatype field; the block builds its result in a loop,
  // so neither it nor the façade is bounded by the call stack.
  assert.deepEqual(meter.Levels({ name: 1, readings: [{ at: 1, level: 10 }, { at: 2, level: 20 }, { at: 3, level: 30 }] }), [30, 20, 10]);
  assert.deepEqual(meter.Levels({ name: 1, readings: [] }), []);
  const long = Array.from({ length: 200_000 }, (_, i) => ({ at: i, level: i % 101 }));
  const levels = meter.Levels({ name: 1, readings: long });
  assert.equal(levels.length, 200_000);
  assert.deepEqual([levels[0], levels[1], levels.at(-1)], [199_999 % 101, 199_998 % 101, 0]);
  assert.throws(() => meter.Levels({ name: 1, readings: { 0: { at: 1, level: 1 }, length: 1 } }), { name: "TypeError", message: /^not an array: / });
  assert.throws(() => meter.Levels({ name: 1, readings: [{ at: 1, level: 10 }, { at: 2, level: 101 }] }), { name: "RangeError", message: "not a Level: 101" });
  assert.throws(() => meter.Levels({ name: 1, readings: [{ at: 1, level: 10 }, undefined] }), { name: "TypeError", message: "not a Reading: undefined" });
  // A constructor without fields is one shared value, found by its own name only.
  assert.deepEqual([meter.Grain("Fine"), meter.Grain("Coarse"), meter.Grain("Fine")], [1, 10, 1]);
  for (const name of ["Medium", "constructor", "__proto__", "toString", undefined, 0]) {
    assert.throws(() => meter.Grain(name), { name: "TypeError", message: `not a Scale: ${JSON.stringify(name)}` });
  }
  // A method's work array is lent by the façade, fresh for each call and as long as the sequence its precondition
  // names: the method's TypeScript signature has no array, and what a call left behind never reaches the next.
  assert.deepEqual(meter.Firsts([2, 0, 2, 1, 0]), [1, 0, 2]);
  assert.deepEqual(meter.Firsts([2, 0, 2, 1, 0]), [1, 0, 2]);
  assert.deepEqual(meter.Firsts([7, 0]), [0]);
  assert.deepEqual(meter.Firsts([]), []);
  assert.throws(() => meter.Firsts([0, -1]), { name: "RangeError", message: "not a Position: -1" });
  assert.throws(() => meter.Firsts("20"), { name: "TypeError", message: /^not an array: / });
  assert.throws(() => meter.Slot(1.5, 2), { name: "RangeError", message: "not a Ms: 1.5" });
  assert.throws(() => meter.Slot(2 ** 53, 2), { name: "RangeError", message: "not a Ms: 9007199254740992" });
  assert.throws(() => meter.Slot("7", 2), { name: "RangeError", message: "not a Ms: 7" });
  assert.throws(() => meter.Compare({ at: 1, level: 101 }, { at: 2, level: 0 }), { name: "RangeError", message: "not a Level: 101" });
  assert.throws(() => meter.Compare({ at: 1, level: -1 }, { at: 2, level: 0 }), { name: "RangeError", message: "not a Level: -1" });
  assert.throws(() => meter.Slot(1000, 2), { name: "RangeError", message: "precondition Recent(at) of Slot does not hold" });
  assert.throws(() => meter.Slot(5, 0), { name: "RangeError", message: "precondition Period(every) of Slot does not hold" });

  assert.equal(facade("--check").status, 0);
  for (const file of ["facade.ts", "core.mjs"]) {
    const path = join(shell, file);
    const text = readFileSync(path, "utf8");
    writeFileSync(path, `${text}// hand edit\n`);
    const stale = facade("--check");
    assert.equal(stale.status, 1);
    assert.match(stale.stderr, new RegExp(`${file.replace(".", "\\.")} in .* differ from the sources`));
    writeFileSync(path, text);
  }

  // A copied runtime helper must stand alone: only its parameters, its locals and Math.
  const { closedHelper } = await import(join(ROOT, "tools/proof/dafny2wire/facade.mjs"));
  const division = /^  EuclideanDivisionNumber: (function[\s\S]*?\n  \}),$/m.exec(core)[1];
  assert.equal(closedHelper(division), true);
  for (const open of ["function(a, b) { return _dafny.ZERO; }", "function(a, b) { return Seq.of(a, b); }", "function(a, b) { return this.x; }",
    "function(a, b) { return new BigNumber(a); }", "function(a, b) { return a + $module.b; }", "function(a) { return 'text'; }", "(a) => a", "not a function"]) {
    assert.equal(closedHelper(open), false, open);
  }

  // What would need the Dafny runtime is refused before anything is written, naming the function.
  const edit = (file, from, to) => { const text = readFileSync(file, "utf8"); assert.ok(text.includes(from)); writeFileSync(file, text.replace(from, to)); return () => writeFileSync(file, text); };
  const block = join(root, "blocks/demo/meter/Block.dfy");
  const laws = join(root, "laws/demo/Meter.dfy");
  for (const [file, from, to, message] of [
    [block, "    else Flat", "    else if a == b then Flat else Flat", /Compare needs the Dafny runtime \(compiled line \d+: .*_dafny\.areEqual/],
    [block, "{ at / every }", "{ Total([at, every]) }\n  function Total(s: seq<Ms>): Ms { if |s| == 0 then 0 else s[0] }", /Slot needs the Dafny runtime \(compiled line \d+: .*_dafny\.Seq\.of/],
    // A block's own function is never exempt, whatever its name or owner: only the compiler's datatype and newtype
    // members are.
    [block, "{ at / every }", "{ if equals(at, every) then 0 else at / every }\n  function equals(a: Ms, b: Ms): bool { [a] == [b] }", /equals needs the Dafny runtime/],
    [block, "{ at / every }", "{ if Box.IntegerRange(at) then at / every else 0 }\n  datatype Box = Box(n: Ms) { static function IntegerRange(a: Ms): bool { [a] == [a] } }", /IntegerRange needs the Dafny runtime/],
    [block, "{ at / every }", "{ if Box(at).equals(every) then 0 else at / every }\n  datatype Box = Box(n: Ms) { function equals(b: Ms): bool { [n] == [b] } }", /equals needs the Dafny runtime/],
    // A parameter may not take one of the façade's own names.
    [laws, "function Slot(at: Ms, every: Ms): Ms\n    requires Recent(at) && Period(every)", "function Slot(at: Ms, bool: Ms): Ms\n    requires Recent(at) && Period(bool)", /Slot: parameter name bool is reserved by the façade/],
    [laws, "predicate Recent(at: Ms) { -1000 < at < 1000 }", "predicate Recent(inMs: Ms) { -1000 < inMs < 1000 }", /Recent: parameter name inMs is reserved by the façade/],
    [laws, "function Compare(a: Reading, b: Reading): Trend", "function Compare(a: Reading, b: Reading): Trend\n  function Wide(x: int): int", /unsupported Dafny type int/],
    [laws, "newtype Level = x: int | 0 <= x <= 100", "newtype Level = x: int | 0 <= x <= Top()\n  ghost function Top(): int { 100 }", /cannot read newtype as a literal integer range within the safe integers/],
    // A method's array must be sized by a sequence parameter, and its preconditions must be ones the façade
    // establishes or checks.
    [laws, "requires |order| < 0x1_0000_0000 && taken.Length == |order|", "requires |order| < 0x1_0000_0000", /Firsts: array taken needs a precondition taken\.Length == \|<a sequence parameter>\|/],
    [laws, "requires |order| < 0x1_0000_0000 && taken.Length == |order|", "requires |order| < 0x1_0000_0000 && taken.Length == |order| && taken.Length > 0", /Firsts: precondition 'taken\.Length > 0' cannot be checked by the façade/],
    // A linked list is exactly an empty constructor, then one of an item and the rest.
    [laws, "datatype Chain<T> = End | Link(first: T, rest: Chain<T>)", "datatype Chain<T> = Link(first: T, rest: Chain<T>) | End", /unsupported Dafny type Chain</],
    [laws, "datatype Chain<T> = End | Link(first: T, rest: Chain<T>)", "datatype Chain<T> = End(size: Level) | Link(first: T, rest: Chain<T>)", /unsupported Dafny type Chain</],
    // A generic datatype that is not a linked list has no shape the façade knows.
    [laws, "datatype Chain<T> = End | Link(first: T, rest: Chain<T>)", "datatype Chain<T> = End | Link(first: T, rest: Chain<T>) | Loop(back: T)", /unsupported Dafny type Chain</],
  ]) {
    const restore = edit(file, from, to);
    rmSync(shell, { recursive: true, force: true });
    const refused = facade();
    assert.equal(refused.status, 2, refused.stderr);
    assert.match(refused.stderr, message);
    assert.equal(existsSync(shell), false);
    restore();
  }
});
