import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
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
 * and gitignored, so an operator can inspect exactly which RPCs the session idle
 * admission admitted or rejected without committing one-off output. */
const REPORT_PATH = join(process.cwd(), "test-results", "rpc-idle-admission.integration.json");
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
  if (failures.length) throw new AggregateError(failures.map((result) => result.reason), "RPC idle fixture cleanup failed");
});

async function until(predicate: () => boolean | Promise<boolean>, label = "condition"): Promise<void> {
  const deadline = Date.now() + 10_000;
  while (!await predicate()) {
    if (Date.now() >= deadline) throw new Error(`${label} timed out`);
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

interface Client {
  frames: any[];
  request(id: string, method: string, params: object): Promise<any>;
}

interface Fixture {
  root: string;
  faux: ReturnType<typeof fauxProvider>;
  connect(): Promise<Client>;
  coldSession(label: string): Promise<{ id: string; file: string; entryId: string }>;
  snapshot(client: Client, sessionId: string): Promise<any>;
  openSession(client: Client, sessionId: string): Promise<any>;
}

async function fixture(options: { tokensPerSecond?: number } = {}): Promise<Fixture> {
  const root = await mkdtemp(join(tmpdir(), "tron-rpc-idle-"));
  const agentDir = join(root, "agent");
  const cwd = join(root, "project");
  const sessionDirectory = join(agentDir, "sessions", "workspace");
  await Promise.all([mkdir(sessionDirectory, { recursive: true }), mkdir(cwd, { recursive: true })]);
  const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
  process.env.PI_CODING_AGENT_DIR = agentDir;

  const faux = fauxProvider({ provider: "rpc-idle-fixture", tokensPerSecond: options.tokensPerSecond ?? 10_000 });
  faux.setResponses([fauxAssistantMessage("idle admission fixture response")]);
  const runtimeFactory = vi.fn(async () => {
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    return runtime;
  });
  const sockets: WebSocket[] = [];
  const devices = new DeviceStore(root, "fixture-machine");
  await devices.initialize();
  const invitation = await devices.ensureEnrollment();
  const paired = await devices.pair(invitation.code, "Fixture phone");
  await devices.ensureEnrollment();

  let server: GatewayServer | undefined;
  const registry = new RuntimeRegistry({
    agentDir,
    tronHome: root,
    idleRuntimeMs: 60_000,
    modelRuntimeFactory: runtimeFactory as never,
    trust: new TrustService(agentDir),
    broadcast: (sessionId: string, topic: string, payload: unknown) => {
      server?.broadcastSession(sessionId, topic, payload as never);
    },
    sessionSummaryChanged: () => {},
    sessionListChanged: () => { server?.notifySessionListChanged(); },
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

  cleanup.push(async () => {
    sockets.forEach((socket) => socket.terminate());
    await server?.close();
    await registry.dispose();
    if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
    await rm(root, { recursive: true, force: true });
  });

  const connect = async (): Promise<Client> => {
    const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${paired.token}` } });
    sockets.push(socket);
    const frames: any[] = [];
    socket.on("message", (raw) => frames.push(JSON.parse(raw.toString())));
    await until(() => socket.readyState === WebSocket.OPEN, "socket open");
    socket.send(JSON.stringify({ type: "hello", protocolVersion: 6 }));
    await until(() => frames.some((frame) => frame.type === "hello"), "hello");
    return {
      frames,
      request: async (id: string, method: string, params: object) => {
        socket.send(JSON.stringify({ type: "request", id, method, params }));
        await until(() => frames.some((frame) => frame.id === id), `response ${method}`);
        return frames.find((frame) => frame.id === id);
      },
    };
  };
  /** A canonical, persisted session with no live runtime, created the way the
   * pinned SDK creates one. The fixture writes the file itself, so it forces the
   * catalog owner's cut: a read that lands before the owner has indexed it
   * refuses retryably, and no reader walks the folder (G-1c). */
  const coldSession = async (label: string) => {
    const manager = SessionManager.create(cwd, sessionDirectory);
    manager.appendMessage(fauxAssistantMessage(`${label} canonical response`));
    const file = manager.getSessionFile()!;
    const entry = SessionManager.open(file).getBranch().at(-1) as { id?: string } | undefined;
    if (typeof entry?.id !== "string") throw new Error("fixture session has no canonical branch entry");
    const owner = (registry as unknown as {
      sessionCatalog: { reconcile(): Promise<void>; settled(): Promise<void> };
    }).sessionCatalog;
    await owner.reconcile();
    await owner.settled();
    return { id: manager.getSessionId(), file, entryId: entry.id };
  };
  /** Authoritative live snapshot: `revision` and `runtimeGeneration` are the
   * optimistic-concurrency inputs `session.setContextWindow` requires. */
  const snapshot = async (client: Client, sessionId: string) => {
    const opened = await client.request(`snapshot-${Math.random().toString(36).slice(2, 8)}`, "session.open", { sessionId });
    expect(opened.ok, JSON.stringify(opened)).toBe(true);
    return opened.result.session;
  };
  const openSession = async (client: Client, sessionId: string) => {
    const opened = await client.request(`open-${sessionId}`, "session.open", { sessionId });
    expect(opened.ok, JSON.stringify(opened)).toBe(true);
    const synced = await client.request(`sync-${sessionId}`, "session.sync", { sessionId, syncToken: opened.result.syncToken });
    expect(synced.ok, JSON.stringify(synced)).toBe(true);
    return opened.result.session;
  };
  return { root, faux, connect, coldSession, snapshot, openSession };
}

const list = async (client: Client) => {
  const response = await client.request(`list-${Math.random().toString(36).slice(2, 8)}`, "session.list", { scope: "user" });
  expect(response.ok, JSON.stringify(response)).toBe(true);
  return response.result as { sessions: Array<{ id: string; phase?: string }> };
};

describe("receipt-backed mutations against their own session work entry", () => {
  it("admits every idle-checked mutation on an idle session", async () => {
    const f = await fixture();
    const client = await f.connect();
    const session = await f.coldSession("idle-mutations");
    const opened = await f.openSession(client, session.id);

    const accepted: string[] = [];
    const step = async (method: string, params: Record<string, unknown>) => {
      const commandId = `${method.replace(/\./g, "-")}-command`;
      const response = await client.request(`rpc-${method}`, method, { commandId, sessionId: session.id, ...params });
      expect(response.ok, `${method}: ${JSON.stringify(response)}`).toBe(true);
      accepted.push(method);
      return response.result;
    };

    await step("session.setThinking", { level: (opened.availableThinkingLevels as string[])[0] });
    await step("session.setTools", { tools: [] });
    await step("session.label", { entryId: session.entryId, label: "idle admission" });
    const bash = await step("session.bash", { command: "echo rpc-idle-admission" });
    expect(JSON.stringify(bash)).toContain("rpc-idle-admission");
    await step("session.navigate", { entryId: session.entryId, summarize: false });
    await step("session.reloadResources", {});
    const current = await f.snapshot(client, session.id);
    expect(current.model, JSON.stringify(current)).toBeDefined();
    await step("session.setContextWindow", {
      provider: current.model.provider,
      modelId: current.model.id,
      contextWindow: null,
      expectedRevision: current.revision,
      expectedRuntimeGeneration: current.runtimeGeneration,
    });
    // Fork last: it rebinds the live runtime to a new session identity.
    const fork = await client.request("rpc-session-fork", "session.fork", {
      commandId: "session-fork-command", sessionId: session.id, entryId: session.entryId, position: "at",
    });
    expect(fork.ok, JSON.stringify(fork)).toBe(true);
    expect(fork.result.sessionId).not.toBe(session.id);
    accepted.push("session.fork");

    expect(accepted).toEqual([
      "session.setThinking",
      "session.setTools",
      "session.label",
      "session.bash",
      "session.navigate",
      "session.reloadResources",
      "session.setContextWindow",
      "session.fork",
    ]);
    record("admits every idle-checked mutation on an idle session", {
      accepted,
      forkChild: fork.result.sessionId as string,
    });
  });

  it("still rejects a mutation while the session is running or another mutation holds it", async () => {
    const f = await fixture({ tokensPerSecond: 4 });
    const client = await f.connect();
    const session = await f.coldSession("busy-session");
    await f.openSession(client, session.id);

    // A running prompt is not the caller's own entry, so idle admission must
    // still reject every idle-checked mutation.
    f.faux.setResponses([fauxAssistantMessage("slow response ".repeat(60))]);
    const prompt = client.request("busy-prompt", "session.prompt", {
      commandId: "busy-prompt-command", sessionId: session.id, text: "start a slow run",
    });
    await until(async () => (await list(client)).sessions.some((row) => row.id === session.id && row.phase === "running"), "running phase");

    const rejectedByRun: string[] = [];
    for (const [method, params] of [
      ["session.setTools", { tools: [] }],
      ["session.setThinking", { level: "off" }],
      ["session.label", { entryId: session.entryId, label: "blocked" }],
      ["session.reloadResources", {}],
    ] as Array<[string, Record<string, unknown>]>) {
      const response = await client.request(`blocked-${method}`, method, {
        commandId: `${method.replace(/\./g, "-")}-blocked-command`, sessionId: session.id, ...params,
      });
      expect(response, `${method}: ${JSON.stringify(response)}`).toMatchObject({ ok: false, error: { code: "busy" } });
      rejectedByRun.push(method);
    }
    await client.request("busy-abort", "session.abort", { commandId: "busy-abort-command", sessionId: session.id });
    expect((await prompt).ok, "prompt admitted").toBe(true);
    await until(async () => (await list(client)).sessions.some((row) => row.id === session.id && row.phase === "idle"), "settled after abort");

    // A concurrently admitted Bash RPC keeps the session unavailable: excluding
    // one request's own entry must not disable the check for another request.
    const bash = client.request("held-bash", "session.bash", {
      commandId: "held-bash-command", sessionId: session.id, command: "sleep 5", excludeFromContext: true,
    });
    await until(async () => (await list(client)).sessions.some((row) => row.id === session.id && row.phase === "running"), "bash running");
    const blocked = await client.request("held-set-tools", "session.setTools", {
      commandId: "held-set-tools-command", sessionId: session.id, tools: [],
    });
    expect(blocked, JSON.stringify(blocked)).toMatchObject({ ok: false, error: { code: "busy" } });
    await client.request("held-abort", "session.abort", { commandId: "held-abort-command", sessionId: session.id, kind: "bash" });
    await bash;

    record("still rejects a mutation while the session is running or another mutation holds it", {
      rejectedByRun,
      rejectedByConcurrentBash: "session.setTools",
    });
  });
});
