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
  const options: SettingsMigrationOptions = { tronHome, agentDir };
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
  it("backs up before publication, preserves and rehashes pending approvals, never touches the Home chapter and reruns byte-for-byte as a no-op", async () => {
    const f = await copiedState(); const pending = await legacyApproval(f); const sessionPath = await legacyHomeChapter(f);
    const sessionBefore = await migrationFileHash(sessionPath);
    const transaction = await SettingsMigration.prepare(f.options);
    const prepared = await journal(f);
    expect(prepared.state).toBe("prepared");
    expect((await new SettingsApprovals(f.tronHome).pending())[0]?.digest).toBe(pending.digest);
    for (const [index, input] of prepared.inputs.entries()) {
      if (input.hash !== null) expect(await migrationFileHash(join(dirname(f.journalPath), "backup", String(index)))).toBe(input.hash);
      expect(await migrationFileHash(input.path)).toBe(input.hash);
    }
    await transaction.complete();
    const migrated = (await new SettingsApprovals(f.tronHome).pending())[0]!;
    expect(migrated).toMatchObject({ requestId: pending.requestId, createdAt: pending.createdAt, expiresAt: pending.expiresAt, status: "pending", actor: pending.actor,
      target: { kind: "global" }, changes: [{ changeId: "legacy-change", layer: "global", before: 1, after: 2 }] });
    expect(migrated.digest).not.toBe(pending.digest);
    expect(migrated.digest).toBe(approvalDigest(migrated.target, migrated.changes));
    // The saved Profile model stays; the Home chapter session is not an input.
    expect(JSON.parse(await readFile(f.profilePath, "utf8")).model.chat).toEqual({ provider: "fixture", id: "profile" });
    expect(await migrationFileHash(sessionPath)).toBe(sessionBefore);
    const completed = await journal(f);
    expect(completed.inputs.map(input => input.path).filter(path => path.endsWith(".jsonl") && !path.includes(join("settings", "changes")))).toEqual([]);
    const hashes = await Promise.all([...completed.inputs.map(input => input.path), f.journalPath].map(migrationFileHash));
    expect(await migrateSettings(f.options)).toMatchObject({ alreadyComplete: true, replaced: 0 });
    expect(await Promise.all([...completed.inputs.map(input => input.path), f.journalPath].map(migrationFileHash))).toEqual(hashes);
    expect((await stat(dirname(f.journalPath))).mode & 0o777).toBe(0o700);
    evidence.push({ case: "backup, pending preservation/rehash, Home chapter untouched, no-op", passed: true, inputs: completed.inputs.length });
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
    // Interrupted after durable intent: prepared, never completed.
    await SettingsMigration.prepare(f.options);
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
    await SettingsMigration.prepare(f.options);
    const prepared = await journal(f); const replacement = prepared.replacements[0]!;
    await writeFile(join(dirname(f.journalPath), "stage", String(replacement.index)), "damaged-stage");
    await expect(migrateSettings(f.options)).rejects.toThrow("staged hash does not match");
    expect(await migrationFileHash(path)).toBe(createHash("sha256").update(original).digest("hex"));
    evidence.push({ case: "preflight/refused replay", passed: true });
  });

  it("never reads into or rewrites session JSONL, including a U+2028 subagent run and an unclassifiable chat (#1647, #1649)", async () => {
    const f = await copiedState(); await legacyApproval(f);
    const sessions = join(f.agentDir, "sessions");
    const runDirectory = join(sessions, "--fixture--", "parent", "ccdf4b15", "run-0"); await mkdir(runDirectory, { recursive: true });
    const subagent = SessionManager.create(f.root, runDirectory);
    subagent.appendMessage(fauxAssistantMessage("guard output\u2028line two\u2029para \u2028 end"));
    subagent.appendCustomEntry("tron.settings.v1", { settings: {}, fixed: {
      "run.retry.maxRetries": { value: 0, from: "mac", ref: "old-default", at: "2026-01-01T00:00:00.000Z" } } });
    const chat = SessionManager.create(f.root, sessions);
    chat.appendMessage(fauxAssistantMessage("Chat with an unclassifiable legacy scope"));
    chat.appendCustomEntry("tron.settings.v1", { settings: {}, fixed: {
      "run.retry.maxRetries": { value: 0, from: "unknown-scope", ref: "odd", at: "2026-01-01T00:00:00.000Z" } } });
    const paths = [subagent.getSessionFile()!, chat.getSessionFile()!];
    const before = await Promise.all(paths.map(migrationFileHash));
    expect(await migrateSettings(f.options)).toMatchObject({ alreadyComplete: false });
    const completed = await journal(f);
    expect(completed.state).toBe("complete");
    expect(completed.inputs.filter(input => input.path.startsWith(sessions))).toEqual([]);
    expect(await Promise.all(paths.map(migrationFileHash))).toEqual(before);
    evidence.push({ case: "session JSONL is never a migration input (#1647, #1649)", passed: true });
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
      // Old Chat overrides: explicit settings and `chat` frames; inherited `mac`/`builtin` frames.
      data: { receiptId: `receipt-${index}`, settings: index % 3 === 0 ? { retry: { maxRetries: 0 } } : {}, fixed: legacyFixed(index),
        requestPins: { "context.images.block": { value: false, from: "builtin", at: stamp, ref: `b-${index}` } } } });
    parent = "e2";
  }
  for (let turn = 0; turn < 6; turn += 1) {
    const entry = `m${turn}`;
    const text = `${index}:${turn} ${"transcript ".repeat(60)}${index === 7 && turn === 2 ? "raw\u2028separator\u2029kept" : ""}`;
    lines.push({ type: "message", id: entry, parentId: parent, timestamp: stamp,
      message: turn % 2 ? fauxAssistantMessage(text) : { role: "user", content: [{ type: "text", text }], timestamp: Date.parse(stamp) } });
    parent = entry;
  }
  return `${lines.map(line => JSON.stringify(line)).join("\n")}\n${index === 11 ? `{"type":"message","id":"torn"` : ""}`;
}
async function stableShapedState(count = SESSIONS, withUnreadable = false) {
  const root = await mkdtemp(join(tmpdir(), "tron-settings-startup-")); roots.push(root);
  const tronHome = join(root, "tron"), agentDir = join(root, "agent"), sessions = join(agentDir, "sessions");
  for (const directory of ["home", "tmp", "project", "agent", join("tron", "gateway", "home")]) await mkdir(join(root, directory), { recursive: true, mode: 0o700 });
  // The Global the old `mac` frames recorded (unchanged since), with its own retry policy.
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({ defaultProvider: "fixture", defaultModel: "global", defaultThinkingLevel: "medium", retry: { maxRetries: 2 } }));
  const paths: string[] = [];
  let homeSession = "";
  for (let index = 0; index < count; index += 1) {
    const cwd = join(root, "project", `p${index % 200}`);
    if (index < 200) await mkdir(cwd, { recursive: true });
    // Pi's own cwd directory naming, so the catalog proves each file's membership.
    const directory = join(sessions, `--${cwd.slice(1).replace(/[/\\:]/g, "-")}--`);
    const id = randomUUID();
    let path = join(directory, `${stamp.replaceAll(":", "-")}_${id}.jsonl`);
    // Nested subagent runs, the shape of the #1647 file.
    if (index >= count - SUBAGENT_RUNS) path = join(directory, `parent-${index}`, randomUUID().slice(0, 8), "run-0", "session.jsonl");
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, sessionText(id, cwd, index, index < LEGACY));
    paths.push(path);
    if (index === LEGACY) homeSession = id;
  }
  // One unreadable session: one bad file can never take the Gateway down.
  const unreadable = paths[Math.min(LEGACY, count) - 1]!;
  if (withUnreadable) await chmod(unreadable, 0o000);
  await writeFile(join(tronHome, "gateway", "home", "profile.json"), JSON.stringify({ memory: { model: { provider: "fixture", id: "memory" } } }));
  await writeFile(join(tronHome, "gateway", "home", "home.json"), JSON.stringify({ version: 2, homeId: "fixture-home", enabled: false,
    model: { provider: "fixture", id: "record" }, chapters: [{ sessionId: homeSession, ordinal: 1, state: "active", createdAt: stamp, activationStarted: true }],
    bindingRevision: 1, generation: 1, routeGeneration: 1, policyRevision: 3, createdAt: stamp, updatedAt: stamp }));
  const pending = await legacyApproval({ settings: join(tronHome, "gateway", "settings") } as Awaited<ReturnType<typeof copiedState>>);
  const hashes = async () => Promise.all(paths.map(path => withUnreadable && path === unreadable ? "unreadable" : migrationFileHash(path)));
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

const LEGACY_KEYS = ["model.ref[role=chat]", "model.thinking[role=chat]", "run.retry.maxRetries", "context.images.block"];
async function resolveLegacy(gateway: Awaited<ReturnType<typeof startGateway>>, path: string) {
  const { id } = JSON.parse((await readFile(path, "utf8")).split("\n")[0]!) as { id: string };
  // Serving precedes the bounded catalog passes; their refusals are retryable by contract.
  let opened = await gateway.request("session.open", { sessionId: id });
  for (const deadline = performance.now() + 60_000; !opened.ok && /catalog|proven|provable/.test(opened.error?.message ?? "") && performance.now() < deadline;) {
    await new Promise(done => setTimeout(done, 250));
    opened = await gateway.request("session.open", { sessionId: id });
  }
  expect(opened.ok, opened.error?.message).toBe(true);
  const resolved = await gateway.request("settings.resolve", { target: { kind: "session", sessionId: id }, keys: LEGACY_KEYS });
  expect(resolved.ok, resolved.error?.message).toBe(true);
  return Object.fromEntries((resolved.result as Resolution).keys.map(row => [row.key, { value: row.value, layer: row.layer }]));
}

describe("Gateway startup over Stable-shaped legacy state (#1649)", () => {
  it("listens within the replace window over thousands of sessions, never changes one, and an old chat/mac session resumes with the same effective settings across a no-op restart", { timeout: 420_000 }, async () => {
    const state = await stableShapedState();
    const before = await state.hashes();
    const first = await startGateway(state);
    let rows: Record<string, unknown>;
    try {
      expect(await state.hashes()).toEqual(before);
      // Shared stores moved to the current vocabulary at startup.
      expect((await new SettingsApprovals(state.tronHome).pending())[0]).toMatchObject({ requestId: state.pending.requestId, target: { kind: "global" } });
      const profile = JSON.parse(await readFile(join(state.tronHome, "gateway", "home", "profile.json"), "utf8"));
      expect(profile.model.chat).toEqual({ provider: "fixture", id: "record" });
      expect(Object.hasOwn(JSON.parse(await readFile(join(state.tronHome, "gateway", "home", "home.json"), "utf8")), "model")).toBe(false);
      rows = await resolveLegacy(first, state.legacySession);
      // Old Chat overrides stay Session overrides; old Mac/builtin frames are the unchanged Global.
      expect(rows).toEqual({
        "model.ref[role=chat]": { value: { provider: "fixture", id: "chosen" }, layer: "session" },
        "model.thinking[role=chat]": { value: "medium", layer: "global" },
        "run.retry.maxRetries": { value: 0, layer: "session" },
        "context.images.block": expect.objectContaining({ value: false }),
      });
      expect(await state.hashes()).toEqual(before);
      evidence.push({ case: "#1649 startup", listenerMs: Math.round(first.listenerMs!), readyMs: Math.round(first.readyMs!), sessions: SESSIONS, legacy: LEGACY, rows });
    } finally { await first.stop(); }
    const journal = join(state.tronHome, "gateway", "settings", "migrations", "three-layer-v1", "journal.json");
    const settled = await migrationFileHash(journal);
    const second = await startGateway(state);
    try {
      expect(await migrationFileHash(journal)).toBe(settled);
      expect(await resolveLegacy(second, state.legacySession)).toEqual(rows);
      const log = await readGatewayLog(state.tronHome);
      expect(log.filter(record => record.event === "settings.migration").map(record => record.message))
        .toEqual([expect.stringMatching(/^Settings migration published [1-9]\d* of \d+ shared settings file/), "Settings migration already complete"]);
      expect(log.filter(record => ["settings.migration-failed", "gateway.fatal-startup"].includes(record.event ?? ""))).toEqual([]);
      evidence.push({ case: "#1649 second start", listenerMs: Math.round(second.listenerMs!), readyMs: Math.round(second.readyMs!) });
    } finally { await second.stop(); }
  });

  it("an unreadable session file and a refused shared-store migration never stop startup; every store is unchanged", { timeout: 420_000 }, async () => {
    const state = await stableShapedState(400, true);
    const approvals = join(state.tronHome, "gateway", "settings", "approvals.json");
    const corrupt = JSON.parse(await readFile(approvals, "utf8")); corrupt.requests[0].changes[0].after = 3;
    await writeFile(approvals, JSON.stringify(corrupt));
    const before = await migrationFileHash(approvals);
    const gateway = await startGateway(state);
    try {
      const log = await readGatewayLog(state.tronHome);
      expect(log.filter(record => record.event === "settings.migration-failed")).toHaveLength(1);
      expect(await migrationFileHash(approvals)).toBe(before);
      await expect(stat(join(state.tronHome, "gateway", "settings", "migrations", "three-layer-v1"))).rejects.toMatchObject({ code: "ENOENT" });
      evidence.push({ case: "#1649 refused migration, Gateway serving", listenerMs: Math.round(gateway.listenerMs!), readyMs: Math.round(gateway.readyMs!) });
    } finally { await gateway.stop(); await chmod(state.unreadable, 0o600); }
  });
});
