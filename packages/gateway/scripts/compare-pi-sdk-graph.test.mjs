import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { piGraphChanged, piGraphDocument, comparePiSdkRevisions } from "./compare-pi-sdk-graph.mjs";

test("compares the complete resolved Pi dependency closure without unrelated metadata", () => {
  const packageJson = { dependencies: { "@earendil-works/pi-ai": "9.1.0" }, description: "one" };
  const lock = { packages: {
    "node_modules/@earendil-works/pi-ai": { version: "9.1.0", resolved: "a", dependencies: { shared: "1" } },
    "node_modules/shared": { version: "1", dependencies: { nested: "1" } },
    "node_modules/shared/node_modules/nested": { version: "1" },
    "node_modules/unrelated": { version: "1" },
  } };
  assert.equal(piGraphChanged(packageJson, lock, { ...packageJson, description: "two" }, lock), false);
  assert.equal(piGraphChanged(packageJson, lock, { dependencies: { "@earendil-works/pi-ai": "9.1.1" } }, lock), true);

  const graph = piGraphDocument(packageJson, lock);
  assert.deepEqual(Object.keys(graph.resolved), [
    "node_modules/@earendil-works/pi-ai",
    "node_modules/shared",
    "node_modules/shared/node_modules/nested",
  ]);
  const changedClosure = structuredClone(lock);
  changedClosure.packages["node_modules/shared"].version = "2";
  assert.equal(piGraphChanged(packageJson, lock, packageJson, changedClosure), true);
  const changedUnrelated = structuredClone(lock);
  changedUnrelated.packages["node_modules/unrelated"].version = "2";
  assert.equal(piGraphChanged(packageJson, lock, packageJson, changedUnrelated), false);
  assert.equal(
    piGraphChanged(packageJson, lock, { dependencies: { ...packageJson.dependencies, "@earendil-works/pi-new": "1.0.0" } }, lock),
    true,
  );
});

test("compares committed package revisions deterministically", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-pi-graph-"));
  try {
    execFileSync("git", ["init", "-q"], { cwd: root });
    const pkg = (version) => JSON.stringify({ dependencies: { "@earendil-works/pi-ai": version } });
    const lock = (version) => JSON.stringify({ packages: { "node_modules/@earendil-works/pi-ai": { version, resolved: `pi-${version}` } } });
    await writeFile(join(root, "package.json"), pkg("9.1.0")); await writeFile(join(root, "package-lock.json"), lock("9.1.0"));
    execFileSync("git", ["add", "."], { cwd: root }); execFileSync("git", ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "one"], { cwd: root });
    const base = execFileSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" }).trim();
    await writeFile(join(root, "package.json"), pkg("9.1.1")); await writeFile(join(root, "package-lock.json"), lock("9.1.1"));
    execFileSync("git", ["add", "."], { cwd: root }); execFileSync("git", ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "two"], { cwd: root });
    const candidate = execFileSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" }).trim();
    assert.equal(comparePiSdkRevisions({ repoDir: root, base, candidate, gatewayPath: "." }).changed, true);
  } finally { await rm(root, { recursive: true, force: true }); }
});
