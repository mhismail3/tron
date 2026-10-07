#!/usr/bin/env node
import { randomUUID } from "node:crypto";
import { createInterface } from "node:readline/promises";
import { homedir } from "node:os";
import { resolveBindHost } from "../config.js";
import { resolveTronHome } from "../tron-home.js";
import type { ContentPart, HomeContextProjection, HomeMemoryStatus, HomeStatus, JsonValue, SessionSnapshot, TranscriptItem } from "../protocol/types.js";
import { GatewayClientError, GatewayProtocolClient } from "./gateway-client.js";
import { readLocalCredential } from "./local-credential.js";

export interface SnapshotEnvelope { session: SessionSnapshot; syncToken: string; subscriptionToken: string; completionRevision?: number }
interface SessionMutationEnvelope { sessionId: string }
interface SessionListEnvelope { sessions: Array<{ id: string; name?: string; firstMessage: string; cwd: string }>; nextCursor?: string; listRevision: number }

function argument(name: string): string | undefined {
  const equals = process.argv.find((value) => value.startsWith(`${name}=`));
  if (equals) return equals.slice(name.length + 1);
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

function text(parts: ContentPart[]): string {
  return parts.flatMap((part) => part.type === "text" ? [part.text] : []).join("");
}

function assistantMessage(snapshot: SessionSnapshot): Extract<TranscriptItem, { kind: "message" }> | undefined {
  return snapshot.streaming?.kind === "message" && snapshot.streaming.role === "assistant"
    ? snapshot.streaming
    : [...snapshot.transcript].reverse().find(
      (item): item is Extract<TranscriptItem, { kind: "message" }> => item.kind === "message" && item.role === "assistant",
    );
}

export function assistantText(snapshot: SessionSnapshot): string {
  const assistant = assistantMessage(snapshot);
  if (!assistant) return "";
  const content = text(assistant.content);
  return assistant.errorMessage
    ? [content, assistant.errorMessage].filter(Boolean).join("\n")
    : content;
}

interface SessionEventEnvelope {
  runtimeGeneration: string;
  eventSequence: number;
  revision: number;
  data: JsonValue;
}

function assistantMessageId(snapshot: SessionSnapshot): string | undefined {
  const message = assistantMessage(snapshot);
  return message?.presentationId ?? message?.id;
}

function renderDelta(previous: string, current: string, isNewMessage: boolean): string {
  if (isNewMessage) return current;
  if (current.startsWith(previous)) return current.slice(previous.length);
  return `\n${current}`;
}

function sleep(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

export async function connectResilient(client: GatewayProtocolClient): Promise<void> {
  let delay = 250;
  while (true) {
    try {
      await client.connect();
      return;
    } catch (error) {
      // Protocol incompatibility is definitive; retrying it forever hides the
      // operator action required to upgrade the peer.
      if (error instanceof GatewayClientError && !error.retryable) throw error;
      client.close();
      await sleep(delay);
      delay = Math.min(Math.round(delay * 1.7), 5_000);
    }
  }
}

async function acknowledgeTerminalAttention(
  client: Pick<GatewayProtocolClient, "request">,
  sessionId: string,
  completionRevision: number,
): Promise<void> {
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      await client.request("session.attention.read", {
        sessionId,
        throughCompletionRevision: completionRevision,
      }, 8_000);
      return;
    } catch (error) {
      if (!(error instanceof GatewayClientError) || !error.retryable || attempt === 2) return;
    }
  }
}

/** Install and render the synchronized cut before best-effort attention I/O. */
export async function synchronizeTerminalSession(
  client: Pick<GatewayProtocolClient, "request">,
  sessionId: string,
  install: (baseline: SnapshotEnvelope) => void,
): Promise<SnapshotEnvelope> {
  const baseline = await client.request("session.open", { sessionId }) as unknown as SnapshotEnvelope;
  await client.request("session.sync", { sessionId, syncToken: baseline.syncToken });
  install(baseline);
  void acknowledgeTerminalAttention(client, sessionId, baseline.completionRevision ?? 0);
  return baseline;
}

export async function listSessions(
  client: Pick<GatewayProtocolClient, "request">,
  limits: {
    pageSize?: number;
    maximumPages?: number;
    maximumSessions?: number;
    maximumBytes?: number;
    revisionRestarts?: number;
  } = {},
): Promise<SessionListEnvelope["sessions"]> {
  const pageSize = limits.pageSize ?? 200;
  const maximumPages = limits.maximumPages ?? 126;
  const maximumSessions = limits.maximumSessions ?? 25_000;
  const maximumBytes = limits.maximumBytes ?? 8 * 1_024 * 1_024;
  const revisionRestarts = limits.revisionRestarts ?? 1;
  if (![pageSize, maximumPages, maximumSessions, maximumBytes].every((value) => Number.isSafeInteger(value) && value > 0)
    || !Number.isSafeInteger(revisionRestarts) || revisionRestarts < 0) {
    throw new Error("Terminal session catalog bounds are invalid");
  }
  const sessions: SessionListEnvelope["sessions"] = [];
  const ids = new Set<string>();
  const cursors = new Set<string>();
  let retainedBytes = 0;
  let cursor: string | undefined;
  let revision: number | undefined;
  for (let page = 0; page < maximumPages; page += 1) {
    const result = await client.request("session.list", {
      cursor: cursor ?? null,
      limit: pageSize,
    }) as unknown as SessionListEnvelope;
    if (!result || typeof result !== "object" || !Array.isArray(result.sessions)
      || result.sessions.length > pageSize || !Number.isSafeInteger(result.listRevision)
      || (result.nextCursor !== undefined
        && (typeof result.nextCursor !== "string" || Buffer.byteLength(result.nextCursor) > 500))) {
      throw new Error("Gateway returned a malformed session catalog page");
    }
    if (revision !== undefined && revision !== result.listRevision) {
      if (revisionRestarts < 1) throw new Error("Gateway session catalog changed repeatedly during traversal");
      return listSessions(client, { ...limits, revisionRestarts: revisionRestarts - 1 });
    }
    revision = result.listRevision;
    for (const session of result.sessions) {
      if (!session || typeof session !== "object" || typeof session.id !== "string" || session.id.length === 0
        || typeof session.cwd !== "string" || typeof session.firstMessage !== "string"
        || (session.name !== undefined && typeof session.name !== "string") || ids.has(session.id)) {
        throw new Error("Gateway returned a malformed or ambiguous session catalog");
      }
      ids.add(session.id);
      retainedBytes += Buffer.byteLength(JSON.stringify(session));
      if (sessions.length >= maximumSessions || retainedBytes > maximumBytes) {
        throw new Error("Gateway session catalog exceeds terminal client capacity");
      }
      sessions.push(session);
    }
    cursor = result.nextCursor;
    if (!cursor) return sessions;
    if (result.sessions.length === 0 || cursors.has(cursor)) {
      throw new Error("Gateway session catalog cursor stalled");
    }
    cursors.add(cursor);
  }
  throw new Error("Gateway session catalog exceeds its bounded page count");
}

function usage(): never {
  process.stderr.write(`Usage: tron-chat [--session <id>] [--cwd <path>] [--host <host>] [--port <port>]\n\n`);
  process.stderr.write(`Attaches to the Gateway-owned canonical runtime. It never opens Pi JSONL directly.\n`);
  process.stderr.write(`Commands: /home [status], /home designate [provider/id], /home disable, /home memory <provider/id>, /home resume, /home context, /abort, /quit\n`);
  process.exit(64);
}

/** `home.status`: the protocol's bounded projection, rendered without a terminal-only shape. */
type HomeStatusEnvelope = HomeStatus;

interface HomeDesignationEnvelope { homeId: string; sessionId: string; generation: number }

/** `home.configureMemory`/`home.resumeMemory` and `home.status`'s `memory`: the
 * same bounded memory projection the RPCs return. */
export type HomeMemoryEnvelope = HomeMemoryStatus;

/** `home.context`: the bounded request context of Home's current or last
 * activation. The sizes are absent when that activation prepared no request. */
export type HomeContextEnvelope = HomeContextProjection;

/** One `/home` line, resolved without touching the Gateway. */
export type HomeCommand =
  | { kind: "status" }
  | { kind: "designate"; model?: { provider: string; id: string } }
  | { kind: "disable" }
  | { kind: "memory"; model: { provider: string; id: string } }
  | { kind: "resume" }
  | { kind: "context" }
  | { kind: "usage" };

/** Returns undefined for any line that is not a `/home` command, so it continues
 * to the model. An unknown subcommand prints usage instead of reaching the
 * model, and a malformed model argument throws for the caller to report. */
export function parseHomeCommand(input: string): HomeCommand | undefined {
  if (input !== "/home" && !input.startsWith("/home ")) return undefined;
  if (input === "/home" || input === "/home status") return { kind: "status" };
  if (input === "/home disable") return { kind: "disable" };
  if (input === "/home resume") return { kind: "resume" };
  if (input === "/home context") return { kind: "context" };
  if (input === "/home designate") return { kind: "designate" };
  if (input.startsWith("/home designate ")) {
    return { kind: "designate", model: parseHomeModelArgument(input.slice("/home designate ".length).trim()) };
  }
  if (input === "/home memory" || input.startsWith("/home memory ")) {
    const arguments_ = input.slice("/home memory".length).trim().split(/\s+/u).filter((part) => part !== "");
    // The shape is exactly a model; the memory regulates its own spend (#493).
    // Any other shape is usage; a model that cannot be read reports its reason.
    if (arguments_.length !== 1) return { kind: "usage" };
    return { kind: "memory", model: parseHomeModelArgument(arguments_[0]!) };
  }
  return { kind: "usage" };
}

export function describeHomeStatus(status: HomeStatusEnvelope): string {
  const designation = !status.available
    ? `Home unavailable: ${status.reason ?? "the stored record could not be used"}`
    : !status.enabled ? "Home is not designated."
      : `Home is designated: session ${status.sessionId}, generation ${status.generation}${status.model ? `, model ${status.model.provider}/${status.model.id}` : ""}, ${status.live ? "runtime live" : "runtime not loaded"}${status.sessionPresent ? "" : ", session missing"}.`;
  const gaps = status.readiness.gaps.length ? status.readiness.gaps.join(", ") : "none";
  const recovery = status.recovery.reason ? `${status.recovery.action} (${status.recovery.reason})` : status.recovery.action;
  return `${designation} Phase: ${status.phase}. Readiness: ${status.readiness.ready ? "ready" : `not ready; ${gaps}`}. ${describeHomeMemory(status.memory)} ${describeHomeContext(status.activation)} Recovery: ${recovery}.`;
}

const HOME_USAGE = "Usage: /home [status] | /home designate [provider/id] | /home disable | /home memory <provider/id> | /home resume | /home context\n";

export async function homeStatusCommand(client: Pick<GatewayProtocolClient, "request">): Promise<string> {
  return describeHomeStatus(await client.request("home.status", {}) as unknown as HomeStatusEnvelope);
}

/** `provider/id`, the same spelling the model picker uses. */
export function parseHomeModelArgument(argument: string): { provider: string; id: string } {
  const separator = argument.indexOf("/");
  const provider = separator > 0 ? argument.slice(0, separator) : "";
  const id = separator > 0 ? argument.slice(separator + 1) : "";
  if (!provider || !id) throw new Error("Name the model as provider/id, for example anthropic/claude-sonnet-4-5");
  return { provider, id };
}

/** What the memory projection says, in one line: its model, the spend so far,
 * whether its store is open yet and the reason it is blocked. */
export function describeHomeMemory(memory: HomeMemoryEnvelope): string {
  if (!memory.configured) {
    return `Home memory is not configured${memory.reason ? `: ${memory.reason}` : ""}. /home memory <provider/id> configures it.`;
  }
  const model = memory.model ? `model ${memory.model.provider}/${memory.model.id}` : "an unrecorded model";
  const spend = memory.spentTokens === undefined ? "" : `, ${memory.spentTokens} tokens spent`;
  const open = memory.open ? "open" : "not open yet (it opens at the first activation)";
  const blocked = memory.blocked ? `, blocked: ${memory.blocked}` : "";
  const episodic = memory.episodic;
  const progress = episodic
    ? `, ${episodic.coverage.admitted} admitted, ${episodic.coverage.summarized} summarized, ${episodic.view.unbuilt} unbuilt view parts, pump busy: ${episodic.pump.busy}`
    : "";
  const reason = memory.reason ? `, degraded: ${memory.reason}` : "";
  return `Home memory: ${model}${spend}, ${open}${blocked}${progress}${reason}.`;
}

/** What the request-context projection says: the activation's start, whether it
 * is still open, the size of the request it prepared, and its own refusal. */
export function describeHomeContext(context: HomeContextEnvelope): string {
  if (!context.available) return "Home has no activation to report yet.";
  const start = context.activationStartEntryId ?? "the start of the conversation";
  const state = context.activationOpen ? "open" : "settled";
  const sizes = context.viewLines === undefined
    ? context.lastRefusalReason ? "it was refused before it prepared a request" : "it is awaiting request preparation"
    : `${context.viewLines} view lines (${context.viewBytes} bytes), about ${context.effectiveTokens} tokens of a ${context.contextWindow}-token window`;
  const refusal = context.lastRefusalReason
    ? `, last refusal ${context.lastRefusalReason}${context.lastRefusalDetail ? `: ${context.lastRefusalDetail}` : ""}`
    : "";
  return `Home activation (${state}), started after ${start}: ${sizes}${refusal}.`;
}

export async function configureHomeMemory(
  client: Pick<GatewayProtocolClient, "request">,
  model: { provider: string; id: string },
): Promise<string> {
  const result = await client.request("home.configureMemory", { commandId: randomUUID(), model }) as unknown as HomeMemoryEnvelope;
  return describeHomeMemory(result);
}

export async function resumeHomeMemory(client: Pick<GatewayProtocolClient, "request">): Promise<string> {
  const result = await client.request("home.resumeMemory", { commandId: randomUUID() }) as unknown as HomeMemoryEnvelope;
  return describeHomeMemory(result);
}

export async function homeContextCommand(client: Pick<GatewayProtocolClient, "request">): Promise<string> {
  return describeHomeContext(await client.request("home.context", {}) as unknown as HomeContextEnvelope);
}

export async function designateHome(
  client: Pick<GatewayProtocolClient, "request">,
  model?: { provider: string; id: string },
): Promise<string> {
  const result = await client.request("home.designate", {
    commandId: randomUUID(),
    ...(model ? { model } : {}),
  }) as unknown as HomeDesignationEnvelope;
  return `Home designated: session ${result.sessionId}, generation ${result.generation}.`;
}

export async function disableHome(client: Pick<GatewayProtocolClient, "request">): Promise<string> {
  const result = await client.request("home.disable", { commandId: randomUUID() }) as unknown as HomeDesignationEnvelope;
  return `Home disabled: session ${result.sessionId}, generation ${result.generation}. It is an ordinary session now.`;
}

/** Resolve and run one `/home` line without letting malformed arguments escape the prompt loop. */
export async function runHomeInput(client: Pick<GatewayProtocolClient, "request">, input: string): Promise<boolean> {
  let command: HomeCommand | undefined;
  try {
    command = parseHomeCommand(input);
  } catch (error) {
    process.stderr.write(`${HOME_USAGE}${error instanceof Error ? `home: ${error.message}\n` : `home: ${String(error)}\n`}`);
    return true;
  }
  if (!command) return false;
  await runHomeCommand(client, command);
  return true;
}

/** Run one parsed `/home` command, reporting its outcome on stdout and failures on stderr. */
export async function runHomeCommand(client: Pick<GatewayProtocolClient, "request">, command: HomeCommand): Promise<void> {
  if (command.kind === "usage") {
    process.stderr.write(HOME_USAGE);
    return;
  }
  try {
    if (command.kind === "status") process.stdout.write(`${await homeStatusCommand(client)}\n`);
    else if (command.kind === "designate") process.stdout.write(`${await designateHome(client, command.model)}\n`);
    else if (command.kind === "memory") process.stdout.write(`${await configureHomeMemory(client, command.model)}\n`);
    else if (command.kind === "resume") process.stdout.write(`${await resumeHomeMemory(client)}\n`);
    else if (command.kind === "context") process.stdout.write(`${await homeContextCommand(client)}\n`);
    else process.stdout.write(`${await disableHome(client)}\n`);
  } catch (error) {
    process.stderr.write(`home: ${error instanceof Error ? error.message : String(error)}\n`);
  }
}

function operationNeedsSettlement(
  operationId: string,
  reconciledSettledOperation: string | undefined,
): boolean {
  return operationId !== reconciledSettledOperation;
}

async function runTerminalChat(): Promise<void> {
  if (process.argv.includes("--help") || process.argv.includes("-h")) usage();
  const tronHome = resolveTronHome();
  const port = Number(argument("--port") ?? process.env.TRON_GATEWAY_PORT ?? (process.env.TRON_HOME_NAME === ".tron-dev" ? 9848 : 9847));
  if (!Number.isSafeInteger(port) || port < 1 || port > 65_535) throw new Error("Gateway port must be between 1 and 65535");
  const requestedHost = argument("--host") ?? process.env.TRON_GATEWAY_HOST;
  const host = requestedHost ? resolveBindHost(requestedHost) : resolveBindHost("tailscale");
  const socketURL = `ws://${host.includes(":") ? `[${host}]` : host}:${port}/v1/socket`;
  let client = new GatewayProtocolClient(socketURL, await readLocalCredential(tronHome));
  await client.connect();

  const requestedSession = argument("--session");
  let sessionId = requestedSession;
  if (!sessionId) {
    const sessions = await listSessions(client);
    const cwd = argument("--cwd") ?? process.cwd();
    const matching = sessions.filter((session) => session.cwd === cwd);
    const recent = matching[0] ?? sessions[0];
    sessionId = recent?.id;
    if (!sessionId) {
      const result = await client.request("session.create", { cwd, commandId: randomUUID() }) as unknown as SessionMutationEnvelope;
      sessionId = result.sessionId;
    }
  }

  let snapshot!: SessionSnapshot;
  let subscriptionToken!: string;
  let rendered = "";
  let renderedMessageId: string | undefined;
  let cursor!: { runtimeGeneration: string; eventSequence: number };
  let awaitingOperation: string | undefined;
  let reconciledSettledOperation: string | undefined;
  let pendingCommand: { method: string; commandId: string } | undefined;
  let settledResolve: (() => void) | undefined;
  await synchronizeTerminalSession(client, sessionId, (installed) => {
    snapshot = installed.session;
    subscriptionToken = installed.subscriptionToken;
    rendered = assistantText(snapshot);
    renderedMessageId = assistantMessageId(snapshot);
    cursor = { runtimeGeneration: snapshot.runtimeGeneration, eventSequence: snapshot.eventSequence };
    process.stdout.write(`Attached to Tron session ${snapshot.sessionId} (${snapshot.cwd})\n`);
    if (rendered) process.stdout.write(rendered);
  });

  let unsubscribers: Array<() => void> = [];
  let reconnecting: Promise<void> | undefined;
  let reconnect: () => Promise<void>;
  const attachListeners = () => {
    unsubscribers.forEach((unsubscribe) => unsubscribe());
    unsubscribers = [
      client.onEvent((event) => {
        if (event.sessionId !== sessionId) return;
        if (event.topic === "transport.resyncRequired") {
          void reconnect();
          return;
        }
        if (event.topic === "session.snapshot") {
          const next = event.payload as unknown as SessionSnapshot;
          if (next.runtimeGeneration === cursor.runtimeGeneration && next.eventSequence <= cursor.eventSequence) return;
          snapshot = next;
          cursor = { runtimeGeneration: snapshot.runtimeGeneration, eventSequence: snapshot.eventSequence };
        } else {
          const envelope = event.payload as unknown as SessionEventEnvelope;
          if (envelope.runtimeGeneration !== cursor.runtimeGeneration || envelope.eventSequence !== cursor.eventSequence + 1) {
            void reconnect();
            return;
          }
          cursor.eventSequence = envelope.eventSequence;
          if (event.topic === "session.progress") {
            const data = envelope.data as Record<string, JsonValue>;
            if (data.message) snapshot.streaming = data.message as unknown as TranscriptItem;
          } else if (event.topic === "session.toolProgress") {
            // Tool evidence is rendered by native clients; retain ordering here
            // and let the next authoritative snapshot converge terminal state.
          }
        }
        const current = assistantText(snapshot);
        const messageId = assistantMessageId(snapshot);
        const delta = renderDelta(rendered, current, messageId !== renderedMessageId);
        if (delta) process.stdout.write(delta);
        rendered = current;
        renderedMessageId = messageId;
        if (snapshot.phase === "idle" && !snapshot.operation && settledResolve) {
          process.stdout.write("\n");
          awaitingOperation = undefined;
          settledResolve();
          settledResolve = undefined;
        }
      }),
      client.onDisconnect(() => { void reconnect(); }),
    ];
  };
  reconnect = (): Promise<void> => {
    reconnecting ??= (async () => {
      unsubscribers.forEach((unsubscribe) => unsubscribe());
      process.stderr.write("\n[Tron disconnected; reconnecting…]\n");
      while (true) {
        client = new GatewayProtocolClient(socketURL, await readLocalCredential(tronHome));
        try {
          await connectResilient(client);
          await synchronizeTerminalSession(client, sessionId, (installed) => {
            snapshot = installed.session;
            subscriptionToken = installed.subscriptionToken;
            cursor = { runtimeGeneration: snapshot.runtimeGeneration, eventSequence: snapshot.eventSequence };
            const current = assistantText(snapshot);
            const messageId = assistantMessageId(snapshot);
            const delta = renderDelta(rendered, current, messageId !== renderedMessageId);
            if (awaitingOperation && delta) process.stdout.write(delta);
            rendered = current;
            renderedMessageId = messageId;
          });
          attachListeners();
          process.stderr.write("[Tron synchronized]\n");
          if (pendingCommand) {
            const status = await client.request("command.status", pendingCommand) as unknown as { status: string; result?: { operationId?: string } };
            if (status.status === "completed") awaitingOperation = status.result?.operationId ?? awaitingOperation;
            else if (status.status === "missing") awaitingOperation = undefined;
            pendingCommand = undefined;
          }
          if (awaitingOperation && snapshot.phase === "idle" && !snapshot.operation) {
            reconciledSettledOperation = awaitingOperation;
            awaitingOperation = undefined;
            settledResolve?.();
            settledResolve = undefined;
          }
          return;
        } catch (error) {
          if (error instanceof GatewayClientError && !error.retryable) throw error;
          client.close();
          await sleep(500);
        }
      }
    })().finally(() => { reconnecting = undefined; });
    return reconnecting;
  };
  attachListeners();

  const confirmedRequest = async (method: string, params: Record<string, JsonValue>, commandId: string): Promise<JsonValue> => {
    try {
      return await client.request(method, params);
    } catch (error) {
      if (!(error instanceof GatewayClientError) || !error.retryable) throw error;
      const deadline = Date.now() + 90_000;
      let replayAllowed = false;
      while (Date.now() < deadline) {
        await reconnect();
        try {
          const status = await client.request("command.status", { method, commandId }) as unknown as { status: string; result?: JsonValue };
          if (status.status === "completed") return status.result ?? null;
          if (status.status === "missing") replayAllowed = true;
          if (replayAllowed) {
            try { return await client.request(method, params); }
            catch (retry) {
              if (!(retry instanceof GatewayClientError) || !retry.retryable) throw retry;
              replayAllowed = false;
            }
          }
        } catch (statusError) {
          if (!(statusError instanceof GatewayClientError) || !statusError.retryable) throw statusError;
        }
        await sleep(250);
      }
      throw new GatewayClientError(
        "outcome_unknown",
        "Tron may have accepted this command. Check the synchronized transcript before sending it again.",
        false,
      );
    }
  };

  const readline = createInterface({ input: process.stdin, output: process.stdout, terminal: true });
  try {
    while (true) {
      const prompt = (await readline.question("you> ")).trim();
      if (!prompt) continue;
      if (prompt === "/quit" || prompt === "/exit") break;
      if (prompt === "/abort") {
        await client.request("session.abort", { sessionId, kind: "agent", commandId: randomUUID() });
        continue;
      }
      // Home commands are Gateway-wide, not session-scoped, so they work before
      // or without an attached session's runtime being the Home one.
      if (await runHomeInput(client, prompt)) continue;
      const commandId = randomUUID();
      reconciledSettledOperation = undefined;
      pendingCommand = { method: "session.prompt", commandId };
      const result = await confirmedRequest("session.prompt", {
        sessionId,
        text: prompt,
        uploadIds: [],
        ...(snapshot.phase === "idle" ? {} : { behavior: "followUp" }),
        commandId,
      }, commandId) as unknown as { operationId: string };
      pendingCommand = undefined;
      if (!operationNeedsSettlement(result.operationId, reconciledSettledOperation)) {
        reconciledSettledOperation = undefined;
        continue;
      }
      awaitingOperation = result.operationId;
      await new Promise<void>((resolve) => { settledResolve = resolve; });
    }
  } finally {
    unsubscribers.forEach((unsubscribe) => unsubscribe());
    readline.close();
    await client.request("session.close", { sessionId, subscriptionToken }).catch(() => null);
    client.close();
  }
}

const invoked = process.argv[1] ? new URL(import.meta.url).pathname === process.argv[1] : false;
if (invoked) {
  runTerminalChat().catch((error) => {
    process.stderr.write(`tron-chat: ${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  });
}
