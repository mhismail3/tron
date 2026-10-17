import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

// The checked-in Oxlint allowlist, run through the binary `npm ci` installed from the lockfile
// against real source files in a temp directory. Nothing is mocked, and the fixtures are removed.
const gatewayRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const oxlint = join(gatewayRoot, "node_modules", ".bin", "oxlint");
const config = join(gatewayRoot, ".oxlintrc.json");

// The same flags as the `lint` script in package.json.
const flags = ["-c", config, "--deny-warnings", "--report-unused-disable-directives"];

async function lintFixture(files) {
  const root = await mkdtemp(join(tmpdir(), "tron-oxlint-rules-"));
  try {
    await Promise.all(Object.entries(files).map(([name, text]) => writeFile(join(root, name), text)));
    const run = spawnSync(oxlint, [...flags, "."], {
      cwd: root,
      encoding: "utf8",
      env: { ...process.env, HOME: root, TMPDIR: root },
    });
    if (run.error) throw run.error;
    return { status: run.status, output: `${run.stdout}${run.stderr}` };
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

test("fails at file and line for each enabled rule and for an unused disable directive", async () => {
  const { status, output } = await lintFixture({
    "dupe-keys.ts": 'export const modes = { mode: "asynchronous", mode: "workflow" };\n',
    "optional-non-null.ts": "export function size(input?: { size: number }): number {\n  return input?.size!;\n}\n",
    "unused-disable.ts": "// oxlint-disable-next-line eslint/no-dupe-keys -- nothing to suppress here\nexport const ok = { mode: \"workflow\" };\n",
  });
  assert.notEqual(status, 0);
  assert.match(output, /dupe-keys\.ts:1:\d+: error eslint\(no-dupe-keys\)/u);
  assert.match(output, /optional-non-null\.ts:2:\d+: error typescript\(no-non-null-asserted-optional-chain\)/u);
  assert.match(output, /unused-disable\.ts:1:\d+: warning: Unused oxlint-disable directive/u);
});

test("passes code that uses the enabled rules' intended forms under the same flags", async () => {
  const { status, output } = await lintFixture({
    "clean.ts": "export const modes = { mode: \"workflow\" };\nexport function size(input?: { size: number }): number | undefined {\n  return input?.size;\n}\n",
  });
  assert.equal(status, 0, output);
  assert.equal(output.trim(), "");
});
