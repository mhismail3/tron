import { mkdir, mkdtemp, readFile, readdir, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";
import WebSocket from "ws";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import {
  fauxAssistantMessage, fauxProvider, getCurrentSystemPrompt, getCurrentTools,
  type AssistantMessage, type SimpleStreamOptions, type TranscriptContext,
} from "@earendil-works/pi-ai";
import { TrustService } from "../src/admin/trust-service.js";
import { SettingsChangePath, SettingsModel } from "../src/admin/settings-model.js";
import { SettingsChangeRecord } from "../src/admin/settings-record.js";
import { SettingsApprovals } from "../src/admin/settings-approvals.js";
import { OutsideChanges } from "../src/admin/settings-outside.js";
import { MacTerminalKeys } from "../src/security/mac-terminal.js";
import { DeviceStore } from "../src/security/device-store.js";
import { UploadStore } from "../src/machine/upload-store.js";
import { RuntimeRegistry } from "../src/sessions/runtime-registry.js";
import { CommandReceiptStore } from "../src/transport/command-receipts.js";
import { GatewayService, type GatewayServiceDependencies } from "../src/transport/gateway-service.js";
import { GatewayServer } from "../src/transport/server.js";
import {
  clientEventTrace, eventShapePaths, hashPromptText, normalizeTraceValue, promptSectionHeadings,
  type TraceNormalization, type TraceValue,
} from "./scenario-lock.js";
import { waitFor } from "./wait-for.js";

/**
 * One real Gateway for a kernel scenario lock (restructure plan §6.4): the
 * production `RuntimeRegistry`, `GatewayService` and `GatewayServer` on a
 * loopback WebSocket with a paired device, the settings model and its change
 * path, and the faux provider as the only scripted party. Nothing inside the
 * kernel is replaced. The boundaries a scenario does not cross (uploads, PTY
 * terminals, provider auth) get inert owners that throw if a scenario reaches
 * them, so a lock can never pass through a fake.
 *
 * The harness records what the plan's V3 lock compares:
 * - every request a client makes, with its normalized response values;
 * - every client-visible event topic with the union of its payload structure
 *   (in-flight subtrees pruned, as the SDK boundary trace does);
 * - each provider request's tools, prompt sections, prompt hash and messages;
 * - canonical JSONL, and files under the stores a lock names;
 * - notifications enqueued at the relay boundary.
 */

type Step = (context: TranscriptContext, options: SimpleStreamOptions | undefined) => AssistantMessage | Promise<AssistantMessage>;

export interface LockGatewayOptions {
  /** Extension sources written to `<agentDir>/extensions/<name>`. */
  readonly extensions?: ReadonlyArray<{ name: string; source: string }>;
  /** Extra `settings.json` keys; the default model is always the faux model. */
  readonly settings?: Record<string, unknown>;
}

export interface ProviderRequestRecord {
  readonly tools: readonly string[];
  readonly promptSections: readonly string[];
  readonly promptHash: string;
  /** Each message after the system prompt: role, text and tool calls, normalized. */
  readonly messages: readonly TraceValue[];
}

export interface LockClient {
  /** Send one request and wait for its response frame; the exchange is recorded. */
  request(method: string, params: Record<string, unknown>): Promise<{ ok: boolean; result?: any; error?: any }>;
  /** Send without waiting; await the returned promise for the response. */
  send(method: string, params: Record<string, unknown>): Promise<{ ok: boolean; result?: any; error?: any }>;
  /** Every event frame this connection received, in arrival order. */
  readonly events: ReadonlyArray<{ topic: string; sessionId?: string; payload: unknown }>;
  close(): Promise<void>;
}

export interface LockGateway {
  readonly root: string;
  readonly agentDir: string;
  readonly tronHome: string;
  readonly cwd: string;
  readonly registry: RuntimeRegistry;
  readonly normalization: TraceNormalization;
  /** Script the provider: each step answers one request and is recorded. */
  script(steps: readonly Step[]): void;
  connect(label: string): Promise<LockClient>;
  /** A deterministic command id, unique within the lock. */
  commandId(): string;
  /** Wait until the session's run, queue and maintenance have settled. */
  settled(sessionId: string): Promise<void>;
  canonical(sessionId: string): Promise<TraceValue[]>;
  /** A normalized JSON file under the Gateway's roots, or `null` if absent. */
  file(path: string): Promise<TraceValue>;
  /** Relative paths of every file below a directory, sorted. */
  tree(path: string): Promise<string[]>;
  readonly notifications: ReadonlyArray<TraceValue>;
  /** The recorded client and provider facts, normalized. */
  record(): { exchanges: TraceValue[]; events: TraceValue[]; providerRequests: ProviderRequestRecord[] };
  dispose(): Promise<void>;
}

/** An owner the scenario must never reach: reaching it fails the lock loudly. */
function unreachable(name: string): unknown {
  return new Proxy({}, { get: (_target, property) => {
    if (property === "then") return undefined;
    throw new Error(`Lock scenario reached the ${name} owner (${String(property)}), which this harness does not provide`);
  } });
}

function textOf(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.map((part) => part !== null && typeof part === "object" && (part as { type?: unknown }).type === "text"
    ? String((part as { text?: unknown }).text ?? "") : "").join("");
}

function messageRecord(message: unknown, normalization: TraceNormalization): TraceValue {
  const entry = (message ?? {}) as { role?: unknown; content?: unknown; toolName?: unknown };
  const calls = Array.isArray(entry.content)
    ? entry.content.flatMap((part) => part !== null && typeof part === "object" && (part as { type?: unknown }).type === "toolCall"
      ? [String((part as { name?: unknown }).name)] : [])
    : [];
  return normalizeTraceValue({
    role: entry.role ?? null,
    text: textOf(entry.content),
    ...(calls.length ? { toolCalls: calls } : {}),
    ...(typeof entry.toolName === "string" ? { toolName: entry.toolName } : {}),
  }, normalization);
}

export async function startLockGateway(name: string, options: LockGatewayOptions = {}): Promise<LockGateway> {
  const root = await mkdtemp(join(tmpdir(), `tron-lock-${name}-`));
  const tronHome = join(root, "tron");
  const agentDir = join(tronHome, "agent");
  const cwd = join(root, "workspace");
  await Promise.all([mkdir(agentDir, { recursive: true }), mkdir(cwd, { recursive: true })]);
  await writeFile(join(cwd, "notes.txt"), "lock notes\n");
  const normalization: TraceNormalization = { roots: [root, await realpath(root)] };

  const faux = fauxProvider({ provider: `tron-lock-${name}`, tokensPerSecond: 10_000, tokenSize: { min: 4, max: 4 } });
  const model = faux.getModel();
  if (options.extensions?.length) {
    await mkdir(join(agentDir, "extensions"), { recursive: true });
    for (const extension of options.extensions) await writeFile(join(agentDir, "extensions", extension.name), extension.source);
  }
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({
    sessionDir: join(root, "sessions"), defaultProvider: model.provider, defaultModel: model.id,
    compaction: { enabled: false, reserveTokens: 2_048, keepRecentTokens: 120 },
    ...options.settings,
  }));
  const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
  process.env.PI_CODING_AGENT_DIR = agentDir;

  const providerRequests: ProviderRequestRecord[] = [];
  const record = (context: TranscriptContext): void => {
    const prompt = getCurrentSystemPrompt(context.messages);
    providerRequests.push({
      tools: getCurrentTools(context.messages).map((tool) => tool.name),
      promptSections: promptSectionHeadings(prompt),
      promptHash: hashPromptText(prompt, normalization),
      messages: context.messages.filter((message) => (message as { role?: unknown }).role !== "system")
        .map((message) => messageRecord(message, normalization)),
    });
  };
  const runtimeFactory = async (): Promise<ModelRuntime> => {
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    return runtime;
  };
  const modelRuntime = await runtimeFactory();
  const trust = new TrustService(agentDir);
  await trust.set(cwd, true);

  const devices = new DeviceStore(tronHome, "lock-machine");
  await devices.initialize();
  const paired = await devices.pair((await devices.ensureEnrollment()).code, "Lock phone");
  await devices.ensureEnrollment();

  let server: GatewayServer | undefined;
  const registry = new RuntimeRegistry({
    agentDir, tronHome, idleRuntimeMs: 60_000, modelRuntimeFactory: runtimeFactory, trust,
    // Mirrors gateway-main: slot events reach subscribed sockets.
    broadcast: (sessionId, topic, payload) => server?.broadcastSession(sessionId, topic, payload as never),
    sessionSummaryChanged: () => {},
    sessionListChanged: () => server?.notifySessionListChanged(),
    sessionRekeyed: (previous, next) => server?.rekeySession(previous, next),
  });
  await registry.initialize();
  await (registry as unknown as { sessionCatalog: { whenPublished(): Promise<void> } }).sessionCatalog.whenPublished();

  // Production settings wiring (gateway-main.ts): every read reconciles outside changes.
  const settingsModel = new SettingsModel({ agentDir, tronHome, trust, modelRuntime, macTerminalKeys: new MacTerminalKeys(join(root, "home", ".ssh")) });
  const settingsRecord = new SettingsChangeRecord(tronHome);
  const outside = new OutsideChanges(tronHome, agentDir, settingsRecord, settingsModel.observedReaders);
  settingsModel.observeOutside(outside);
  const settingsChanges = new SettingsChangePath(settingsModel, settingsRecord, new SettingsApprovals(tronHome), {
    setTrust: async (project, decision) => trust.setAndApply(project, decision,
      async (inspection) => { await registry.reloadProject(inspection.projectDir, inspection.effectiveDecision === true, false); },
      async (inspection) => { await registry.commitProjectReload(inspection.projectDir); }),
  }, agentDir);
  registry.setSettings(settingsModel, settingsChanges);

  // The relay boundary: what would be pushed to the maintainer's iPhone.
  const notifications: TraceValue[] = [];
  const receipts = new CommandReceiptStore(tronHome);
  // The real upload owner: a prompt materializes its (empty) attachment list through it.
  const uploads = new UploadStore(tronHome, 1_048_576);
  const service = new GatewayService({
    config: { machineId: "lock-machine", machineGroupID: "lock-group", machineName: "Lock Mac", tronHome, agentDir },
    modelRuntime, devices, sessions: registry, trust, settingsModel, settingsChanges, receipts,
    notifications: { enqueue: async (push: unknown) => { notifications.push(normalizeTraceValue(push, normalization)); } },
    broadcast: (topic: string, payload: unknown) => server?.broadcast(topic, payload as never),
    globalProviderResources: { withStableSnapshot: async (operation: () => Promise<unknown>) => operation(), requestReload: () => {} },
    logger: { log: () => {} },
    sessionDeleted: (sessionId: string) => server?.revokeSessionTerminals(sessionId),
    requestRestart: () => { throw new Error("Lock scenario requested a restart"); },
    requestStop: () => { throw new Error("Lock scenario requested a stop"); },
    uploads, terminals: { belongsToSession: () => false },
    filesystem: unreachable("filesystem"), modelConfig: unreachable("modelConfig"), packages: unreachable("packages"),
    hookResources: unreachable("hookResources"), auth: unreachable("auth"),
  } as unknown as GatewayServiceDependencies);
  server = new GatewayServer({
    host: "127.0.0.1", port: 0, maxFrameBytes: 1_048_576, devices, sessions: registry, service,
    uploads,
    auth: { cancelOwner: () => {}, detachClient: () => {} } as never,
    logger: { log: () => {} } as never,
  });
  await server.listen();
  const port = (server as unknown as { server: { address(): { port: number } } }).server.address().port;

  const exchanges: Array<{ client: string; method: string; params: unknown; response: unknown }> = [];
  const events: Array<{ topic: string; paths: readonly string[] }> = [];
  const sockets: WebSocket[] = [];
  let commandCounter = 0;
  let frameCounter = 0;

  const gateway: LockGateway = {
    root, agentDir, tronHome, cwd, registry, normalization, notifications,
    script(steps) {
      // An unscripted request is itself a delta: it is recorded rather than crashing
      // the run, and the repeated tail keeps later requests from desynchronizing.
      faux.setResponses([
        ...steps.map((step): Step => async (context, requestOptions) => { record(context); return step(context, requestOptions); }),
        ...Array.from({ length: 8 }, (): Step => (context) => {
          record(context);
          return fauxAssistantMessage("Unscripted lock response.");
        }),
      ]);
    },
    async connect(label) {
      const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${paired.token}` } });
      sockets.push(socket);
      const frames: any[] = [];
      const received: Array<{ topic: string; sessionId?: string; payload: unknown }> = [];
      socket.on("message", (raw) => {
        const frame = JSON.parse(raw.toString());
        frames.push(frame);
        if (frame.type === "event") {
          received.push({ topic: frame.topic, sessionId: frame.sessionId, payload: frame.payload });
          events.push({ topic: frame.topic, paths: eventShapePaths(frame.topic, frame.payload) });
        }
      });
      await waitFor(() => socket.readyState === WebSocket.OPEN, `the ${label} socket to open`);
      socket.send(JSON.stringify({ type: "hello", protocolVersion: 8 }));
      await waitFor(() => frames.some((frame) => frame.type === "hello"), `the ${label} hello`);
      const send = (method: string, params: Record<string, unknown>) => {
        const id = `${label}-${String(++frameCounter).padStart(3, "0")}`;
        const entry = { client: label, method, params: normalizeTraceValue(params, normalization), response: null as unknown };
        exchanges.push(entry);
        socket.send(JSON.stringify({ type: "request", id, method, params }));
        return waitFor(() => frames.find((frame) => frame.type === "response" && frame.id === id), `the ${method} response`)
          .then((frame) => {
            entry.response = normalizeTraceValue({ ok: frame.ok, result: frame.result ?? null, error: frame.error ?? null }, normalization);
            return frame as { ok: boolean; result?: any; error?: any };
          });
      };
      return {
        send,
        request: send,
        events: received,
        close: async () => {
          if (socket.readyState === WebSocket.CLOSED) return;
          await new Promise<void>((resolve) => { socket.once("close", () => resolve()); socket.close(); });
        },
      };
    },
    commandId: () => `lock-command-${String(++commandCounter).padStart(4, "0")}`,
    async settled(sessionId) {
      const slot = await registry.acquire(sessionId);
      // Admission installs the operation before its response is sent, so "no
      // operation and not busy" after an admitted request is a settled run, never
      // a run that has not started yet.
      await waitFor(() => !slot.isBusy && !slot.snapshot().operation, `session ${sessionId} to settle`);
    },
    async canonical(sessionId) {
      const slot = await registry.acquire(sessionId);
      return (await readFile(slot.sessionFile!, "utf8")).trimEnd().split("\n")
        .map((line) => normalizeTraceValue(JSON.parse(line), normalization));
    },
    async file(path) {
      const text = await readFile(path, "utf8").catch(() => undefined);
      return text === undefined ? null : normalizeTraceValue(JSON.parse(text), normalization);
    },
    async tree(path) {
      const entries = await readdir(path, { recursive: true, withFileTypes: true }).catch(() => []);
      return entries.filter((entry) => entry.isFile())
        .map((entry) => normalizeTraceValue(relative(path, join(entry.parentPath, entry.name)), normalization) as string)
        .sort();
    },
    // Events are read after the caller's last response: each socket's frames are
    // ordered, so every broadcast the Gateway emitted before answering it is here.
    record() {
      const sorted = clientEventTrace(events).sort((left, right) => left.topic.localeCompare(right.topic));
      return {
        exchanges: exchanges.map((entry) => normalizeTraceValue(entry, normalization)),
        events: sorted.map((entry) => ({ topic: entry.topic, paths: [...entry.paths] })),
        providerRequests: [...providerRequests],
      };
    },
    async dispose() {
      for (const socket of sockets) socket.terminate();
      await server?.close();
      await registry.dispose().catch(() => {});
      await receipts.dispose();
      await outside.dispose();
      if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
      else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
      await rm(root, { recursive: true, force: true });
    },
  };
  return gateway;
}
