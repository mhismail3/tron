import { chmod, lstat, mkdir, mkdtemp, readFile, rename, rm, symlink, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  cleanupDelegatedRootCutover,
  preflightDelegatedRootCutover,
  publishDelegatedRootCutover,
  recoverDelegatedRootCutover,
  stageDelegatedRootCutover,
  verifyDelegatedRootCutover,
} from "./delegated-root-migration.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });
async function fixture(prefix: string) { const root = await mkdtemp(join(tmpdir(), prefix)); roots.push(root); return root; }

function options(root: string) {
  return {
    legacyRoots: [join(root, "legacy")],
    destinationRoot: join(root, "tron", "internal", "subagents"),
    staging: join(root, "staging", "subagents"),
    acknowledgeQuiescence: true,
    acknowledgeBackup: true,
  };
}

async function retainedRun(root: string, state: "completed" | "running" = "completed") {
  const run = join(root, "async-subagent-runs", "run-1");
  await mkdir(run, { recursive: true, mode: 0o700 });
  await writeFile(join(run, "status.json"), JSON.stringify({ runId: "run-1", state, asyncDir: run,
    processTerminal: state === "completed" ? { state: "observed" } : undefined }), { mode: 0o600 });
  await writeFile(join(run, "events.jsonl"), `${JSON.stringify({ runId: "run-1", asyncDir: run })}\n`, { mode: 0o600 });
}

describe("delegated provider root cutover", () => {
  it("uses the pinned provider root contract in an isolated child process", () => {
    const provider = join(homedir(), ".tron", "agent", "npm", "node_modules", "pi-subagents");
    if (!existsSync(join(provider, "src", "shared", "types.ts"))) return;
    const root = join(tmpdir(), `tron-provider-fixture-${process.pid}`);
    const output = execFileSync(process.execPath, ["--input-type=module", "--eval", [
      "import { createJiti } from 'jiti';",
      "const dirs = await createJiti(process.cwd() + '/fixture.mjs').import('./src/shared/types.ts');",
      "console.log(JSON.stringify(dirs.DIRS));",
    ].join(" ")], { cwd: provider, env: { ...process.env, PI_SUBAGENTS_TEMP_ROOT: root }, encoding: "utf8" });
    const dirs = JSON.parse(output.trim()) as { async: string; results: string };
    expect(dirs.async).toBe(join(root, "async-subagent-runs"));
    expect(dirs.results).toBe(join(root, "async-subagent-results"));
  });
  it("inventories and migrates retained terminal artifacts while rewriting only provider-root references", async () => {
    const root = await fixture("tron-delegated-cutover-");
    const value = options(root);
    await mkdir(join(root, "tron", "internal"), { recursive: true, mode: 0o700 });
    await retainedRun(value.legacyRoots[0]!);
    const preflight = await preflightDelegatedRootCutover(value);
    expect(preflight.status).toBe("migration-required");
    expect(preflight.roots[0]).toMatchObject({ entries: 2, activeRuns: [], resumabilityRefusals: [] });
    const staged = await stageDelegatedRootCutover(value);
    await verifyDelegatedRootCutover(value.staging);
    const status = JSON.parse(await readFile(join(value.staging, "async-subagent-runs", "run-1", "status.json"), "utf8"));
    expect(status.asyncDir).toBe(value.destinationRoot + "/async-subagent-runs/run-1");
    await publishDelegatedRootCutover(value.staging);
    expect(await readFile(join(value.destinationRoot, "async-subagent-runs", "run-1", "status.json"), "utf8")).toContain(value.destinationRoot);
    await expect(lstat(value.legacyRoots[0]!)).rejects.toMatchObject({ code: "ENOENT" });
    expect(staged.entries.every(entry => entry.digest.length === 64 && entry.stagedDigest.length === 64)).toBe(true);
  });

  it("refuses active runs and unsafe resumability instead of fabricating continuity", async () => {
    const root = await fixture("tron-delegated-cutover-active-");
    const value = options(root);
    await retainedRun(value.legacyRoots[0]!, "running");
    const preflight = await preflightDelegatedRootCutover(value);
    expect(preflight.status).toBe("conflict");
    expect(preflight.roots[0]!.activeRuns).toHaveLength(1);
    await expect(stageDelegatedRootCutover(value)).rejects.toThrow(/active|unresumable/);
  });

  it("preserves protected permissions and rejects a symlinked or broad tree", async () => {
    const root = await fixture("tron-delegated-cutover-safe-");
    const value = options(root);
    await mkdir(join(root, "tron", "internal"), { recursive: true, mode: 0o700 });
    await retainedRun(value.legacyRoots[0]!);
    await chmod(join(value.legacyRoots[0]!, "async-subagent-runs", "run-1", "status.json"), 0o644);
    await expect(preflightDelegatedRootCutover(value)).rejects.toThrow(/private/);
  });

  it("rejects unmanifested staged files and staged symlinks before publication", async () => {
    const root = await fixture("tron-delegated-cutover-staged-integrity-");
    const value = options(root);
    await mkdir(join(root, "tron", "internal"), { recursive: true, mode: 0o700 });
    await retainedRun(value.legacyRoots[0]!);
    await stageDelegatedRootCutover(value);
    await writeFile(join(value.staging, "unexpected.json"), "unexpected", { mode: 0o600 });
    await expect(verifyDelegatedRootCutover(value.staging)).rejects.toThrow(/missing or extra/);
    await expect(lstat(value.destinationRoot)).rejects.toMatchObject({ code: "ENOENT" });
    await rm(join(value.staging, "unexpected.json"));
    await symlink("status.json", join(value.staging, "staged-link"));
    await expect(verifyDelegatedRootCutover(value.staging)).rejects.toThrow(/symlink/);
    await expect(lstat(value.destinationRoot)).rejects.toMatchObject({ code: "ENOENT" });
  });

  it.each(["added", "removed"] as const)("rejects a source path %s after staging without retiring the source", async mutation => {
    const root = await fixture(`tron-delegated-cutover-source-${mutation}-`);
    const value = options(root);
    await mkdir(join(root, "tron", "internal"), { recursive: true, mode: 0o700 });
    await retainedRun(value.legacyRoots[0]!);
    await stageDelegatedRootCutover(value);
    const status = join(value.legacyRoots[0]!, "async-subagent-runs", "run-1", "status.json");
    if (mutation === "added") await writeFile(join(value.legacyRoots[0]!, "new.json"), "new", { mode: 0o600 });
    else await rm(status);
    await expect(publishDelegatedRootCutover(value.staging)).rejects.toThrow(/source/);
    expect(await lstat(value.legacyRoots[0]!)).toBeTruthy();
    await expect(lstat(value.destinationRoot)).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("rejects changed source directory metadata before retirement", async () => {
    const root = await fixture("tron-delegated-cutover-directory-drift-");
    const value = options(root);
    await mkdir(join(root, "tron", "internal"), { recursive: true, mode: 0o700 });
    await retainedRun(value.legacyRoots[0]!);
    await stageDelegatedRootCutover(value);
    await chmod(join(value.legacyRoots[0]!, "async-subagent-runs"), 0o710);
    await expect(publishDelegatedRootCutover(value.staging)).rejects.toThrow(/source directory|unsafe directory/);
    expect(await lstat(value.legacyRoots[0]!)).toBeTruthy();
    await expect(lstat(value.destinationRoot)).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("recovers publication after source retirement without creating a second authority", async () => {
    const root = await fixture("tron-delegated-cutover-recovery-");
    const value = options(root);
    await mkdir(join(root, "tron", "internal"), { recursive: true, mode: 0o700 });
    await retainedRun(value.legacyRoots[0]!);
    const staged = await stageDelegatedRootCutover(value);
    const markerPath = `${value.staging}.tron-delegated-cutover.json`;
    const marker = JSON.parse(await readFile(markerPath, "utf8"));
    await rename(value.legacyRoots[0]!, `${value.legacyRoots[0]}.retired-${marker.operationID}`);
    await writeFile(markerPath, JSON.stringify({ ...marker, phase: "source-retired" }) + "\n");
    const recovered = await recoverDelegatedRootCutover(value.staging);
    expect(recovered.action).toBe("finish-publication");
    expect(recovered.marker.phase).toBe("published");
    expect(await lstat(value.destinationRoot)).toBeTruthy();
    await expect(cleanupDelegatedRootCutover(value.staging)).rejects.toThrow();
    expect(staged.operationID).toBe(marker.operationID);
  });
});
