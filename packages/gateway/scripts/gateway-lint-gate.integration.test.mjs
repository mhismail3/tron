import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, readdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

// The real gate CLI (the program `scripts/tron gate` execs) runs the real `gateway.lint` catalog
// entry, copied verbatim, against a temp Git repository. Only its prerequisite and a later check are
// stand-ins, so the proof is about gate wiring, not the step's command. This suite runs in the
// `gateway.scripts` step, not in `gateway.lint`, which keeps the lint pass under its time target.

const gatewayRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const repoRoot = resolve(gatewayRoot, "..", "..");
const gate = join(repoRoot, "tools", "work", "gate.py");
const realCatalog = JSON.parse(await readFile(join(repoRoot, "tools", "work", "gate-catalog.json"), "utf8"));
const realLint = realCatalog.steps.find((step) => step.id === "gateway.lint");
const realPackage = JSON.parse(await readFile(join(gatewayRoot, "package.json"), "utf8"));
const realLintScript = realPackage.scripts.lint;
const realLintRulesScript = realPackage.scripts["test:lint"];
const duplicateKey = 'export const modes = { mode: "asynchronous", mode: "workflow" };\n';

function runGit(cwd, env, args) {
  const result = spawnSync("git", args, { cwd, env, encoding: "utf8" });
  if (result.status !== 0) throw new Error(`git ${args.join(" ")} failed: ${result.stderr}`);
  return result.stdout.trim();
}

async function fixtureRepo(t) {
  const root = await mkdtemp(join(tmpdir(), "tron-gateway-lint-gate-"));
  // HOME and TMPDIR sit outside the repository: the gate's own temporary index would otherwise
  // be a worktree file, and the workspace tree would never equal the committed tree.
  const scratch = await mkdtemp(join(tmpdir(), "tron-gateway-lint-gate-scratch-"));
  t.after(() => Promise.all([rm(root, { recursive: true, force: true }), rm(scratch, { recursive: true, force: true })]));
  const traceFile = join(scratch, "trace");
  const catalogFile = join(scratch, "catalog.json");
  // Every subprocess (git, gate, npm, oxlint) runs with a HOME and TMPDIR owned by this fixture.
  const env = {
    ...process.env, HOME: scratch, TMPDIR: scratch,
    GIT_AUTHOR_NAME: "Fixture", GIT_AUTHOR_EMAIL: "fixture@example.invalid",
    GIT_COMMITTER_NAME: "Fixture", GIT_COMMITTER_EMAIL: "fixture@example.invalid",
    GATE_TRACE: traceFile, TRON_GATE_CATALOG: catalogFile, TRON_GATE_HEARTBEAT_SECONDS: "0.5",
  };
  const write = async (path, text) => {
    await mkdir(dirname(join(root, path)), { recursive: true });
    await writeFile(join(root, path), text);
  };
  const git = (...args) => runGit(root, env, args);

  await write("README.md", "fixture\n");
  await write(".gitignore", "node_modules\n");
  await write(".node-version", await readFile(join(repoRoot, ".node-version"), "utf8"));
  await write(".github/work.json", await readFile(join(repoRoot, ".github", "work.json"), "utf8"));
  // Each gate step runs behind the pinned-Node preamble, which calls scripts/tron-node.
  await write("scripts/tron-node", await readFile(join(repoRoot, "scripts", "tron-node"), "utf8"));
  await chmod(join(root, "scripts", "tron-node"), 0o755);
  git("init", "-q", "-b", "main");
  git("add", "-A");
  git("commit", "-q", "-m", "base");
  git("update-ref", "refs/remotes/origin/main", "HEAD");
  git("checkout", "-q", "-b", "feature");

  // The Gateway lint surface: the real config and rule-regression script, a clean source tree, and
  // the real node_modules, so the pinned oxlint binary runs unchanged.
  await write("packages/gateway/package.json", `${JSON.stringify({
    name: "fixture-gateway", private: true,
    scripts: { lint: realLintScript, "test:lint": realLintRulesScript },
  }, null, 2)}\n`);
  await write("packages/gateway/.oxlintrc.json", await readFile(join(gatewayRoot, ".oxlintrc.json"), "utf8"));
  await write("packages/gateway/scripts/oxlint-rules.integration.test.mjs",
    await readFile(join(gatewayRoot, "scripts", "oxlint-rules.integration.test.mjs"), "utf8"));
  await write("packages/gateway/src/clean.ts", "export const modes = { mode: \"workflow\" };\n");
  await write("packages/gateway/test-support/clean.ts", "export const support = 1;\n");
  await write("packages/gateway/test-fixtures/clean.ts", "export const fixture = 1;\n");
  await symlink(join(gatewayRoot, "node_modules"), join(root, "packages", "gateway", "node_modules"));

  // The real lint entry, plus stand-ins only for its prerequisite and a later check that records a trace.
  const catalog = {
    version: 1,
    codeExclude: realCatalog.codeExclude,
    steps: [
      { id: "gateway.deps", tier: "L0", trigger: { paths: ["packages/gateway/**"], code: true },
        command: 'echo deps >> "$GATE_TRACE"', inputs: ["packages/gateway", ".node-version"],
        budgetSeconds: 5, timeoutSeconds: 10, class: "light", expectedRssMb: 10, pass: "exit 0", unlocks: "gateway.lint" },
      realLint,
      { id: "gateway.typecheck", tier: "L0", trigger: { paths: ["packages/gateway/**"], code: true },
        after: ["gateway.lint"], command: 'echo typecheck >> "$GATE_TRACE"', inputs: ["packages/gateway", ".node-version"],
        budgetSeconds: 5, timeoutSeconds: 10, class: "light", expectedRssMb: 10, pass: "exit 0", unlocks: "gateway.affected" },
    ],
  };
  await writeFile(catalogFile, `${JSON.stringify(catalog, null, 2)}\n`);

  return {
    root,
    git,
    write,
    commit: (message) => { git("add", "-A"); git("commit", "-q", "-m", message); },
    gate: (...args) => {
      const result = spawnSync("python3", [gate, ...args], { cwd: root, env, encoding: "utf8", timeout: 120_000 });
      return { status: result.status, output: `${result.stdout}${result.stderr}` };
    },
    trace: async () => {
      let text = "";
      try { text = await readFile(traceFile, "utf8"); } catch (error) { if (error.code !== "ENOENT") throw error; }
      await rm(traceFile, { force: true });
      return text.split(/\s+/u).filter(Boolean);
    },
    receipts: async () => {
      const directory = join(root, ".git", "work", "gate", "receipts");
      return (await readdir(directory).catch(() => [])).map((name) => join(directory, name));
    },
  };
}

test("a Gateway lint violation stops gate run at gateway.lint and never starts the later check", { timeout: 120_000 }, async (t) => {
  const fixture = await fixtureRepo(t);
  await fixture.write("packages/gateway/src/bad.ts", duplicateKey);

  const run = fixture.gate("run");
  assert.equal(run.status, 1, run.output);
  assert.match(run.output, /gateway\.lint/u, run.output);
  // The real oxlint finding reaches the gate log with its file and line.
  assert.match(run.output, /bad\.ts:1:\d+: error eslint\(no-dupe-keys\)/u, run.output);
  assert.deepEqual(await fixture.trace(), ["deps"], "gateway.typecheck must not start after the lint failure");
  assert.deepEqual(await fixture.receipts(), [], "a failed plan records no receipt");
});

test("a clean committed Gateway tree passes, records a receipt, reuses it, and reruns lint when a linted input changes", { timeout: 120_000 }, async (t) => {
  const fixture = await fixtureRepo(t);
  fixture.commit("gateway lint fixture");

  const first = fixture.gate("run");
  assert.equal(first.status, 0, first.output);
  assert.deepEqual(await fixture.trace(), ["deps", "typecheck"]);
  const [receipt] = await fixture.receipts();
  assert.ok(receipt, "a passing whole-plan run of a committed tree records a receipt");
  const checks = JSON.parse(await readFile(receipt, "utf8")).checks.map((check) => check.shard);
  assert.ok(checks.includes("gateway.lint"), `receipt checks: ${checks.join(", ")}`);

  const reused = fixture.gate("run");
  assert.equal(reused.status, 0, reused.output);
  assert.match(reused.output, /gateway\.lint: reused pass/u, reused.output);
  assert.deepEqual(await fixture.trace(), [], "an unchanged tree reuses every passing step");

  await fixture.write("packages/gateway/src/clean.ts", "export const modes = { mode: \"changed\" };\n");
  fixture.commit("edit a linted source");
  const edited = fixture.gate("run");
  assert.equal(edited.status, 0, edited.output);
  assert.doesNotMatch(edited.output, /gateway\.lint: reused pass/u, "an edited input invalidates the lint step");
  assert.deepEqual(await fixture.trace(), ["deps", "typecheck"]);
});
