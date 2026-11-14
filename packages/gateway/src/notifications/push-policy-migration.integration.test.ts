import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { applyPushPolicyMigration, planPushPolicyMigration, restorePushPolicyMigration } from "./push-policy-migration.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true }))); });

const documentPath = (home: string) => join(home, "state", "notifications.json");
const settingsPath = (home: string) => join(home, "state", "settings", "gateway.json");

async function seed(version: 2 | 3 = 2): Promise<string> {
  const home = await mkdtemp(join(tmpdir(), "tron-push-policy-migration-"));
  roots.push(home);
  await mkdir(dirname(documentPath(home)), { recursive: true });
  const document = version === 2
    ? { version: 2, policy: { notifyWhenAskPresented: false, notifyWhenFinished: true, notifyWhenWaiting: false }, grants: [], pending: [], receipts: [], revocations: [], inbox: [] }
    : { version: 3, grants: [], pending: [], receipts: [], revocations: [], inbox: [] };
  await writeFile(documentPath(home), `${JSON.stringify(document, null, 2)}\n`);
  return home;
}

describe("push policy migration", () => {
  it("moves the three stored booleans into the Global keys with both stores backed up, and restores exactly", async () => {
    const home = await seed();
    const originalDocument = await readFile(documentPath(home));
    const plan = await planPushPolicyMigration(home);
    expect(plan.policy).toEqual({ inputNeeded: false, finished: true, waiting: false });
    const backup = join(home, "backup-1");
    expect(await applyPushPolicyMigration(plan, backup)).toBe(true);
    expect(JSON.parse(await readFile(settingsPath(home), "utf8"))).toEqual({
      notifications: { push: { inputNeeded: false, finished: true, waiting: false } },
    });
    expect(JSON.parse(await readFile(documentPath(home), "utf8"))).toMatchObject({ version: 3 });
    expect(JSON.parse(await readFile(documentPath(home), "utf8"))).not.toHaveProperty("policy");
    expect(await readFile(join(backup, "notifications.json"))).toEqual(originalDocument);
    expect(await restorePushPolicyMigration(backup)).toBe(true);
    expect(await readFile(documentPath(home))).toEqual(originalDocument);
    await expect(stat(settingsPath(home))).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("recovers from a crash after the settings write and reruns to the same bytes", async () => {
    const home = await seed();
    const clean = await planPushPolicyMigration(home);
    const settingsAfter = clean.changes[0]!.after;
    await mkdir(dirname(settingsPath(home)), { recursive: true });
    await writeFile(settingsPath(home), settingsAfter);
    const rerun = await planPushPolicyMigration(home);
    expect(rerun.changes.map(change => change.path)).toEqual([settingsPath(home), documentPath(home)]);
    expect(await applyPushPolicyMigration(rerun, join(home, "backup-2"))).toBe(true);
    expect(await readFile(settingsPath(home))).toEqual(settingsAfter);
    expect(JSON.parse(await readFile(documentPath(home), "utf8"))).toMatchObject({ version: 3 });
    expect(await planPushPolicyMigration(home)).toEqual({ changes: [] });
    expect(await applyPushPolicyMigration(await planPushPolicyMigration(home), join(home, "backup-3"))).toBe(false);
  });

  it("does nothing to a store already at version 3", async () => {
    const home = await seed(3);
    expect(await planPushPolicyMigration(home)).toEqual({ changes: [] });
    expect(JSON.parse(await readFile(documentPath(home), "utf8"))).toMatchObject({ version: 3 });
  });

  it("refuses a version 2 store whose policy is not three booleans, writing nothing", async () => {
    const home = await seed();
    await writeFile(documentPath(home), JSON.stringify({ version: 2, policy: { notifyWhenAskPresented: "no" }, grants: [], pending: [], receipts: [], revocations: [], inbox: [] }));
    const before = await readFile(documentPath(home));
    await expect(planPushPolicyMigration(home)).rejects.toThrow("three policy booleans");
    expect(await readFile(documentPath(home))).toEqual(before);
    await expect(stat(settingsPath(home))).rejects.toMatchObject({ code: "ENOENT" });
  });
});
