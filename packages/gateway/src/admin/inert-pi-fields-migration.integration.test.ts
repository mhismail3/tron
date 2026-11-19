import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { applyInertPiFields, planInertPiFields, restoreInertPiFields } from "./inert-pi-fields-migration.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });

const SETTINGS = { lastChangelogVersion: "0.84.1", theme: "dark", defaultProvider: "openai", hideThinkingBlock: true, compaction: { mode: "on" } };

async function seed(): Promise<{ agentDir: string; path: string; original: Buffer }> {
  const root = await mkdtemp(join(tmpdir(), "tron-inert-pi-fields-"));
  roots.push(root);
  const agentDir = join(root, "agent");
  await mkdir(agentDir);
  const path = join(agentDir, "settings.json");
  await writeFile(path, JSON.stringify(SETTINGS, null, 2));
  return { agentDir, path, original: await readFile(path) };
}

describe("inert Pi settings fields migration", () => {
  it("backs up, removes only theme and hideThinkingBlock, restores them, and is a no-op once applied", async () => {
    const { agentDir, path, original } = await seed();
    const plan = await planInertPiFields(agentDir);
    expect(plan.fields).toEqual(["theme", "hideThinkingBlock"]);
    expect(await readFile(path)).toEqual(original);
    const backup = join(agentDir, "..", "backup");
    expect(await applyInertPiFields(plan, backup)).toBe(true);
    expect(JSON.parse(await readFile(path, "utf8"))).toEqual({ lastChangelogVersion: "0.84.1", defaultProvider: "openai", compaction: { mode: "on" } });
    expect(await readFile(join(backup, "settings.json"))).toEqual(original);
    expect((await planInertPiFields(agentDir)).fields).toEqual([]);
    expect(await restoreInertPiFields(backup)).toBe(true);
    expect(JSON.parse(await readFile(path, "utf8"))).toEqual(SETTINGS);
    expect(await restoreInertPiFields(backup)).toBe(false);
  });

  it("refuses a non-empty backup directory and a file that changed after the plan, leaving settings untouched", async () => {
    const { agentDir, path, original } = await seed();
    const busy = join(agentDir, "..", "busy");
    await mkdir(busy); await writeFile(join(busy, "other"), "x");
    await expect(applyInertPiFields(await planInertPiFields(agentDir), busy)).rejects.toThrow("is not empty");
    expect(await readFile(path)).toEqual(original);
    const plan = await planInertPiFields(agentDir);
    await writeFile(path, JSON.stringify({ ...SETTINGS, defaultProvider: "anthropic" }, null, 2));
    await expect(applyInertPiFields(plan, join(agentDir, "..", "late"))).rejects.toThrow();
    expect(JSON.parse(await readFile(path, "utf8"))).toEqual({ ...SETTINGS, defaultProvider: "anthropic" });
  });
});
