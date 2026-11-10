import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const FIXTURE = join(ROOT, "tools/proof/tests/fixtures/lawcheck");

test("proof check is scoped, cached, and fails a false law", (t) => {
  const base = mkdtempSync(join(tmpdir(), "tron-proof-check-"));
  t.after(() => rmSync(base, { recursive: true, force: true }));
  const root = join(base, "core");
  cpSync(FIXTURE, root, { recursive: true });
  const cache = join(base, "cache.json");
  const check = () => {
    const run = spawnSync(join(ROOT, "scripts/tron"), ["proof", "check", "--root", root, "--cache", cache, "--json"], { encoding: "utf8" });
    const parsed = run.status === 2 ? null : JSON.parse(run.stdout);
    return { status: run.status, stderr: run.stderr, statuses: parsed && Object.fromEntries(parsed.report.map((r) => [r.block, r.status])),
      output: parsed?.report.find((r) => r.output)?.output };
  };
  const edit = (file, from, to) => {
    const path = join(root, file);
    const text = readFileSync(path, "utf8");
    assert.ok(text.includes(from), `${file} lacks ${from}`);
    writeFileSync(path, text.replace(from, to));
    return () => writeFileSync(path, text);
  };

  assert.deepEqual(check(), { status: 0, stderr: "", statuses: { "arith/divide": "checked", "sched/next": "checked" }, output: undefined });
  assert.deepEqual(check().statuses, { "arith/divide": "cached", "sched/next": "cached" });

  const proofEdit = edit("blocks/arith/divide/Block.dfy",
    "{ assert j * e - i * e == (j - i) * e; MulAtLeast(j - i, e); }",
    "{ MulAtLeast(j - i, e); assert j * e - i * e == (j - i) * e; }");
  assert.deepEqual(check().statuses, { "arith/divide": "checked", "sched/next": "cached" });
  proofEdit();

  const lawEdit = edit("laws/arith/Divide.dfy", "ensures i * e + e <= j * e", "ensures i * e + e <= j * e && i * e < j * e");
  assert.deepEqual(check().statuses, { "arith/divide": "checked", "sched/next": "checked" });
  lawEdit();

  const falseLaw = edit("laws/arith/Divide.dfy", "q * e <= y < q * e + e", "q * e < y < q * e + e");
  const failed = check();
  assert.deepEqual([failed.status, failed.statuses], [1, { "arith/divide": "FAIL" }]);
  assert.match(failed.output, /Block\.dfy\(\d+,\d+\): Error: a postcondition could not be proved/);
  assert.match(failed.output, /Divide\.dfy\(\d+,\d+\): Related location: this is the postcondition that could not be proved/);
  assert.match(failed.output, /finished with \d+ verified, 1 error/);
  falseLaw();
  assert.deepEqual(check().statuses, { "arith/divide": "checked", "sched/next": "checked" });

  const refused = (file, from, to, message) => {
    const restore = edit(file, from, to);
    const run = check();
    restore();
    assert.equal(run.status, 2, `${file}: ${run.stderr}`);
    assert.match(run.stderr, message);
  };
  const header = 'include "../../../laws/sched/Next.dfy"';
  refused("blocks/sched/next/Block.dfy", header, `${header}\ninclude "../../arith/divide/Block.dfy"`,
    /next\/Block\.dfy includes \.\.\/\.\.\/arith\/divide\/Block\.dfy, which is neither its own file nor a dep's interface/);
  refused("blocks/sched/next/Block.dfy", header, `${header} include /* hidden */ "../../arith/divide/Block.dfy"`,
    /includes \.\.\/\.\.\/arith\/divide\/Block\.dfy, which is neither its own file nor a dep's interface/);
  refused("laws/arith/Divide.dfy", "abstract module DivideLaws", 'include "../../blocks/arith/divide/Block.dfy"\nabstract module DivideLaws',
    /arith\/divide: laws\/arith\/Divide\.dfy includes \.\.\/\.\.\/blocks\/arith\/divide\/Block\.dfy, which is neither an interface file of this block or a dep/);
  assert.deepEqual(check().statuses, { "arith/divide": "cached", "sched/next": "cached" });
});
