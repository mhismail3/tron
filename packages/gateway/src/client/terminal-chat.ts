#!/usr/bin/env node
import { randomUUID } from "node:crypto";
import { createInterface } from "node:readline/promises";
import { homedir } from "node:os";
import { resolveBindHost, resolveTronHome } from "../config.js";
import type { ContentPart, JsonValue, SessionSnapshot, TranscriptItem } from "../protocol/types.js";
import { GatewayClientError, GatewayProtocolClient } from "./gateway-client.js";
import { readLocalCredential } from "./local-credential.js";

interface SnapshotEnvelope { session: SessionSnapshot; syncToken: string; subscriptionToken: string; completionRevision?: number }
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

function assistantText(snapshot: SessionSnapshot): string {
  if (snapshot.streaming?.kind === "message" && snapshot.streaming.role === "assistant") {
    return text(snapshot.streaming.content);
  }
  const assistant = [...snapshot.transcript].reverse().find(
    (item): item is Extract<TranscriptItem, { kind: "message" }> => item.kind === "message" && item.role === "assistant",
  );
  return assistant ? text(assistant.content) : "";
}

interface SessionEventEnvelope {
  runtimeGeneration: string;
  eventSequence: number;
  revision: number;
  data: JsonValue;
}

function renderDelta(previous: string, current: string): string {
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

async function synchronize(client: GatewayProtocolClient, sessionId: string): Promise<SnapshotEnvelope> {
  const baseline = await client.request("session.open", { sessionId }) as unknown as SnapshotEnvelope;
  await client.request("session.sync", { sessionId, syncToken: baseline.syncToken });
  try {
    await client.request("session.attention.read", {
      sessionId,
      throughCompletionRevision: baseline.completionRevision ?? 0,
    });
  } catch (error) {
    if (!(error instanceof GatewayClientError)
      || !["unsupported", "not_found", "method_not_found"].includes(error.code)) throw error;
  }
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
  process.exit(64);
}

export function operationNeedsSettlement(
  operationId: string,
  reconciledSettledOperation: string | undefined,
): boolean {
  return operationId !== reconciledSettledOperation;
}

export async function runTerminalChat(): Promise<void> {
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

  let baseline = await synchronize(client, sessionId);
  let snapshot = baseline.session;
  let subscriptionToken = baseline.subscriptionToken;
  let rendered = assistantText(snapshot);
  let cursor = { runtimeGeneration: snapshot.runtimeGeneration, eventSequence: snapshot.eventSequence };
  let awaitingOperation: string | undefined;
  let reconciledSettledOperation: string | undefined;
  let pendingCommand: { method: string; commandId: string } | undefined;
  let settledResolve: (() => void) | undefined;
  process.stdout.write(`Attached to Tron session ${snapshot.sessionId} (${snapshot.cwd})\n`);

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
        const delta = renderDelta(rendered, current);
        if (delta) process.stdout.write(delta);
        rendered = current;
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
          baseline = await synchronize(client, sessionId);
          snapshot = baseline.session;
          subscriptionToken = baseline.subscriptionToken;
          cursor = { runtimeGeneration: snapshot.runtimeGeneration, eventSequence: snapshot.eventSequence };
          const current = assistantText(snapshot);
          const delta = renderDelta(rendered, current);
          if (awaitingOperation && delta) process.stdout.write(delta);
          rendered = current;
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
