import { execFile, spawn, type ChildProcess } from "node:child_process";
import { once } from "node:events";
import { connect, createServer as createNetServer } from "node:net";
import { pathToFileURL } from "node:url";
import WebSocket from "ws";
import { createHash, randomUUID } from "node:crypto";
import { chmod, cp, mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
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
import { PROTOCOL_VERSION } from "../version.js";
import type { Resolution } from "../kernel/settings/tool-contract.js";

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

  it("starts past a subagent session with raw U+2028/U+2029 and keeps an unconvertible chat session untouched (#1647)", async () => {
    const f = await copiedState();
    const sessions = join(f.agentDir, "sessions");
    // Real shape from the Stable crash: a nested subagent run whose tool output holds raw
    // U+2028 inside a JSON string, valid JSON that Pi reads by splitting on "\n" only.
    const runDirectory = join(sessions, "--fixture--", "parent", "ccdf4b15", "run-0"); await mkdir(runDirectory, { recursive: true });
    const subagent = SessionManager.create(f.root, runDirectory);
    subagent.appendMessage(fauxAssistantMessage("guard output\u2028line two\u2029para \u2028 end"));
    subagent.appendCustomEntry("tron.settings.v1", { settings: {}, fixed: {
      "run.retry.maxRetries": { value: 0, from: "mac", ref: "old-default", at: "2026-01-01T00:00:00.000Z" } } });
    const subagentPath = subagent.getSessionFile()!;
    // A crash-torn final line, which Pi skips, must not refuse either.
    await writeFile(subagentPath, `${await readFile(subagentPath, "utf8")}{"type":"message","id":"torn"`);
    const tornLine = `{"type":"message","id":"torn"`;
    const chat = SessionManager.create(f.root, sessions);
    chat.appendMessage(fauxAssistantMessage("Chat with an unclassifiable legacy scope"));
    chat.appendCustomEntry("tron.settings.v1", { settings: {}, fixed: {
      "run.retry.maxRetries": { value: 0, from: "unknown-scope", ref: "odd", at: "2026-01-01T00:00:00.000Z" } } });
    const chatPath = chat.getSessionFile()!;
    const chatBefore = await migrationFileHash(chatPath);
    const skipped = await migrateSettings(f.options);
    expect((await journal(f)).state).toBe("complete");
    expect(skipped).toEqual([{ file: chatPath, reason: expect.stringContaining("unrecognized settings scope") }]);
    expect(await migrationFileHash(chatPath)).toBe(chatBefore);
    const text = await readFile(subagentPath, "utf8");
    expect(text).toContain("guard output\u2028line two\u2029para \u2028 end");
    expect(text.endsWith(`${tornLine}\n`)).toBe(true);
    const settings = text.split("\n").filter(line => line.startsWith("{") && line !== tornLine).map(line => JSON.parse(line))
      .find(entry => entry.customType === "tron.settings.v1");
    expect(settings.data.fixed["run.retry.maxRetries"]).toMatchObject({ value: 0, from: "session", ref: "old-default" });
    evidence.push({ case: "U+2028 subagent session migrates; unconvertible chat session skipped (#1647)", passed: true, skipped: skipped.length });
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

// ---------------------------------------------------------------------------
// #1649: Stable rolled back because this migration ran before the listener and
// read every session byte many times. The real production entry starts against
// a Stable-shaped state (thousands of sessions, the legacy settings shapes found
// on Stable, one unreadable file) under the deploy's own replace windows.
const deployModule = pathToFileURL(resolve(packageRoot, "../../scripts/gateway-payload-deploy.mjs")).href;
const children: ChildProcess[] = [];
afterEach(async () => {
  for (const child of children.splice(0)) {
    if (child.exitCode !== null || child.signalCode !== null) continue;
    const exited = once(child, "exit"); child.kill("SIGKILL"); await exited;
  }
});
const SESSIONS = 5_800, LEGACY = 363, SUBAGENT_RUNS = 150;
const stamp = "2026-10-16T05:58:22.227Z";
const legacyFixed = (index: number) => ({
  // The provenance vocabulary and keys counted on Stable's 363 legacy sessions.
  "model.ref[role=chat]": index % 3 === 0 ? { value: { provider: "fixture", id: "chosen" }, from: "chat", at: stamp, ref: `m-${index}`, qualifiers: { role: "chat" } }
    : { value: { provider: "fixture", id: "delegated" }, from: "delegate", at: stamp, ref: `m-${index}`, qualifiers: { role: "chat" } },
  "model.thinking[role=chat]": { value: "medium", from: "mac", at: stamp, ref: `t-${index}`, qualifiers: { role: "chat", model: "fixture/chosen" } },
  "model.contextWindow": { value: 200_000, from: "builtin", at: stamp, ref: `w-${index}`, qualifiers: { model: "fixture/chosen" } },
  "context.images.autoResize": { value: true, from: "builtin", at: stamp, ref: `r-${index}` },
  "tools.active": { value: ["read", "bash"], from: index % 2 ? "project" : "mac", at: stamp, ref: `a-${index}` },
});
function sessionText(id: string, cwd: string, index: number, legacy: boolean): string {
  const lines: unknown[] = [{ type: "session", version: 3, id, timestamp: stamp, cwd },
    { type: "model_change", id: "e0", parentId: null, timestamp: stamp, provider: "fixture", modelId: "chosen" },
    { type: "thinking_level_change", id: "e1", parentId: "e0", timestamp: stamp, thinkingLevel: "medium" }];
  let parent = "e1";
  if (legacy) {
    lines.push({ type: "custom", customType: "tron.settings.v1", id: "e2", parentId: parent, timestamp: stamp,
      data: { receiptId: `receipt-${index}`, settings: {}, fixed: legacyFixed(index),
        requestPins: { "context.images.block": { value: false, from: "builtin", at: stamp, ref: `b-${index}` } } } });
    parent = "e2";
  }
  for (let turn = 0; turn < 6; turn += 1) {
    const entry = `m${turn}`;
    const text = `${index}:${turn} ${"transcript ".repeat(60)}${index === 7 && turn === 2 ? "raw\u2028separator\u2029kept" : ""}`;
    lines.push({ type: "message", id: entry, parentId: parent, timestamp: stamp,
      message: { role: turn % 2 ? "assistant" : "user", content: [{ type: "text", text }], timestamp: Date.parse(stamp) } });
    parent = entry;
  }
  return `${lines.map(line => JSON.stringify(line)).join("\n")}\n${index === 11 ? `{"type":"message","id":"torn"` : ""}`;
}
async function stableShapedState() {
  const root = await mkdtemp(join(tmpdir(), "tron-settings-startup-")); roots.push(root);
  const tronHome = join(root, "tron"), agentDir = join(root, "agent"), sessions = join(agentDir, "sessions");
  for (const directory of ["home", "tmp", "project", "agent", join("tron", "gateway", "home")]) await mkdir(join(root, directory), { recursive: true, mode: 0o700 });
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({ defaultProvider: "fixture", defaultModel: "global", defaultThinkingLevel: "low" }));
  const paths: string[] = [];
  let homeSession = "";
  for (let index = 0; index < SESSIONS; index += 1) {
    const cwd = join(root, "project", `p${index % 200}`);
    const directory = join(sessions, `--project-p${index % 200}--`);
    const id = randomUUID();
    let path = join(directory, `${stamp.replaceAll(":", "-")}_${id}.jsonl`);
    // Nested subagent runs, the shape of the #1647 file.
    if (index >= SESSIONS - SUBAGENT_RUNS) path = join(directory, `parent-${index}`, randomUUID().slice(0, 8), "run-0", "session.jsonl");
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, sessionText(id, cwd, index, index < LEGACY));
    paths.push(path);
    if (index === LEGACY) homeSession = id;
  }
  // One unreadable session: one bad file can never take the Gateway down.
  const unreadable = paths[LEGACY - 1]!; await chmod(unreadable, 0o000);
  await writeFile(join(tronHome, "gateway", "home", "profile.json"), JSON.stringify({ memory: { model: { provider: "fixture", id: "memory" } } }));
  await writeFile(join(tronHome, "gateway", "home", "home.json"), JSON.stringify({ version: 2, homeId: "fixture-home", enabled: false,
    model: { provider: "fixture", id: "record" }, chapters: [{ sessionId: homeSession, ordinal: 1, state: "active", createdAt: stamp, activationStarted: true }],
    bindingRevision: 1, generation: 1, routeGeneration: 1, policyRevision: 3, createdAt: stamp, updatedAt: stamp }));
  const pending = await legacyApproval({ settings: join(tronHome, "gateway", "settings") } as Awaited<ReturnType<typeof copiedState>>);
  const hashes = async () => Promise.all(paths.map(path => path === unreadable ? "unreadable" : migrationFileHash(path)));
  return { root, tronHome, agentDir, paths, unreadable, pending, hashes, legacySession: paths[3]! };
}
async function freePort(): Promise<number> {
  return await new Promise((resolvePort, reject) => {
    const server = createNetServer(); server.once("error", reject);
    server.listen(0, "127.0.0.1", () => { const address = server.address(); server.close(() => typeof address === "object" && address ? resolvePort(address.port) : reject(new Error("no port"))); });
  });
}
const accepts = (port: number) => new Promise<boolean>(done => {
  const socket = connect(port, "127.0.0.1"); socket.once("connect", () => { socket.destroy(); done(true); }); socket.once("error", () => done(false));
});
/** Production entry and launch environment; the deploy's listener and startup windows. */
async function startGateway(state: Awaited<ReturnType<typeof stableShapedState>>) {
  const { RELAUNCH_LIMIT_MS, STARTUP_LIMIT_MS, readLocalCredential } = await import(deployModule) as
    { RELAUNCH_LIMIT_MS: number; STARTUP_LIMIT_MS: number; readLocalCredential: (path: string) => Promise<string> };
  const port = await freePort();
  const started = performance.now();
  const child = spawn(process.execPath, ["dist/index.js"], { cwd: packageRoot, stdio: ["ignore", "pipe", "pipe"], env: {
    PATH: process.env.PATH, SHELL: "/bin/zsh", HOME: join(state.root, "home"), TMPDIR: join(state.root, "tmp"), TRON_DATA_DIR: state.tronHome,
    PI_CODING_AGENT_DIR: state.agentDir, PI_SUBAGENTS_TEMP_ROOT: join(state.tronHome, "internal", "subagents"),
    TRON_GATEWAY_HOST: "127.0.0.1", TRON_GATEWAY_PORT: String(port), TRON_MACHINE_GROUP_ID: "settings-startup-test" } });
  children.push(child);
  let output = "";
  child.stdout!.on("data", (chunk: Buffer) => { output += chunk; }); child.stderr!.on("data", (chunk: Buffer) => { output += chunk; });
  const exited = () => child.exitCode !== null || child.signalCode !== null;
  let listenerMs: number | undefined;
  while (listenerMs === undefined && performance.now() - started < RELAUNCH_LIMIT_MS && !exited()) {
    if (await accepts(port)) listenerMs = performance.now() - started; else await new Promise(done => setTimeout(done, 100));
  }
  expect({ listener: listenerMs !== undefined, exited: exited(), output: listenerMs === undefined ? output.slice(-2_000) : "" })
    .toEqual({ listener: true, exited: false, output: "" });
  let readyMs: number | undefined;
  const readyDeadline = performance.now() + STARTUP_LIMIT_MS;
  while (readyMs === undefined && performance.now() < readyDeadline && !exited()) {
    const health = await fetch(`http://127.0.0.1:${port}/health`).then(response => response.json() as Promise<{ status?: string }>).catch(() => ({ status: undefined }));
    if (health.status === "ok") readyMs = performance.now() - started; else await new Promise(done => setTimeout(done, 100));
  }
  expect(readyMs).toBeDefined();
  // An authenticated client connection, as the app's first contact after a rebuild.
  const token = await readLocalCredential(join(state.tronHome, "gateway", "local-auth.json"));
  const ws = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${token}` }, perMessageDeflate: false });
  const pending = new Map<string, (frame: Frame) => void>();
  const hello = new Promise<void>((done, reject) => {
    ws.once("error", reject);
    ws.on("message", raw => { const frame = JSON.parse(raw.toString()) as Frame; if (frame.type === "hello") done(); else if (frame.type === "response" && frame.id) pending.get(frame.id)?.(frame); });
  });
  await once(ws, "open");
  ws.send(JSON.stringify({ type: "hello", protocolVersion: PROTOCOL_VERSION, clientId: randomUUID() }));
  await hello;
  const request = (method: string, params: Record<string, unknown>) => new Promise<Frame>(done => {
    const id = randomUUID(); pending.set(id, done); ws.send(JSON.stringify({ type: "request", id, method, params }));
  });
  const stop = async () => {
    ws.close();
    const done = once(child, "exit"); child.kill("SIGTERM"); await done;
  };
  return { listenerMs, readyMs, request, stop, output: () => output };
}
type Frame = { type: string; id?: string; ok?: boolean; result?: unknown; error?: { message?: string } };
const readGatewayLog = async (tronHome: string) => (await readFile(join(tronHome, "logs", "gateway.jsonl"), "utf8").catch(() => ""))
  .split("\n").filter(Boolean).map(line => JSON.parse(line) as { event?: string; message?: string; durationMs?: number; counts?: Record<string, number> });

describe("Gateway startup over Stable-shaped legacy state (#1649)", () => {
  it("listens within the replace window, leaves session files untouched, reads legacy session settings and restarts as a no-op", { timeout: 420_000 }, async () => {
    const state = await stableShapedState();
    const before = await state.hashes();
    const first = await startGateway(state);
    try {
      expect(await state.hashes()).toEqual(before);
      // Shared stores moved to the current vocabulary at startup.
      expect((await new SettingsApprovals(state.tronHome).pending())[0]).toMatchObject({ requestId: state.pending.requestId, target: { kind: "global" } });
      const profile = JSON.parse(await readFile(join(state.tronHome, "gateway", "home", "profile.json"), "utf8"));
      expect(profile.model.chat).toEqual({ provider: "fixture", id: "record" });
      expect(Object.hasOwn(JSON.parse(await readFile(join(state.tronHome, "gateway", "home", "home.json"), "utf8")), "model")).toBe(false);
      // A legacy chat reads in the current vocabulary when it is opened.
      const header = JSON.parse((await readFile(state.legacySession, "utf8")).split("\n")[0]!) as { id: string };
      const opened = await first.request("session.open", { sessionId: header.id });
      expect(opened.ok, opened.error?.message).toBe(true);
      const resolved = await first.request("settings.resolve", { target: { kind: "session", sessionId: header.id },
        keys: ["model.thinking[role=chat]", "model.ref[role=chat]", "context.images.block"] });
      expect(resolved.ok, resolved.error?.message).toBe(true);
      const rows = Object.fromEntries((resolved.result as Resolution).keys.map(row => [row.key, { value: row.value, layer: row.layer }]));
      evidence.push({ case: "#1649 startup", listenerMs: Math.round(first.listenerMs!), readyMs: Math.round(first.readyMs!), sessions: SESSIONS, legacy: LEGACY, rows });
      // The legacy chat kept its own model and thinking, as the old Chat layer reported them.
      expect(rows["model.thinking[role=chat]"]).toEqual({ value: "medium", layer: "session" });
      expect(rows["model.ref[role=chat]"]).toEqual({ value: { provider: "fixture", id: "chosen" }, layer: "session" });
      expect(rows["context.images.block"]?.value).toBe(false);
    } finally { await first.stop(); }
    const journal = join(state.tronHome, "gateway", "settings", "migrations", "three-layer-v1", "journal.json");
    const settled = await migrationFileHash(journal);
    const second = await startGateway(state);
    try {
      expect(await migrationFileHash(journal)).toBe(settled);
      const log = await readGatewayLog(state.tronHome);
      expect(log.filter(record => record.event === "settings.migration-failed")).toEqual([]);
      expect(log.filter(record => record.event === "gateway.fatal-startup")).toEqual([]);
      evidence.push({ case: "#1649 second start", listenerMs: Math.round(second.listenerMs!), readyMs: Math.round(second.readyMs!) });
    } finally { await second.stop(); await chmod(state.unreadable, 0o600); }
  });
});
