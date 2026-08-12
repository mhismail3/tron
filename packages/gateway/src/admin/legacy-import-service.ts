import { stat } from "node:fs/promises";
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

const zeroUsage: Usage = {
  input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
};

class LegacyClient {
  private socket?: WebSocket;
  private sequence = 0;
  private readonly pending = new Map<string, { resolve: (value: unknown) => void; reject: (error: Error) => void }>();

  constructor(private readonly port: number, private readonly token: string) {}

  async connect(): Promise<void> {
    this.socket = new WebSocket(`ws://127.0.0.1:${this.port}/engine`, { headers: { authorization: `Bearer ${this.token}` } });
    this.socket.on("message", (data) => this.receive(data.toString()));
    this.socket.on("close", () => this.rejectAll(new GatewayError("conflict", "The legacy Tron server disconnected", true)));
    this.socket.on("error", () => this.rejectAll(new GatewayError("conflict", "The legacy Tron server is not reachable", true)));
    await new Promise<void>((resolve, reject) => {
      this.socket!.once("open", resolve);
      this.socket!.once("error", reject);
    });
    this.socket.send(JSON.stringify({ type: "hello", id: "legacy-import-hello", protocolVersion: 1, clientName: "tron-gateway-importer", clientVersion: "1" }));
  }

  async invoke(functionId: string, payload: Record<string, unknown>): Promise<unknown> {
    const id = `legacy-import-${++this.sequence}`;
    const result = new Promise<unknown>((resolve, reject) => this.pending.set(id, { resolve, reject }));
    this.socket?.send(JSON.stringify({ type: "invoke", id, functionId, payload }));
    const timer = setTimeout(() => this.pending.get(id)?.reject(new GatewayError("conflict", "Legacy import request timed out", true)), 30_000);
    timer.unref();
    try { return await result; } finally { clearTimeout(timer); this.pending.delete(id); }
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

  constructor(private readonly tronHome: string) {
    this.legacyAuthPath = join(tronHome, "auth.json");
    this.indexPath = join(tronHome, "gateway", "legacy-imports.json");
  }

  async inspect(): Promise<{ available: boolean; importedCount: number }> {
    const index = await readJson<ImportIndex>(this.indexPath, { version: 1, sessions: {} });
    return { available: (await this.readLegacyToken()) !== undefined, importedCount: Object.keys(index.sessions).length };
  }

  async import(port: number): Promise<{ imported: number; skipped: number; sessionIds: string[] }> {
    if (port < 1 || port > 65_535) throw new GatewayError("invalid_request", "Legacy server port is invalid");
    const token = await this.readLegacyToken();
    if (!token) throw new GatewayError("not_found", "No secure legacy Tron credential was found");
    const client = new LegacyClient(port, token);
    await client.connect();
    try {
      const legacySessions = await this.listSessions(client);
      const index = await readJson<ImportIndex>(this.indexPath, { version: 1, sessions: {} });
      const imported: Record<string, string> = {};
      let skipped = 0;
      for (const legacy of legacySessions) {
        if (index.sessions[legacy.sessionId]) { skipped++; continue; }
        const messages = await this.history(client, legacy.sessionId);
        const cwd = legacy.workingDirectory && isAbsolute(legacy.workingDirectory) ? legacy.workingDirectory : homedir();
        const manager = SessionManager.create(cwd);
        if (legacy.title) manager.appendSessionInfo(legacy.title);
        manager.appendCustomEntry("tron.legacy-import", { legacySessionId: legacy.sessionId, importedAt: new Date().toISOString() });
        for (const message of messages) this.appendMessage(manager, legacy, message);
        imported[legacy.sessionId] = manager.getSessionId();
      }
      if (Object.keys(imported).length > 0) {
        await updateJsonLocked<ImportIndex>(this.indexPath, { version: 1, sessions: {} }, (current) => ({
          version: 1,
          sessions: { ...current.sessions, ...imported },
        }));
      }
      return { imported: Object.keys(imported).length, skipped, sessionIds: Object.values(imported) };
    } finally { client.close(); }
  }

  private async listSessions(client: LegacyClient): Promise<LegacySession[]> {
    const all: LegacySession[] = [];
    let cursor: string | undefined;
    do {
      const result = await client.invoke("session::list", { limit: 200, cursor: cursor ?? null, includeArchived: true }) as { sessions?: LegacySession[]; nextCursor?: string };
      all.push(...(result.sessions ?? []));
      cursor = result.nextCursor;
    } while (cursor);
    return all;
  }

  private async history(client: LegacyClient, sessionId: string): Promise<LegacyMessage[]> {
    const pages: LegacyMessage[][] = [];
    let beforeId: string | undefined;
    for (;;) {
      const result = await client.invoke("session::get_history", { sessionId, limit: 500, beforeId: beforeId ?? null }) as { messages?: LegacyMessage[]; hasMore?: boolean };
      const page = result.messages ?? [];
      pages.unshift(page);
      if (!result.hasMore || page.length === 0) break;
      beforeId = page[0]?.id;
    }
    return pages.flat();
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

  private async readLegacyToken(): Promise<string | undefined> {
    try {
      const metadata = await stat(this.legacyAuthPath);
      if ((metadata.mode & 0o077) !== 0) return undefined;
      const document = await readJson<{ bearerToken?: string }>(this.legacyAuthPath, {});
      const token = document.bearerToken?.trim();
      return token && token.length >= 32 ? token : undefined;
    } catch { return undefined; }
  }
}
