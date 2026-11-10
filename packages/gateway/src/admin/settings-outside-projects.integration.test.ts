import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it } from "vitest";
import { TEST_SETTINGS_SCHEMA } from "../../test-support/settings-schema.js";
import { SettingsChangeRecord } from "../kernel/settings/settings-record.js";
import { OutsideChanges, projectStores } from "./settings-outside.js";

const roots: string[] = [];
afterEach(async () => { for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true }); });

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "tron-settings-outside-projects-"));
  roots.push(root);
  const tronHome = join(root, "tron"), agentDir = join(root, "agent");
  await mkdir(agentDir, { recursive: true });
  await mkdir(join(tronHome, "gateway", "settings"), { recursive: true });
  const outside = new OutsideChanges(TEST_SETTINGS_SCHEMA, tronHome, agentDir, new SettingsChangeRecord(tronHome), {
    global: async () => ({}),
    project: async project => {
      try { return JSON.parse(await readFile(join(project, ".pi", "settings.json"), "utf8")) as Record<string, unknown>; }
      catch { return undefined; }
    },
  });
  const project = async (name: string, thinking: string) => {
    const path = join(root, "projects", name);
    await mkdir(join(path, ".pi"), { recursive: true });
    await writeFile(join(path, ".pi", "settings.json"), `${JSON.stringify({ defaultThinkingLevel: thinking })}\n`);
    return path;
  };
  const storeIds = async () => Object.keys((JSON.parse(await readFile(outside.path, "utf8")) as { stores: Record<string, unknown> }).stores).sort();
  return { root, outside, project, storeIds };
}

it("keeps every known project's observed state however many are registered", async () => {
  const { outside, project, storeIds } = await fixture();
  try {
    const projects: string[] = [];
    for (let index = 0; index < 70; index += 1) {
      projects.push(await project(`p${String(index).padStart(2, "0")}`, "low"));
      await outside.reconcile(projectStores(projects.at(-1)!));
    }
    expect((await storeIds()).filter(id => id.startsWith("project:")).length).toBe(70);
    expect((await storeIds()).filter(id => id.startsWith("project-mcp:")).length).toBe(70);

    await writeFile(join(projects[0]!, ".pi", "settings.json"), `${JSON.stringify({ defaultThinkingLevel: "high" })}\n`);
    await outside.reconcile(projectStores(projects[0]!));
    expect(Object.values(await outside.marks({ kind: "project", root: projects[0]! }))).toEqual([
      expect.objectContaining({ before: "Low", after: "High" }),
    ]);
  } finally {
    await outside.dispose();
  }
});

it("forgets a project whose root was removed from disk", async () => {
  const { outside, project, storeIds } = await fixture();
  try {
    const kept = await project("kept", "low");
    const removed = await project("removed", "low");
    await outside.reconcile([...projectStores(kept), ...projectStores(removed)]);
    expect(await storeIds()).toEqual([`project-mcp:${kept}`, `project-mcp:${removed}`, `project:${kept}`, `project:${removed}`].sort());

    await rm(removed, { recursive: true, force: true });
    await writeFile(join(kept, ".pi", "settings.json"), `${JSON.stringify({ defaultThinkingLevel: "high" })}\n`);
    await outside.reconcile(projectStores(kept));
    expect(await storeIds()).toEqual([`project-mcp:${kept}`, `project:${kept}`]);

    await outside.reconcile(projectStores(removed));
    expect(await storeIds()).toEqual([`project-mcp:${kept}`, `project:${kept}`]);
  } finally {
    await outside.dispose();
  }
});
