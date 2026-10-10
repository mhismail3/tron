#!/usr/bin/env node
import { randomUUID } from "node:crypto";
import { createInterface } from "node:readline/promises";
import { resolveBindHost } from "../config.js";
import { resolveTronHome } from "../tron-home.js";
import type { ContentPart, HomeContextProjection, HomeDesignation, HomeMemoryStatus, HomeOpen, HomeStatus, JsonValue, SessionSnapshot, TranscriptItem } from "../protocol/types.js";
import { GatewayClientError, GatewayProtocolClient } from "./gateway-client.js";
import { readLocalCredential } from "./local-credential.js";
import { INVOCATION_RECEIPT_TYPE, parseInvocationReceipt } from "../sessions/invocation-receipts.js";

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

function assistantText(snapshot: SessionSnapshot): string {
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

async function connectResilient(client: GatewayProtocolClient): Promise<void> {
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
async function synchronizeTerminalSession(
  client: Pick<GatewayProtocolClient, "request">,
  sessionId: string,
  install: (baseline: SnapshotEnvelope) => void,
): Promise<SnapshotEnvelope> {
  const baseline = await client.request("session.open", { sessionId }) as unknown as SnapshotEnvelope;
  // The acquisition owns the candidate until installation succeeds. A sync
  // failure occurs before callers can see its token, so only this boundary can
  // retire it without disturbing the previously installed attachment.
  try {
    await client.request("session.sync", { sessionId, syncToken: baseline.syncToken });
    install(baseline);
  } catch (error) {
    await client.request("session.close", { sessionId, subscriptionToken: baseline.subscriptionToken }).catch(() => null);
    throw error;
  }
  void acknowledgeTerminalAttention(client, sessionId, baseline.completionRevision ?? 0);
  return baseline;
}

async function listSessions(
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

/** The `/home` commands, listed once for the usage line and for `/home` errors. */
const HOME_COMMANDS = [
  "/home [status]", "/home designate [provider/id]", "/home disable", "/home memory <provider/id>", "/home resume", "/home context",
  "/home reconfirm-permissions", "/home permissions", "/home revoke-scope <id>", "/home revoke-grant <id>",
  "/home approve-grant <request-id> <expiry-ms>", "/home deny-grant <request-id> <expiry-ms>", "/home task <id>",
  "/home steer <id> <text>", "/home stop <id>", "/home redeliver <id>",
];
const HOME_USAGE = `Usage: ${HOME_COMMANDS.join(" | ")}\n`;

function usage(): never {
  process.stderr.write(`Usage: tron-chat [--session <id>] [--cwd <path>] [--host <host>] [--port <port>]\n\n`);
  process.stderr.write(`Attaches to the Gateway-owned canonical runtime. It never opens Pi JSONL directly.\n`);
  process.stderr.write(`Commands: ${HOME_COMMANDS.join(", ")}, /abort, /quit\n`);
  process.exit(64);
}

/** `home.status`: the protocol's bounded projection, rendered without a terminal-only shape. */
/** One `/home` line, resolved without touching the Gateway. */
export type HomeCommand =
  | { kind: "status" }
  | { kind: "designate"; model?: { provider: string; id: string } }
  | { kind: "disable" }
  | { kind: "reconfirm-permissions" }
  | { kind: "permissions" }
  | { kind: "revoke-scope"; scopeId: string }
  | { kind: "revoke-grant"; grantId: string }
  | { kind: "decide-grant"; requestId: string; approved: boolean; expiresAt: number }
  | { kind: "redeliver-task"; taskId: string }
  | { kind: "task"; taskId: string }
  | { kind: "stop-task"; taskId: string }
  | { kind: "steer-task"; taskId: string; text: string }
  | { kind: "memory"; model: { provider: string; id: string } }
  | { kind: "resume" }
  | { kind: "context" }
  | { kind: "usage" };

/** Returns undefined for any line that is not a `/home` command, so it continues
 * to the model. An unknown subcommand prints usage instead of reaching the
 * model, and a malformed model argument throws for the caller to report. */
function parseHomeCommand(input: string): HomeCommand | undefined {
  if (input !== "/home" && !input.startsWith("/home ")) return undefined;
  if (input === "/home" || input === "/home status") return { kind: "status" };
  if (input === "/home disable") return { kind: "disable" };
  if (input === "/home reconfirm-permissions") return { kind: "reconfirm-permissions" };
  if (input === "/home permissions") return { kind: "permissions" };
  const revoke = /^\/home revoke-(scope|grant) ([A-Za-z0-9][A-Za-z0-9._-]{0,159})$/u.exec(input);
  if (revoke) return revoke[1] === "scope" ? { kind: "revoke-scope", scopeId: revoke[2]! } : { kind: "revoke-grant", grantId: revoke[2]! };
  const decision = /^\/home (approve|deny)-grant ([A-Za-z0-9][A-Za-z0-9._-]{0,159}) ([0-9]+)$/u.exec(input);
  if (decision && Number.isSafeInteger(Number(decision[3]))) return { kind: "decide-grant", requestId: decision[2]!, approved: decision[1] === "approve", expiresAt: Number(decision[3]) };
  const redeliver = /^\/home redeliver ([A-Za-z0-9][A-Za-z0-9._-]{0,159})$/u.exec(input);
  if (redeliver) return { kind: "redeliver-task", taskId: redeliver[1]! };
  const task = /^\/home (task|stop|steer) ([A-Za-z0-9][A-Za-z0-9._-]{0,159})(?: (.+))?$/u.exec(input);
  if (task) {
    if (task[1] === "steer" && task[3]?.trim()) return { kind: "steer-task", taskId: task[2]!, text: task[3] };
    if (task[1] !== "steer" && !task[3]) return { kind: task[1] === "stop" ? "stop-task" : "task", taskId: task[2]! };
  }
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

function describeHomeStatus(status: HomeStatus): string {
  const designation = !status.available
    ? `Home unavailable: ${status.reason ?? "the stored record could not be used"}`
    : !status.enabled ? "Home is not designated."
      : `Home is designated: session ${status.sessionId}, generation ${status.generation}${status.model ? `, model ${status.model.provider}/${status.model.id}` : ""}, ${status.live ? "runtime live" : "runtime not loaded"}${status.sessionPresent ? "" : ", session missing"}.`;
  const gaps = status.readiness.gaps.length ? status.readiness.gaps.join(", ") : "none";
  const recovery = status.recovery.reason ? `${status.recovery.action} (${status.recovery.reason})` : status.recovery.action;
  return `${designation} Phase: ${status.phase}. Readiness: ${status.readiness.ready ? "ready" : `not ready; ${gaps}`}. ${describeHomeMemory(status.memory)} ${describeHomeContext(status.activation)} Recovery: ${recovery}.`;
}

async function homeStatusCommand(client: Pick<GatewayProtocolClient, "request">): Promise<string> {
  return describeHomeStatus(await client.request("home.status", {}) as unknown as HomeStatus);
}

/** `provider/id`, the same spelling the model picker uses. */
function parseHomeModelArgument(argument: string): { provider: string; id: string } {
  const separator = argument.indexOf("/");
  const provider = separator > 0 ? argument.slice(0, separator) : "";
  const id = separator > 0 ? argument.slice(separator + 1) : "";
  if (!provider || !id) throw new Error("Name the model as provider/id, for example anthropic/claude-sonnet-4-5");
  return { provider, id };
}

/** What the memory projection says, in one line: its model, the spend so far,
 * whether its store is open yet and the reason it is blocked. */
export function describeHomeMemory(memory: HomeMemoryStatus): string {
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
export function describeHomeContext(context: HomeContextProjection): string {
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
  const result = await client.request("home.configureMemory", { commandId: randomUUID(), model }) as unknown as HomeMemoryStatus;
  return describeHomeMemory(result);
}

export async function resumeHomeMemory(client: Pick<GatewayProtocolClient, "request">): Promise<string> {
  const result = await client.request("home.resumeMemory", { commandId: randomUUID() }) as unknown as HomeMemoryStatus;
  return describeHomeMemory(result);
}

export async function homeContextCommand(client: Pick<GatewayProtocolClient, "request">): Promise<string> {
  return describeHomeContext(await client.request("home.context", {}) as unknown as HomeContextProjection);
}

export async function designateHome(
  client: Pick<GatewayProtocolClient, "request">,
  model?: { provider: string; id: string },
): Promise<string> {
  const result = await client.request("home.designate", {
    commandId: randomUUID(),
    ...(model ? { model } : {}),
  }) as unknown as HomeDesignation;
  return `Home designated: session ${result.sessionId}, generation ${result.generation}.`;
}

export async function disableHome(client: Pick<GatewayProtocolClient, "request">): Promise<string> {
  const result = await client.request("home.disable", { commandId: randomUUID() }) as unknown as HomeDesignation;
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
async function runHomeCommand(client: Pick<GatewayProtocolClient, "request">, command: HomeCommand): Promise<void> {
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
    else if (command.kind === "permissions") process.stdout.write(`${JSON.stringify(await client.request("home.taskPermissions", {}), null, 2)}\n`);
    else if (command.kind === "revoke-scope" || command.kind === "revoke-grant") {
      await client.request(command.kind === "revoke-scope" ? "home.revokeTaskScope" : "home.revokeTaskGrant", { commandId: randomUUID(),
        ...(command.kind === "revoke-scope" ? { scopeId: command.scopeId } : { grantId: command.grantId }) });
      process.stdout.write("Home task authorization revocation accepted. Already admitted work is unchanged.\n");
    } else if (command.kind === "decide-grant") {
      const result = await client.request("home.decideTaskGrant", { commandId: randomUUID(), requestId: command.requestId, approved: command.approved, expiresAt: command.expiresAt });
      process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    }
    else if (command.kind === "redeliver-task") {
      const route = await client.request("home.status", {}) as unknown as import("../protocol/types.js").HomeStatus;
      if (!route.enabled || !route.homeId || !route.routeGeneration) throw new Error("Home route is unavailable");
      await client.request("home.redeliverTaskResult", { commandId: randomUUID(), taskId: command.taskId, homeId: route.homeId, routeGeneration: route.routeGeneration });
      process.stdout.write(`Task ${command.taskId}: redelivery accepted for the current Home route.\n`);
    }
    else if (command.kind === "reconfirm-permissions") {
      await client.request("home.reconfirmPermissions", { commandId: randomUUID() });
      process.stdout.write("Home task standing permissions reconfirmed. Revoked scopes and one-use grants were not renewed.\n");
    } else if (command.kind === "task" || command.kind === "stop-task" || command.kind === "steer-task") {
      const task = await client.request("home.taskStatus", { taskId: command.taskId }) as unknown as import("../home/home-task-store.js").HomeTaskRecord;
      if (command.kind === "task") {
        const spend = task.spend;
        process.stdout.write(`Task ${task.taskId}: ${task.lifecycle}${task.terminalEvidence ? ` (${task.terminalEvidence.outcome})` : ""}; ${spend?.inputTokens ?? 0} input/cache + ${spend?.outputTokens ?? 0} output tokens.\n`);
      } else {
        if (task.lifecycle !== "active" || !task.operationId) throw new Error("Task is not active");
        await client.request(command.kind === "stop-task" ? "home.stopTask" : "home.steerTask", { commandId: randomUUID(),
          taskId: task.taskId, operationId: task.operationId,
          ...(command.kind === "steer-task" ? { text: command.text } : {}) });
        process.stdout.write(`Task ${task.taskId}: ${command.kind === "stop-task" ? "Stop joined" : "steering accepted"}.\n`);
      }
    }
    else process.stdout.write(`${await disableHome(client)}\n`);
  } catch (error) {
    process.stderr.write(`home: ${error instanceof Error ? error.message : String(error)}\n`);
  }
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
  let sessionId: string | undefined = requestedSession;
  let logicalHome = false;
  if (!sessionId) {
    try {
      const route = await client.request("home.open", {}) as unknown as HomeOpen;
      logicalHome = route.logicalSessionId === "home";
      if (route.chapterState === "active") sessionId = route.sessionId;
    } catch (error) {
      if (!(error instanceof GatewayClientError) || error.code !== "not_found") throw error;
    }
    if (!logicalHome) {
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
  }

  let snapshot: SessionSnapshot | undefined;
  let subscriptionToken!: string;
  let rendered = "";
  let renderedMessageId: string | undefined;
  let cursor!: { runtimeGeneration: string; eventSequence: number };
  let acceptedOperation: {
    sessionId: string; operationId: string; submissionLeaf: string | undefined;
    settle: () => void; fail: (error: unknown) => void; reading?: Promise<void> | undefined;
  } | undefined;
  const settleAcceptedOperation = (): void => {
    const accepted = acceptedOperation;
    if (!accepted || !snapshot || snapshot.sessionId !== accepted.sessionId) return;
    const finish = (): void => {
      if (acceptedOperation !== accepted) return;
      acceptedOperation = undefined;
      process.stdout.write("\n");
      accepted.settle();
    };
    // Foreground retirement only schedules an evidence read; phase can remain
    // running while Home quiescence unwinds. Follow the exact branch cut back
    // to the submission leaf (or this invocation's start in a new Home chapter),
    // stopping at its terminal receipt. Canonical entries, not transcript rows,
    // also cover inputs handled without a user message. No history-page scan.
    if (accepted.reading || snapshot.operation || snapshot.pendingPrompt
      || snapshot.queuedItems.some(item => item.id === accepted.operationId)) return;
    const cut = snapshot;
    const readingClient = client;
    const stillOwned = (): boolean => acceptedOperation === accepted && client === readingClient
      && snapshot?.sessionId === accepted.sessionId && snapshot?.runtimeGeneration === cut.runtimeGeneration
      && snapshot?.leafEntryId === cut.leafEntryId;
    accepted.reading = (async () => {
      const history = await readingClient.request("session.history.list", {
        sessionId: accepted.sessionId, runtimeGeneration: cut.runtimeGeneration,
      }) as unknown as { totalEntries: number };
      if (!stillOwned()) return;
      if (!Number.isSafeInteger(history.totalEntries) || history.totalEntries < 0) {
        throw new Error("Gateway returned an invalid invocation history bound");
      }
      let entryId = cut.leafEntryId;
      for (let remaining = history.totalEntries; entryId && entryId !== accepted.submissionLeaf && remaining > 0; remaining -= 1) {
        const entry = await readingClient.request("session.history.entry", {
          sessionId: accepted.sessionId, runtimeGeneration: cut.runtimeGeneration, entryId,
        }) as unknown as { text: string; nextOffset?: number; metadata: { type: string; customType?: string; parentId: string | null } };
        if (!stillOwned()) return;
        if (entry.metadata.type === "custom" && entry.metadata.customType === INVOCATION_RECEIPT_TYPE && entry.nextOffset === undefined) {
          const receipt = parseInvocationReceipt(JSON.parse(entry.text));
          if (receipt?.sessionId === accepted.sessionId && receipt.operationId === accepted.operationId) {
            if (receipt.receiptKind === "terminal") { finish(); return; }
            if (receipt.receiptKind === "start") return;
          }
        }
        if (entry.metadata.parentId !== null && typeof entry.metadata.parentId !== "string") {
          throw new Error("Gateway returned an invalid invocation history parent");
        }
        entryId = entry.metadata.parentId ?? undefined;
      }
    })().catch(error => {
      if (acceptedOperation !== accepted || client !== readingClient) return;
      if (error instanceof GatewayClientError && error.retryable) void reconnect("resync-required");
      else accepted.fail(error);
    }).finally(() => {
      accepted.reading = undefined;
      if (acceptedOperation === accepted && snapshot !== cut) settleAcceptedOperation();
    });
  };
  const installSnapshot = (installed: SnapshotEnvelope): void => {
    snapshot = installed.session;
    subscriptionToken = installed.subscriptionToken;
    const current = assistantText(snapshot);
    const messageId = assistantMessageId(snapshot);
    const delta = sessionId === snapshot.sessionId
      ? renderDelta(rendered, current, messageId !== renderedMessageId)
      : current;
    sessionId = snapshot.sessionId;
    rendered = current;
    renderedMessageId = messageId;
    cursor = { runtimeGeneration: snapshot.runtimeGeneration, eventSequence: snapshot.eventSequence };
    attachListeners();
    if (delta) process.stdout.write(delta);
  };

  let unsubscribers: Array<() => void> = [];
  let reconnecting: Promise<void> | undefined;
  let reconnect: (reason?: "disconnected" | "resync-required" | "event-gap" | "command-recovery") => Promise<void>;
  const attachListeners = () => {
    unsubscribers.forEach((unsubscribe) => unsubscribe());
    unsubscribers = [
      client.onEvent((event) => {
        if (!sessionId || event.sessionId !== sessionId || !snapshot) return;
        if (event.topic === "transport.resyncRequired") {
          void reconnect("resync-required");
          return;
        }
        if (event.topic === "session.snapshot" || event.topic === "session.rebaseline") {
          const rebaseline = event.topic === "session.rebaseline"
            ? event.payload as unknown as { subscriptionToken: string; snapshot: SessionSnapshot }
            : undefined;
          // Queue coalescing replaces covered sequences with a token-bound
          // authoritative snapshot, not an ordinary sequenced event.
          if (rebaseline && rebaseline.subscriptionToken !== subscriptionToken) return;
          const next = rebaseline?.snapshot ?? event.payload as unknown as SessionSnapshot;
          if (next.runtimeGeneration === cursor.runtimeGeneration && next.eventSequence <= cursor.eventSequence) return;
          snapshot = next;
          cursor = { runtimeGeneration: snapshot.runtimeGeneration, eventSequence: snapshot.eventSequence };
        } else {
          const envelope = event.payload as unknown as SessionEventEnvelope;
          if (envelope.runtimeGeneration !== cursor.runtimeGeneration || envelope.eventSequence !== cursor.eventSequence + 1) {
            const topic = ["session.progress", "session.toolProgress", "session.configuration", "session.operationFailed",
              "session.retry", "session.diagnostic", "session.extensionError", "session.extensionActivity",
              "session.resourcesChanged", "session.structureChanged", "session.contextChanged", "session.rebaseline"].includes(event.topic)
              ? event.topic : "unknown";
            const received = Number.isSafeInteger(envelope.eventSequence) ? envelope.eventSequence : "unknown";
            process.stderr.write(`[Tron resync required: reason=event-gap topic=${topic} expected=${cursor.eventSequence + 1} received=${received}]\n`);
            void reconnect("event-gap");
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
        settleAcceptedOperation();
      }),
      client.onDisconnect(() => { void reconnect(); }),
    ];
  };
  reconnect = (reason = "disconnected"): Promise<void> => {
    reconnecting ??= (async () => {
      unsubscribers.forEach((unsubscribe) => unsubscribe());
      // Resync can replace a healthy transport too. Retire the connection and
      // all of its server-owned tokens before losing the only client reference.
      client.close();
      process.stderr.write(`\n[Tron disconnected; reconnecting…] reason=${reason}\n`);
      while (true) {
        client = new GatewayProtocolClient(socketURL, await readLocalCredential(tronHome));
        try {
          await connectResilient(client);
          if (sessionId) {
            await synchronizeTerminalSession(client, sessionId, installSnapshot);
          }
          attachListeners();
          process.stderr.write("[Tron synchronized]\n");
          settleAcceptedOperation();
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
  if (sessionId) {
    await synchronizeTerminalSession(client, sessionId, installSnapshot);
    process.stdout.write(`Attached to Tron session ${sessionId} (${snapshot!.cwd})\n`);
  } else if (logicalHome) {
    process.stdout.write("Attached to Tron Home (logical route; the next prompt activates its reserved chapter).\n");
    attachListeners();
  }

  const confirmedRequest = async (method: string, params: Record<string, JsonValue>, commandId: string): Promise<JsonValue> => {
    const submittedClient = client;
    try {
      return await submittedClient.request(method, params);
    } catch (error) {
      if (!(error instanceof GatewayClientError) || !error.retryable) throw error;
      const deadline = Date.now() + 90_000;
      let replayAllowed = false;
      let failedClient: GatewayProtocolClient | undefined = submittedClient;
      while (Date.now() < deadline) {
        // A disconnect listener may already have replaced the failed transport.
        // Join its recovery; never close the healthy successor to recover an
        // older connection's command receipt.
        if (reconnecting) await reconnecting;
        else if (client === failedClient) await reconnect("command-recovery");
        const recoveryClient = client;
        try {
          const status = await recoveryClient.request("command.status", { method, commandId }) as unknown as { status: string; result?: JsonValue };
          failedClient = undefined;
          if (status.status === "completed") return status.result ?? null;
          if (status.status === "missing") replayAllowed = true;
          if (replayAllowed) {
            try { return await recoveryClient.request(method, params); }
            catch (retry) {
              if (!(retry instanceof GatewayClientError) || !retry.retryable) throw retry;
              replayAllowed = false;
              failedClient = recoveryClient;
            }
          }
        } catch (statusError) {
          if (!(statusError instanceof GatewayClientError) || !statusError.retryable) throw statusError;
          failedClient = recoveryClient;
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
        if (sessionId) await client.request("session.abort", { sessionId, kind: "agent", commandId: randomUUID() });
        else process.stdout.write("No active Home chapter to abort.\n");
        continue;
      }
      // Home commands are Gateway-wide, not session-scoped, so they work before
      // or without an attached session's runtime being the Home one.
      if (await runHomeInput(client, prompt)) continue;
      const commandId = randomUUID();
      const submissionCut = snapshot;
      const method = logicalHome ? "home.prompt" : "session.prompt";
      let result: { operationId: string; sessionId?: string };
      if (logicalHome) {
        result = await confirmedRequest(method, { text: prompt, commandId }, commandId) as unknown as typeof result;
      } else {
        if (!sessionId) throw new Error("No terminal session is attached");
        result = await confirmedRequest(method, {
          sessionId,
          text: prompt,
          uploadIds: [],
          ...(snapshot?.phase === "idle" ? {} : { behavior: "followUp" }),
          commandId,
        }, commandId) as unknown as typeof result;
      }
      if (logicalHome && result.sessionId !== sessionId) {
        if (!result.sessionId) throw new Error("Home prompt returned no physical chapter identity");
        const previousSessionId = sessionId;
        const previousSubscriptionToken = subscriptionToken;
        const nextSessionId = result.sessionId;
        await synchronizeTerminalSession(client, nextSessionId, installSnapshot);
        if (previousSessionId && previousSubscriptionToken) {
          await client.request("session.close", {
            sessionId: previousSessionId, subscriptionToken: previousSubscriptionToken,
          }).catch(() => null);
        }
      }
      if (!sessionId) throw new Error("Accepted prompt returned no terminal session identity");
      // The command receipt identifies acceptance, never completion. Only this
      // exact physical chapter's canonical invocation terminal cut retires it,
      // even when reconnect recovered an outgoing idle chapter first.
      const operationSessionId = sessionId;
      const submissionLeaf = submissionCut?.sessionId === operationSessionId ? submissionCut.leafEntryId : undefined;
      await new Promise<void>((settle, fail) => {
        acceptedOperation = { sessionId: operationSessionId, operationId: result.operationId, submissionLeaf, settle, fail };
        settleAcceptedOperation();
      });
    }
  } finally {
    acceptedOperation = undefined;
    unsubscribers.forEach((unsubscribe) => unsubscribe());
    readline.close();
    if (sessionId && subscriptionToken) await client.request("session.close", { sessionId, subscriptionToken }).catch(() => null);
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
