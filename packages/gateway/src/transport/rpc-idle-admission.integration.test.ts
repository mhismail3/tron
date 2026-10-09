import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { ModelRuntime, SessionManager } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import WebSocket from "ws";
import { afterAll, afterEach, describe, expect, it, vi } from "vitest";
import { AuthBroker } from "../admin/auth-broker.js";
import { TrustService } from "../admin/trust-service.js";
import { DeviceStore } from "../security/device-store.js";
import { RuntimeRegistry } from "../sessions/runtime-registry.js";
import { CommandReceiptStore } from "./command-receipts.js";
import { GatewayService } from "./gateway-service.js";
import { GatewayServer } from "./server.js";
import { waitFor } from "../../test-support/wait-for.js";

/** Retained, regenerable evidence for one run of this file. The path is stable
 * and gitignored, so an operator can inspect exactly which RPCs the session idle
 * admission admitted or rejected without committing one-off output. */
const REPORT_PATH = join(process.cwd(), "test-results", "rpc-idle-admission.integration.json");
const report: {
  generatedAt: string;
  processID: number;
  ports: number[];
  cases: Array<{ name: string; passed: boolean; evidence: Record<string, unknown> }>;
} = { generatedAt: new Date().toISOString(), processID: process.pid, ports: [], cases: [] };

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
  vi.unstubAllEnvs();
  const failures = results.filter((result) => result.status === "rejected");
  if (failures.length) throw new AggregateError(failures.map((result) => result.reason), "RPC idle fixture cleanup failed");
});

interface Client {
  frames: any[];
  request(id: string, method: string, params: object): Promise<any>;
}

interface Fixture {
  root: string;
  registry: RuntimeRegistry;
  faux: ReturnType<typeof fauxProvider>;
  port: number;
  logRecords: Array<{ level: string; message: string; metadata: Record<string, unknown> }>;
  connect(): Promise<Client>;
  coldSession(label: string): Promise<{ id: string; file: string; entryId: string }>;
  snapshot(client: Client, sessionId: string): Promise<any>;
  openSession(client: Client, sessionId: string): Promise<any>;
  retirementState(): string;
}

async function fixture(options: {
  tokensPerSecond?: number;
  authRuntime?: ModelRuntime;
  onStopRequested?: (registry: RuntimeRegistry) => void;
} = {}): Promise<Fixture> {
  const root = await mkdtemp(join(tmpdir(), "tron-rpc-idle-"));
  const agentDir = join(root, "agent");
  const cwd = join(root, "project");
  const sessionDirectory = join(agentDir, "sessions", "workspace");
  await Promise.all([mkdir(sessionDirectory, { recursive: true }), mkdir(cwd, { recursive: true })]);
  const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
  process.env.PI_CODING_AGENT_DIR = agentDir;

  const faux = fauxProvider({ provider: "rpc-idle-fixture", tokensPerSecond: options.tokensPerSecond ?? 10_000,
    models: [{ id: "model-a", reasoning: true }, { id: "model-b", reasoning: true }],
  });
  faux.setResponses([fauxAssistantMessage("idle admission fixture response")]);
  const runtimeFactory = vi.fn(async () => {
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    return runtime;
  });
  const sockets: WebSocket[] = [];
  const logRecords: Array<{ level: string; message: string; metadata: Record<string, unknown> }> = [];
  const devices = new DeviceStore(root, "fixture-machine");
  await devices.initialize();
  const invitation = await devices.ensureEnrollment();
  const paired = await devices.pair(invitation.code, "Fixture phone");
  await devices.ensureEnrollment();

  const diagnosticLogger = {
    log: (level: string, message: string, metadata: Record<string, unknown> = {}) => logRecords.push({ level, message, metadata }),
    recent: () => [],
    debugTail: () => [],
  };
  let server: GatewayServer | undefined;
  const registry = new RuntimeRegistry({
    agentDir,
    tronHome: root,
    idleRuntimeMs: 60_000,
    modelRuntimeFactory: runtimeFactory as never,
    trust: new TrustService(agentDir),
    stopSteeringDiagnostic: (diagnostic) => logRecords.push({
      level: diagnostic.outcome === "failed" ? "warning" : "info",
      message: `Stop continuation ${diagnostic.outcome}`,
      metadata: { event: "session.stop-steering-continuation", source: "session", ...diagnostic },
    }),
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
  const auth = options.authRuntime ? new AuthBroker(
    options.authRuntime,
    (clientId, topic, payload) => server?.emitToClient(clientId, topic, payload),
    (topic, payload) => server?.broadcast(topic, payload),
    { workRegistry: registry.administrativeWorkRegistry },
  ) : undefined;
  let retirement = "running";
  let retirementTask: Promise<void> | undefined;
  const service = new GatewayService({
    config: { tronHome: root },
    devices,
    sessions: registry,
    receipts: new CommandReceiptStore(root),
    uploads,
    terminals: { belongsToSession: () => false, beginRestartDrain: () => true, activeTerminalIds: () => [] },
    logger: diagnosticLogger,
    ...(options.authRuntime ? { modelRuntime: options.authRuntime } : {}),
    ...(auth ? { auth } : {}),
    workRegistry: registry.administrativeWorkRegistry,
    requestStop: () => {
      retirement = "draining";
      retirementTask = Promise.resolve().then(() => options.onStopRequested?.(registry)).then(
        () => { retirement = "drained"; },
        () => { retirement = "failed"; },
      );
    },
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
    logger: diagnosticLogger as never,
  });
  await server.listen();
  const port = (server as unknown as { server: { address(): { port: number } } }).server.address().port;
  report.ports.push(port);

  cleanup.push(async () => {
    sockets.forEach((socket) => socket.terminate());
    auth?.cancelWaitingForRestart();
    await retirementTask;
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
    await waitFor(() => socket.readyState === WebSocket.OPEN, "socket open");
    socket.send(JSON.stringify({ type: "hello", protocolVersion: 7 }));
    await waitFor(() => frames.some((frame) => frame.type === "hello"), "hello");
    return {
      frames,
      request: async (id: string, method: string, params: object) => {
        socket.send(JSON.stringify({ type: "request", id, method, params }));
        await waitFor(() => frames.some((frame) => frame.id === id), `response ${method}`);
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
    const synced = await client.request(`sync-${Math.random()}`, "session.sync", { sessionId, syncToken: opened.result.syncToken });
    expect(synced.ok, JSON.stringify(synced)).toBe(true);
    return opened.result.session;
  };
  const openSession = async (client: Client, sessionId: string) => {
    const opened = await client.request(`open-${sessionId}`, "session.open", { sessionId });
    expect(opened.ok, JSON.stringify(opened)).toBe(true);
    const synced = await client.request(`sync-${sessionId}`, "session.sync", { sessionId, syncToken: opened.result.syncToken });
    expect(synced.ok, JSON.stringify(synced)).toBe(true);
    return opened.result.session;
  };
  return { root, registry, faux, uploads, port, logRecords, connect, coldSession, snapshot, openSession,
    retirementState: () => retirement };
}

describe("diagnostic export RPC boundary", () => {
  it("records bounded authenticated ingress and completion without export content", async () => {
    const fixtureValue = await fixture();
    const client = await fixtureValue.connect();
    const requestID = "ad8d4b12-4392-467e-b7ef-39a8198e8b12";
    const privateContent = "synthetic-private-diagnostic-body";
    const response = await client.request(requestID, "system.logs.export", {
      commandId: "synthetic-command-identifier",
      content: privateContent,
    });
    expect(response.ok, JSON.stringify(response)).toBe(true);
    const records = fixtureValue.logRecords.filter(({ metadata }) => metadata.event === "rpc.received" || metadata.event === "rpc.completed");
    const ingressRecords = records.filter(({ metadata }) => metadata.event === "rpc.received");
    expect(ingressRecords).toHaveLength(1);
    expect(records).toEqual(expect.arrayContaining([
      expect.objectContaining({
        message: "Logs Export RPC admitted",
        metadata: expect.objectContaining({ event: "rpc.received", requestID, method: "system.logs.export", outcome: "admitted" }),
      }),
    ]));
    expect(records.some(({ metadata }) => metadata.event === "rpc.completed" && metadata.requestID === requestID && metadata.outcome === "success")).toBe(true);
    expect(JSON.stringify(records)).not.toContain(privateContent);
    expect(JSON.stringify(ingressRecords)).not.toContain("synthetic-command-identifier");
  });
});

const list = async (client: Client) => {
  const response = await client.request(`list-${Math.random().toString(36).slice(2, 8)}`, "session.list", { scope: "user" });
  expect(response.ok, JSON.stringify(response)).toBe(true);
  return response.result as { sessions: Array<{ id: string; phase?: string }> };
};

describe("receipt-backed mutations against their own session work entry", () => {
  it.each([1, 2])("continues once with %i queued steer(s) after Stop", async (steerCount) => {
    const f = await fixture();
    const client = await f.connect();
    const session = await f.coldSession("stop-with-queued-steering");
    await f.openSession(client, session.id);
    const beforeModel = await f.snapshot(client, session.id);
    const model = f.faux.models[0]!;
    const configured = await client.request("steer-model", "session.setModel", {
      sessionId: session.id, commandId: "steer-model", provider: model.provider, modelId: model.id,
      expectedRuntimeGeneration: beforeModel.runtimeGeneration, expectedModel: beforeModel.model ?? null,
    });
    expect(configured.ok, JSON.stringify(configured)).toBe(true);
    let providerStarted!: () => void;
    const started = new Promise<void>((resolve) => { providerStarted = resolve; });
    const continuationInputs: string[][] = [];
    const continuationImageCounts: number[] = [];
    f.uploads.materialize.mockImplementation(async (uploadIds: string[]) => ({
      envelope: uploadIds.length > 0 ? "[fixture image attached]" : "",
      images: uploadIds.length > 0 ? [{ type: "image", data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=", mimeType: "image/png" }] : [],
      attachments: uploadIds.map((id) => ({ id, name: "fixture.png", mimeType: "image/png", size: 5 })),
      photoCount: uploadIds.length,
      fileAttachmentCount: 0,
    }));
    const continuationResponse = async (context: any) => {
      const userParts = context.messages.filter((message: any) => message.role === "user")
        .flatMap((message: any) => Array.isArray(message.content) ? message.content : []);
      continuationInputs.push(userParts.map((part: any) => part.text ?? ""));
      continuationImageCounts.push(userParts.filter((part: any) => part.type === "image").length);
      return fauxAssistantMessage("continued after queued steering");
    };
    f.faux.setResponses([
      async () => {
        providerStarted();
        return fauxAssistantMessage(fauxToolCall("bash", { command: "sleep 30" }));
      },
      continuationResponse,
      continuationResponse,
    ]);
    const initial = await client.request("steer-start", "session.prompt", {
      sessionId: session.id, commandId: "steer-start", text: "hold the current run",
    });
    expect(initial.ok, JSON.stringify(initial)).toBe(true);
    await started;
    await waitFor(async () => (await f.snapshot(client, session.id)).toolExecutions.length === 1, "the running tool call");
    const first = await client.request("steer-one", "session.prompt", {
      sessionId: session.id, commandId: "steer-one", text: "first queued steer", behavior: "steer", uploadIds: ["fixture-image"],
    });
    const acceptedSteers = [first];
    if (steerCount === 2) acceptedSteers.push(await client.request("steer-two", "session.prompt", {
      sessionId: session.id, commandId: "steer-two", text: "second queued steer", behavior: "steer",
    }));
    expect(acceptedSteers.every((response) => response.ok)).toBe(true);
    const expectedTexts = steerCount === 1 ? ["first queued steer"] : ["first queued steer", "second queued steer"];
    const operationIDs = acceptedSteers.map((response) => response.result.operationId);
    const acceptedSteerFrameIndex = client.frames.length;
    const slotBeforeStop = await f.registry.acquire(session.id);
    const stopRecoveryPromptImages: number[] = [];
    const sdkSession = (slotBeforeStop as any).runtime.session;
    const originalSessionPrompt = sdkSession.prompt.bind(sdkSession);
    sdkSession.prompt = (text: string, options: any) => {
      if (text.startsWith("first queued steer")) stopRecoveryPromptImages.push(options.images?.length ?? 0);
      return originalSessionPrompt(text, options);
    };
    const queuedBeforeStop = (slotBeforeStop as any).queuedMessages.map((item: any) => ({ id: item.id, behavior: item.behavior, images: item.images?.length }));
    const activeBashOwners = {
      sdk: (slotBeforeStop as any).runtime.session.isBashRunning,
      direct: (slotBeforeStop as any).directBashProcesses?.hasActiveProcesses,
    };
    expect(queuedBeforeStop).toHaveLength(steerCount);
    const stopped = await client.request("steer-stop", "session.abort", {
      sessionId: session.id, commandId: "steer-stop",
    });
    expect(stopped.ok, JSON.stringify(stopped)).toBe(true);
    const slot = await f.registry.acquire(session.id);
    expect(f.logRecords).toContainEqual(expect.objectContaining({
      metadata: expect.objectContaining({
        event: "session.stop-steering-continuation", outcome: "started", queuedSteerCount: steerCount,
      }),
    }));
    try {
      await waitFor(() => client.frames.some((frame: any) => frame.topic === "session.snapshot"
        && frame.payload?.sessionId === session.id && frame.payload.phase === "idle"
        && frame.payload.queuedItems.length === 0
        && frame.payload.transcript.filter((item: any) => item.kind === "message" && item.role === "user"
          && item.content?.some((part: any) => expectedTexts.some((text) => part.text?.startsWith(text)))).length === steerCount),
      "the stopped prompt and queued steers consumed and idle");
    } catch (error) {
      const latest = client.frames.filter((frame: any) => frame.topic === "session.snapshot" && frame.payload?.sessionId === session.id).at(-1);
      throw new Error(`${String(error)}\n${JSON.stringify(latest?.payload)}`);
    }
    const stopSignals = f.logRecords.filter(({ metadata }) => metadata.event === "session.stop-steering-continuation");
    expect(stopSignals.map(({ metadata }) => metadata.outcome)).toEqual(["started", "completed"]);
    expect(JSON.stringify(stopSignals)).not.toContain("first queued steer");
    const users = slot.canonicalSessionEntries().filter((entry: any) => entry.type === "message" && entry.message.role === "user")
      .map((entry: any) => entry.message.content.map((part: any) => part.text ?? "").join(""));
    expect(users.filter((text: string) => text.includes("queued steer")).map((text: string) => text.split("\n")[0]))
      .toEqual(expectedTexts);
    const snapshots = client.frames.slice(acceptedSteerFrameIndex)
      .filter((frame: any) => frame.topic === "session.snapshot" && frame.payload?.sessionId === session.id)
      .map((frame: any) => frame.payload);
    for (const snapshot of snapshots) {
      const queuedIDs = new Set(snapshot.queuedItems.map((item: any) => item.id));
      const users = snapshot.transcript.filter((item: any) => item.role === "user");
      for (let index = 0; index < acceptedSteers.length; index += 1) {
        const matchingInputs = users.filter((item: any) => item.semantic?.operationId === operationIDs[index]
          || item.content?.some((part: any) => part.text?.startsWith(expectedTexts[index])));
        if (queuedIDs.has(operationIDs[index])) {
          expect(matchingInputs, `queued item ${operationIDs[index]} must not also be canonical`).toHaveLength(0);
        } else {
          expect(matchingInputs, `retired queue item ${operationIDs[index]} must be canonical exactly once`).toHaveLength(1);
        }
      }
    }
    const deliveredReceipts = slot.canonicalSessionEntries().filter((entry: any) => entry.customType === "tron.chat-invocation.v1"
      && operationIDs.includes(entry.data?.operationId));
    expect(deliveredReceipts.filter((entry: any) => entry.data?.receiptKind === "terminal"
      && entry.data?.lifecycle === "completed").map((entry: any) => entry.data.operationId).sort())
      .toEqual([...operationIDs].sort());
    expect(continuationInputs).toHaveLength(1);
    const providerSteers = continuationInputs[0]!.filter((input) => expectedTexts.some((text) => input.startsWith(text)))
      .map((input) => input.split("\n")[0]);
    expect(providerSteers).toEqual(expectedTexts);
    expect(stopRecoveryPromptImages).toEqual([1]);
    expect(continuationImageCounts).toEqual([1]);
    expect(f.faux.state.callCount).toBe(2);
    record(`Stop continues ${steerCount} accepted steer(s) exactly once`, { delivered: users.filter((text: string) => text.includes("queued steer")), providerCalls: f.faux.state.callCount });
  });
  it("holds a steer submitted during Stop outside Pi until the continuation admission", async () => {
    const f = await fixture();
    const client = await f.connect();
    const session = await f.coldSession("stop-steer-race");
    await f.openSession(client, session.id);
    const beforeModel = await f.snapshot(client, session.id);
    const model = f.faux.models[0]!;
    const configured = await client.request("race-model", "session.setModel", {
      sessionId: session.id, commandId: "race-model", provider: model.provider, modelId: model.id,
      expectedRuntimeGeneration: beforeModel.runtimeGeneration, expectedModel: beforeModel.model ?? null,
    });
    expect(configured.ok, JSON.stringify(configured)).toBe(true);
    let providerStarted!: () => void;
    const started = new Promise<void>((resolve) => { providerStarted = resolve; });
    const continuationInputs: string[][] = [];
    f.faux.setResponses([
      async () => {
        providerStarted();
        return fauxAssistantMessage(fauxToolCall("bash", { command: "sleep 30" }));
      },
      async (context: any) => {
        continuationInputs.push(context.messages.filter((message: any) => message.role === "user")
          .flatMap((message: any) => Array.isArray(message.content) ? message.content : [])
          .map((part: any) => part.text ?? ""));
        return fauxAssistantMessage("race continuation completed");
      },
    ]);
    expect((await client.request("race-start", "session.prompt", {
      sessionId: session.id, commandId: "race-start", text: "start before stop race",
    })).ok).toBe(true);
    await started;
    await waitFor(async () => (await f.snapshot(client, session.id)).toolExecutions.length === 1, "the running race tool");
    const first = await client.request("race-first", "session.prompt", {
      sessionId: session.id, commandId: "race-first", text: "steer before stop", behavior: "steer",
    });
    expect(first.ok, JSON.stringify(first)).toBe(true);
    const slot = await f.registry.acquire(session.id);
    const direct = (slot as any).directBashProcesses;
    const originalAbort = direct.abortAll.bind(direct);
    let abortStarted!: () => void;
    const abortIsRunning = new Promise<void>((resolve) => { abortStarted = resolve; });
    let releaseAbort!: () => void;
    const abortGate = new Promise<void>((resolve) => { releaseAbort = resolve; });
    direct.abortAll = async () => {
      const settlement = originalAbort();
      abortStarted();
      await abortGate;
      await settlement;
    };
    const stop = client.request("race-stop", "session.abort", {
      sessionId: session.id, commandId: "race-stop",
    });
    await abortIsRunning;
    expect((slot as any).runtime.session.getSteeringMessages()).toHaveLength(0);
    expect((slot as any).queuedMessages.map((item: any) => item.text)).toContain("steer before stop");
    const late = await client.request("race-late-steer", "session.prompt", {
      sessionId: session.id, commandId: "race-late-steer", text: "steer during stop", behavior: "steer",
    });
    expect(late.ok, JSON.stringify(late)).toBe(true);
    expect((slot as any).heldPrompts.some((item: any) => item.id === late.result.operationId)).toBe(true);
    releaseAbort();
    const stopped = await stop;
    expect(stopped.ok, JSON.stringify(stopped)).toBe(true);
    try {
      await waitFor(async () => {
        const snapshot = await f.snapshot(client, session.id);
        return snapshot.phase === "idle" && snapshot.queuedItems.length === 0
          && snapshot.transcript.filter((item: any) => item.role === "user"
            && ["steer before stop", "steer during stop"].some((text) => item.content?.some((part: any) => part.text?.startsWith(text)))).length === 2;
      }, "both stop-racing steers admitted and consumed once");
    } catch (error) {
      const snapshot = client.frames.filter((frame: any) => frame.topic === "session.snapshot" && frame.payload?.sessionId === session.id).at(-1)?.payload;
      throw new Error(`${String(error)}\n${JSON.stringify({snapshot, queued:(slot as any).queuedMessages, held:(slot as any).heldPrompts, recovery:[...(slot as any).stopSteeringRecoveryIDs], closed:(slot as any).stopRecoveryQueueClosed})}`);
    }
    expect(continuationInputs).toHaveLength(1);
    expect(continuationInputs[0]!.some((text) => text.startsWith("steer before stop"))).toBe(true);
    expect(continuationInputs[0]!.some((text) => text.startsWith("steer during stop"))).toBe(true);
    expect(f.faux.state.callCount).toBe(2);
  });
  it("does not replay steering after a second Stop during continuation", async () => {
    const f = await fixture({ tokensPerSecond: 3 });
    const client = await f.connect();
    const session = await f.coldSession("second-stop-continuation");
    await f.openSession(client, session.id);
    const beforeModel = await f.snapshot(client, session.id);
    const model = f.faux.models[0]!;
    const configured = await client.request("second-model", "session.setModel", {
      sessionId: session.id, commandId: "second-model", provider: model.provider, modelId: model.id,
      expectedRuntimeGeneration: beforeModel.runtimeGeneration, expectedModel: beforeModel.model ?? null,
    });
    expect(configured.ok, JSON.stringify(configured)).toBe(true);
    let providerStarted!: () => void;
    const started = new Promise<void>((resolve) => { providerStarted = resolve; });
    f.faux.setResponses([
      async () => {
        providerStarted();
        return fauxAssistantMessage(fauxToolCall("bash", { command: "sleep 30" }));
      },
      fauxAssistantMessage("continuation response that remains active ".repeat(80)),
    ]);
    expect((await client.request("second-start", "session.prompt", {
      sessionId: session.id, commandId: "second-start", text: "start second stop test",
    })).ok).toBe(true);
    await started;
    await waitFor(async () => (await f.snapshot(client, session.id)).toolExecutions.length === 1, "the second-stop tool");
    const accepted = await client.request("second-steer", "session.prompt", {
      sessionId: session.id, commandId: "second-steer", text: "only once after stop", behavior: "steer",
    });
    expect(accepted.ok, JSON.stringify(accepted)).toBe(true);
    expect((await client.request("second-stop-one", "session.abort", {
      sessionId: session.id, commandId: "second-stop-one",
    })).ok).toBe(true);
    await waitFor(async () => {
      const snapshot = await f.snapshot(client, session.id);
      return snapshot.phase === "running" && snapshot.transcript.some((item: any) => item.role === "user"
        && item.content?.some((part: any) => part.text?.startsWith("only once after stop")));
    }, "the continuation user input before second Stop");
    expect((await client.request("second-stop-two", "session.abort", {
      sessionId: session.id, commandId: "second-stop-two",
    })).ok).toBe(true);
    await waitFor(async () => (await f.snapshot(client, session.id)).phase === "idle", "second Stop settlement");
    const slot = await f.registry.acquire(session.id);
    const users = slot.canonicalSessionEntries().filter((entry: any) => entry.type === "message" && entry.message.role === "user")
      .flatMap((entry: any) => entry.message.content.map((part: any) => part.text ?? ""));
    expect(users.filter((text: string) => text.startsWith("only once after stop"))).toHaveLength(1);
    expect(f.faux.state.callCount).toBe(2);
  });
  it("publishes ready after real assistant completion without reopening the session", async () => {
    const f = await fixture();
    const client = await f.connect();
    const session = await f.coldSession("completion-readiness");
    await f.openSession(client, session.id);
    const start = client.frames.length;
    const prompted = await client.request("normal-completion", "session.prompt", {
      sessionId: session.id, commandId: "normal-completion", text: "Complete normally",
    });
    expect(prompted.ok).toBe(true);
    await waitFor(() => client.frames.slice(start).some(frame => frame.topic === "session.snapshot"
      && frame.payload.phase === "idle" && frame.payload.transcript.some((item: any) => item.role === "assistant")), "completed assistant snapshot");
    const settledIndex = client.frames.findLastIndex(frame => frame.topic === "session.snapshot" && frame.payload.phase === "idle");
    await waitFor(() => client.frames.slice(settledIndex + 1).some(frame => frame.topic === "session.configuration"
      && frame.payload.data.configurationBlocker === null), "normal completion ready event");
    record("normal assistant retirement publishes readiness", { readyWithoutReopen: true });
  });
  it("changes all parent configuration immediately after Stop while independent child work remains", async () => {
    const f = await fixture({ tokensPerSecond: 4 });
    const client = await f.connect();
    const session = await f.coldSession("post-stop-configuration");
    await f.openSession(client, session.id);
    f.faux.setResponses([fauxAssistantMessage("slow response ".repeat(60))]);
    const prompt = await client.request("configuration-prompt", "session.prompt", {
      commandId: "configuration-prompt", sessionId: session.id, text: "Start a slow run",
    });
    expect(prompt.ok).toBe(true);
    await waitFor(async () => (await f.snapshot(client, session.id)).phase === "running", "the running phase reported by the snapshot");
    const stopped = await client.request("configuration-stop", "session.abort", {
      commandId: "configuration-stop", sessionId: session.id,
    });
    expect(stopped.ok, JSON.stringify(stopped)).toBe(true);
    const stoppedSnapshot = await f.snapshot(client, session.id);
    expect(stoppedSnapshot.phase).toBe("idle");
    expect(f.faux.state.callCount).toBe(1);
    const slot = await f.registry.acquire(session.id);
    // Installed extension lifecycle is independent authority. Inject only its
    // admitted artifact, not the configuration admission or RPC under test.
    const activities = (slot as any).extensionActivities as Map<string, unknown>;
    const now = new Date().toISOString();
    activities.set("independent-child", {
      id: "independent-child", activityId: "independent-child", runId: "independent-child", toolCallId: "independent-child",
      source: { source: "pi-subagents" }, title: "Subagent", mode: "asynchronous", status: "running",
      startedAt: now, updatedAt: now, children: [],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: now },
    });
    const accepted: string[] = [];
    try {
      expect(slot.isDrainBusy).toBe(true);
      for (const method of ["session.setModel", "session.setThinking", "session.setContextWindow"]) {
        const before = await f.snapshot(client, session.id);
        const nextModel = method === "session.setModel" ? f.faux.models.find(model => model.id !== before.model.id)! : before.model;
        const nextThinking = before.availableThinkingLevels.find((level: string) => level !== before.thinkingLevel)!;
        const response = await client.request(method, method, {
          sessionId: session.id, commandId: method,
          expectedRuntimeGeneration: before.runtimeGeneration, expectedModel: before.model ?? null,
          provider: nextModel.provider, modelId: nextModel.id,
          level: nextThinking, contextWindow: 64_000, expectedRevision: before.revision,
        });
        expect(response.ok, `${method}: ${JSON.stringify(response)}`).toBe(true);
        accepted.push(method);
        const after = await f.snapshot(client, session.id);
        expect(response.result.revision).toBe(after.revision);
        expect(after.model).toEqual({ provider: nextModel.provider, id: nextModel.id });
        if (method === "session.setModel") expect(after.model).not.toEqual(before.model);
        if (method === "session.setThinking") {
          expect(after.thinkingLevel).toBe(nextThinking);
          expect(after.thinkingLevel).not.toBe(before.thinkingLevel);
        }
        if (method === "session.setContextWindow") expect(after.contextWindowPolicy).toMatchObject({ effective: 64_000, override: 64_000, source: "session" });
      }
      expect((await f.snapshot(client, session.id)).configurationBlocker).toBeNull();
      expect(slot.isDrainBusy).toBe(true);
      const deleted = await client.request("delete-with-child", "session.delete", {sessionId: session.id, commandId: "delete-with-child"});
      expect(deleted).toMatchObject({ok: false, error: {code: "busy"}});
      record("post-Stop configuration with independent child", { accepted, deletionRejected: true });
    } finally { activities.delete("independent-child"); }
  });

  it("publishes configuration settlement without changing context revision and fences stale model intent", async () => {
    const f = await fixture();
    const client = await f.connect();
    const session = await f.coldSession("configuration-settlement");
    const before = await f.openSession(client, session.id);
    const work = f.registry.administrativeWorkRegistry.begin({kind: "terminal-receipt-persistence", sessionId: session.id, hostEpoch: "fixture"});
    let settlementFrameCut = 0;
    try {
      await waitFor(() => client.frames.some(frame => frame.topic === "session.configuration" && frame.payload?.data?.configurationBlocker === "settling"), "settling publication");
      const busy = await f.snapshot(client, session.id);
      expect(busy.configurationBlocker).toBe("settling");
      const rejected = await client.request("settling-thinking", "session.setThinking", {
        sessionId: session.id, commandId: "settling-thinking", level: "off",
        expectedRuntimeGeneration: before.runtimeGeneration, expectedModel: before.model ?? null,
      });
      expect(rejected).toMatchObject({ok: false, error: {code: "busy", details: {configurationBlocker: "settling"}}});
      expect(f.logRecords.some(record => record.metadata.event === "rpc.error" && record.metadata.reason === "session_configuration_settling")).toBe(true);
      settlementFrameCut = client.frames.length;
    } finally { work.settle(); }
    // No session.open/snapshot RPC may rescue a missing retirement event.
    await waitFor(() => client.frames.slice(settlementFrameCut).some(frame => frame.topic === "session.configuration" && frame.payload?.data?.configurationBlocker === null), "ready publication after terminal retirement");
    const ready = await f.snapshot(client, session.id);
    expect(ready.revision).toBe(before.revision);
    const stale = await client.request("stale-thinking", "session.setThinking", {
      sessionId: session.id, commandId: "stale-thinking", level: "off",
      expectedRuntimeGeneration: "retired-runtime", expectedModel: before.model ?? null,
    });
    expect(stale).toMatchObject({ok: false, error: {code: "conflict"}});
    const wrongModel = await client.request("wrong-model-thinking", "session.setThinking", {
      sessionId: session.id, commandId: "wrong-model-thinking", level: "off",
      expectedRuntimeGeneration: before.runtimeGeneration, expectedModel: {provider: "retired-provider", id: "retired-model"},
    });
    expect(wrongModel).toMatchObject({ok: false, error: {code: "conflict"}});
    const competing = f.registry.administrativeWorkRegistry.begin({kind: "rpc-mutation", sessionId: session.id, hostEpoch: "fixture"});
    try {
      for (const method of ["session.setModel", "session.setThinking", "session.setContextWindow"]) {
        const response = await client.request(`competing-${method}`, method, {
          sessionId: session.id, commandId: `competing-${method}`, level: "off",
          provider: before.model.provider, modelId: before.model.id, contextWindow: null, expectedRevision: before.revision,
          expectedRuntimeGeneration: before.runtimeGeneration, expectedModel: before.model ?? null,
        });
        expect(response).toMatchObject({ok: false, error: {code: "busy", details: {configurationBlocker: "mutation"}}});
      }
    } finally { competing.settle(); }
    const context = await client.request("ready-context", "session.setContextWindow", {
      sessionId: session.id, commandId: "ready-context", provider: before.model.provider, modelId: before.model.id,
      expectedRuntimeGeneration: before.runtimeGeneration, expectedRevision: before.revision, contextWindow: null,
    });
    expect(context.ok, JSON.stringify(context)).toBe(true);
    record("configuration settlement and original intent", { revisionPreserved: true, staleIntentRejected: true, contextAccepted: true });
  });

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

    await step("session.setThinking", { level: (opened.availableThinkingLevels as string[])[0], expectedRuntimeGeneration: opened.runtimeGeneration, expectedModel: opened.model ?? null });
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
    const opened = await f.openSession(client, session.id);

    // A running prompt is not the caller's own entry, so idle admission must
    // still reject every idle-checked mutation.
    f.faux.setResponses([fauxAssistantMessage("slow response ".repeat(60))]);
    const prompt = client.request("busy-prompt", "session.prompt", {
      commandId: "busy-prompt-command", sessionId: session.id, text: "start a slow run",
    });
    await waitFor(async () => (await list(client)).sessions.some((row) => row.id === session.id && row.phase === "running"), "running phase");

    const rejectedByRun: string[] = [];
    for (const [method, params] of [
      ["session.setTools", { tools: [] }],
      ["session.setThinking", { level: "off", expectedRuntimeGeneration: opened.runtimeGeneration, expectedModel: opened.model ?? null }],
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
    await waitFor(async () => (await list(client)).sessions.some((row) => row.id === session.id && row.phase === "idle"), "settled after abort");

    // A concurrently admitted Bash RPC keeps the session unavailable: excluding
    // one request's own entry must not disable the check for another request.
    const bash = client.request("held-bash", "session.bash", {
      commandId: "held-bash-command", sessionId: session.id, command: "sleep 5", excludeFromContext: true,
    });
    await waitFor(async () => (await list(client)).sessions.some((row) => row.id === session.id && row.phase === "running"), "bash running");
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

describe("authenticated intentional stop preserves accepted provider login", () => {
  it("replays the accepted stop receipt while provider login keeps the drain waiting", async () => {
    vi.stubEnv("TRON_GATEWAY_SUPERVISED", "1");
    let completedCredential = "";
    const authRuntime = {
      getProvider: () => ({ auth: { apiKey: { login: async () => "" } } }),
      login: async (_providerId: string, _authType: string, interaction: { prompt(input: { type: "secret"; message: string }): Promise<string> }) => {
        completedCredential = await interaction.prompt({ type: "secret", message: "Fixture-only replay credential" });
      },
    } as unknown as ModelRuntime;
    let retirementAttempts = 0;
    const f = await fixture({ authRuntime, onStopRequested: (registry) => {
      retirementAttempts += 1;
      return registry.waitUntilIdle();
    } });
    const client = await f.connect();
    const login = await client.request("replay-login-begin", "auth.begin", {
      commandId: "replay-login-command", providerId: "rpc-idle-fixture", authType: "api_key",
    });
    expect(login.ok, JSON.stringify(login)).toBe(true);
    const prompt = await waitFor(() => client.frames.find(frame => frame.topic === "auth.prompt"), "held provider login prompt");
    const first = await client.request("replay-stop-first", "gateway.stop", { commandId: "pending-stop-command" });
    expect(first.ok, JSON.stringify(first)).toBe(true);
    await waitFor(() => f.registry.administrativeDrainSnapshot().phase === "waiting", "accepted stop to wait on provider login");
    expect(f.registry.administrativeDrainSnapshot().blockerCounts["provider-login"]).toBe(1);
    const replay = await client.request("replay-stop-same-command", "gateway.stop", { commandId: "pending-stop-command" });
    expect(replay.ok, JSON.stringify(replay)).toBe(true);
    expect(replay.result).toEqual(first.result);
    expect(retirementAttempts).toBe(1);
    const answer = await client.request("replay-login-answer", "auth.respond", {
      operationId: login.result.operationId, promptId: prompt.payload.promptId, value: "synthetic-replay-fixture-key",
    });
    expect(answer.ok, JSON.stringify(answer)).toBe(true);
    await waitFor(() => f.retirementState() === "drained", "the one accepted retirement to drain");
    expect(completedCredential).toBe("synthetic-replay-fixture-key");
    expect(f.registry.administrativeDrainSnapshot()).toMatchObject({ phase: "complete", blockerCount: 0 });
    record("accepted stop receipt replays while provider login blocks the drain", {
      pid: process.pid, port: f.port, retirementAttempts, identicalAcknowledgement: true,
      finalDrainPhase: f.registry.administrativeDrainSnapshot().phase,
    });
  });

  it("keeps accepted auth work through stop failure, refuses new work, and completes only after explicit retry", async () => {
    vi.stubEnv("TRON_GATEWAY_SUPERVISED", "1");
    let completedCredential = "";
    const authRuntime = {
      getProvider: () => ({ auth: { apiKey: { login: async () => "" } } }),
      login: async (_providerId: string, _authType: string, interaction: { prompt(input: { type: "secret"; message: string }): Promise<string> }) => {
        completedCredential = await interaction.prompt({ type: "secret", message: "Fixture-only credential" });
      },
    } as unknown as ModelRuntime;
    let retirementAttempts = 0;
    const f = await fixture({
      authRuntime,
      onStopRequested: (registry) => {
        retirementAttempts += 1;
        if (retirementAttempts === 1) {
          registry.failAdministrativeDrain();
          throw new Error("fixture process-owner proof failure");
        }
        return registry.waitUntilIdle();
      },
    });
    const client = await f.connect();
    const authStarted = await client.request("accepted-login-begin", "auth.begin", {
      commandId: "accepted-login-command", providerId: "rpc-idle-fixture", authType: "api_key",
    });
    expect(authStarted.ok, JSON.stringify(authStarted)).toBe(true);
    const promptFrame = await waitFor(() => client.frames.find(frame => frame.topic === "auth.prompt"), "accepted provider login prompt");
    const acceptedWork = f.registry.administrativeWorkRegistry.facts();
    expect(acceptedWork.some(fact => fact.kind === "provider-login"), JSON.stringify(acceptedWork)).toBe(true);

    const stop = await client.request("intentional-stop", "gateway.stop", { commandId: "intentional-stop-command" });
    expect(stop.ok, JSON.stringify(stop)).toBe(true);
    expect(stop.result).toMatchObject({ scheduled: true, stopping: false });
    await waitFor(() => f.retirementState() === "failed", "failed intentional-stop retirement proof");
    const duringFailure = await client.request("drain-snapshot-before-login-answer", "gateway.drain.status", {});
    expect(duringFailure.ok, JSON.stringify(duringFailure)).toBe(true);
    expect(duringFailure.result.phase).toBe("failed");
    expect(duringFailure.result.blockerCounts["provider-login"], JSON.stringify(duringFailure.result)).toBe(1);

    const lateLogin = await client.request("late-login-during-stop", "auth.begin", {
      commandId: "late-login-command", providerId: "rpc-idle-fixture", authType: "api_key",
    });
    expect(lateLogin).toMatchObject({ ok: false, error: { code: "busy" } });

    const answer = await client.request("complete-accepted-login", "auth.respond", {
      operationId: authStarted.result.operationId,
      promptId: promptFrame.payload.promptId,
      value: "synthetic-stop-fixture-key",
    });
    expect(answer).toMatchObject({ ok: true, result: { answered: true } });
    await waitFor(() => completedCredential === "synthetic-stop-fixture-key", "accepted provider login completion");
    expect(f.retirementState()).toBe("failed");

    const retry = await client.request("intentional-stop-retry", "gateway.stop", { commandId: "intentional-stop-retry-command" });
    expect(retry).toMatchObject({ ok: true, result: { scheduled: true } });
    await waitFor(() => f.retirementState() === "drained", "explicit stop recovery retirement completion");
    const afterDrain = await client.request("drain-snapshot-after-login", "gateway.drain.status", {});
    expect(afterDrain).toMatchObject({ ok: true, result: { phase: "complete", blockerCount: 0 } });
    record("intentional stop preserves accepted provider login through failure and explicit retry", {
      pid: process.pid,
      port: f.port,
      providerLoginBlockerAtFailedStop: duringFailure.result.blockerCounts["provider-login"],
      failedStopPhase: duringFailure.result.phase,
      loginCompleted: completedCredential === "synthetic-stop-fixture-key",
      retirementAfterExplicitRetry: f.retirementState(),
      finalDrainPhase: afterDrain.result.phase,
      finalBlockerCount: afterDrain.result.blockerCount,
      retirementAttempts,
    });
  });
});
