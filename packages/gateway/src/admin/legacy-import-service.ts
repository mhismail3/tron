import { rm, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { isAbsolute, join } from "node:path";
import WebSocket from "ws";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import type { AssistantMessage, Usage } from "@earendil-works/pi-ai";
import { GatewayError } from "../errors.js";
import { readJson, updateJsonLocked } from "../util/json.js";

interface LegacySession {
  sessionId: string;
  model?: string;
  workingDirectory?: string;
  title?: string;
}
interface LegacyMessage {
  id: string;
  role: string;
  content: string;
  timestamp: string;
  toolInvocations?: unknown[];
}
interface ImportIndex { version: 1; sessions: Record<string, string> }

const SESSION_PAGE_LIMIT = 200;
const MAX_SESSION_PAGES = 20;
const MAX_SESSIONS = 500;
const HISTORY_PAGE_LIMIT = 500;
const MAX_HISTORY_PAGES = 25;
const MAX_HISTORY_MESSAGES = 10_000;
const MAX_HISTORY_BYTES = 32 * 1_024 * 1_024;
const MAX_TOOLS_PER_MESSAGE = 64;
const MAX_INDEX_SESSIONS = 10_000;
const MAX_INDEX_BYTES = 8 * 1_024 * 1_024;
const MAX_AUTH_BYTES = 64 * 1_024;
const MAX_TOKEN_BYTES = 4_096;
const MAX_ID_BYTES = 200;
const MAX_CURSOR_BYTES = 512;
const MAX_MODEL_BYTES = 200;
const MAX_PATH_BYTES = 4_096;
const MAX_TITLE_BYTES = 4_096;
const MAX_ROLE_BYTES = 64;
const MAX_TIMESTAMP_BYTES = 128;
const MAX_MESSAGE_BYTES = 256 * 1_024;
const MAX_TOOL_BYTES = 128 * 1_024;
const MAX_TOOLS_BYTES = 512 * 1_024;
const MAX_DYNAMIC_DEPTH = 20;
const MAX_DYNAMIC_NODES = 10_000;
const MAX_DYNAMIC_MEMBERS = 1_000;
const MAX_DYNAMIC_STRING_BYTES = 64 * 1_024;
const MAX_LEGACY_FRAME_BYTES = 32 * 1_024 * 1_024;
const CONNECT_TIMEOUT_MS = 10_000;
const REQUEST_TIMEOUT_MS = 30_000;

const zeroUsage: Usage = {
  input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
};

function malformed(message: string): never {
  throw new GatewayError("conflict", `Legacy import rejected malformed data: ${message}`);
}

function record(value: unknown, label: string): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) malformed(`${label} must be an object`);
  return value as Record<string, unknown>;
}

function boundedString(value: unknown, label: string, maximumBytes: number, allowEmpty = true): string {
  if (typeof value !== "string" || (!allowEmpty && value.trim().length === 0)
    || Buffer.byteLength(value, "utf8") > maximumBytes) {
    malformed(`${label} must be ${allowEmpty ? "a" : "a nonempty"} bounded string`);
  }
  return value;
}

function optionalBoundedString(value: unknown, label: string, maximumBytes: number): string | undefined {
  return value === undefined || value === null ? undefined : boundedString(value, label, maximumBytes);
}

function validateDynamicPayload(value: unknown, label: string): number {
  const pending: Array<{ value: unknown; depth: number }> = [{ value, depth: 0 }];
  let nodes = 0;
  while (pending.length > 0) {
    const current = pending.pop()!;
    nodes++;
    if (nodes > MAX_DYNAMIC_NODES) malformed(`${label} exceeds its dynamic node limit`);
    if (current.depth > MAX_DYNAMIC_DEPTH) malformed(`${label} exceeds its dynamic depth limit`);
    if (current.value === null || typeof current.value === "boolean") continue;
    if (typeof current.value === "number") {
      if (!Number.isFinite(current.value)) malformed(`${label} contains a non-finite number`);
      continue;
    }
    if (typeof current.value === "string") {
      if (Buffer.byteLength(current.value, "utf8") > MAX_DYNAMIC_STRING_BYTES) malformed(`${label} exceeds its dynamic string limit`);
      continue;
    }
    if (Array.isArray(current.value)) {
      if (current.value.length > MAX_DYNAMIC_MEMBERS) malformed(`${label} exceeds its dynamic collection limit`);
      for (const item of current.value) pending.push({ value: item, depth: current.depth + 1 });
      continue;
    }
    if (typeof current.value === "object") {
      const entries = Object.entries(current.value);
      if (entries.length > MAX_DYNAMIC_MEMBERS) malformed(`${label} exceeds its dynamic collection limit`);
      for (const [key, item] of entries) {
        if (Buffer.byteLength(key, "utf8") > MAX_DYNAMIC_STRING_BYTES) malformed(`${label} exceeds its dynamic key limit`);
        pending.push({ value: item, depth: current.depth + 1 });
      }
      continue;
    }
    malformed(`${label} is not JSON data`);
  }
  const encoded = JSON.stringify(value);
  if (encoded === undefined) malformed(`${label} is not JSON data`);
  return Buffer.byteLength(encoded, "utf8");
}

function parseSession(value: unknown, position: number): LegacySession {
  const source = record(value, `sessions[${position}]`);
  const model = optionalBoundedString(source.model, `sessions[${position}].model`, MAX_MODEL_BYTES);
  const workingDirectory = optionalBoundedString(source.workingDirectory, `sessions[${position}].workingDirectory`, MAX_PATH_BYTES);
  const title = optionalBoundedString(source.title, `sessions[${position}].title`, MAX_TITLE_BYTES);
  return {
    sessionId: boundedString(source.sessionId, `sessions[${position}].sessionId`, MAX_ID_BYTES, false),
    ...(model === undefined ? {} : { model }),
    ...(workingDirectory === undefined ? {} : { workingDirectory }),
    ...(title === undefined ? {} : { title }),
  };
}

function parseMessage(value: unknown, position: number): { message: LegacyMessage; bytes: number } {
  const source = record(value, `messages[${position}]`);
  const tools = source.toolInvocations;
  if (tools !== undefined && (!Array.isArray(tools) || tools.length > MAX_TOOLS_PER_MESSAGE)) {
    malformed(`messages[${position}].toolInvocations exceeds its item limit`);
  }
  let toolBytes = 0;
  for (const [toolIndex, tool] of (tools ?? []).entries()) {
    const bytes = validateDynamicPayload(tool, `messages[${position}].toolInvocations[${toolIndex}]`);
    if (bytes > MAX_TOOL_BYTES) malformed(`messages[${position}].toolInvocations[${toolIndex}] exceeds its byte limit`);
    toolBytes += bytes;
    if (toolBytes > MAX_TOOLS_BYTES) malformed(`messages[${position}].toolInvocations exceeds its byte limit`);
  }
  const message: LegacyMessage = {
    id: boundedString(source.id, `messages[${position}].id`, MAX_ID_BYTES, false),
    role: boundedString(source.role, `messages[${position}].role`, MAX_ROLE_BYTES, false),
    content: boundedString(source.content, `messages[${position}].content`, MAX_MESSAGE_BYTES),
    timestamp: boundedString(source.timestamp, `messages[${position}].timestamp`, MAX_TIMESTAMP_BYTES, false),
    ...(tools === undefined ? {} : { toolInvocations: tools }),
  };
  const bytes = toolBytes + Buffer.byteLength(message.id, "utf8") + Buffer.byteLength(message.role, "utf8")
    + Buffer.byteLength(message.content, "utf8") + Buffer.byteLength(message.timestamp, "utf8");
  return { message, bytes };
}

class LegacyClient {
  private socket?: WebSocket;
  private sequence = 0;
  private readonly pending = new Map<string, { resolve: (value: unknown) => void; reject: (error: Error) => void }>();

  constructor(private readonly port: number, private readonly token: string) {}

  async connect(): Promise<void> {
    this.socket = new WebSocket(`ws://127.0.0.1:${this.port}/engine`, {
      headers: { authorization: `Bearer ${this.token}` },
      maxPayload: MAX_LEGACY_FRAME_BYTES,
    });
    this.socket.on("message", (data) => this.receive(data.toString()));
    this.socket.on("close", () => this.rejectAll(new GatewayError("conflict", "The legacy Tron server disconnected", true)));
    this.socket.on("error", () => this.rejectAll(new GatewayError("conflict", "The legacy Tron server is not reachable", true)));
    await new Promise<void>((resolve, reject) => {
      const opened = (): void => settle(resolve);
      const failed = (): void => settle(() => reject(new GatewayError("conflict", "The legacy Tron server is not reachable", true)));
      const closed = (): void => settle(() => reject(new GatewayError("conflict", "The legacy Tron server disconnected during connection", true)));
      const timer = setTimeout(() => settle(() => reject(new GatewayError("conflict", "Legacy import connection timed out", true))), CONNECT_TIMEOUT_MS);
      timer.unref();
      const settle = (completion: () => void): void => {
        clearTimeout(timer);
        this.socket?.off("open", opened);
        this.socket?.off("error", failed);
        this.socket?.off("close", closed);
        completion();
      };
      this.socket!.once("open", opened);
      this.socket!.once("error", failed);
      this.socket!.once("close", closed);
    });
    await this.send(JSON.stringify({ type: "hello", id: "legacy-import-hello", protocolVersion: 1, clientName: "tron-gateway-importer", clientVersion: "1" }));
  }

  async invoke(functionId: string, payload: Record<string, unknown>): Promise<unknown> {
    const id = `legacy-import-${++this.sequence}`;
    const result = new Promise<unknown>((resolve, reject) => this.pending.set(id, { resolve, reject }));
    let timer: NodeJS.Timeout | undefined;
    try {
      await this.send(JSON.stringify({ type: "invoke", id, functionId, payload }));
      timer = setTimeout(() => this.pending.get(id)?.reject(new GatewayError("conflict", "Legacy import request timed out", true)), REQUEST_TIMEOUT_MS);
      timer.unref();
      return await result;
    } finally {
      if (timer) clearTimeout(timer);
      this.pending.delete(id);
    }
  }

  private async send(payload: string): Promise<void> {
    await new Promise<void>((resolve, reject) => {
      if (!this.socket) {
        reject(new GatewayError("conflict", "Legacy import socket is unavailable", true));
        return;
      }
      this.socket.send(payload, (error) => error
        ? reject(new GatewayError("conflict", "Legacy import request could not be sent", true))
        : resolve());
    });
  }

  close(): void { this.socket?.close(); this.rejectAll(new GatewayError("cancelled", "Legacy import ended")); }

  private receive(raw: string): void {
    let frame: Record<string, unknown>;
    try { frame = JSON.parse(raw) as Record<string, unknown>; } catch { return; }
    if (typeof frame.id !== "string") return;
    const pending = this.pending.get(frame.id);
    if (!pending) return;
    if (frame.ok === false || frame.error) {
      const error = frame.error as Record<string, unknown> | undefined;
      pending.reject(new GatewayError("conflict", typeof error?.message === "string" ? error.message : "Legacy import request failed"));
    } else pending.resolve(frame.result);
  }

  private rejectAll(error: Error): void {
    for (const pending of this.pending.values()) pending.reject(error);
    this.pending.clear();
  }
}

export class LegacyImportService {
  private readonly legacyAuthPath: string;
  private readonly indexPath: string;
  private importing = false;

  constructor(private readonly tronHome: string) {
    this.legacyAuthPath = join(tronHome, "auth.json");
    this.indexPath = join(tronHome, "gateway", "legacy-imports.json");
  }

  async inspect(): Promise<{ available: boolean; importedCount: number }> {
    const index = await this.readIndex();
    return { available: (await this.readLegacyToken()) !== undefined, importedCount: Object.keys(index.sessions).length };
  }

  async import(port: number): Promise<{ imported: number; skipped: number; sessionIds: string[] }> {
    if (port < 1 || port > 65_535) throw new GatewayError("invalid_request", "Legacy server port is invalid");
    if (this.importing) throw new GatewayError("busy", "A legacy import is already running", true);
    this.importing = true;
    let client: LegacyClient | undefined;
    try {
      const token = await this.readLegacyToken();
      if (!token) throw new GatewayError("not_found", "No secure legacy Tron credential was found");
      client = new LegacyClient(port, token);
      await client.connect();
      const legacySessions = await this.listSessions(client);
      const index = await this.readIndex();
      const pendingCount = legacySessions.reduce((count, session) => count + (index.sessions[session.sessionId] ? 0 : 1), 0);
      if (Object.keys(index.sessions).length + pendingCount > MAX_INDEX_SESSIONS) {
        throw new GatewayError("conflict", "Legacy import index exceeds its session limit");
      }

      const sessionIds: string[] = [];
      let skipped = 0;
      for (const legacy of legacySessions) {
        if (index.sessions[legacy.sessionId]) { skipped++; continue; }
        const messages = await this.history(client, legacy.sessionId);
        const cwd = legacy.workingDirectory && isAbsolute(legacy.workingDirectory) ? legacy.workingDirectory : homedir();
        const manager = SessionManager.create(cwd);
        const sessionFile = manager.getSessionFile();
        try {
          if (legacy.title) manager.appendSessionInfo(legacy.title);
          manager.appendCustomEntry("tron.legacy-import", { legacySessionId: legacy.sessionId, importedAt: new Date().toISOString() });
          for (const message of messages) this.appendMessage(manager, legacy, message);
          const canonicalId = boundedString(manager.getSessionId(), "canonical sessionId", MAX_ID_BYTES, false);
          await updateJsonLocked<ImportIndex>(this.indexPath, { version: 1, sessions: {} }, (current) => {
            this.validateIndex(current);
            if (Object.keys(current.sessions).length >= MAX_INDEX_SESSIONS) {
              throw new GatewayError("conflict", "Legacy import index exceeds its session limit");
            }
            return { version: 1, sessions: { ...current.sessions, [legacy.sessionId]: canonicalId } };
          }, MAX_INDEX_BYTES);
          index.sessions[legacy.sessionId] = canonicalId;
          sessionIds.push(canonicalId);
        } catch (error) {
          if (sessionFile) {
            try {
              await rm(sessionFile, { force: true });
            } catch (cleanupError) {
              throw new AggregateError([error, cleanupError], "Legacy import failed and its unindexed session file could not be removed");
            }
          }
          throw error;
        }
      }
      return { imported: sessionIds.length, skipped, sessionIds };
    } finally {
      client?.close();
      this.importing = false;
    }
  }

  private async listSessions(client: LegacyClient): Promise<LegacySession[]> {
    const all: LegacySession[] = [];
    const identities = new Set<string>();
    const cursors = new Set<string>();
    let cursor: string | undefined;
    for (let pageNumber = 0; pageNumber < MAX_SESSION_PAGES; pageNumber++) {
      const result = record(await client.invoke("session::list", { limit: SESSION_PAGE_LIMIT, cursor: cursor ?? null, includeArchived: true }), "session list response");
      const rawSessions = result.sessions ?? [];
      if (!Array.isArray(rawSessions) || rawSessions.length > SESSION_PAGE_LIMIT) malformed("session list page exceeds its item limit");
      if (all.length + rawSessions.length > MAX_SESSIONS) malformed("session list exceeds its total item limit");
      for (const raw of rawSessions) {
        const session = parseSession(raw, all.length);
        if (identities.has(session.sessionId)) malformed("session list contains duplicate session identities");
        identities.add(session.sessionId);
        all.push(session);
      }
      const nextCursor = optionalBoundedString(result.nextCursor, "session list nextCursor", MAX_CURSOR_BYTES);
      if (nextCursor === undefined) return all;
      if (nextCursor.length === 0 || nextCursor === cursor || cursors.has(nextCursor) || rawSessions.length === 0) {
        malformed("session list cursor did not make progress");
      }
      cursors.add(nextCursor);
      cursor = nextCursor;
    }
    malformed("session list exceeds its page limit");
  }

  private async history(client: LegacyClient, sessionId: string): Promise<LegacyMessage[]> {
    const pages: LegacyMessage[][] = [];
    const messageIds = new Set<string>();
    const cursors = new Set<string>();
    let beforeId: string | undefined;
    let messageCount = 0;
    let historyBytes = 0;
    for (let pageNumber = 0; pageNumber < MAX_HISTORY_PAGES; pageNumber++) {
      const result = record(await client.invoke("session::get_history", { sessionId, limit: HISTORY_PAGE_LIMIT, beforeId: beforeId ?? null }), "session history response");
      const rawMessages = result.messages ?? [];
      if (!Array.isArray(rawMessages) || rawMessages.length > HISTORY_PAGE_LIMIT) malformed("session history page exceeds its item limit");
      if (result.hasMore !== undefined && typeof result.hasMore !== "boolean") malformed("session history hasMore must be a boolean");
      if (messageCount + rawMessages.length > MAX_HISTORY_MESSAGES) malformed("session history exceeds its total message limit");
      const page: LegacyMessage[] = [];
      for (const [position, raw] of rawMessages.entries()) {
        const parsed = parseMessage(raw, messageCount + position);
        historyBytes += parsed.bytes;
        if (historyBytes > MAX_HISTORY_BYTES) malformed("session history exceeds its retained byte limit");
        if (messageIds.has(parsed.message.id)) malformed("session history contains duplicate message identities");
        messageIds.add(parsed.message.id);
        page.push(parsed.message);
      }
      messageCount += page.length;
      pages.unshift(page);
      if (result.hasMore !== true) return pages.flat();
      const nextBeforeId = page[0]?.id;
      if (!nextBeforeId || nextBeforeId === beforeId || cursors.has(nextBeforeId)) malformed("session history cursor did not make progress");
      cursors.add(nextBeforeId);
      beforeId = nextBeforeId;
    }
    malformed("session history exceeds its page limit");
  }

  private appendMessage(manager: SessionManager, session: LegacySession, message: LegacyMessage): void {
    const timestamp = Date.parse(message.timestamp) || Date.now();
    if (message.role === "user") manager.appendMessage({ role: "user", content: message.content, timestamp });
    else if (message.role === "assistant") {
      const assistant: AssistantMessage = {
        role: "assistant", content: [{ type: "text", text: message.content }], api: "openai-completions",
        provider: "legacy-tron", model: session.model ?? "unknown", usage: zeroUsage, stopReason: "stop", timestamp,
      };
      manager.appendMessage(assistant);
    } else manager.appendCustomMessageEntry("tron.legacy-message", message.content, true, { role: message.role, legacyMessageId: message.id });
    for (const invocation of message.toolInvocations ?? []) {
      manager.appendCustomEntry("tron.legacy-tool", { legacyMessageId: message.id, invocation });
    }
  }

  private async readIndex(): Promise<ImportIndex> {
    const index = await readJson<ImportIndex>(this.indexPath, { version: 1, sessions: {} }, MAX_INDEX_BYTES);
    this.validateIndex(index);
    return index;
  }

  private validateIndex(value: unknown): asserts value is ImportIndex {
    const index = record(value, "legacy import index");
    const sessions = record(index.sessions, "legacy import index sessions");
    if (index.version !== 1 || Object.keys(sessions).length > MAX_INDEX_SESSIONS) malformed("legacy import index is invalid or oversized");
    for (const [legacyId, canonicalId] of Object.entries(sessions)) {
      boundedString(legacyId, "legacy import index identity", MAX_ID_BYTES, false);
      boundedString(canonicalId, "legacy import index canonical identity", MAX_ID_BYTES, false);
    }
  }

  private async readLegacyToken(): Promise<string | undefined> {
    try {
      const metadata = await stat(this.legacyAuthPath);
      if ((metadata.mode & 0o077) !== 0) return undefined;
      const document = await readJson<{ bearerToken?: unknown }>(this.legacyAuthPath, {}, MAX_AUTH_BYTES);
      if (typeof document.bearerToken !== "string") return undefined;
      const token = document.bearerToken.trim();
      return token.length >= 32 && Buffer.byteLength(token, "utf8") <= MAX_TOKEN_BYTES ? token : undefined;
    } catch { return undefined; }
  }
}
