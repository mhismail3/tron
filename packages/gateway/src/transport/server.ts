import { createServer, type IncomingMessage, type Server as HTTPServer, type ServerResponse } from "node:http";
import type { Duplex } from "node:stream";
import { randomUUID } from "node:crypto";
import { WebSocketServer, WebSocket } from "ws";
import { GatewayError, publicError } from "../errors.js";
import type { JsonValue } from "../protocol/types.js";
import type { DeviceStore } from "../security/device-store.js";
import { RateLimiter } from "../security/rate-limiter.js";
import type { UploadStore } from "../machine/upload-store.js";
import type { RuntimeRegistry } from "../sessions/runtime-registry.js";
import type { AuthBroker } from "../admin/auth-broker.js";
import type { GatewayLogger } from "./logger.js";
import { GatewayService, type ClientContext } from "./gateway-service.js";
import { MIN_PROTOCOL_VERSION, PROTOCOL_VERSION } from "../version.js";
import { SessionSyncBarrier, type BufferedSessionEvent } from "./session-sync.js";

export interface ActiveSessionSynchronization {
  barrier: SessionSyncBarrier;
  timeout: NodeJS.Timeout;
  requestId: string;
}

export function releaseOwnedSubscription(
  tokens: Map<string, string>,
  sessionId: string,
  token: string,
  release: () => void,
): boolean {
  if (tokens.get(sessionId) !== token) return false;
  tokens.delete(sessionId);
  release();
  return true;
}

export function releaseSessionTerminals(
  terminals: Set<string>,
  sessionId: string,
  belongsToSession: (terminalId: string, sessionId: string) => boolean,
): void {
  for (const terminalId of terminals) {
    if (belongsToSession(terminalId, sessionId)) terminals.delete(terminalId);
  }
}

export function canAttachTerminal(
  subscriptions: ReadonlySet<string>,
  terminalId: string,
  belongsToSession: (terminalId: string, sessionId: string) => boolean,
): boolean {
  return [...subscriptions].some((sessionId) => belongsToSession(terminalId, sessionId));
}

export function clearRequestSynchronizations(
  synchronizations: Map<string, ActiveSessionSynchronization>,
  requestId: string,
): void {
  for (const [sessionId, synchronization] of synchronizations) {
    if (synchronization.requestId !== requestId) continue;
    clearTimeout(synchronization.timeout);
    synchronizations.delete(sessionId);
  }
}

interface Connection {
  id: string;
  identity: string;
  isLocal: boolean;
  socket: WebSocket;
  alive: boolean;
  ready: boolean;
  subscriptions: Set<string>;
  terminals: Set<string>;
  inFlight: Set<string>;
  synchronizations: Map<string, ActiveSessionSynchronization>;
  subscriptionTokens: Map<string, string>;
  helloTimer: NodeJS.Timeout;
}

function bearer(request: IncomingMessage): string | undefined {
  const value = request.headers.authorization;
  if (!value?.startsWith("Bearer ")) return undefined;
  return value.slice(7);
}

function sendJson(response: ServerResponse, status: number, value: unknown): void {
  const data = Buffer.from(JSON.stringify(value));
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": data.length,
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
  });
  response.end(data);
}

export function encodeOutboundFrame(value: unknown, maximum: number): string | undefined {
  const encoded = JSON.stringify(value);
  const bytes = Buffer.byteLength(encoded);
  if (bytes <= maximum) return encoded;
  const frame = typeof value === "object" && value !== null ? value as Record<string, unknown> : {};
  const replacement = frame.type === "response" && typeof frame.id === "string"
    ? {
        type: "response",
        id: frame.id,
        ok: false,
        error: {
          code: "response_too_large",
          message: "This response is too large for the mobile connection. Refresh and try a narrower view.",
          retryable: false,
          details: { bytes, maximum },
        },
      }
    : {
        type: "event",
        topic: "transport.resyncRequired",
        ...(typeof frame.sessionId === "string" ? { sessionId: frame.sessionId } : {}),
        payload: { reason: "oversized projection", bytes, maximum },
      };
  const fallback = JSON.stringify(replacement);
  return Buffer.byteLength(fallback) <= maximum ? fallback : undefined;
}

async function readBody(request: IncomingMessage, maximum: number): Promise<Buffer> {
  const declared = Number(request.headers["content-length"] ?? 0);
  if (declared > maximum) throw new GatewayError("invalid_request", "Request body is too large");
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const value of request) {
    const chunk = Buffer.isBuffer(value) ? value : Buffer.from(value);
    size += chunk.length;
    if (size > maximum) throw new GatewayError("invalid_request", "Request body is too large");
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

export class GatewayServer {
  private readonly server: HTTPServer;
  private readonly sockets: WebSocketServer;
  private readonly clients = new Map<string, Connection>();
  private readonly pairingLimiter = new RateLimiter(10, 10 * 60_000);
  private readonly heartbeat: NodeJS.Timeout;
  private shuttingDown = false;

  constructor(
    private readonly options: {
      host: string;
      port: number;
      maxFrameBytes: number;
      maxUploadBytes: number;
      devices: DeviceStore;
      uploads: UploadStore;
      sessions: RuntimeRegistry;
      auth: AuthBroker;
      service: GatewayService;
      logger: GatewayLogger;
    },
  ) {
    this.server = createServer((request, response) => void this.handleHttp(request, response));
    this.sockets = new WebSocketServer({ noServer: true, maxPayload: options.maxFrameBytes, perMessageDeflate: false });
    this.server.on("upgrade", (request, socket, head) => void this.handleUpgrade(request, socket, head));
    this.heartbeat = setInterval(() => {
      for (const connection of this.clients.values()) {
        if (connection.socket.readyState !== WebSocket.OPEN) continue;
        if (!connection.alive) {
          connection.socket.terminate();
          continue;
        }
        connection.alive = false;
        connection.socket.ping();
      }
    }, 25_000);
    this.heartbeat.unref();
  }

  async listen(): Promise<void> {
    await new Promise<void>((resolve, reject) => {
      this.server.once("error", reject);
      this.server.listen(this.options.port, this.options.host, () => {
        this.server.off("error", reject);
        resolve();
      });
    });
    this.options.logger.log("info", `Gateway listening on ${this.options.host}:${this.options.port}`);
  }

  broadcastSession(sessionId: string, topic: string, payload: JsonValue): void {
    const event: BufferedSessionEvent = { type: "event", topic, sessionId, payload };
    for (const client of this.clients.values()) {
      if (!client.ready || !client.subscriptions.has(sessionId)) continue;
      const deliverable = client.synchronizations.get(sessionId)?.barrier.offer(event) ?? event;
      if (deliverable) this.send(client, deliverable);
    }
  }

  broadcast(topic: string, payload: JsonValue): void {
    for (const client of this.clients.values()) {
      if (client.ready) this.send(client, { type: "event", topic, payload });
    }
  }

  emitToClient(clientId: string, topic: string, payload: JsonValue): void {
    const client = this.clients.get(clientId);
    if (client?.ready) this.send(client, { type: "event", topic, payload });
  }

  broadcastTerminal(terminalId: string, topic: string, payload: JsonValue): void {
    for (const client of this.clients.values()) {
      if (client.ready && client.terminals.has(terminalId)) this.send(client, { type: "event", topic, payload });
    }
  }

  notifySessionListChanged(): void {
    this.broadcast("session.listChanged", {});
  }

  disconnectDevice(deviceId: string): void {
    const timer = setTimeout(() => {
      for (const client of this.clients.values()) {
        if (!client.isLocal && client.identity === deviceId) client.socket.close(1008, "device revoked");
      }
    }, 100);
    timer.unref();
  }

  private async handleHttp(request: IncomingMessage, response: ServerResponse): Promise<void> {
    try {
      const url = new URL(request.url ?? "/", `http://${request.headers.host ?? "localhost"}`);
      if (request.method === "GET" && url.pathname === "/health") {
        const info = this.options.service.info() as Record<string, JsonValue>;
        return sendJson(response, this.shuttingDown ? 503 : 200, {
          status: this.shuttingDown ? "stopping" : "ok",
          gatewayVersion: info.gatewayVersion,
          protocolVersion: info.protocolVersion,
          minProtocolVersion: info.minProtocolVersion,
        });
      }
      if (request.method === "POST" && url.pathname === "/v1/pair") {
        const key = request.socket.remoteAddress ?? "unknown";
        if (!this.pairingLimiter.admit(key)) throw new GatewayError("unauthenticated", "Too many pairing attempts; wait before retrying");
        const body = JSON.parse((await readBody(request, 16_384)).toString("utf8")) as Record<string, unknown>;
        if (typeof body.code !== "string" || typeof body.deviceName !== "string") throw new GatewayError("invalid_request", "Pairing requires code and deviceName");
        const result = await this.options.devices.pair(body.code.trim(), body.deviceName);
        return sendJson(response, 200, { ...result, ...this.options.service.info() as Record<string, JsonValue> });
      }

      const authenticated = await this.options.devices.authenticate(bearer(request));
      if (!authenticated) return sendJson(response, 401, { error: { code: "unauthenticated", message: "Pairing token is invalid" } });

      if (request.method === "POST" && url.pathname === "/v1/uploads") {
        const name = url.searchParams.get("name") ?? "attachment";
        const mimeType = request.headers["content-type"] ?? "application/octet-stream";
        const upload = await this.options.uploads.save(name, mimeType, await readBody(request, this.options.maxUploadBytes));
        return sendJson(response, 201, { upload: { id: upload.id, name: upload.name, mimeType: upload.mimeType, size: upload.size } });
      }
      if (request.method === "GET" && url.pathname.startsWith("/v1/blobs/")) {
        const id = decodeURIComponent(url.pathname.slice("/v1/blobs/".length));
        const blob = this.options.sessions.getBlob(id);
        response.writeHead(200, {
          "content-type": blob.mimeType,
          "content-length": blob.data.length,
          "cache-control": "private, max-age=300",
          "x-content-type-options": "nosniff",
        });
        response.end(blob.data);
        return;
      }
      sendJson(response, 404, { error: { code: "not_found", message: "Route not found" } });
    } catch (error) {
      const failure = publicError(error);
      const status = failure.code === "unauthenticated" ? 401 : failure.code === "not_found" ? 404 : failure.code === "invalid_request" ? 400 : 500;
      sendJson(response, status, { error: failure });
    }
  }

  private async handleUpgrade(request: IncomingMessage, socket: Duplex, head: Buffer): Promise<void> {
    try {
      const url = new URL(request.url ?? "/", `http://${request.headers.host ?? "localhost"}`);
      if (url.pathname !== "/v1/socket") {
        socket.destroy();
        return;
      }
      const authenticated = await this.options.devices.authenticate(bearer(request));
      if (!authenticated || this.shuttingDown) {
        socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n");
        socket.destroy();
        return;
      }
      this.sockets.handleUpgrade(request, socket, head, (webSocket) => {
        this.admit(webSocket, authenticated.kind === "local" ? "local-wrapper" : authenticated.device.id, authenticated.kind === "local");
      });
    } catch {
      socket.destroy();
    }
  }

  private admit(socket: WebSocket, identity: string, isLocal: boolean): void {
    const connection: Connection = {
      id: randomUUID(),
      identity,
      isLocal,
      socket,
      alive: true,
      ready: false,
      subscriptions: new Set(),
      terminals: new Set(),
      inFlight: new Set(),
      synchronizations: new Map(),
      subscriptionTokens: new Map(),
      helloTimer: setTimeout(() => socket.close(1008, "hello required"), 5_000),
    };
    this.clients.set(connection.id, connection);
    socket.on("message", (data, binary) => {
      connection.alive = true;
      void this.onMessage(connection, binary ? data : data.toString());
    });
    socket.on("pong", () => { connection.alive = true; });
    socket.on("close", () => this.disconnect(connection));
    socket.on("error", () => this.disconnect(connection));
  }

  private async onMessage(connection: Connection, raw: unknown): Promise<void> {
    let frame: Record<string, unknown>;
    try {
      const text = typeof raw === "string" ? raw : Buffer.from(raw as ArrayBuffer).toString("utf8");
      frame = JSON.parse(text) as Record<string, unknown>;
      if (typeof frame !== "object" || frame === null || Array.isArray(frame)) throw new Error();
    } catch {
      return connection.socket.close(1007, "invalid JSON");
    }

    if (!connection.ready) {
      if (frame.type !== "hello" || !Number.isSafeInteger(frame.protocolVersion)) return connection.socket.close(1008, "valid hello required");
      const protocol = frame.protocolVersion as number;
      if (protocol < MIN_PROTOCOL_VERSION || protocol > PROTOCOL_VERSION) return connection.socket.close(1008, "protocol version mismatch");
      connection.ready = true;
      clearTimeout(connection.helloTimer);
      this.send(connection, { type: "hello", ...this.options.service.info() as Record<string, JsonValue> });
      return;
    }

    if (frame.type !== "request" || typeof frame.id !== "string" || typeof frame.method !== "string") {
      this.send(connection, { type: "response", id: typeof frame.id === "string" ? frame.id : "invalid", ok: false, error: publicError(new GatewayError("invalid_request", "Malformed request envelope")) });
      return;
    }
    if (frame.id.length > 160 || frame.method.length > 160 || connection.inFlight.has(frame.id)) {
      this.send(connection, { type: "response", id: frame.id, ok: false, error: publicError(new GatewayError("invalid_request", "Invalid or duplicate request id")) });
      return;
    }
    if (connection.inFlight.size >= 32) {
      this.send(connection, { type: "response", id: frame.id, ok: false, error: publicError(new GatewayError("busy", "Too many concurrent requests", true)) });
      return;
    }
    connection.inFlight.add(frame.id);
    const requestId = frame.id;
    const synchronizationCompletions: Array<{ sessionId: string; syncToken: string }> = [];
    try {
      const context: ClientContext = {
        id: connection.id,
        identity: connection.identity,
        isLocal: connection.isLocal,
        beginSynchronization: (sessionId) => {
          const previous = connection.synchronizations.get(sessionId);
          if (previous) {
            clearTimeout(previous.timeout);
            connection.synchronizations.delete(sessionId);
          }
          connection.subscriptions.add(sessionId);
          this.options.sessions.subscribe(connection.id, sessionId);
          const syncToken = randomUUID();
          connection.subscriptionTokens.set(sessionId, syncToken);
          const barrier = new SessionSyncBarrier();
          barrier.begin(syncToken);
          const timeout = setTimeout(() => {
            const active = connection.synchronizations.get(sessionId);
            if (active?.barrier !== barrier) return;
            connection.synchronizations.delete(sessionId);
            this.send(connection, {
              type: "event",
              topic: "transport.resyncRequired",
              sessionId,
              payload: { reason: "subscription synchronization timed out" },
            });
          }, 30_000);
          timeout.unref();
          connection.synchronizations.set(sessionId, { barrier, timeout, requestId });
          return syncToken;
        },
        establishSynchronization: (sessionId, snapshot) => {
          const active = connection.synchronizations.get(sessionId);
          if (!active) throw new GatewayError("conflict", "Session synchronization was not established before snapshot capture");
          active.barrier.establish(snapshot);
        },
        completeSynchronization: (sessionId, syncToken) => {
          if (!connection.synchronizations.has(sessionId)) {
            throw new GatewayError("conflict", "Session synchronization is no longer active", true);
          }
          synchronizationCompletions.push({ sessionId, syncToken });
        },
        unsubscribe: (sessionId, subscriptionToken) => {
          if (subscriptionToken !== undefined) {
            return releaseOwnedSubscription(connection.subscriptionTokens, sessionId, subscriptionToken, () => {
              connection.subscriptions.delete(sessionId);
              releaseSessionTerminals(
                connection.terminals,
                sessionId,
                (terminalId, ownerSessionId) => this.options.service.terminalBelongsToSession(terminalId, ownerSessionId),
              );
              const synchronization = connection.synchronizations.get(sessionId);
              if (synchronization) clearTimeout(synchronization.timeout);
              connection.synchronizations.delete(sessionId);
              this.options.sessions.unsubscribe(connection.id, sessionId);
            });
          }
          connection.subscriptionTokens.delete(sessionId);
          connection.subscriptions.delete(sessionId);
          releaseSessionTerminals(
            connection.terminals,
            sessionId,
            (terminalId, ownerSessionId) => this.options.service.terminalBelongsToSession(terminalId, ownerSessionId),
          );
          const synchronization = connection.synchronizations.get(sessionId);
          if (synchronization) clearTimeout(synchronization.timeout);
          connection.synchronizations.delete(sessionId);
          this.options.sessions.unsubscribe(connection.id, sessionId);
          return true;
        },
        attachTerminal: (terminalId) => {
          if (!canAttachTerminal(
            connection.subscriptions,
            terminalId,
            (id, sessionId) => this.options.service.terminalBelongsToSession(id, sessionId),
          )) {
            throw new GatewayError("invalid_request", "Open the terminal's session before attaching", false);
          }
          connection.terminals.add(terminalId);
        },
        detachTerminal: (terminalId) => connection.terminals.delete(terminalId),
        ownsTerminal: (terminalId) => connection.terminals.has(terminalId),
      };
      const result = await this.options.service.invoke(context, frame.method, frame.params ?? {});
      const responseSentIntact = this.send(connection, { type: "response", id: frame.id, ok: true, result });
      if (!responseSentIntact) clearRequestSynchronizations(connection.synchronizations, requestId);
      // The acknowledgement is enqueued before the barrier is removed. Because
      // this block is synchronous, no newer broadcast can overtake the buffered
      // catch-up on the WebSocket.
      for (const completion of synchronizationCompletions) {
        const active = connection.synchronizations.get(completion.sessionId);
        if (!active) continue;
        const completed = active.barrier.commit(completion.syncToken);
        clearTimeout(active.timeout);
        connection.synchronizations.delete(completion.sessionId);
        if (completed.overflowed) {
          this.send(connection, {
            type: "event",
            topic: "transport.resyncRequired",
            sessionId: completion.sessionId,
            payload: { reason: "subscription catch-up overflow" },
          });
        } else {
          for (const event of completed.events) this.send(connection, event);
        }
      }
    } catch (error) {
      clearRequestSynchronizations(connection.synchronizations, requestId);
      this.send(connection, { type: "response", id: frame.id, ok: false, error: publicError(error) });
    } finally {
      connection.inFlight.delete(frame.id);
    }
  }

  private send(connection: Connection, value: unknown): boolean {
    if (connection.socket.readyState !== WebSocket.OPEN) return false;
    const direct = JSON.stringify(value);
    if (Buffer.byteLength(direct) <= this.options.maxFrameBytes) {
      connection.socket.send(direct);
      return true;
    }
    const encoded = encodeOutboundFrame(value, this.options.maxFrameBytes);
    if (!encoded) return false;
    connection.socket.send(encoded);
    return false;
  }

  private disconnect(connection: Connection): void {
    if (!this.clients.delete(connection.id)) return;
    clearTimeout(connection.helloTimer);
    for (const synchronization of connection.synchronizations.values()) clearTimeout(synchronization.timeout);
    connection.synchronizations.clear();
    this.options.sessions.unsubscribeClient(connection.id);
    this.options.service.releaseClient(connection.id);
    this.options.auth.cancelClient(connection.id);
  }

  async close(): Promise<void> {
    if (this.shuttingDown) return;
    this.shuttingDown = true;
    clearInterval(this.heartbeat);
    for (const client of this.clients.values()) {
      this.send(client, { type: "event", topic: "system.stopping", payload: {} });
      client.socket.close(1012, "gateway restarting");
    }
    await new Promise<void>((resolve) => this.server.close(() => resolve()));
    this.sockets.close();
  }
}
