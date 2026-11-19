import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { acquireAgentRuntimeLock } from "../sessions/agent-runtime-lock.js";
import { applyObservedGitResidue, planObservedGitResidue, restoreObservedGitResidue } from "./observed-git-residue-migration.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });

const STORES = {
  global: { digest: "g", values: {}, tron: {}, outside: {} },
  "project:/repo": { digest: "p", values: { a: { key: "run.transport", value: "auto" } }, tron: {}, outside: {}, staged: [], head: "abc123" },
  "project-mcp:/repo": { digest: "m", values: {}, tron: {}, outside: {}, staged: [], head: null },
};

async function seed(): Promise<{ home: string; path: string; original: Buffer }> {
  const home = await mkdtemp(join(tmpdir(), "tron-observed-git-residue-"));
  roots.push(home);
  const path = join(home, "state", "settings", "observed.json");
  await mkdir(join(home, "state", "settings"), { recursive: true });
  await writeFile(path, JSON.stringify({ version: 1, stores: STORES }));
  return { home, path, original: await readFile(path) };
}

describe("observed settings git residue migration", () => {
  it("backs up, strips the retired staged/head fields from every store, restores exactly, and is a no-op once applied", async () => {
    const { home, path, original } = await seed();
    const plan = await planObservedGitResidue(home);
    expect(plan.stores).toBe(2);
    expect(await readFile(path)).toEqual(original);
    const backup = join(home, "backup");
    expect(await applyObservedGitResidue(plan, backup, join(home, "agent"))).toBe(true);
    const migrated = JSON.parse(await readFile(path, "utf8")) as { version: number; stores: Record<string, Record<string, unknown>> };
    expect(migrated).toEqual({ version: 1, stores: {
      global: STORES.global,
      "project:/repo": { digest: "p", values: { a: { key: "run.transport", value: "auto" } }, tron: {}, outside: {} },
      "project-mcp:/repo": { digest: "m", values: {}, tron: {}, outside: {} },
    } });
    expect(await readFile(join(backup, "observed.json"))).toEqual(original);
    expect((await planObservedGitResidue(home)).stores).toBe(0);
    expect(await restoreObservedGitResidue(backup, join(home, "agent"))).toBe(true);
    expect(await readFile(path)).toEqual(original);
    expect(await restoreObservedGitResidue(backup, join(home, "agent"))).toBe(false);
  });

  it("refuses a non-empty backup directory and leaves the store untouched", async () => {
    const { home, path, original } = await seed();
    const backup = join(home, "backup");
    await mkdir(backup); await writeFile(join(backup, "other"), "x");
    await expect(applyObservedGitResidue(await planObservedGitResidue(home), backup, join(home, "agent"))).rejects.toThrow("is not empty");
    expect(await readFile(path)).toEqual(original);
  });

  it("refuses apply and restore while a Gateway owns the agent directory, leaving the store untouched", async () => {
    const { home, path, original } = await seed();
    const agentDir = join(home, "agent");
    const backup = join(home, "backup");
    const plan = await planObservedGitResidue(home);
    let release = await acquireAgentRuntimeLock(agentDir);
    try {
      await expect(applyObservedGitResidue(plan, backup, agentDir)).rejects.toThrow("Another Tron Gateway");
      expect(await readFile(path)).toEqual(original);
    } finally { await release(); }
    expect(await applyObservedGitResidue(plan, backup, agentDir)).toBe(true);
    const migrated = await readFile(path);
    release = await acquireAgentRuntimeLock(agentDir);
    try {
      await expect(restoreObservedGitResidue(backup, agentDir)).rejects.toThrow("Another Tron Gateway");
      expect(await readFile(path)).toEqual(migrated);
    } finally { await release(); }
    expect(await restoreObservedGitResidue(backup, agentDir)).toBe(true);
    expect(await readFile(path)).toEqual(original);
  });
});
