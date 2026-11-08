// Integration test for `scripts/tron proof check` (tools/proof/README.md "Check"): the real CLI with the
// pinned toolchain on a copy of two fixture blocks, sched/next (laws proven from arith/divide's laws only)
// above arith/divide, with a disposable cache:
// cold check runs both; a warm run is all cached; a proof-only edit re-checks only that block; a law edit
// re-checks it and the block above; a deliberately false law fails (exit 1) and the block above never runs;
// an include of a dep's implementation is refused (exit 2).
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
    const run = spawnSync(join(ROOT, "scripts/tron"), ["proof", "check", "--root", root, "--cache", cache, "--json"], { encoding: "utf8", timeout: 600_000 });
    const parsed = run.status === 2 ? null : JSON.parse(run.stdout);
    return { status: run.status, stderr: run.stderr, statuses: parsed && Object.fromEntries(parsed.report.map((r) => [r.block, r.status])) };
  };
  const edit = (file, from, to) => {
    const path = join(root, file);
    const text = readFileSync(path, "utf8");
    assert.ok(text.includes(from), `${file} lacks ${from}`);
    writeFileSync(path, text.replace(from, to));
    return () => writeFileSync(path, text);
  };

  assert.deepEqual(check(), { status: 0, stderr: "", statuses: { "arith/divide": "checked", "sched/next": "checked" } });
  assert.deepEqual(check().statuses, { "arith/divide": "cached", "sched/next": "cached" });

  const proofEdit = edit("blocks/arith/divide/Block.dfy",
    "{ assert j * e - i * e == (j - i) * e; MulAtLeast(j - i, e); }",
    "{ MulAtLeast(j - i, e); assert j * e - i * e == (j - i) * e; }");
  assert.deepEqual(check(), { status: 0, stderr: "", statuses: { "arith/divide": "checked", "sched/next": "cached" } });
  proofEdit();

  const lawEdit = edit("laws/arith/Divide.dfy", "ensures i * e + e <= j * e", "ensures i * e + e <= j * e && i * e < j * e");
  assert.deepEqual(check(), { status: 0, stderr: "", statuses: { "arith/divide": "checked", "sched/next": "checked" } });
  lawEdit();

  const falseLaw = edit("laws/arith/Divide.dfy", "q * e <= y < q * e + e", "q * e < y < q * e + e");
  assert.deepEqual(check(), { status: 1, stderr: "", statuses: { "arith/divide": "FAIL" } });
  falseLaw();
  // The cache keeps one passing key per block (the law edit's), so the restored laws re-check both.
  assert.deepEqual(check().statuses, { "arith/divide": "checked", "sched/next": "checked" });

  edit("blocks/sched/next/Block.dfy", 'include "../../../laws/sched/Next.dfy"',
    'include "../../../laws/sched/Next.dfy"\ninclude "../../arith/divide/Block.dfy"');
  const leak = check();
  assert.equal(leak.status, 2);
  assert.match(leak.stderr, /includes \.\.\/\.\.\/arith\/divide\/Block\.dfy, which is neither its own file nor a dep's interface/);
});
