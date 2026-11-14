import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { migratePushPolicy, restorePushPolicyMigration } from "./push-policy-migration.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true }))); });

const documentPath = (home: string) => join(home, "state", "notifications.json");
const settingsPath = (home: string) => join(home, "state", "settings", "gateway.json");
const backupPath = (home: string) => join(home, "state", "migrations", "push-policy-v3");

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

describe("push policy migration at Gateway start", () => {
  it("moves the three stored booleans into the Global keys with both stores backed up first, and restores exactly", async () => {
    const home = await seed();
    const originalDocument = await readFile(documentPath(home));
    expect(await migratePushPolicy(home)).toBe(true);
    expect(JSON.parse(await readFile(settingsPath(home), "utf8"))).toEqual({
      notifications: { push: { inputNeeded: false, finished: true, waiting: false } },
    });
    expect(JSON.parse(await readFile(documentPath(home), "utf8"))).toEqual({ version: 3, grants: [], pending: [], receipts: [], revocations: [], inbox: [] });
    expect(await readFile(join(backupPath(home), "notifications.json"))).toEqual(originalDocument);
    await expect(stat(join(backupPath(home), "gateway.json"))).rejects.toMatchObject({ code: "ENOENT" });
    expect(await migratePushPolicy(home)).toBe(false);
    expect(await restorePushPolicyMigration(home, backupPath(home))).toBe(true);
    expect(await readFile(documentPath(home))).toEqual(originalDocument);
    await expect(stat(settingsPath(home))).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("recovers from a crash after the settings write by reusing its receipt and ends at the same bytes", async () => {
    const home = await seed();
    const originalDocument = await readFile(documentPath(home));
    expect(await migratePushPolicy(home)).toBe(true);
    const receipt = await readFile(join(backupPath(home), "manifest.json"));
    const settled = await readFile(settingsPath(home));
    await writeFile(documentPath(home), originalDocument);
    expect(await migratePushPolicy(home)).toBe(true);
    expect(await readFile(join(backupPath(home), "manifest.json"))).toEqual(receipt);
    expect(await readFile(settingsPath(home))).toEqual(settled);
    expect(JSON.parse(await readFile(documentPath(home), "utf8"))).toMatchObject({ version: 3 });
    expect(await migratePushPolicy(home)).toBe(false);
  });

  it("discards a backup without its receipt and backs up again before writing", async () => {
    const home = await seed();
    await mkdir(backupPath(home), { recursive: true });
    await writeFile(join(backupPath(home), "notifications.json"), "stale partial copy");
    expect(await migratePushPolicy(home)).toBe(true);
    expect(JSON.parse(await readFile(join(backupPath(home), "notifications.json"), "utf8"))).toMatchObject({ version: 2 });
  });

  it("does nothing to a store already at version 3", async () => {
    const home = await seed(3);
    expect(await migratePushPolicy(home)).toBe(false);
    expect(JSON.parse(await readFile(documentPath(home), "utf8"))).toMatchObject({ version: 3 });
    await expect(stat(settingsPath(home))).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("refuses a version 2 store whose policy is not three booleans, writing nothing", async () => {
    const home = await seed();
    await writeFile(documentPath(home), JSON.stringify({ version: 2, policy: { notifyWhenAskPresented: "no" }, grants: [], pending: [], receipts: [], revocations: [], inbox: [] }));
    const before = await readFile(documentPath(home));
    await expect(migratePushPolicy(home)).rejects.toThrow("three policy booleans");
    expect(await readFile(documentPath(home))).toEqual(before);
    await expect(stat(settingsPath(home))).rejects.toMatchObject({ code: "ENOENT" });
  });
});
