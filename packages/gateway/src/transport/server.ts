import { createServer, type IncomingMessage, type Server as HTTPServer, type ServerResponse } from "node:http";
import type { Duplex } from "node:stream";
import { pipeline } from "node:stream/promises";
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

// Retain only recent former IDs while an active subscription is rekeyed. Older
// IDs are stale control paths and may safely require a fresh session.open.
export const MAXIMUM_REKEYED_SESSION_IDS = 64;

export interface ActiveSessionSynchronization {
  barrier: SessionSyncBarrier;
  timeout: NodeJS.Timeout;
  requestId: string;
  subscriptionToken: string;
  /** Updated if its canonical session forks while acknowledgement is pending. */
  sessionId: string;
}

interface SynchronizationCompletion {
  sessionId: string;
  syncToken: string;
  requestId: string;
  subscriptionToken: string;
}

type SynchronizationOwner = SynchronizationCompletion;

export function existingSessionOpenOwner(
  pendingSessionOpens: ReadonlyMap<string, string>,
  synchronizations: ReadonlyMap<string, ActiveSessionSynchronization>,
  subscriptionTokens: ReadonlyMap<string, string>,
  sessionId: string,
): string | undefined {
  // Only genuinely in-flight opens are rejected. An installed subscription is
  // not an open owner: beginSynchronization replaces it deterministically so
  // reconnecting clients always converge instead of deadlocking on conflict.
  void subscriptionTokens;
  return pendingSessionOpens.get(sessionId)
    ?? synchronizations.get(sessionId)?.requestId;
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
  revoke?: (sessionId: string, synchronization: ActiveSessionSynchronization) => void,
): void {
  for (const [sessionId, synchronization] of synchronizations) {
    if (synchronization.requestId !== requestId) continue;
    clearTimeout(synchronization.timeout);
    revoke?.(sessionId, synchronization);
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
  presentationOnly: boolean;
  subscriptions: Set<string>;
  terminals: Set<string>;
  inFlight: Set<string>;
  synchronizations: Map<string, ActiveSessionSynchronization>;
  subscriptionTokens: Map<string, string>;
  // A fork may occur after session.open but before session.sync. Retain the
  // former ID only while its carried subscription remains current.
  rekeyedSessionIds: Map<string, string>;
  synchronizationBytes: number;
  // Reserved before asynchronous service invocation so overlapping opens for
  // the same connection/session are rejected deterministically.
  pendingSessionOpens: Map<string, string>;
  outboundFrames: number;
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

async function* completeRequestBody(request: IncomingMessage): AsyncGenerator<Buffer> {
  for await (const value of request) {
    yield Buffer.isBuffer(value) ? value : Buffer.from(value);
  }
  if (request.aborted || !request.complete) {
    throw new GatewayError("invalid_request", "Request body ended before it was complete");
  }
}

async function readBoundedBody(request: IncomingMessage, maximum: number): Promise<Buffer> {
  const rawDeclared = request.headers["content-length"];
  const declared = rawDeclared === undefined ? undefined : Number(rawDeclared);
  if (declared !== undefined
    && (!Number.isSafeInteger(declared) || declared < 0 || declared > maximum)) {
    throw new GatewayError("invalid_request", "Request body is too large");
  }
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of completeRequestBody(request)) {
    size += chunk.length;
    if (size > maximum) throw new GatewayError("invalid_request", "Request body is too large");
    chunks.push(chunk);
  }
  if (declared !== undefined && size !== declared) {
    throw new GatewayError("invalid_request", "Request body size did not match Content-Length");
  }
  return Buffer.concat(chunks);
}

export class GatewayServer {
  private readonly server: HTTPServer;
  private readonly sockets: WebSocketServer;
  private readonly clients = new Map<string, Connection>();
  private readonly pairingLimiter = new RateLimiter(10, 10 * 60_000);
  private readonly heartbeat: NodeJS.Timeout;
  private ready = false;
  private shuttingDown = false;

  constructor(
    private readonly options: {
      host: string;
      port: number;
      maxFrameBytes: number;
      maximumConnections?: number;
      maximumConnectionsPerIdentity?: number;
      maximumSubscriptionsPerConnection?: number;
      maximumOutboundFrames?: number;
      maximumOutboundBytes?: number;
      maximumSynchronizationBytes?: number;
      synchronizationTimeoutMs?: number;
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

  async listen(afterBind: () => Promise<void> = async () => {}): Promise<void> {
    await new Promise<void>((resolve, reject) => {
      this.server.once("error", reject);
      this.server.listen(this.options.port, this.options.host, () => {
        this.server.off("error", reject);
        resolve();
      });
    });
    try {
      await afterBind();
      this.ready = true;
    } catch (error) {
      await new Promise<void>((resolve) => this.server.close(() => resolve()));
      throw error;
    }
    this.options.logger.log("info", `Gateway listening on ${this.options.host}:${this.options.port}`, { event: "gateway.listening", source: "transport" });
  }

  /** Move connection-local ownership with the registry's canonical rekey. */
  rekeySession(previousSessionId: string, nextSessionId: string): void {
    if (previousSessionId === nextSessionId) return;
    for (const connection of this.clients.values()) {
      const sourceSynchronization = connection.synchronizations.get(previousSessionId);
      const sourceToken = connection.subscriptionTokens.get(previousSessionId);
      const sourceSubscribed = connection.subscriptions.has(previousSessionId);
      if (!sourceSynchronization && sourceToken === undefined && !sourceSubscribed) continue;

      // A destination owner can only be stale here: RuntimeRegistry prevents
      // two live slots from owning the replacement ID. Retire it locally
      // without unsubscribing the merged registry subscriber set.
      const destinationSynchronization = connection.synchronizations.get(nextSessionId);
      if (destinationSynchronization && destinationSynchronization !== sourceSynchronization) {
        clearTimeout(destinationSynchronization.timeout);
        destinationSynchronization.barrier.abort(destinationSynchronization.requestId);
        connection.synchronizations.delete(nextSessionId);
      }
      connection.subscriptionTokens.delete(nextSessionId);
      releaseSessionTerminals(
        connection.terminals,
        nextSessionId,
        (terminalId, ownerSessionId) => this.options.service.terminalBelongsToSession(terminalId, ownerSessionId),
      );

      connection.subscriptions.delete(previousSessionId);
      connection.subscriptionTokens.delete(previousSessionId);
      connection.synchronizations.delete(previousSessionId);
      releaseSessionTerminals(
        connection.terminals,
        previousSessionId,
        (terminalId, ownerSessionId) => this.options.service.terminalBelongsToSession(terminalId, ownerSessionId),
      );
      connection.subscriptions.add(nextSessionId);
      if (sourceToken !== undefined) connection.subscriptionTokens.set(nextSessionId, sourceToken);
      if (sourceSynchronization) {
        sourceSynchronization.sessionId = nextSessionId;
        connection.synchronizations.set(nextSessionId, sourceSynchronization);
      }
      for (const [former, current] of connection.rekeyedSessionIds) {
        if (current === previousSessionId) connection.rekeyedSessionIds.set(former, nextSessionId);
      }
      connection.rekeyedSessionIds.set(previousSessionId, nextSessionId);
      while (connection.rekeyedSessionIds.size > MAXIMUM_REKEYED_SESSION_IDS) {
        const oldest = connection.rekeyedSessionIds.keys().next().value;
        if (oldest === undefined) break;
        connection.rekeyedSessionIds.delete(oldest);
      }
    }
  }

  broadcastSession(sessionId: string, topic: string, payload: JsonValue): void {
    const event: BufferedSessionEvent = { type: "event", topic, sessionId, payload };
    for (const client of this.clients.values()) {
      if (!client.ready || !client.subscriptions.has(sessionId)) continue;
      // While a synchronization quarantine owns this session's catch-up, its
      // barrier is the only delivery path: the event is flushed exactly once
      // after the acknowledgement. Sending it here as well would deliver every
      // in-window event twice and break the client's contiguous replay.
      const barrier = client.synchronizations.get(sessionId)?.barrier;
      const deliverable = barrier ? barrier.offer(event) : event;
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

  revokeSessionTerminals(sessionId: string): void {
    for (const client of this.clients.values()) {
      releaseSessionTerminals(
        client.terminals,
        sessionId,
        (terminalId, ownerSessionId) => this.options.service.terminalBelongsToSession(terminalId, ownerSessionId),
      );
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
      if (!this.ready) {
        const info = this.options.service.info() as Record<string, JsonValue>;
        if (request.method === "GET" && url.pathname === "/health") {
          return sendJson(response, 503, {
            status: "starting",
            gatewayVersion: info.gatewayVersion,
            protocolVersion: info.protocolVersion,
            minProtocolVersion: info.minProtocolVersion,
            ...(typeof info.sourceRevision === "string" ? { sourceRevision: info.sourceRevision } : {}),
            ...(typeof info.buildFingerprint === "string" ? { buildFingerprint: info.buildFingerprint } : {}),
            ...(typeof info.runtimeEpoch === "string" ? { runtimeEpoch: info.runtimeEpoch } : {}),
          });
        }
        return sendJson(response, 503, { error: { code: "busy", message: "Gateway is starting", retryable: true } });
      }
      if (request.method === "GET" && url.pathname === "/health") {
        const info = this.options.service.info() as Record<string, JsonValue>;
        return sendJson(response, this.shuttingDown ? 503 : 200, {
          status: this.shuttingDown ? "stopping" : "ok",
          gatewayVersion: info.gatewayVersion,
          protocolVersion: info.protocolVersion,
          minProtocolVersion: info.minProtocolVersion,
          ...(typeof info.sourceRevision === "string" ? { sourceRevision: info.sourceRevision } : {}),
          ...(typeof info.buildFingerprint === "string" ? { buildFingerprint: info.buildFingerprint } : {}),
          ...(typeof info.runtimeEpoch === "string" ? { runtimeEpoch: info.runtimeEpoch } : {}),
        });
      }
      if (request.method === "POST" && url.pathname === "/v1/pair") {
        const key = request.socket.remoteAddress ?? "unknown";
        if (!this.pairingLimiter.admit(key)) throw new GatewayError("unauthenticated", "Too many pairing attempts; wait before retrying");
        const body = JSON.parse((await readBoundedBody(request, 16_384)).toString("utf8")) as Record<string, unknown>;
        if (typeof body.code !== "string" || typeof body.deviceName !== "string") throw new GatewayError("invalid_request", "Pairing requires code and deviceName");
        const result = await this.options.devices.pair(body.code.trim(), body.deviceName);
        return sendJson(response, 200, { ...result, ...this.options.service.info() as Record<string, JsonValue> });
      }

      const authenticated = await this.options.devices.authenticate(bearer(request));
      if (!authenticated) return sendJson(response, 401, { error: { code: "unauthenticated", message: "Pairing token is invalid" } });

      if (request.method === "POST" && url.pathname === "/v1/uploads") {
        await this.options.uploads.withBodyAdmission(async () => {
          const name = url.searchParams.get("name") ?? "attachment";
          const mimeType = request.headers["content-type"] ?? "application/octet-stream";
          const rawDeclared = request.headers["content-length"];
          const declaredBytes = rawDeclared === undefined ? undefined : Number(rawDeclared);
          const upload = await this.options.uploads.saveStream(
            name,
            mimeType,
            completeRequestBody(request),
            declaredBytes,
          );
          sendJson(response, 201, { upload: { id: upload.id, name: upload.name, mimeType: upload.mimeType, size: upload.size } });
        });
        return;
      }
      if (request.method === "GET" && url.pathname.startsWith("/v1/blobs/")) {
        const id = decodeURIComponent(url.pathname.slice("/v1/blobs/".length));
        const lease = await this.options.sessions.acquireBlob(id);
        try {
          response.writeHead(200, {
            "content-type": lease.mimeType,
            "content-length": lease.size,
            "cache-control": "private, max-age=300",
            "x-content-type-options": "nosniff",
          });
          await pipeline(lease.stream, response);
        } finally {
          await lease.release();
        }
        return;
      }
      sendJson(response, 404, { error: { code: "not_found", message: "Route not found" } });
    } catch (error) {
      if (response.headersSent) {
        response.destroy(error instanceof Error ? error : undefined);
        return;
      }
      const failure = publicError(error);
      const status = failure.code === "unauthenticated" ? 401
        : failure.code === "not_found" ? 404
          : failure.code === "invalid_request" ? 400
            : failure.code === "busy" ? 503
              : 500;
      if (!request.complete) {
        response.setHeader("connection", "close");
        response.once("finish", () => request.destroy());
      }
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
      if (!authenticated || !this.ready || this.shuttingDown) {
        this.options.logger.log("warning", "Rejected unauthenticated or unavailable socket upgrade", { event: "connection.rejected", source: "transport" });
        socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n");
        socket.destroy();
        return;
      }
      const identity = authenticated.kind === "local" ? "local-wrapper" : authenticated.device.id;
      const maximumConnections = this.options.maximumConnections ?? 32;
      const maximumPerIdentity = this.options.maximumConnectionsPerIdentity ?? 4;
      const identityConnections = [...this.clients.values()].filter((client) => client.identity === identity).length;
      if (this.clients.size >= maximumConnections || identityConnections >= maximumPerIdentity) {
        this.options.logger.log("warning", "Rejected socket upgrade at connection capacity", { event: "connection.capacity", source: "transport" });
        socket.write("HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n");
        socket.destroy();
        return;
      }
      this.sockets.handleUpgrade(request, socket, head, (webSocket) => {
        this.admit(webSocket, identity, authenticated.kind === "local");
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
      presentationOnly: false,
      subscriptions: new Set(),
      terminals: new Set(),
      inFlight: new Set(),
      synchronizations: new Map(),
      subscriptionTokens: new Map(),
      rekeyedSessionIds: new Map(),
      synchronizationBytes: 0,
      pendingSessionOpens: new Map(),
      outboundFrames: 0,
      helloTimer: setTimeout(() => socket.close(1008, "hello required"), 5_000),
    };
    this.clients.set(connection.id, connection);
    this.options.logger.log("info", `Client connection admitted (${isLocal ? "local" : "paired"})`, { event: "connection.admitted", source: "transport" });
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
      connection.presentationOnly = (frame as Record<string, unknown>).clientRole === "mobile";
      this.options.logger.log("info", `Client handshake accepted (${connection.presentationOnly ? "mobile" : "local"})`, { event: "connection.handshake", source: "transport" });
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
    const sessionOpenID = frame.method === "session.open"
      && typeof frame.params === "object"
      && frame.params !== null
      && !Array.isArray(frame.params)
      && typeof (frame.params as Record<string, unknown>).sessionId === "string"
      ? (frame.params as Record<string, unknown>).sessionId as string
      : undefined;
    if (sessionOpenID !== undefined) {
      const owner = existingSessionOpenOwner(
        connection.pendingSessionOpens,
        connection.synchronizations,
        connection.subscriptionTokens,
        sessionOpenID,
      );
      if (owner !== undefined) {
        this.send(connection, {
          type: "response",
          id: frame.id,
          ok: false,
          error: publicError(new GatewayError("conflict", "A session synchronization is already in progress for this connection", true)),
        });
        return;
      }
      connection.pendingSessionOpens.set(sessionOpenID, frame.id);
    }
    connection.inFlight.add(frame.id);
    this.options.logger.log("info", `RPC request ${frame.method}`, { event: "rpc.request", source: "transport" });
    const requestId = frame.id;
    const synchronizationOwners: SynchronizationOwner[] = [];
    const synchronizationCompletions: SynchronizationCompletion[] = [];
    let responseAttempted = false;
    const resolveSessionId = (sessionId: string): string => {
      const seen = new Set<string>();
      let current = sessionId;
      while (!seen.has(current)) {
        seen.add(current);
        const replacement = connection.rekeyedSessionIds.get(current);
        if (replacement === undefined) return current;
        current = replacement;
      }
      return sessionId;
    };
    const clearRekeyedSessionIds = (sessionId: string): void => {
      for (const [former, current] of connection.rekeyedSessionIds) {
        if (former === sessionId || current === sessionId) connection.rekeyedSessionIds.delete(former);
      }
    };
    const revokeSynchronization = (sessionId: string, synchronization: ActiveSessionSynchronization): boolean => {
      sessionId = resolveSessionId(sessionId);
      // A later session.open may have replaced this request's owner. In that
      // case, only the current token may revoke the runtime subscription.
      if (connection.synchronizations.get(sessionId) !== synchronization
          || connection.subscriptionTokens.get(sessionId) !== synchronization.subscriptionToken) return false;
      synchronization.barrier.abort(synchronization.requestId);
      connection.subscriptionTokens.delete(sessionId);
      connection.subscriptions.delete(sessionId);
      clearRekeyedSessionIds(sessionId);
      releaseSessionTerminals(
        connection.terminals,
        sessionId,
        (terminalId, ownerSessionId) => this.options.service.terminalBelongsToSession(terminalId, ownerSessionId),
      );
      this.options.sessions.unsubscribe(connection.id, sessionId);
      return true;
    };
    const revokeSubscription = (sessionId: string, token: string): boolean => {
      sessionId = resolveSessionId(sessionId);
      const synchronization = connection.synchronizations.get(sessionId);
      if (synchronization && synchronization.subscriptionToken === token) {
        clearTimeout(synchronization.timeout);
        const revoked = revokeSynchronization(sessionId, synchronization);
        if (revoked) connection.synchronizations.delete(sessionId);
        return revoked;
      }
      if (connection.subscriptionTokens.get(sessionId) !== token) return false;
      connection.subscriptionTokens.delete(sessionId);
      connection.subscriptions.delete(sessionId);
      clearRekeyedSessionIds(sessionId);
      releaseSessionTerminals(
        connection.terminals,
        sessionId,
        (terminalId, ownerSessionId) => this.options.service.terminalBelongsToSession(terminalId, ownerSessionId),
      );
      this.options.sessions.unsubscribe(connection.id, sessionId);
      return true;
    };
    const revokePresentationOwners = (exceptSessionID: string): void => {
      for (const [sessionId, synchronization] of [...connection.synchronizations]) {
        if (sessionId === exceptSessionID) continue;
        clearTimeout(synchronization.timeout);
        if (revokeSynchronization(sessionId, synchronization)) {
          connection.synchronizations.delete(sessionId);
        }
      }
      for (const [sessionId, token] of [...connection.subscriptionTokens]) {
        if (sessionId !== exceptSessionID) revokeSubscription(sessionId, token);
      }
      for (const [sessionId] of [...connection.pendingSessionOpens]) {
        if (sessionId !== exceptSessionID) connection.pendingSessionOpens.delete(sessionId);
      }
    };
    try {
      const context: ClientContext = {
        id: connection.id,
        identity: connection.identity,
        isLocal: connection.isLocal,
        beginSynchronization: (sessionId) => {
          if (connection.presentationOnly
              && connection.pendingSessionOpens.get(sessionId) !== requestId) {
            throw new GatewayError("conflict", "This mobile presentation open was retired", true);
          }
          if (connection.presentationOnly) revokePresentationOwners(sessionId);
          if (!connection.subscriptionTokens.has(sessionId)
              && connection.subscriptionTokens.size >= (this.options.maximumSubscriptionsPerConnection ?? 64)) {
            throw new GatewayError("busy", "Connection subscription capacity is full", true);
          }
          if (connection.synchronizations.has(sessionId)) {
            // A genuinely overlapping in-flight open is a race the protocol
            // must reject; only the current owner may proceed.
            throw new GatewayError("conflict", "A session synchronization is already in progress for this connection", true);
          }
          const installedToken = connection.subscriptionTokens.get(sessionId);
          if (installedToken !== undefined) {
            // The client asked for a fresh authoritative baseline. Replace the
            // installed subscription deterministically instead of conflicting:
            // after recycled client state, a missed close, or a half-open
            // reconnect, an unconditional replacement is the only path that
            // keeps client and server subscription ownership convergent. A
            // stale close for the revoked token is ignored harmlessly.
            revokeSubscription(sessionId, installedToken);
          }
          connection.subscriptions.add(sessionId);
          this.options.sessions.subscribe(connection.id, sessionId);
          const syncToken = randomUUID();
          connection.subscriptionTokens.set(sessionId, syncToken);
          const maximumSynchronizationBytes = this.options.maximumSynchronizationBytes ?? 2 * 1_048_576;
          const barrier = new SessionSyncBarrier({
            reserve: (bytes) => {
              if (bytes > maximumSynchronizationBytes - connection.synchronizationBytes) return false;
              connection.synchronizationBytes += bytes;
              return true;
            },
            release: (bytes) => {
              connection.synchronizationBytes = Math.max(0, connection.synchronizationBytes - bytes);
            },
          });
          barrier.begin(syncToken);
          let installed!: ActiveSessionSynchronization;
          const timeout = setTimeout(() => {
            const active = connection.synchronizations.get(installed.sessionId);
            if (active !== installed) return;
            revokeSynchronization(installed.sessionId, active);
            connection.synchronizations.delete(installed.sessionId);
            this.send(connection, {
              type: "event",
              topic: "transport.resyncRequired",
              sessionId: installed.sessionId,
              payload: { reason: "subscription synchronization timed out" },
            });
          }, this.options.synchronizationTimeoutMs ?? 30_000);
          timeout.unref();
          installed = { barrier, timeout, requestId, subscriptionToken: syncToken, sessionId };
          connection.synchronizations.set(sessionId, installed);
          synchronizationOwners.push({
            sessionId,
            syncToken,
            requestId,
            subscriptionToken: syncToken,
          });
          return syncToken;
        },
        establishSynchronization: (sessionId, snapshot) => {
          sessionId = resolveSessionId(sessionId);
          const active = connection.synchronizations.get(sessionId);
          if (!active || active.requestId !== requestId) {
            throw new GatewayError("conflict", "Session synchronization is owned by another request", true);
          }
          active.barrier.establish(snapshot);
        },
        completeSynchronization: (sessionId, syncToken) => {
          sessionId = resolveSessionId(sessionId);
          const active = connection.synchronizations.get(sessionId);
          if (!active || active.subscriptionToken !== syncToken) {
            throw new GatewayError("conflict", "Session synchronization is no longer owned by this token", true);
          }
          synchronizationCompletions.push({
            sessionId,
            syncToken,
            // The open request remains the synchronization owner until this
            // acknowledgement commits. The sync request may have a different
            // request ID, but can never commit without this exact owner token.
            requestId: active.requestId,
            subscriptionToken: active.subscriptionToken,
          });
        },
        unsubscribe: (sessionId, subscriptionToken) => {
          sessionId = resolveSessionId(sessionId);
          if (subscriptionToken !== undefined) return revokeSubscription(sessionId, subscriptionToken);
          const synchronization = connection.synchronizations.get(sessionId);
          if (synchronization) {
            clearTimeout(synchronization.timeout);
            if (revokeSynchronization(sessionId, synchronization)) {
              connection.synchronizations.delete(sessionId);
              return true;
            }
          }
          const token = connection.subscriptionTokens.get(sessionId);
          if (token !== undefined) return revokeSubscription(sessionId, token);
          connection.subscriptions.delete(sessionId);
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
      // Validate every synchronization created by this request before writing
      // the response. A timed-out open may have no completion at all; it must
      // not publish an orphan successful response/token after its barrier was
      // revoked.
      for (const owner of synchronizationOwners) {
        const active = connection.synchronizations.get(resolveSessionId(owner.sessionId));
        if (!active
            || active.requestId !== owner.requestId
            || active.subscriptionToken !== owner.subscriptionToken) {
          throw new GatewayError("conflict", "Session synchronization ownership changed before acknowledgement", true);
        }
      }
      // Validate every completion before writing the response. The checks are
      // request+token exact; this prevents a stale request from ever sending a
      // successful response which it can no longer commit.
      for (const completion of synchronizationCompletions) {
        const active = connection.synchronizations.get(resolveSessionId(completion.sessionId));
        if (!active
            || active.requestId !== completion.requestId
            || active.subscriptionToken !== completion.subscriptionToken
            || completion.syncToken !== active.subscriptionToken) {
          throw new GatewayError("conflict", "Session synchronization ownership changed before acknowledgement", true);
        }
      }
      const responseSentIntact = this.send(connection, { type: "response", id: frame.id, ok: true, result });
      responseAttempted = true;
      if (!responseSentIntact) {
        const ownerRequestIDs = new Set([
          requestId,
          ...synchronizationCompletions.map((completion) => completion.requestId),
        ]);
        for (const ownerRequestID of ownerRequestIDs) {
          clearRequestSynchronizations(connection.synchronizations, ownerRequestID, (sessionId, synchronization) => {
            revokeSynchronization(sessionId, synchronization);
          });
        }
      }
      // The acknowledgement is enqueued before the barrier is removed. Because
      // this block is synchronous, no newer broadcast can overtake the buffered
      // catch-up on the WebSocket. Re-check exact ownership before committing.
      if (responseSentIntact) for (const completion of synchronizationCompletions) {
        completion.sessionId = resolveSessionId(completion.sessionId);
        const active = connection.synchronizations.get(completion.sessionId);
        if (!active
            || active.requestId !== completion.requestId
            || active.subscriptionToken !== completion.subscriptionToken
            || completion.syncToken !== active.subscriptionToken) continue;
        if (active.barrier.isOverflowed(completion.syncToken)) {
          // Replace the overflowed quarantine before awaiting recovery. Events
          // arriving during the snapshot read must be retained for the fresh
          // recovery baseline, not discarded by the old overflow flag.
          if (!active.barrier.beginRecovery(completion.syncToken)) continue;
          const recoveryToken = connection.subscriptionTokens.get(completion.sessionId);
          const recovery = recoveryToken === completion.subscriptionToken
            ? await this.options.service.recoverySnapshot(completion.sessionId)
            : undefined;
          const stillOwned = connection.synchronizations.get(completion.sessionId) === active
            && connection.subscriptionTokens.get(completion.sessionId) === completion.subscriptionToken;
          if (!stillOwned) continue;

          const sendResyncRequired = () => this.send(connection, {
            type: "event",
            topic: "transport.resyncRequired",
            sessionId: completion.sessionId,
            payload: { reason: "subscription catch-up overflow" },
          });
          if (recovery === undefined) {
            active.barrier.abort(completion.syncToken);
            clearTimeout(active.timeout);
            connection.synchronizations.delete(completion.sessionId);
            sendResyncRequired();
            continue;
          }

          active.barrier.establish(recovery);
          const recovered = active.barrier.commit(completion.syncToken);
          clearTimeout(active.timeout);
          connection.synchronizations.delete(completion.sessionId);
          if (recovered.overflowed) {
            // The recovery quarantine overflowed too; no snapshot or suffix is
            // trustworthy enough to publish.
            sendResyncRequired();
            continue;
          }

          // `fallback` means encodeOutboundFrame already emitted the compact
          // resync replacement. Do not emit a duplicate or flush a suffix that
          // has no corresponding published baseline.
          const recoveryOutcome = this.sendOutcome(connection, {
            type: "event",
            topic: "session.rebaseline",
            sessionId: completion.sessionId,
            payload: {
              reason: "subscription catch-up overflow",
              subscriptionToken: completion.subscriptionToken,
              snapshot: recovery as unknown as JsonValue,
            },
          });
          if (recoveryOutcome === "sent") {
            for (const event of recovered.events) this.send(connection, event);
          } else if (recoveryOutcome === "failed") {
            sendResyncRequired();
          }
        } else {
          const completed = active.barrier.commit(completion.syncToken);
          clearTimeout(active.timeout);
          connection.synchronizations.delete(completion.sessionId);
          for (const event of completed.events) this.send(connection, event);
        }
      }
    } catch (error) {
      this.options.logger.log("error", `RPC ${frame.method} failed: ${error instanceof Error ? error.message : String(error)}`, { event: "rpc.error", source: "transport" });
      const ownerRequestIDs = new Set([
        requestId,
        ...synchronizationCompletions.map((completion) => completion.requestId),
      ]);
      for (const ownerRequestID of ownerRequestIDs) {
        clearRequestSynchronizations(connection.synchronizations, ownerRequestID, (sessionId, synchronization) => {
          revokeSynchronization(sessionId, synchronization);
        });
      }
      if (!responseAttempted) {
        responseAttempted = true;
        this.send(connection, { type: "response", id: frame.id, ok: false, error: publicError(error) });
      }
    } finally {
      if (sessionOpenID !== undefined && connection.pendingSessionOpens.get(sessionOpenID) === frame.id) {
        connection.pendingSessionOpens.delete(sessionOpenID);
      }
      connection.inFlight.delete(frame.id);
    }
  }

  private send(connection: Connection, value: unknown): boolean {
    return this.sendOutcome(connection, value) === "sent";
  }

  private sendOutcome(connection: Connection, value: unknown): "sent" | "fallback" | "failed" {
    if (connection.socket.readyState !== WebSocket.OPEN) return "failed";
    try {
      const direct = JSON.stringify(value);
      if (direct === undefined) return "failed";
      const encoded = Buffer.byteLength(direct, "utf8") <= this.options.maxFrameBytes
        ? direct
        : encodeOutboundFrame(value, this.options.maxFrameBytes);
      if (!encoded) return "failed";

      const bytes = Buffer.byteLength(encoded, "utf8");
      const maximumFrames = this.options.maximumOutboundFrames ?? 32;
      const maximumBytes = this.options.maximumOutboundBytes ?? 2 * 1_048_576;
      if (connection.outboundFrames >= maximumFrames
        || bytes > maximumBytes
        || connection.socket.bufferedAmount > maximumBytes - bytes) {
        // Never silently drop a sequenced live event. Force the established
        // reconnect/snapshot path when this client cannot drain its stream.
        connection.socket.close(1013, "client outbound capacity exceeded");
        return "failed";
      }
      connection.outboundFrames += 1;
      connection.socket.send(encoded, () => {
        connection.outboundFrames = Math.max(0, connection.outboundFrames - 1);
      });
      return encoded === direct ? "sent" : "fallback";
    } catch {
      // Broadcast payloads are supplied by runtime projections. A malformed
      // value must not escape the broadcast loop or take down the Gateway.
      return "failed";
    }
  }

  private disconnect(connection: Connection): void {
    if (!this.clients.delete(connection.id)) return;
    this.options.logger.log("info", "Client connection closed", { event: "connection.closed", source: "transport" });
    clearTimeout(connection.helloTimer);
    for (const synchronization of connection.synchronizations.values()) {
      clearTimeout(synchronization.timeout);
      synchronization.barrier.abort(synchronization.requestId);
    }
    connection.synchronizations.clear();
    this.options.sessions.unsubscribeClient(connection.id);
    this.options.service.releaseClient(connection.id);
    this.options.auth.cancelClient(connection.id);
  }

  async close(): Promise<void> {
    if (this.shuttingDown) return;
    this.shuttingDown = true;
    this.options.logger.log("info", "Closing Gateway transport", { event: "gateway.transport-closing", source: "transport" });
    this.ready = false;
    clearInterval(this.heartbeat);
    for (const client of this.clients.values()) {
      this.send(client, { type: "event", topic: "system.stopping", payload: {} });
      client.socket.close(1012, "gateway restarting");
    }
    await new Promise<void>((resolve) => this.server.close(() => resolve()));
    this.sockets.close();
  }
}
