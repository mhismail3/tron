// Integration test for `scripts/tron proof facade` (tools/proof/README.md "Façade") on a copy of the fixture
// block demo/counter (tests/fixtures/facade; test input, not a core block): the generated façade exposes
// exactly the compiled declarations of the laws (a multi-line datatype in full, an opaque function, not a
// ghost function or a commented-out one), marshals values both ways, refuses unknown constructors,
// non-integers, negative naturals and a broken precondition before calling the core, and a result outside
// the safe integers after it; --check fails on a
// hand edit of either file; and laws the façade cannot translate faithfully are refused.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cpSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { test } from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");

test("the generated façade is complete, faithful and refuses what it cannot carry", async (t) => {
  const base = mkdtempSync(join(tmpdir(), "tron-proof-facade-"));
  t.after(() => rmSync(base, { recursive: true, force: true }));
  const root = join(base, "core");
  cpSync(join(ROOT, "tools/proof/tests/fixtures/facade"), root, { recursive: true });
  cpSync(join(ROOT, "packages/core/package.json"), join(root, "package.json"));
  symlinkSync(join(ROOT, "packages/core/node_modules"), join(root, "node_modules"));
  const facade = (...args) => spawnSync(join(ROOT, "scripts/tron"), ["proof", "facade", "demo/counter", "--root", root, ...args], { encoding: "utf8" });

  assert.equal(facade().status, 0);
  const source = readFileSync(join(root, "dist/demo/counter/facade.ts"), "utf8");
  assert.match(source, /export type Color = "Red" \| "Green" \| "Blue";/);
  assert.match(source, /^export interface Core \{\n  Valid\(b: Box\): boolean;\n  Apply\(b: Box, s: Step\): Box;\n  Shade\(c: Color\): Color;\n  Delta\(a: number, b: number\): number;\n\}$/m);
  const { core } = await import(pathToFileURL(join(root, "dist/demo/counter/facade.ts")).href);
  assert.deepEqual(core.Apply({ count: 3, color: "Blue" }, { $: "Inc", amount: 4 }), { count: 7, color: "Blue" });
  assert.deepEqual(core.Apply({ count: 3, color: "Red" }, { $: "Reset" }), { count: 0, color: "Red" });
  assert.deepEqual(["Red", "Green", "Blue"].map((c) => core.Shade(c)), ["Green", "Blue", "Red"]);
  assert.equal(core.Delta(-(2 ** 52), 2 ** 52 - 1), -(2 ** 53) + 1);
  assert.throws(() => core.Delta(-(2 ** 52), 2 ** 52), { name: "RangeError", message: "core returned an integer outside the safe range" });
  assert.equal(core.Valid({ count: 101, color: "Red" }), false);
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
  ]) {
    writeFileSync(laws, original.replace(from, to));
    const refused = facade();
    assert.equal(refused.status, 2, refused.stderr);
    assert.match(refused.stderr, message);
  }
});
