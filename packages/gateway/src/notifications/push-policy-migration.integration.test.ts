import { mkdir, mkdtemp, readdir, readFile, rename, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { acquireAgentRuntimeLock } from "../sessions/agent-runtime-lock.js";
import { migratePushPolicy, restorePushPolicyMigration } from "./push-policy-migration.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true }))); });

const documentPath = (home: string) => join(home, "state", "notifications.json");
const settingsPath = (home: string) => join(home, "state", "settings", "gateway.json");
const backupPath = (home: string) => join(home, "state", "migrations", "push-policy-v3");
const agentPath = (home: string) => join(home, "agent");
const V2 = { version: 2, policy: { notifyWhenAskPresented: false, notifyWhenFinished: true, notifyWhenWaiting: false }, grants: [], pending: [], receipts: [], revocations: [], inbox: [] };
const V3 = { version: 3, grants: [], pending: [], receipts: [], revocations: [], inbox: [] };

async function seed(): Promise<string> {
  const home = await mkdtemp(join(tmpdir(), "tron-push-policy-migration-"));
  roots.push(home);
  await mkdir(dirname(documentPath(home)), { recursive: true });
  await writeFile(documentPath(home), `${JSON.stringify(V2, null, 2)}\n`);
  return home;
}

async function incompleteDirectories(home: string): Promise<string[]> {
  return (await readdir(join(home, "state", "migrations"))).filter((name) => name.startsWith("push-policy-v3.incomplete-"));
}

describe("push policy migration at Gateway start", () => {
  it("moves the three stored booleans into the Global keys with both stores backed up first, owner-only", async () => {
    const home = await seed();
    const originalDocument = await readFile(documentPath(home));
    expect(await migratePushPolicy(home)).toBe(true);
    expect(JSON.parse(await readFile(settingsPath(home), "utf8"))).toEqual({
      notifications: { push: { inputNeeded: false, finished: true, waiting: false } },
    });
    expect(JSON.parse(await readFile(documentPath(home), "utf8"))).toEqual(V3);
    expect(await readFile(join(backupPath(home), "notifications.json"))).toEqual(originalDocument);
    expect((await stat(join(backupPath(home), "notifications.json"))).mode & 0o777).toBe(0o600);
    expect((await stat(join(backupPath(home), "manifest.json"))).mode & 0o777).toBe(0o600);
    expect(JSON.parse(await readFile(join(backupPath(home), "manifest.json"), "utf8")).files.map((file: { path: string }) => file.path))
      .toEqual(["state/settings/gateway.json", "state/notifications.json"]);
    expect(await migratePushPolicy(home)).toBe(false);
  });

  it("a truncated receipt from an interrupted backup is kept as evidence and the migration still completes", async () => {
    const home = await seed();
    await mkdir(backupPath(home), { recursive: true });
    await writeFile(join(backupPath(home), "notifications.json"), `${JSON.stringify(V2, null, 2)}\n`);
    await writeFile(join(backupPath(home), "manifest.json"), '{"version":1,"fi');
    expect(await migratePushPolicy(home)).toBe(true);
    expect(JSON.parse(await readFile(documentPath(home), "utf8"))).toEqual(V3);
    const [kept] = await incompleteDirectories(home);
    expect(await readFile(join(home, "state", "migrations", kept!, "manifest.json"), "utf8")).toBe('{"version":1,"fi');
    expect(JSON.parse(await readFile(join(backupPath(home), "manifest.json"), "utf8")).version).toBe(1);
  });

  it("a backup with no receipt is kept as evidence and backed up again before any write", async () => {
    const home = await seed();
    await mkdir(backupPath(home), { recursive: true });
    await writeFile(join(backupPath(home), "notifications.json"), "stale partial copy");
    expect(await migratePushPolicy(home)).toBe(true);
    const [kept] = await incompleteDirectories(home);
    expect(await readFile(join(home, "state", "migrations", kept!, "notifications.json"), "utf8")).toBe("stale partial copy");
    expect(JSON.parse(await readFile(join(backupPath(home), "notifications.json"), "utf8"))).toMatchObject({ version: 2 });
  });

  it("a receipt that names a path outside the store is shape-invalid: kept, and nothing is written outside the store", async () => {
    const home = await seed();
    await mkdir(backupPath(home), { recursive: true });
    await writeFile(join(backupPath(home), "notifications.json"), `${JSON.stringify(V2, null, 2)}\n`);
    await writeFile(join(backupPath(home), "manifest.json"), JSON.stringify({ version: 1, files: [
      { path: "../escape.json", before: null, after: "0".repeat(64) },
      { path: "state/notifications.json", before: "0".repeat(64), after: "1".repeat(64) },
    ] }));
    expect(await migratePushPolicy(home)).toBe(true);
    await expect(stat(join(home, "..", "escape.json"))).rejects.toMatchObject({ code: "ENOENT" });
    expect(JSON.parse(await readFile(documentPath(home), "utf8"))).toEqual(V3);
  });

  it("a crash after the settings write resumes from the same receipt and ends at the same bytes", async () => {
    const home = await seed();
    const originalDocument = await readFile(documentPath(home));
    expect(await migratePushPolicy(home)).toBe(true);
    const receipt = await readFile(join(backupPath(home), "manifest.json"));
    const settled = await readFile(settingsPath(home));
    await writeFile(documentPath(home), originalDocument);
    expect(await migratePushPolicy(home)).toBe(true);
    expect(await readFile(join(backupPath(home), "manifest.json"))).toEqual(receipt);
    expect(await readFile(settingsPath(home))).toEqual(settled);
    expect(JSON.parse(await readFile(documentPath(home), "utf8"))).toEqual(V3);
    expect(await incompleteDirectories(home)).toEqual([]);
  });

  it("a store changed after an interrupted migration is refused and nothing is written", async () => {
    const home = await seed();
    expect(await migratePushPolicy(home)).toBe(true);
    await writeFile(documentPath(home), `${JSON.stringify(V2, null, 2)}\n`);
    await writeFile(settingsPath(home), `${JSON.stringify({ notifications: { push: { inputNeeded: true } } }, null, 2)}\n`);
    const receipt = await readFile(join(backupPath(home), "manifest.json"));
    const settingsBefore = await readFile(settingsPath(home));
    await expect(migratePushPolicy(home)).rejects.toThrow("changed after its push policy backup");
    expect(await readFile(join(backupPath(home), "manifest.json"))).toEqual(receipt);
    expect(await readFile(settingsPath(home))).toEqual(settingsBefore);
    expect(await readFile(documentPath(home), "utf8")).toBe(`${JSON.stringify(V2, null, 2)}\n`);
    expect(await incompleteDirectories(home)).toEqual([]);
  });

  it("an intact receipt whose stored after digest differs from this build's plan is a conflict: nothing is quarantined or re-backed-up", async () => {
    const home = await seed();
    const originalDocument = await readFile(documentPath(home));
    expect(await migratePushPolicy(home)).toBe(true);
    const migratedSettings = await readFile(settingsPath(home));
    await writeFile(documentPath(home), originalDocument);
    const manifest = join(backupPath(home), "manifest.json");
    const receipt = JSON.parse(await readFile(manifest, "utf8"));
    receipt.files[0].after = "f".repeat(64);
    await writeFile(manifest, JSON.stringify(receipt, null, 2));
    const tampered = await readFile(manifest);
    await expect(migratePushPolicy(home)).rejects.toThrow("does not match");
    expect(await readFile(manifest)).toEqual(tampered);
    expect(await readFile(settingsPath(home))).toEqual(migratedSettings);
    expect(await readFile(documentPath(home))).toEqual(originalDocument);
    expect(await readFile(join(backupPath(home), "notifications.json"))).toEqual(originalDocument);
    await expect(stat(join(backupPath(home), "gateway.json"))).rejects.toMatchObject({ code: "ENOENT" });
    expect(await incompleteDirectories(home)).toEqual([]);
  });

  it("a stale temporary file left under a process-id name cannot fail a start", async () => {
    const home = await seed();
    await mkdir(dirname(settingsPath(home)), { recursive: true });
    await writeFile(`${settingsPath(home)}.migration-${process.pid}.tmp`, "stale");
    await writeFile(`${documentPath(home)}.migration-${process.pid}.tmp`, "stale");
    expect(await migratePushPolicy(home)).toBe(true);
    expect(JSON.parse(await readFile(documentPath(home), "utf8"))).toEqual(V3);
  });

  it("does nothing to a store already at version 3", async () => {
    const home = await seed();
    await writeFile(documentPath(home), `${JSON.stringify(V3, null, 2)}\n`);
    expect(await migratePushPolicy(home)).toBe(false);
    await expect(stat(settingsPath(home))).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("refuses a version 2 store whose policy is not three booleans, writing nothing", async () => {
    const home = await seed();
    await writeFile(documentPath(home), JSON.stringify({ ...V2, policy: { notifyWhenAskPresented: "no" } }));
    const before = await readFile(documentPath(home));
    await expect(migratePushPolicy(home)).rejects.toThrow("three policy booleans");
    expect(await readFile(documentPath(home))).toEqual(before);
    await expect(stat(settingsPath(home))).rejects.toMatchObject({ code: "ENOENT" });
  });
});

describe("push policy restore", () => {
  it("refuses while a Gateway owns the agent directory, then restores the exact pre-migration bytes", async () => {
    const home = await seed();
    const originalDocument = await readFile(documentPath(home));
    expect(await migratePushPolicy(home)).toBe(true);
    const migratedDocument = await readFile(documentPath(home));
    const release = await acquireAgentRuntimeLock(agentPath(home));
    try {
      await expect(restorePushPolicyMigration(home, agentPath(home))).rejects.toThrow("Another Tron Gateway");
      expect(await readFile(documentPath(home))).toEqual(migratedDocument);
      expect(await readFile(settingsPath(home), "utf8")).toContain("inputNeeded");
    } finally { await release(); }
    expect(await restorePushPolicyMigration(home, agentPath(home))).toBe(true);
    expect(await readFile(documentPath(home))).toEqual(originalDocument);
    await expect(stat(settingsPath(home))).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("refuses a manifest with a path outside the store, a non-digest, or a store edited after migrating", async () => {
    const home = await seed();
    expect(await migratePushPolicy(home)).toBe(true);
    const good = JSON.parse(await readFile(join(backupPath(home), "manifest.json"), "utf8"));
    const manifest = join(backupPath(home), "manifest.json");
    await writeFile(manifest, JSON.stringify({ ...good, files: [{ ...good.files[0], path: "../../escape.json" }, good.files[1]] }));
    await expect(restorePushPolicyMigration(home, agentPath(home))).rejects.toThrow("incomplete");
    await writeFile(manifest, JSON.stringify({ ...good, files: [good.files[0], { ...good.files[1], before: "not-a-digest" }] }));
    await expect(restorePushPolicyMigration(home, agentPath(home))).rejects.toThrow("incomplete");
    await writeFile(manifest, JSON.stringify(good));
    await writeFile(documentPath(home), "{\"edited\":true}\n");
    const edited = await readFile(documentPath(home));
    await expect(restorePushPolicyMigration(home, agentPath(home))).rejects.toThrow("changed after the migration");
    expect(await readFile(documentPath(home))).toEqual(edited);
    await expect(stat(join(home, "escape.json"))).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("refuses a backup location that is a symbolic link", async () => {
    const home = await seed();
    expect(await migratePushPolicy(home)).toBe(true);
    const elsewhere = join(home, "elsewhere");
    await rename(backupPath(home), elsewhere);
    await symlink(elsewhere, backupPath(home));
    const migrated = await readFile(documentPath(home));
    await expect(restorePushPolicyMigration(home, agentPath(home))).rejects.toThrow("not a link");
    expect(await readFile(documentPath(home))).toEqual(migrated);
  });
});
