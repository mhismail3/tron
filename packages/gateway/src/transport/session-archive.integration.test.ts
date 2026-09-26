import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { ModelRuntime, SessionManager } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider } from "@earendil-works/pi-ai";
import WebSocket from "ws";
import { afterAll, afterEach, describe, expect, it, vi } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import { DeviceStore } from "../security/device-store.js";
import { RuntimeRegistry } from "../sessions/runtime-registry.js";
import { CommandReceiptStore } from "./command-receipts.js";
import { GatewayService } from "./gateway-service.js";
import { GatewayServer } from "./server.js";

/** Retained, regenerable evidence for one run of this file. The path is stable
 * and gitignored so an operator can inspect exactly what the archive contract
 * did without committing one-off output. */
const REPORT_PATH = join(process.cwd(), "test-results", "session-archive.integration.json");
const report: {
  generatedAt: string;
  cases: Array<{ name: string; passed: boolean; evidence: Record<string, unknown> }>;
} = { generatedAt: new Date().toISOString(), cases: [] };

function record(name: string, evidence: Record<string, unknown>): void {
  report.cases.push({ name, passed: true, evidence });
}

afterAll(async () => {
  await mkdir(dirname(REPORT_PATH), { recursive: true });
  await writeFile(REPORT_PATH, `${JSON.stringify(report, null, 2)}\n`, "utf8");
});

const cleanup: Array<() => Promise<void>> = [];
afterEach(async () => {
  const results = await Promise.allSettled(cleanup.splice(0).map((dispose) => dispose()));
  vi.restoreAllMocks();
  const failures = results.filter((result) => result.status === "rejected");
  if (failures.length) throw new AggregateError(failures.map((result) => result.reason), "Archive fixture cleanup failed");
});

async function until(predicate: () => boolean | Promise<boolean>, label = "condition"): Promise<void> {
  const deadline = Date.now() + 5_000;
  while (!await predicate()) {
    if (Date.now() >= deadline) throw new Error(`${label} timed out`);
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

interface Stack {
  registry: RuntimeRegistry;
  service: GatewayService;
  server: GatewayServer;
  port: number;
}

interface Client {
  frames: any[];
  send(id: string, method: string, params: object): void;
  request(id: string, method: string, params: object): Promise<any>;
}

async function fixture(options: {
  /** Writes `${agentDir}/extensions/wake.ts`, modelling an extension-owned
   * trigger that starts a turn of its own. */
  extension?: (root: string) => string;
  /** Writes `${agentDir}/settings.json` before the first runtime starts. */
  settings?: Record<string, unknown>;
} = {}) {
  const root = await mkdtemp(join(tmpdir(), "tron-session-archive-"));
  const agentDir = join(root, "agent");
  const cwd = join(root, "project");
  const sessionDirectory = join(agentDir, "sessions", "workspace");
  await Promise.all([mkdir(sessionDirectory, { recursive: true }), mkdir(cwd, { recursive: true })]);
  if (options.extension) {
    await mkdir(join(agentDir, "extensions"), { recursive: true });
    await writeFile(join(agentDir, "extensions", "wake.ts"), options.extension(root));
  }
  if (options.settings) {
    await writeFile(join(agentDir, "settings.json"), `${JSON.stringify(options.settings)}\n`, "utf8");
  }
  const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
  process.env.PI_CODING_AGENT_DIR = agentDir;

  const faux = fauxProvider({ provider: "session-archive-fixture", tokensPerSecond: 10_000 });
  faux.setResponses([fauxAssistantMessage("archive fixture response")]);
  const runtimeFactory = vi.fn(async () => {
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    return runtime;
  });
  const listChanged = vi.fn();
  const archiveDiagnostic = vi.fn();
  const sockets: WebSocket[] = [];
  const devices = new DeviceStore(root, "fixture-machine");
  await devices.initialize();
  const invitation = await devices.ensureEnrollment();
  const paired = await devices.pair(invitation.code, "Fixture phone");
  await devices.ensureEnrollment();

  let current: Stack | undefined;
  let server: GatewayServer | undefined;
  const start = async (): Promise<Stack> => {
    server = undefined;
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: root,
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: runtimeFactory as never,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      // Mirrors gateway-main: the registry announcement is what reaches clients.
      sessionListChanged: () => { listChanged(); server?.notifySessionListChanged(); },
      archiveDiagnostic,
    });
    await registry.initialize();
    await registry.recoverCanonicalAttention();
    const uploads = {
      acquire: vi.fn(),
      materialize: vi.fn(async () => ({ envelope: "", images: [], attachments: [], photoCount: 0, fileAttachmentCount: 0 })),
      removeSession: vi.fn(async () => {}),
    };
    const service = new GatewayService({
      config: { tronHome: root },
      devices,
      sessions: registry,
      receipts: new CommandReceiptStore(root),
      uploads,
      terminals: { belongsToSession: () => false },
      logger: { log: () => {} },
      sessionDeleted: (sessionId: string) => server?.revokeSessionTerminals(sessionId),
    } as never);
    server = new GatewayServer({
      host: "127.0.0.1",
      port: 0,
      maxFrameBytes: 1_048_576,
      devices,
      sessions: registry,
      service,
      uploads: uploads as never,
      auth: { cancelOwner: () => {}, detachClient: () => {} } as never,
      logger: { log: () => {} } as never,
    });
    await server.listen();
    const port = (server as unknown as { server: { address(): { port: number } } }).server.address().port;
    current = { registry, service, server, port };
    return current;
  };
  const stack = await start();
  cleanup.push(async () => {
    if (current) {
      sockets.forEach((socket) => socket.terminate());
      await current.server.close();
      await current.registry.dispose();
      current = undefined;
    }
    if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
    await rm(root, { recursive: true, force: true });
  });
  const restart = async (): Promise<Stack> => {
    sockets.forEach((socket) => socket.terminate());
    sockets.splice(0);
    const previous = current!;
    current = undefined;
    await previous.server.close();
    await previous.registry.dispose();
    return start();
  };
  const connect = async (): Promise<Client> => {
    const active = current!;
    const socket = new WebSocket(`ws://127.0.0.1:${active.port}/v1/socket`, { headers: { authorization: `Bearer ${paired.token}` } });
    sockets.push(socket);
    const frames: any[] = [];
    socket.on("message", (raw) => frames.push(JSON.parse(raw.toString())));
    await until(() => socket.readyState === WebSocket.OPEN, "socket open");
    socket.send(JSON.stringify({ type: "hello", protocolVersion: 5 }));
    await until(() => frames.some((frame) => frame.type === "hello"), "hello");
    const send = (id: string, method: string, params: object) => socket.send(JSON.stringify({ type: "request", id, method, params }));
    return {
      frames,
      send,
      request: async (id: string, method: string, params: object) => {
        send(id, method, params);
        await until(() => frames.some((frame) => frame.id === id), `response ${method}`);
        return frames.find((frame) => frame.id === id);
      },
    };
  };
  /** A canonical, persisted session with no live runtime, created the way the
   * pinned SDK creates one. */
  const coldSession = (label: string): { id: string; file: string } => {
    const manager = SessionManager.create(cwd, sessionDirectory);
    manager.appendMessage(fauxAssistantMessage(`${label} canonical response`));
    const file = manager.getSessionFile()!;
    return { id: manager.getSessionId(), file };
  };
  return { root, agentDir, cwd, sessionDirectory, devices, paired, faux, runtimeFactory, listChanged, archiveDiagnostic, connect, coldSession, restart, current: () => current! };
}

const list = async (client: Client, archived: "exclude" | "only", extra: Record<string, unknown> = {}) => {
  const response = await client.request(`list-${archived}-${Math.random().toString(36).slice(2, 8)}`, "session.list", { scope: "user", archived, ...extra });
  expect(response.ok, JSON.stringify(response)).toBe(true);
  return response.result as {
    sessions: Array<{ id: string; archivedAt?: string; phase?: string; updatedAt?: string }>;
    archivedCount?: number;
    nextCursor?: string;
  };
};

/** A live, idle session: `openedSlot` requires the subscription an open+sync
 * establishes, and archiving is allowed while a slot is idle. */
const openSession = async (client: Client, sessionId: string) => {
  const opened = await client.request(`open-${sessionId}`, "session.open", { sessionId });
  expect(opened.ok, JSON.stringify(opened)).toBe(true);
  const synced = await client.request(`sync-${sessionId}`, "session.sync", { sessionId, syncToken: opened.result.syncToken });
  expect(synced.ok, JSON.stringify(synced)).toBe(true);
};

const archiveSession = async (client: Client, sessionId: string, commandId: string) => {
  const response = await client.request(`archive-${commandId}`, "session.archive.set", { commandId, sessionId, archived: true });
  expect(response.ok, JSON.stringify(response)).toBe(true);
  return response.result as { archived: boolean; archivedAt: string };
};

const listedIds = async (client: Client, archived: "exclude" | "only") =>
  (await list(client, archived)).sessions.map((session) => session.id);

const archivedRecord = async (root: string, sessionId: string): Promise<unknown> => {
  const document = JSON.parse(await readFile(join(root, "gateway", "session-archive.json"), "utf8")) as {
    sessions: Record<string, unknown>;
  };
  return document.sessions[sessionId];
};

const listChangedFrames = (client: Client) =>
  client.frames.filter((frame) => frame.type === "event" && frame.topic === "session.listChanged").length;

describe("session archive over the real Gateway", () => {
  it("archives an idle session without touching its canonical file", async () => {
    const f = await fixture();
    const client = await f.connect();
    const archived = f.coldSession("archived");
    const visible = f.coldSession("visible");
    const before = await readFile(archived.file, "utf8");
    const beforeRow = (await list(client, "exclude")).sessions.find((session) => session.id === archived.id);
    expect(beforeRow?.updatedAt).toBeDefined();
    const factoryCallsBeforeArchive = f.runtimeFactory.mock.calls.length;
    f.listChanged.mockClear();

    const response = await client.request("archive-1", "session.archive.set", {
      commandId: "archive-command-0001", sessionId: archived.id, archived: true,
    });
    expect(response.ok, JSON.stringify(response)).toBe(true);
    expect(response.result).toMatchObject({ archived: true });
    expect(typeof response.result.archivedAt).toBe("string");

    const excluded = await list(client, "exclude");
    expect(excluded.sessions.map((session) => session.id)).toEqual([visible.id]);
    expect(excluded.archivedCount).toBe(1);
    const only = await list(client, "only");
    expect(only.sessions.map((session) => session.id)).toEqual([archived.id]);
    expect(typeof only.sessions[0]?.archivedAt).toBe("string");
    expect(only.sessions[0]?.archivedAt).toBe(response.result.archivedAt);
    expect(only.sessions[0]?.updatedAt).toBe(beforeRow!.updatedAt);
    expect(only.archivedCount).toBeUndefined();
    expect(f.listChanged).toHaveBeenCalled();

    // The canonical file, its bytes and its revision fields are untouched, and
    // archiving a cold session never starts a runtime for it.
    expect(await readFile(archived.file, "utf8")).toBe(before);
    const row = (await list(client, "exclude")).sessions.find((session) => session.id === visible.id);
    expect(row).toBeDefined();
    expect(f.runtimeFactory.mock.calls.length).toBe(factoryCallsBeforeArchive);
    record("archives an idle session without touching its canonical file", {
      archivedAt: response.result.archivedAt,
      archivedCount: excluded.archivedCount,
      canonicalBytesUnchanged: true,
      updatedAtUnchanged: only.sessions[0]?.updatedAt === beforeRow!.updatedAt,
      runtimeStartsDuringArchive: f.runtimeFactory.mock.calls.length - factoryCallsBeforeArchive,
    });
  });

  it("keeps one receipt, one timestamp and one archived row for a replayed command", async () => {
    const f = await fixture();
    const client = await f.connect();
    const session = f.coldSession("replay");
    const first = await client.request("archive-first", "session.archive.set", {
      commandId: "archive-command-replay", sessionId: session.id, archived: true,
    });
    const second = await client.request("archive-second", "session.archive.set", {
      commandId: "archive-command-replay", sessionId: session.id, archived: true,
    });
    expect(second.ok).toBe(true);
    expect(second.result).toEqual(first.result);
    const only = await list(client, "only");
    expect(only.sessions).toHaveLength(1);
    expect(only.sessions[0]?.archivedAt).toBe(first.result.archivedAt);

    // A distinct command ID that repeats the same state is idempotent too.
    const third = await client.request("archive-third", "session.archive.set", {
      commandId: "archive-command-replay-again", sessionId: session.id, archived: true,
    });
    expect(third.result).toEqual(first.result);
    expect((await list(client, "only")).sessions).toHaveLength(1);
    record("keeps one receipt, one timestamp and one archived row for a replayed command", {
      archivedAt: first.result.archivedAt,
      replayMatched: true,
      archivedRows: 1,
    });
  });

  it("binds a list cursor to its archive filter and orders the archived list newest first", async () => {
    const f = await fixture();
    const client = await f.connect();
    const older = f.coldSession("cursor-archived-older");
    const visible = f.coldSession("cursor-visible");
    const visibleOther = f.coldSession("cursor-visible-other");
    const archive = (id: string, commandId: string) => client.request(commandId, "session.archive.set", {
      commandId, sessionId: id, archived: true,
    });
    const firstArchived = await archive(older.id, "archive-command-cursor-older");
    expect(firstArchived.ok).toBe(true);
    // Archive timestamps are the ordering source, so the two commits must not
    // share one millisecond.
    await new Promise((resolve) => setTimeout(resolve, 5));
    const newer = f.coldSession("cursor-archived-newer");
    const secondArchived = await archive(newer.id, "archive-command-cursor-newer");
    expect(secondArchived.ok).toBe(true);
    expect((await list(client, "only")).sessions.map((row) => row.id)).toEqual([newer.id, older.id]);

    const received: string[] = [];
    let page = await list(client, "exclude", { limit: 1 });
    expect(page.archivedCount).toBe(2);
    received.push(...page.sessions.map((row) => row.id));
    while (page.nextCursor) {
      const continued = await client.request(`cursor-continue-${received.length}`, "session.list", {
        scope: "user", archived: "exclude", limit: 1, cursor: page.nextCursor,
      });
      expect(continued.ok).toBe(true);
      expect(continued.result.archivedCount).toBeUndefined();
      received.push(...continued.result.sessions.map((session: { id: string }) => session.id));
      page = continued.result;
    }
    expect(received).toHaveLength(2);
    expect([...received].sort()).toEqual([visible.id, visibleOther.id].sort());
    expect(new Set(received).size).toBe(received.length);
    // The cursor belongs to the exclude traversal: an `only` request cannot
    // continue it and receive the other projection.
    const excludeCursor = (await list(client, "exclude", { limit: 1 })).nextCursor;
    expect(excludeCursor).toBeDefined();
    const mismatched = await client.request("cursor-mismatch", "session.list", {
      scope: "user", archived: "only", limit: 1, cursor: excludeCursor,
    });
    expect(mismatched).toMatchObject({ ok: false, error: { code: "invalid_request" } });
    record("binds a list cursor to its archive filter and orders the archived list newest first", {
      archivedOnlyOrder: [newer.id, older.id],
      excludeTraversal: received,
      mismatchedFilterRejected: mismatched.error.code,
    });
  });

  it("rejects archiving a session that is running, waiting for input, or working through subagents", async () => {
    const f = await fixture();
    const client = await f.connect();
    const session = f.coldSession("busy");
    let release!: () => void;
    const barrier = new Promise<void>((resolve) => { release = resolve; });
    f.faux.setResponses([async () => { await barrier; return fauxAssistantMessage("finished"); }]);
    const opened = await client.request("busy-open", "session.open", { sessionId: session.id });
    expect(opened.ok, JSON.stringify(opened)).toBe(true);
    await client.request("busy-sync", "session.sync", { sessionId: session.id, syncToken: opened.result.syncToken });
    const prompt = await client.request("busy-prompt", "session.prompt", {
      commandId: "busy-prompt-command", sessionId: session.id, text: "stay running",
    });
    expect(prompt.ok, JSON.stringify(prompt)).toBe(true);
    await until(async () => (await list(client, "exclude")).sessions.some((row) => row.id === session.id && row.phase === "running"), "running phase");
    const running = await client.request("busy-archive", "session.archive.set", {
      commandId: "busy-archive-command", sessionId: session.id, archived: true,
    });
    expect(running).toMatchObject({ ok: false, error: { code: "busy" } });
    release();
    await until(async () => (await list(client, "exclude")).sessions.some((row) => row.id === session.id && row.phase === "idle"), "idle phase");

    // Waiting for a semantic interaction and detached subagent work are the
    // other two projections a user sees as active. The session is idle, so no
    // heartbeat can replace the injected projection before the request runs.
    const internals = f.current().registry as unknown as { latestSummaries: Map<string, Record<string, unknown>> };
    const published = internals.latestSummaries.get(session.id);
    expect(published).toBeDefined();
    let waitingCode: string | undefined;
    let subagentCode: string | undefined;
    try {
      internals.latestSummaries.set(session.id, { ...published!, phase: "idle", foregroundPhase: undefined, waitingForUser: true });
      const waiting = await client.request("waiting-archive", "session.archive.set", {
        commandId: "waiting-archive-command", sessionId: session.id, archived: true,
      });
      expect(waiting).toMatchObject({ ok: false, error: { code: "busy" } });
      waitingCode = waiting.error.code;
      internals.latestSummaries.set(session.id, { ...published!, foregroundPhase: undefined, waitingForUser: false, hasActiveSubagents: true });
      const subagents = await client.request("subagent-archive", "session.archive.set", {
        commandId: "subagent-archive-command", sessionId: session.id, archived: true,
      });
      expect(subagents).toMatchObject({ ok: false, error: { code: "busy" } });
      subagentCode = subagents.error.code;
    } finally {
      internals.latestSummaries.set(session.id, published!);
    }
    expect((await list(client, "exclude")).sessions.map((row) => row.id)).toContain(session.id);
    expect((await list(client, "only")).sessions).toHaveLength(0);
    record("rejects archiving a session that is running, waiting for input, or working through subagents", {
      running: running.error.code,
      waitingForUser: waitingCode,
      hasActiveSubagents: subagentCode,
      archivedRowsAfterRejections: 0,
    });
  });

  it("keeps archive state across a Gateway restart and an open", async () => {
    const f = await fixture();
    const first = await f.connect();
    const session = f.coldSession("restart");
    const archived = await first.request("restart-archive", "session.archive.set", {
      commandId: "restart-archive-command", sessionId: session.id, archived: true,
    });
    expect(archived.ok).toBe(true);
    await f.restart();
    const second = await f.connect();
    expect((await list(second, "exclude")).sessions.map((row) => row.id)).not.toContain(session.id);
    const only = await list(second, "only");
    expect(only.sessions.map((row) => row.id)).toEqual([session.id]);
    expect(only.sessions[0]?.archivedAt).toBe(archived.result.archivedAt);

    const opened = await second.request("restart-open", "session.open", { sessionId: session.id });
    expect(opened.ok).toBe(true);
    await second.request("restart-sync", "session.sync", { sessionId: session.id, syncToken: opened.result.syncToken });
    expect((await list(second, "exclude")).sessions.map((row) => row.id)).not.toContain(session.id);
    expect((await list(second, "only")).sessions.map((row) => row.id)).toEqual([session.id]);
    record("keeps archive state across a Gateway restart and an open", {
      archivedAt: archived.result.archivedAt,
      hiddenAfterRestart: true,
      hiddenAfterOpen: true,
    });
  });

  it("keeps a renamed session archived and forks an unarchived child", async () => {
    const f = await fixture();
    const client = await f.connect();
    const parent = f.coldSession("fork-parent");
    await client.request("fork-archive", "session.archive.set", {
      commandId: "fork-archive-command", sessionId: parent.id, archived: true,
    });
    const renamed = await client.request("fork-rename", "session.rename", {
      commandId: "fork-rename-command", sessionId: parent.id, name: "Archived and renamed",
    });
    expect(renamed.ok).toBe(true);
    const only = await list(client, "only");
    expect(only.sessions.map((row) => row.id)).toEqual([parent.id]);

    const opened = await client.request("fork-open", "session.open", { sessionId: parent.id });
    await client.request("fork-sync", "session.sync", { sessionId: parent.id, syncToken: opened.result.syncToken });
    const entryId = (SessionManager.open(parent.file).getBranch().at(-1) as { id?: string } | undefined)?.id;
    expect(typeof entryId).toBe("string");
    // The fork itself runs on the owning runtime, because the `session.fork` RPC
    // path is blocked by its own admitted work entry (reported separately). The
    // archive ownership under test is the rebind hook either path reaches.
    const parentSlot = await f.current().registry.acquire(parent.id);
    const forked = await parentSlot.fork(entryId!, "at");
    const childId = forked.sessionId;
    expect(childId).not.toBe(parent.id);

    const excluded = await list(client, "exclude");
    const child = excluded.sessions.find((row) => row.id === childId);
    expect(child).toBeDefined();
    expect(child?.archivedAt).toBeUndefined();
    expect((await list(client, "only")).sessions.map((row) => row.id)).toEqual([parent.id]);
    record("keeps a renamed session archived and forks an unarchived child", {
      childId,
      childArchived: false,
      archivedRows: (await list(client, "only")).sessions.map((row) => row.id),
    });
  });

  it("rejects archiving a runtime-owned subagent session", async () => {
    const f = await fixture();
    const client = await f.connect();
    const parent = f.coldSession("subagent-parent");
    const childDirectory = join(f.sessionDirectory, parent.id, "worker", "run-0");
    await mkdir(childDirectory, { recursive: true });
    const childId = "runtime-owned-subagent-child";
    await writeFile(join(childDirectory, "session.jsonl"), `${JSON.stringify({
      type: "session", version: 3, id: childId, timestamp: new Date().toISOString(), cwd: f.cwd,
    })}\n`);
    const rejected = await client.request("subagent-archive-request", "session.archive.set", {
      commandId: "subagent-archive-command", sessionId: childId, archived: true,
    });
    expect(rejected).toMatchObject({ ok: false, error: { code: "conflict" } });
    expect((await list(client, "only")).sessions).toHaveLength(0);
    record("rejects archiving a runtime-owned subagent session", { code: rejected.error.code });
  });

  it("deletes an archived session and never resurrects its archive record", async () => {
    const f = await fixture();
    const client = await f.connect();
    const session = f.coldSession("delete");
    await client.request("delete-archive", "session.archive.set", {
      commandId: "delete-archive-command", sessionId: session.id, archived: true,
    });
    expect((await list(client, "only")).sessions).toHaveLength(1);
    const deleted = await client.request("delete-session", "session.delete", {
      commandId: "delete-archived-session-command", sessionId: session.id,
    });
    expect(deleted.ok, JSON.stringify(deleted)).toBe(true);
    const store = JSON.parse(await readFile(join(f.root, "gateway", "session-archive.json"), "utf8")) as { sessions: Record<string, unknown> };
    expect(Object.keys(store.sessions)).toEqual([]);
    expect((await list(client, "only")).sessions).toHaveLength(0);
    expect((await list(client, "exclude")).archivedCount).toBe(0);

    // A re-created canonical file with the same identity is a new session, not a
    // resurrected archive record.
    await writeFile(session.file, `${JSON.stringify({
      type: "session", version: 3, id: session.id, timestamp: new Date().toISOString(), cwd: f.cwd,
    })}\n${JSON.stringify({
      type: "message", id: "recreated-entry", timestamp: Date.now(),
      message: { role: "assistant", content: [{ type: "text", text: "re-created" }] },
    })}\n`);
    const afterRecreate = await list(client, "exclude");
    expect(afterRecreate.sessions.map((row) => row.id)).toContain(session.id);
    expect(afterRecreate.archivedCount).toBe(0);
    expect((await list(client, "only")).sessions).toHaveLength(0);
    record("deletes an archived session and never resurrects its archive record", {
      storeAfterDelete: [],
      recreatedSessionVisible: true,
      archivedCountAfterRecreate: afterRecreate.archivedCount,
    });
  });

  it("archives a live idle session and unarchives it again", async () => {
    const f = await fixture();
    const client = await f.connect();
    const slot = await f.current().registry.create(f.cwd);
    // A brand-new session has no canonical file yet; it is still an admitted
    // dashboard row and must be archivable while it is idle.
    const response = await client.request("live-archive", "session.archive.set", {
      commandId: "live-archive-command", sessionId: slot.id, archived: true,
    });
    expect(response.ok, JSON.stringify(response)).toBe(true);
    expect(slot.persistedSessionFile).toBeUndefined();
    expect((await list(client, "only")).sessions.map((row) => row.id)).toEqual([slot.id]);

    const restored = await client.request("live-unarchive", "session.archive.set", {
      commandId: "live-unarchive-command", sessionId: slot.id, archived: false,
    });
    expect(restored.result).toEqual({ archived: false });
    expect((await list(client, "only")).sessions).toHaveLength(0);
    expect((await list(client, "exclude")).sessions.map((row) => row.id)).toEqual([slot.id]);
    record("archives a live idle session and unarchives it again", {
      liveOnlyArchived: true,
      unarchiveResult: restored.result,
      runtimeStarts: f.runtimeFactory.mock.calls.length,
    });
  });

  it("clears archive state before a prompt is admitted and announces it to every client", async () => {
    const f = await fixture();
    const first = await f.connect();
    const second = await f.connect();
    const session = f.coldSession("prompt-unarchive");
    await openSession(first, session.id);
    await archiveSession(first, session.id, "prompt-archive-command");
    expect(await listedIds(first, "exclude")).not.toContain(session.id);
    const announcementAt = { first: listChangedFrames(first), second: listChangedFrames(second) };
    f.faux.setResponses([fauxAssistantMessage("awake")]);

    const prompt = await first.request("prompt-unarchive-request", "session.prompt", {
      commandId: "prompt-unarchive-command", sessionId: session.id, text: "come back",
    });
    expect(prompt.ok, JSON.stringify(prompt)).toBe(true);
    // The admission response is the exact boundary: the durable record must
    // already be gone, before the run's first event can reach any client.
    expect(await archivedRecord(f.root, session.id)).toBeUndefined();

    await until(async () => (await listedIds(first, "exclude")).includes(session.id), "visible on the prompting client");
    await until(async () => (await listedIds(second, "exclude")).includes(session.id), "visible on the observing client");
    await until(() => listChangedFrames(first) > announcementAt.first, "first client list change");
    await until(() => listChangedFrames(second) > announcementAt.second, "second client list change");
    expect(f.archiveDiagnostic).toHaveBeenCalledWith({ outcome: "auto-unarchived", trigger: "admission" });
    await until(async () => (await list(first, "exclude")).sessions.some(
      (row) => row.id === session.id && row.phase === "idle"), "settled");
    record("clears archive state before a prompt is admitted and announces it to every client", {
      recordClearedAtAdmission: true,
      promptingClientListChanged: listChangedFrames(first) - announcementAt.first,
      observingClientListChanged: listChangedFrames(second) - announcementAt.second,
    });
  });

  it("clears archive state when Bash is admitted", async () => {
    const f = await fixture();
    const client = await f.connect();
    const session = f.coldSession("bash-unarchive");
    await openSession(client, session.id);
    await archiveSession(client, session.id, "bash-archive-command");

    // Bash is driven on the owning runtime because the `session.bash` RPC is
    // rejected by its own admitted work entry before this boundary is reached.
    // That defect is reported separately; the archive ownership under test is
    // the same one that RPC reaches.
    const slot = await f.current().registry.acquire(session.id);
    await slot.executeBash("echo archive-bash", true);
    expect(await archivedRecord(f.root, session.id)).toBeUndefined();
    expect(await listedIds(client, "exclude")).toContain(session.id);
    expect(f.archiveDiagnostic).toHaveBeenCalledWith({ outcome: "auto-unarchived", trigger: "admission" });
    await until(async () => !(await f.current().registry.acquire(session.id)).isBusy, "settled");
    record("clears archive state when Bash is admitted", {
      bashAdmitted: true,
      recordCleared: (await archivedRecord(f.root, session.id)) === undefined,
      rpcBlockedByOwnWorkEntry: true,
    });
  });

  it("clears archive state when a manual compaction is admitted", async () => {
    // A tiny compaction budget gives the session history that manual compaction
    // can actually summarize, so the admitted work is observable end to end.
    const f = await fixture({ settings: { compaction: { enabled: true, reserveTokens: 1_024, keepRecentTokens: 0 } } });
    const client = await f.connect();
    const session = f.coldSession("compaction-unarchive");
    await openSession(client, session.id);
    f.faux.setResponses([
      fauxAssistantMessage(`History for compaction. ${"detail ".repeat(200)}`),
      // Compaction may summarize the recent turn prefix before the main summary.
      fauxAssistantMessage("turn prefix summary"),
      fauxAssistantMessage("compacted summary"),
      fauxAssistantMessage("compacted summary"),
    ]);
    const primed = await client.request("compaction-prime", "session.prompt", {
      commandId: "compaction-prime-command", sessionId: session.id, text: `Prime the history. ${"context ".repeat(200)}`,
    });
    expect(primed.ok, JSON.stringify(primed)).toBe(true);
    await until(async () => (await list(client, "exclude")).sessions.some(
      (row) => row.id === session.id && row.phase === "idle"), "primed history settled");
    await archiveSession(client, session.id, "compaction-archive-command");

    const compaction = await client.request("compaction-unarchive-request", "session.compact", {
      commandId: "compaction-unarchive-command", sessionId: session.id,
    });
    expect(compaction.ok, JSON.stringify(compaction)).toBe(true);
    expect(compaction.result).toMatchObject({ compacted: true });
    // Either compaction path (immediate or queued behind a run) is admitted
    // through the same boundary, so the record must be gone once it returns.
    expect(await archivedRecord(f.root, session.id)).toBeUndefined();
    expect(await listedIds(client, "exclude")).toContain(session.id);
    expect(f.archiveDiagnostic).toHaveBeenCalledWith({ outcome: "auto-unarchived", trigger: "admission" });
    record("clears archive state when a manual compaction is admitted", {
      compactionRpcAccepted: true,
      queued: compaction.result.queued,
      recordCleared: true,
    });
  });

  it("clears archive state for an automation-owned prompt on an existing session", async () => {
    const f = await fixture();
    const client = await f.connect();
    const session = f.coldSession("automation-unarchive");
    await openSession(client, session.id);
    await archiveSession(client, session.id, "automation-archive-command");
    f.faux.setResponses([fauxAssistantMessage("scheduled response")]);

    // Mirrors AutomationExecutor: take the automation lease for a persisted
    // session, then admit the prompt with its exact operation ownership.
    const lease = await f.current().registry.acquireAutomationLease(session.id);
    const admission = await lease.slot.prompt(
      "scheduled run",
      [],
      undefined,
      { text: "scheduled run", attachmentEnvelope: "", attachmentCount: 0 },
      undefined,
      {
        operationId: "automation:fixture-operation",
        origin: { kind: "gateway", ownerId: "fixture-automation", title: "Automation", confidence: "boundary" },
        onTerminal: () => {},
      },
    );
    lease.release();
    expect(admission.operationId).toBe("automation:fixture-operation");
    expect(await archivedRecord(f.root, session.id)).toBeUndefined();
    await until(async () => (await listedIds(client, "exclude")).includes(session.id), "automation target visible");
    await until(async () => !(await f.current().registry.acquire(session.id)).isBusy, "automation run settled");
    record("clears archive state for an automation-owned prompt on an existing session", {
      operationId: admission.operationId,
      recordClearedAtAdmission: true,
    });
  });

  it("treats a queued prompt as busy for archive admission", async () => {
    const f = await fixture();
    const client = await f.connect();
    const session = f.coldSession("queued-unarchive");
    await openSession(client, session.id);
    let release!: () => void;
    const barrier = new Promise<void>((resolve) => { release = resolve; });
    f.faux.setResponses([async () => { await barrier; return fauxAssistantMessage("finished"); }]);

    const running = await client.request("queued-running-prompt", "session.prompt", {
      commandId: "queued-running-prompt-command", sessionId: session.id, text: "stay running",
    });
    expect(running.ok, JSON.stringify(running)).toBe(true);
    await until(async () => (await list(client, "exclude")).sessions.some(
      (row) => row.id === session.id && row.phase === "running"), "running phase");
    const queued = await client.request("queued-follow-up", "session.prompt", {
      commandId: "queued-follow-up-command", sessionId: session.id, text: "queued follow-up", behavior: "followUp",
    });
    expect(queued.ok, JSON.stringify(queued)).toBe(true);

    const archive = await client.request("queued-archive", "session.archive.set", {
      commandId: "queued-archive-command", sessionId: session.id, archived: true,
    });
    expect(archive).toMatchObject({ ok: false, error: { code: "busy" } });
    release();
    await until(async () => (await list(client, "exclude")).sessions.some(
      (row) => row.id === session.id && row.phase === "idle"), "settled");
    expect(await archivedRecord(f.root, session.id)).toBeUndefined();
    record("treats a queued prompt as busy for archive admission", {
      archiveError: archive.error.code,
      queuedOperationId: queued.result.operationId,
    });
  });

  it("clears archive state when an extension starts a turn without Gateway admission", async () => {
    // An extension-owned trigger (a scheduled wake) starts the turn inside Pi,
    // so no Gateway run admission can see it. The active projection is the only
    // boundary that can restore visibility, and it must do so immediately.
    const f = await fixture({
      extension: (root) => `
        import { existsSync } from "node:fs";
        import { setTimeout as delay } from "node:timers/promises";
        export default function (pi) {
          void (async () => {
            for (;;) {
              if (existsSync(${JSON.stringify(join(root, "wake-trigger"))})) {
                pi.sendMessage({ customType: "external-wake", content: "external wake", display: false }, { triggerTurn: true });
                return;
              }
              await delay(5);
            }
          })();
        }
      `,
    });
    const client = await f.connect();
    const session = f.coldSession("backstop-unarchive");
    await openSession(client, session.id);
    await archiveSession(client, session.id, "backstop-archive-command");
    expect(await listedIds(client, "exclude")).not.toContain(session.id);
    let release!: () => void;
    const barrier = new Promise<void>((resolve) => { release = resolve; });
    f.faux.setResponses([async () => { await barrier; return fauxAssistantMessage("woke by itself"); }]);
    try {
      await writeFile(join(f.root, "wake-trigger"), "", "utf8");
      await until(async () => (await list(client, "exclude")).sessions.some(
        (row) => row.id === session.id && row.phase === "running"), "externally started run");
      // The row is visible from the moment the active projection is published,
      // and the durable record is cleared behind it rather than only hidden in
      // memory.
      const visibleWhileRunning = (await list(client, "exclude")).sessions.find((row) => row.id === session.id);
      expect(visibleWhileRunning?.phase).toBe("running");
      expect(visibleWhileRunning?.archivedAt).toBeUndefined();
      await until(() => f.archiveDiagnostic.mock.calls.some(
        (call) => JSON.stringify(call[0]) === JSON.stringify({ outcome: "auto-unarchived", trigger: "backstop" })),
      "backstop diagnostic");
      expect(await archivedRecord(f.root, session.id)).toBeUndefined();
      release();
      await until(async () => (await list(client, "exclude")).sessions.some(
        (row) => row.id === session.id && row.phase === "idle"), "settled");
      record("clears archive state when an extension starts a turn without Gateway admission", {
        visibleWhileRunning: visibleWhileRunning?.phase,
        durableRecordCleared: true,
        trigger: "backstop",
      });
    } finally {
      release();
    }
  });

  it("rejects a prompt retryably when archive state cannot be cleared", async () => {
    const f = await fixture();
    const client = await f.connect();
    const session = f.coldSession("persist-failure");
    await openSession(client, session.id);
    await archiveSession(client, session.id, "failure-archive-command");
    const registry = f.current().registry as unknown as {
      archive: { remove(sessionId: string): Promise<boolean> };
      markers: { evidence(): Promise<ReadonlyMap<string, readonly unknown[]>> };
    };
    const durableRemove = registry.archive.remove.bind(registry.archive);
    // A failing durable write leaves the in-memory projection untouched, which
    // is exactly what a full or failing disk produces.
    registry.archive.remove = async () => { throw new Error("Fixture archive write failure"); };
    f.faux.setResponses([fauxAssistantMessage("must never run")]);

    let prompt: any;
    try {
      prompt = await client.request("failure-prompt", "session.prompt", {
        commandId: "failure-prompt-command", sessionId: session.id, text: "must not run",
      });
    } finally {
      registry.archive.remove = durableRemove;
    }
    expect(prompt).toMatchObject({ ok: false, error: { code: "busy", retryable: true } });
    expect(f.archiveDiagnostic).toHaveBeenCalledWith({ outcome: "failure", stage: "auto-unarchive" });
    // Fail closed: the session stays archived, no run marker exists, and no
    // runtime work was admitted for the rejected prompt.
    expect(await archivedRecord(f.root, session.id)).toBeDefined();
    expect(await listedIds(client, "only")).toEqual([session.id]);
    expect([...(await registry.markers.evidence()).keys()]).not.toContain(session.id);
    const slot = await f.current().registry.acquire(session.id);
    expect(slot.isBusy).toBe(false);
    expect(slot.snapshot().phase).toBe("idle");
    record("rejects a prompt retryably when archive state cannot be cleared", {
      promptError: prompt.error.code,
      retryable: prompt.error.retryable,
      runMarkers: 0,
      phaseAfterRejection: slot.snapshot().phase,
    });
  });

  it("holds the session lane from archive admission through the durable commit", async () => {
    // The review finding this covers: if archive admission released the session
    // lane before its durable commit, a prompt could be admitted in the gap, and
    // the archive would then commit over running work. Holding the durable write
    // open inside the commit makes that gap observable.
    const f = await fixture();
    const client = await f.connect();
    const session = f.coldSession("lane-hold");
    await openSession(client, session.id);
    const registry = f.current().registry as unknown as {
      archive: { archive(sessionId: string): Promise<string> };
    };
    const durableArchive = registry.archive.archive.bind(registry.archive);
    let enteredCommit!: () => void;
    const inCommit = new Promise<void>((resolve) => { enteredCommit = resolve; });
    let releaseCommit!: () => void;
    const commitBarrier = new Promise<void>((resolve) => { releaseCommit = resolve; });
    registry.archive.archive = async (sessionId: string) => {
      enteredCommit();
      await commitBarrier;
      return durableArchive(sessionId);
    };
    f.faux.setResponses([fauxAssistantMessage("must not be hidden")]);
    let promptSettled = false;
    try {
      const archivePromise = client.request("lane-hold-archive", "session.archive.set", {
        commandId: "lane-hold-archive-command", sessionId: session.id, archived: true,
      });
      await inCommit;
      const promptPromise = client.request("lane-hold-prompt", "session.prompt", {
        commandId: "lane-hold-prompt-command", sessionId: session.id, text: "must not run hidden",
      }).then((response) => { promptSettled = true; return response; });
      await new Promise((resolve) => setTimeout(resolve, 100));
      const admittedDuringCommit = promptSettled;
      // The archive still owns the session lane, so no prompt may be admitted.
      expect(admittedDuringCommit).toBe(false);
      releaseCommit();
      expect((await archivePromise).ok).toBe(true);
      const prompt = await promptPromise;
      // The prompt is admitted only after the commit, and it clears the record
      // before it runs: the session is never both working and hidden.
      expect(prompt.ok, JSON.stringify(prompt)).toBe(true);
      expect(await archivedRecord(f.root, session.id)).toBeUndefined();
      await until(async () => (await list(client, "exclude")).sessions.some((row) => row.id === session.id), "visible after the commit");
      record("holds the session lane from archive admission through the durable commit", {
        promptAdmittedDuringCommit: admittedDuringCommit,
        archiveCommitted: true,
        recordClearedAfterAdmission: true,
      });
    } finally {
      releaseCommit();
      registry.archive.archive = durableArchive;
    }
  });

  it("never commits an archive over a run that admission already admitted", async () => {
    const f = await fixture();
    const client = await f.connect();
    const session = f.coldSession("race");
    await openSession(client, session.id);
    const registry = f.current().registry as unknown as {
      archive: { archivedAt(sessionId: string): string | undefined };
    };
    const slot = await f.current().registry.acquire(session.id);
    const outcomes = { promptAdmitted: 0, archiveWonPromptRejected: 0, bothCommitted: 0 };
    const rounds = 10;
    for (let round = 0; round < rounds; round += 1) {
      f.faux.setResponses([fauxAssistantMessage(`race response ${round}`)]);
      // Warm the catalog acquisition on alternating rounds so the archive
      // request can reach the session lane before the prompt does, instead of
      // always losing the walk to it.
      if (round % 2 === 1) await list(client, "exclude", { limit: 1 });
      const [archive, prompt] = await Promise.all([
        client.request(`race-archive-${round}`, "session.archive.set", {
          commandId: `race-archive-command-${round}`, sessionId: session.id, archived: true,
        }),
        client.request(`race-prompt-${round}`, "session.prompt", {
          commandId: `race-prompt-command-${round}`, sessionId: session.id, text: `race ${round}`,
        }),
      ]);
      if (prompt.ok) {
        outcomes.promptAdmitted += 1;
        // The invariant this race protects: once a run owns the session, no
        // archive record may exist, so it can never work while hidden.
        expect(registry.archive.archivedAt(session.id)).toBeUndefined();
        expect(await archivedRecord(f.root, session.id)).toBeUndefined();
        expect(await listedIds(client, "exclude")).toContain(session.id);
        if (archive.ok) outcomes.bothCommitted += 1;
      } else {
        expect(prompt).toMatchObject({ ok: false, error: { code: "busy" } });
        expect(archive.ok, JSON.stringify(archive)).toBe(true);
        outcomes.archiveWonPromptRejected += 1;
      }
      await until(() => !slot.isBusy, "race run settled");
      // Reset for the next round: an unarchive is a no-op when the prompt won.
      const reset = await client.request(`race-reset-${round}`, "session.archive.set", {
        commandId: `race-reset-command-${round}`, sessionId: session.id, archived: false,
      });
      expect(reset.ok).toBe(true);
    }

    // One gated round with a committed record: the prompt then clears it and
    // the row must be visible for the whole run that follows.
    const gated = (() => {
      let release!: () => void;
      const barrier = new Promise<void>((resolve) => { release = resolve; });
      return { barrier, release: () => release() };
    })();
    f.faux.setResponses([async () => { await gated.barrier; return fauxAssistantMessage("gated response"); }]);
    await archiveSession(client, session.id, "race-gated-archive-command");
    expect(await listedIds(client, "exclude")).not.toContain(session.id);
    const gatedPrompt = await client.request("race-gated-prompt", "session.prompt", {
      commandId: "race-gated-prompt-command", sessionId: session.id, text: "gated race",
    });
    expect(gatedPrompt.ok, JSON.stringify(gatedPrompt)).toBe(true);
    await until(() => slot.snapshot().phase === "running", "gated run started");
    expect(registry.archive.archivedAt(session.id)).toBeUndefined();
    const duringRun = (await list(client, "exclude")).sessions.find((row) => row.id === session.id);
    expect(duringRun?.phase).toBe("running");
    expect(duringRun?.archivedAt).toBeUndefined();
    gated.release();
    await until(() => !slot.isBusy, "gated run settled");
    record("never commits an archive over a run that admission already admitted", {
      rounds,
      outcomes,
      visibleWhileRunning: duringRun?.phase,
    });
  });
});
