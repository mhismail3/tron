import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it } from "vitest";
import { TEST_SETTINGS_SCHEMA } from "../../test-support/settings-schema.js";
import { SettingsChangeRecord } from "../kernel/settings/settings-record.js";
import { OutsideChanges } from "./settings-outside.js";

const roots: string[] = [];
afterEach(async () => { for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true }); });

// Every settings read (`settings.resolve`, `home.status`) reconciles outside changes
// first. An unchanged comparison must not durably rewrite `observed.json`: under
// fsync pressure that write held the comparison mutex, and every queued read behind
// it, for tens of seconds.
it("persists observed state only when a comparison changed it", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-settings-outside-"));
  roots.push(root);
  const tronHome = join(root, "tron"), agentDir = join(root, "agent");
  await mkdir(agentDir, { recursive: true });
  await mkdir(join(tronHome, "gateway", "settings"), { recursive: true });
  const settingsPath = join(agentDir, "settings.json");
  await writeFile(settingsPath, `${JSON.stringify({ defaultThinkingLevel: "low" })}\n`);
  const outside = new OutsideChanges(TEST_SETTINGS_SCHEMA, tronHome, agentDir, new SettingsChangeRecord(tronHome), {
    global: async () => JSON.parse(await readFile(settingsPath, "utf8")) as Record<string, unknown>,
    project: async () => undefined,
  });
  try {
    const stores = [{ kind: "global" as const }, { kind: "trust" as const }];
    await outside.reconcile(stores);
    const baseline = await stat(outside.path);
    for (let read = 0; read < 5; read += 1) await outside.reconcile(stores);
    const unchanged = await stat(outside.path);
    expect([unchanged.ino, unchanged.mtimeMs]).toEqual([baseline.ino, baseline.mtimeMs]);

    await writeFile(settingsPath, `${JSON.stringify({ defaultThinkingLevel: "high" })}\n`);
    await outside.reconcile(stores);
    expect((await stat(outside.path)).ino).not.toBe(baseline.ino);
    expect(Object.keys(await outside.marks({ kind: "global" })).length).toBeGreaterThan(0);
  } finally {
    await outside.dispose();
  }
});
