import { spawn, type ChildProcess } from "node:child_process";
import { once } from "node:events";
import { mkdir, mkdtemp, readFile, realpath, rm, writeFile } from "node:fs/promises";
import { createServer as createHttpServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { createServer, type AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { randomUUID } from "node:crypto";
import WebSocket from "ws";
import { readLocalCredential } from "../src/client/local-credential.js";
import { PROTOCOL_VERSION } from "../src/version.js";
import { awaitsWithin, HOOK_HANG_BOUND_MS, waitFor } from "./wait-for.js";

/**
 * One real source Gateway *process* (`src/index.ts`, the same entrypoint and
 * environment shape the iOS E2E fixture launches) on an isolated root, with a
 * scripted OpenAI-compatible HTTP provider as the only scripted party. Clients
 * cross the production loopback WebSocket with the root's local credential.
 * `restart()` is the fixture restart the iOS fault proxy performs: SIGTERM, join
 * the exit, then spawn the same entrypoint over the same root and port.
 * Nothing inside the Gateway is replaced or imported into the test process.
 */

const gatewayRoot = fileURLToPath(new URL("..", import.meta.url));
// The source resolver, and the inert-unless-enabled attention recovery hold.
const preloads = ["home-ledger-crash-preload.mjs", "attention-recovery-hold-preload.mjs"]
  .map((name) => join(gatewayRoot, "test-support", name));

export const SCRIPTED_PROVIDER = "scripted";
export const SCRIPTED_MODEL = "scripted-model";

/** One OpenAI chat-completions request the Gateway's Pi made. */
export interface ScriptedRequest {
  readonly model: string;
  readonly messages: ReadonlyArray<{ role: string; content?: unknown; tool_calls?: unknown; tool_call_id?: string }>;
  readonly body: string;
}

/** One reply: streamed text chunks and/or tool calls. `chunks` are written in
 * order; a function chunk is awaited between writes, so a step can hold mid-stream. */
export interface ScriptedReply {
  readonly chunks?: ReadonlyArray<string | (() => Promise<void>)>;
  readonly toolCalls?: ReadonlyArray<{ id: string; name: string; arguments: Record<string, unknown> }>;
}

export type ScriptedStep = (request: ScriptedRequest, signal: AbortSignal) => ScriptedReply | Promise<ScriptedReply>;

export interface ScriptedProvider {
  readonly port: number;
  readonly requests: ReadonlyArray<ScriptedRequest>;
  /** Fixture faults: an unparsable request or a step that threw. A test asserts it empty. */
  readonly errors: ReadonlyArray<string>;
  /** Steps answer requests in order; an unscripted request is answered with HTTP 500. */
  script(steps: readonly ScriptedStep[]): void;
  close(): Promise<void>;
}

function sse(response: ServerResponse, model: string, delta: Record<string, unknown>, finish: string | null): void {
  response.write(`data: ${JSON.stringify({ id: "scripted", object: "chat.completion.chunk", created: 1, model,
    choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`);
}

export async function startScriptedProvider(): Promise<ScriptedProvider> {
  const requests: ScriptedRequest[] = [];
  const errors: string[] = [];
  let steps: ScriptedStep[] = [];
  const server: Server = createHttpServer(async (request: IncomingMessage, response: ServerResponse) => {
    const parts: Buffer[] = [];
    for await (const chunk of request) parts.push(chunk as Buffer);
    const body = Buffer.concat(parts).toString("utf8");
    let parsed: { model?: unknown; messages?: ScriptedRequest["messages"] };
    try { parsed = JSON.parse(body); } catch (error) {
      errors.push(`unparsable provider request: ${String(error)}`);
      response.writeHead(500, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: { message: "unparsable provider request" } }));
      return;
    }
    const record: ScriptedRequest = { model: String(parsed.model), messages: parsed.messages ?? [], body };
    requests.push(record);
    const step = steps.shift();
    if (!step) {
      response.writeHead(500, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: { message: "unscripted provider request" } }));
      return;
    }
    const aborted = new AbortController();
    response.once("close", () => { if (!response.writableFinished) aborted.abort(); });
    try {
      const reply = await step(record, aborted.signal);
      response.writeHead(200, { "content-type": "text/event-stream" });
      sse(response, record.model, { role: "assistant" }, null);
      for (const chunk of reply.chunks ?? []) {
        if (typeof chunk === "function") await chunk();
        else sse(response, record.model, { content: chunk }, null);
      }
      for (const [index, call] of (reply.toolCalls ?? []).entries()) {
        sse(response, record.model, { tool_calls: [{ index, id: call.id, type: "function",
          function: { name: call.name, arguments: JSON.stringify(call.arguments) } }] }, null);
      }
      sse(response, record.model, {}, reply.toolCalls?.length ? "tool_calls" : "stop");
      response.end("data: [DONE]\n\n");
    } catch (error) {
      // A step rejects when its held request is aborted by the Gateway (the
      // socket closed under it); any other rejection is a fixture fault.
      if (!aborted.signal.aborted) errors.push(`provider step failed: ${String(error)}`);
      response.destroy();
    }
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return {
    port: (server.address() as AddressInfo).port,
    requests,
    errors,
    script(next) { steps = [...next]; },
    async close() {
      server.closeAllConnections();
      await new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
    },
  };
}

export interface ProcessClient {
  request(method: string, params: Record<string, unknown>): Promise<{ ok: boolean; result?: any; error?: any }>;
  readonly events: ReadonlyArray<{ topic: string; sessionId?: string; payload: any }>;
  close(): Promise<void>;
}

export interface GatewayProcess {
  readonly root: string;
  readonly tronHome: string;
  readonly agentDir: string;
  readonly cwd: string;
  readonly provider: ScriptedProvider;
  /** The live child's PID; changes on `restart()`. */
  pid(): number;
  connect(): Promise<ProcessClient>;
  /** Every `gateway.jsonl` record written so far, across restarts. */
  log(): Promise<Array<Record<string, any>>>;
  /** Stop this process and start the same entrypoint over the same root and port.
   * `environment` adds variables to the new process only (test preload switches). */
  restart(options?: { environment?: Record<string, string> }): Promise<void>;
  dispose(): Promise<void>;
}

async function freePort(): Promise<number> {
  return await new Promise((resolve, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      server.close(() => typeof address === "object" && address ? resolve(address.port) : reject(new Error("no port")));
    });
  });
}

async function joinExit(child: ChildProcess, label: string, boundMs?: number): Promise<void> {
  if (child.exitCode !== null || child.signalCode !== null) return;
  const exited = once(child, "exit");
  await waitFor(async () => (child.exitCode !== null || child.signalCode !== null) || undefined, label,
    boundMs === undefined ? undefined : { boundMs });
  await exited.catch(() => undefined);
}

/** Disposal runs in an `afterEach` hook (10 s `hookTimeout`): a SIGTERM join
 * within the hook bound, then a SIGKILL join, so a shutdown hang is reported by
 * its label and the process is still removed. */
const KILL_JOIN_BOUND_MS = 3_000;

export async function startGatewayProcess(options: { settings?: Record<string, unknown> } = {}): Promise<GatewayProcess> {
  const provider = await startScriptedProvider();
  let root: string | undefined;
  let child: ChildProcess | undefined;
  try {
    // Canonical: the Tron workspace refuses a root reached through a symlink (macOS /var).
    root = await realpath(await mkdtemp(join(tmpdir(), "tron-gateway-process-")));
    return await launchGatewayProcess(options, provider, root, (spawned) => { child = spawned; });
  } catch (error) {
    // A failed start never reaches the caller's disposal list: remove what it made.
    if (child && child.exitCode === null && child.signalCode === null) {
      child.kill("SIGKILL");
      await joinExit(child, "the failed Gateway start exited after SIGKILL", KILL_JOIN_BOUND_MS).catch(() => undefined);
    }
    await provider.close();
    if (root) await rm(root, { recursive: true, force: true });
    throw error;
  }
}

async function launchGatewayProcess(
  options: { settings?: Record<string, unknown> },
  provider: ScriptedProvider,
  root: string,
  spawned: (child: ChildProcess) => void,
): Promise<GatewayProcess> {
  const tronHome = join(root, "tron");
  const agentDir = join(root, "agent");
  const cwd = join(root, "workspace");
  // Owner-only, as the Mac app creates its Tron home: the internal workspace refuses any other mode.
  for (const directory of [tronHome, agentDir, cwd, join(root, "home"), join(root, "tmp")]) await mkdir(directory, { recursive: true, mode: 0o700 });
  const model = (id: string) => ({ id, name: id, reasoning: false, input: ["text"], contextWindow: 128000, maxTokens: 4096,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } });
  await writeFile(join(agentDir, "models.json"), JSON.stringify({ providers: { [SCRIPTED_PROVIDER]: {
    baseUrl: `http://127.0.0.1:${provider.port}/v1`, api: "openai-completions", apiKey: "fixture-only",
    models: [model(SCRIPTED_MODEL), model("scripted-alternate")] } } }, null, 2));
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({
    defaultProvider: SCRIPTED_PROVIDER, defaultModel: SCRIPTED_MODEL, defaultProjectTrust: "never",
    enableAnalytics: false, enableInstallTelemetry: false, ...options.settings,
  }, null, 2));
  const port = await freePort();
  const environment = {
    PATH: process.env.PATH,
    HOME: join(root, "home"),
    TMPDIR: join(root, "tmp"),
    TRON_DATA_DIR: tronHome,
    PI_CODING_AGENT_DIR: agentDir,
    PI_SUBAGENTS_TEMP_ROOT: join(tronHome, "internal", "subagents"),
    TRON_GATEWAY_HOST: "127.0.0.1",
    TRON_GATEWAY_PORT: String(port),
  };
  const clients = new Set<WebSocket>();
  let child!: ChildProcess;
  let output = "";

  const readLog = async () => (await readFile(join(tronHome, "logs", "gateway.jsonl"), "utf8").catch(() => ""))
    .split("\n").filter(Boolean).flatMap((line) => { try { return [JSON.parse(line) as Record<string, any>]; } catch { return []; } });

  const launch = async (extra: Record<string, string> = {}) => {
    const startedAt = (await readLog()).filter((record) => record.event === "gateway.startup-budget").length;
    output = "";
    child = spawn(process.execPath, ["--experimental-transform-types", "--no-warnings",
      ...preloads.flatMap((preload) => ["--import", pathToFileURL(preload).href]),
      join(gatewayRoot, "src", "index.ts")], { cwd: gatewayRoot, stdio: ["ignore", "pipe", "pipe"], env: { ...environment, ...extra } });
    spawned(child);
    child.stdout!.on("data", (chunk: Buffer) => { output += chunk.toString(); });
    child.stderr!.on("data", (chunk: Buffer) => { output += chunk.toString(); });
    const launched = child;
    await waitFor(async () => {
      if (launched.exitCode !== null || launched.signalCode !== null) throw new Error(`Gateway exited during startup: ${output}`);
      return (await readLog()).filter((record) => record.event === "gateway.startup-budget").length > startedAt || undefined;
    }, "the Gateway process is serving");
  };
  const stop = async (label: string, boundMs?: number) => {
    for (const socket of clients) socket.terminate();
    clients.clear();
    if (child.exitCode === null && child.signalCode === null) child.kill("SIGTERM");
    await joinExit(child, label, boundMs);
  };
  await launch();

  return {
    root, tronHome, agentDir, cwd, provider,
    pid: () => child.pid!,
    log: readLog,
    async connect() {
      const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, {
        headers: { authorization: `Bearer ${await readLocalCredential(tronHome)}` }, maxPayload: 16 * 1024 * 1024,
      });
      clients.add(socket);
      const events: Array<{ topic: string; sessionId?: string; payload: any }> = [];
      const pending = new Map<string, (frame: any) => void>();
      let hello: (() => void) | undefined;
      const helloed = new Promise<void>((resolve) => { hello = resolve; });
      socket.on("message", (raw) => {
        const frame = JSON.parse(raw.toString());
        if (frame.type === "hello") hello?.();
        else if (frame.type === "response") pending.get(frame.id)?.(frame);
        else if (frame.type === "event") events.push({ topic: frame.topic, sessionId: frame.sessionId, payload: frame.payload });
      });
      await once(socket, "open");
      socket.send(JSON.stringify({ type: "hello", protocolVersion: PROTOCOL_VERSION }));
      await awaitsWithin(helloed, "the Gateway hello");
      return {
        events,
        async request(method, params) {
          const id = randomUUID();
          const answered = new Promise<any>((resolve) => pending.set(id, resolve));
          socket.send(JSON.stringify({ type: "request", id, method, params }));
          const frame = await awaitsWithin(answered, `the ${method} response`);
          pending.delete(id);
          return { ok: frame.ok, result: frame.result, error: frame.error };
        },
        async close() {
          clients.delete(socket);
          if (socket.readyState === WebSocket.CLOSED) return;
          const closed = once(socket, "close");
          socket.close();
          await closed;
        },
      };
    },
    async restart(restartOptions = {}) {
      await stop("the Gateway process exited after SIGTERM");
      await launch(restartOptions.environment);
    },
    async dispose() {
      let failure: unknown;
      try {
        await stop("the Gateway process exited after SIGTERM at disposal", HOOK_HANG_BOUND_MS);
      } catch (error) {
        failure = error;
        child.kill("SIGKILL");
        await joinExit(child, "the Gateway process exited after SIGKILL", KILL_JOIN_BOUND_MS);
      } finally {
        await provider.close();
        await rm(root, { recursive: true, force: true });
      }
      if (failure !== undefined) throw failure;
    },
  };
}
