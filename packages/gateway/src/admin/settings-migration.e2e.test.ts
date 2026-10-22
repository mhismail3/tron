import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { cp, mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { promisify } from "node:util";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { SessionManager } from "../kernel/pi/coding-agent.js";
import { acquireAgentRuntimeLocks } from "../sessions/agent-runtime-lock.js";
import { approvalDigest, SettingsApprovals } from "./settings-approvals.js";
import { migrateSettings, SettingsMigration, type SettingsMigrationOptions } from "./settings-migration.js";
import { migrationFileHash } from "./settings-migration-plan.js";

const exec = promisify(execFile);
const roots: string[] = [];
const packageRoot = resolve(import.meta.dirname, "../..");
const evidenceRoot = resolve(packageRoot, "../../test-results/settings-three-layer/phase5");
const evidence: unknown[] = [];
beforeAll(async () => {
  await mkdir(evidenceRoot, { recursive: true });
  // The real production entry, not a test substitute or a source-text oracle.
  await exec(process.execPath, ["node_modules/typescript/bin/tsc", "--incremental", "false", "--sourceMap", "false", "--declaration", "false", "-p", "tsconfig.json"], { cwd: packageRoot });
});
afterEach(async () => { for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true }); });
afterAll(async () => { await writeFile(join(evidenceRoot, "migration-contracts.json"), JSON.stringify(evidence, null, 2) + "\n"); });

async function copiedState() {
  const root = await mkdtemp(join(tmpdir(), "tron-settings-migration-copy-")); roots.push(root);
  const tronHome = join(root, "home", ".tron"), agentDir = join(tronHome, "agent");
  const profilePath = join(tronHome, "gateway", "home", "profile.json");
  await mkdir(agentDir, { recursive: true, mode: 0o700 }); await mkdir(dirname(profilePath), { recursive: true, mode: 0o700 });
  // Only owned settings are copied; never credentials, live canonical clients or
  // a live session directory. Assertions/logs contain no copied personal values.
  const sourceHome = join(homedir(), ".tron");
  await cp(join(sourceHome, "agent", "settings.json"), join(agentDir, "settings.json"));
  await cp(join(sourceHome, "gateway", "home", "profile.json"), profilePath);
  const global = JSON.parse(await readFile(join(agentDir, "settings.json"), "utf8"));
  const profile = JSON.parse(await readFile(profilePath, "utf8"));
  // Physical directories are relocated on the copy. Deterministic legacy
  // choices exercise migration without exposing or contacting copied accounts.
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({ ...global, sessionDir: join(agentDir, "sessions"), defaultProvider: "fixture", defaultModel: "global", retry: { maxRetries: 1 } }));
  await writeFile(profilePath, JSON.stringify({ ...profile, model: { ...profile.model, chat: { provider: "fixture", id: "profile" } } }));
  const options: SettingsMigrationOptions = { tronHome, agentDir, acquireRuntimeLocks: async paths => {
    expect(paths.every(path => relative(root, path) !== ".." && !relative(root, path).startsWith("../"))).toBe(true);
    return acquireAgentRuntimeLocks(paths);
  } };
  const settings = join(tronHome, "gateway", "settings");
  const journalPath = join(settings, "migrations", "three-layer-v1", "journal.json");
  return { root, tronHome, agentDir, profilePath, settings, journalPath, options };
}
async function legacyApproval(f: Awaited<ReturnType<typeof copiedState>>) {
  const change = { changeId: "legacy-change", key: "run.retry.maxRetries", layer: "mac", op: "set", before: 1, after: 2,
    tier: "approve", tierBasis: { direction: "widen", floor: "approve", floorSource: "override", web: false, risk: null } };
  const target = { kind: "mac" };
  const request = { requestId: "legacy-request", createdAt: "2026-01-01T00:00:00.000Z", expiresAt: "2099-01-02T00:00:00.000Z",
    target, actor: { kind: "agent", id: "fixture-agent", sessionId: "fixture-chat" }, reason: "Existing request", status: "pending",
    changes: [change], digest: approvalDigest(target, [change]) };
  await mkdir(f.settings, { recursive: true });
  await writeFile(join(f.settings, "approvals.json"), JSON.stringify({ version: 1, requests: [request] }));
  await mkdir(join(f.settings, "changes"));
  await writeFile(join(f.settings, "changes", "000000.jsonl"), JSON.stringify({ ...change, target, at: request.createdAt,
    actor: request.actor, status: "pending", requestId: request.requestId }) + "\n");
  await writeFile(join(f.settings, "changes", "index.json"), JSON.stringify({ version: 1, segments: [{ name: "000000", count: 1 }] }));
  return request;
}
async function legacyHomeChapter(f: Awaited<ReturnType<typeof copiedState>>) {
  const directory = join(f.agentDir, "sessions"); await mkdir(directory, { recursive: true });
  const manager = SessionManager.create(f.root, directory);
  manager.appendModelChange("fixture", "chosen"); manager.appendThinkingLevelChange("high");
  manager.appendCustomEntry("tron.settings.v1", { settings: { retry: { maxRetries: 0 } }, fixed: {
    "model.ref[role=chat]": { value: { provider: "fixture", id: "chosen" }, from: "chat", ref: "model-choice", at: "2026-01-01T00:00:00.000Z" },
    "run.retry.maxRetries": { value: 0, from: "mac", ref: "old-default", at: "2026-01-01T00:00:00.000Z" },
  } });
  manager.appendMessage(fauxAssistantMessage("Copied-state migration fixture"));
  const home = { version: 2, homeId: "fixture-home", chapters: [{ sessionId: manager.getSessionId(), ordinal: 1, state: "active", createdAt: "2026-01-01T00:00:00.000Z", activationStarted: true }],
    enabled: true, model: { provider: "fixture", id: "chosen" }, bindingRevision: 1, generation: 1, routeGeneration: 1, policyRevision: 3,
    createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z" };
  await writeFile(join(f.tronHome, "gateway", "home", "home.json"), JSON.stringify(home));
  return manager.getSessionFile()!;
}
async function journal(f: Awaited<ReturnType<typeof copiedState>>) {
  return JSON.parse(await readFile(f.journalPath, "utf8")) as { state: string; inputs: Array<{ path: string; hash: string | null }>; replacements: Array<{ path: string; index: number }> };
}

describe("settings startup migration on copied state", () => {
  it("refuses the corrupt copied Profile before the real runtime owner and leaves Global bytes unchanged", async () => {
    const f = await copiedState();
    const before = await migrationFileHash(join(f.agentDir, "settings.json"));
    await writeFile(f.profilePath, "{not-valid-json");
    await mkdir(join(f.agentDir, ".tron-gateway-runtime.lock.lock"));
    let stderr = "";
    try {
      await exec(process.execPath, ["dist/gateway-main.js", "--host", "127.0.0.1", "--port", "19848"], {
        cwd: packageRoot, env: { PATH: process.env.PATH, HOME: join(f.root, "home"), TMPDIR: f.root,
          TRON_DATA_DIR: f.tronHome, PI_CODING_AGENT_DIR: f.agentDir, TRON_MACHINE_GROUP_ID: "settings-startup-test" },
      });
    } catch (error) { stderr = (error as { stderr?: string }).stderr ?? ""; }
    expect(stderr).toContain(f.profilePath);
    expect(stderr).not.toContain("already owns a canonical session directory");
    expect(await migrationFileHash(join(f.agentDir, "settings.json"))).toBe(before);
    await expect(stat(f.journalPath)).rejects.toMatchObject({ code: "ENOENT" });
    evidence.push({ case: "actual startup before runtime owner", passed: true, copiedGlobalUnchanged: true });
  });

  it("backs up before publication, preserves and rehashes pending approvals, folds Home and reruns byte-for-byte as a no-op", async () => {
    const f = await copiedState(); const pending = await legacyApproval(f); const sessionPath = await legacyHomeChapter(f);
    const transaction = await SettingsMigration.prepare(f.options);
    try {
      const prepared = await journal(f);
      expect(prepared.state).toBe("prepared");
      expect((await new SettingsApprovals(f.tronHome).pending())[0]?.digest).toBe(pending.digest);
      for (const [index, input] of prepared.inputs.entries()) {
        if (input.hash !== null) expect(await migrationFileHash(join(dirname(f.journalPath), "backup", String(index)))).toBe(input.hash);
        expect(await migrationFileHash(input.path)).toBe(input.hash);
      }
      await transaction.complete();
    } finally { await transaction.release(); }
    const migrated = (await new SettingsApprovals(f.tronHome).pending())[0]!;
    expect(migrated).toMatchObject({ requestId: pending.requestId, createdAt: pending.createdAt, expiresAt: pending.expiresAt, status: "pending", actor: pending.actor,
      target: { kind: "global" }, changes: [{ changeId: "legacy-change", layer: "global", before: 1, after: 2 }] });
    expect(migrated.digest).not.toBe(pending.digest);
    expect(migrated.digest).toBe(approvalDigest(migrated.target, migrated.changes));
    const profile = JSON.parse(await readFile(f.profilePath, "utf8"));
    expect(profile.model.chat).toEqual({ provider: "fixture", id: "chosen" });
    const session = (await readFile(sessionPath, "utf8")).trim().split("\n").map(line => JSON.parse(line));
    expect(session.find(entry => entry.customType === "tron.settings.v1").data.fixed["run.retry.maxRetries"]).toMatchObject({ value: 0, from: "session", ref: "old-default" });
    const completed = await journal(f);
    const hashes = await Promise.all([...completed.inputs.map(input => input.path), f.journalPath].map(migrationFileHash));
    const release = await acquireAgentRuntimeLocks([f.agentDir]);
    try { await migrateSettings(f.options); } finally { await release(); }
    expect(await Promise.all([...completed.inputs.map(input => input.path), f.journalPath].map(migrationFileHash))).toEqual(hashes);
    expect((await stat(dirname(f.journalPath))).mode & 0o777).toBe(0o700);
    evidence.push({ case: "backup, pending preservation/rehash, Home fold, no-op", passed: true, inputs: completed.inputs.length });
  });

  it.each([true, false])("moves the retired Home record model into Home's saved settings only when none is saved (saved: %s)", async saved => {
    const f = await copiedState();
    const directory = join(f.agentDir, "sessions"); await mkdir(directory, { recursive: true });
    const manager = SessionManager.create(f.root, directory);
    manager.appendMessage(fauxAssistantMessage("Home chapter without a model choice"));
    const profile = JSON.parse(await readFile(f.profilePath, "utf8"));
    if (!saved) { delete profile.model.chat; await writeFile(f.profilePath, JSON.stringify(profile)); }
    const homePath = join(f.tronHome, "gateway", "home", "home.json");
    await writeFile(homePath, JSON.stringify({ version: 2, homeId: "fixture-home", enabled: true, model: { provider: "fixture", id: "record" },
      chapters: [{ sessionId: manager.getSessionId(), ordinal: 1, state: "active", createdAt: "2026-01-01T00:00:00.000Z", activationStarted: true }],
      bindingRevision: 1, generation: 1, routeGeneration: 1, policyRevision: 3, createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z" }));
    await migrateSettings(f.options);
    expect(JSON.parse(await readFile(f.profilePath, "utf8")).model.chat).toEqual({ provider: "fixture", id: saved ? "profile" : "record" });
    const record = JSON.parse(await readFile(homePath, "utf8"));
    expect(Object.hasOwn(record, "model")).toBe(false);
    expect(record).toMatchObject({ homeId: "fixture-home", enabled: true, generation: 1 });
    evidence.push({ case: `retired Home record model (saved ${saved})`, passed: true });
  });

  it("resumes the same prepared transaction after a partial canonical publication without duplicating approvals or audit", async () => {
    const f = await copiedState(); await legacyApproval(f); await legacyHomeChapter(f);
    const transaction = await SettingsMigration.prepare(f.options);
    await transaction.release();
    const prepared = await journal(f);
    const first = prepared.replacements[0]!;
    await cp(join(dirname(f.journalPath), "stage", String(first.index)), first.path);
    await migrateSettings(f.options);
    expect((await journal(f)).state).toBe("complete");
    const pending = await new SettingsApprovals(f.tronHome).pending();
    expect(pending).toHaveLength(1); expect(pending[0]?.status).toBe("pending");
    const audit = (await readFile(join(f.settings, "changes", "000000.jsonl"), "utf8")).trim().split("\n").map(line => JSON.parse(line));
    expect(audit).toHaveLength(1); expect(audit[0]).toMatchObject({ changeId: "legacy-change", requestId: "legacy-request", layer: "global" });
    evidence.push({ case: "partial publication recovery", passed: true, approvals: 1, auditEntries: 1 });
  });

  it("refuses a changed pending diff before backup or canonical writes, and a damaged staged payload before replay", async () => {
    const f = await copiedState(); await legacyApproval(f);
    const path = join(f.settings, "approvals.json"); const original = await readFile(path, "utf8");
    const corrupt = JSON.parse(original); corrupt.requests[0].changes[0].after = 3;
    await writeFile(path, JSON.stringify(corrupt)); const before = await migrationFileHash(path);
    await expect(migrateSettings(f.options)).rejects.toThrow("pending approval digest does not match");
    expect(await migrationFileHash(path)).toBe(before);
    await expect(stat(f.journalPath)).rejects.toMatchObject({ code: "ENOENT" });
    await writeFile(path, original);
    const transaction = await SettingsMigration.prepare(f.options); await transaction.release();
    const prepared = await journal(f); const replacement = prepared.replacements[0]!;
    await writeFile(join(dirname(f.journalPath), "stage", String(replacement.index)), "damaged-stage");
    await expect(migrateSettings(f.options)).rejects.toThrow("staged hash does not match");
    expect(await migrationFileHash(path)).toBe(createHash("sha256").update(original).digest("hex"));
    evidence.push({ case: "preflight/refused replay", passed: true });
  });

  it("restores every original byte from the automatic backup into a separate test copy", async () => {
    const f = await copiedState(); await legacyApproval(f); await legacyHomeChapter(f); await migrateSettings(f.options);
    const completed = await journal(f);
    const restored = await mkdtemp(join(tmpdir(), "tron-settings-restoration-copy-")); roots.push(restored);
    for (const [index, input] of completed.inputs.entries()) if (input.hash !== null) {
      const destination = join(restored, relative(f.root, input.path));
      await mkdir(dirname(destination), { recursive: true });
      await cp(join(dirname(f.journalPath), "backup", String(index)), destination);
      expect(await migrationFileHash(destination)).toBe(input.hash);
    }
    expect((await readdir(join(restored, "home", ".tron", "gateway", "settings", "changes"))).sort()).toEqual(["000000.jsonl", "index.json"]);
    evidence.push({ case: "backup restoration on separate copy", passed: true });
  });
});
