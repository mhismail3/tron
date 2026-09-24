import { createServer, type IncomingMessage, type Server as HTTPServer, type ServerResponse } from "node:http";
import { GATEWAY_JSON_MAXIMUM_NODES, jsonNodeCount } from "../protocol/json-budget.js";
import type { Duplex } from "node:stream";
import { finished, pipeline } from "node:stream/promises";
import { abortableRead } from "../util/abortable-read.js";
import { randomUUID } from "node:crypto";
import { WebSocketServer, WebSocket } from "ws";
import { GatewayError, publicError } from "../errors.js";
import type { JsonValue } from "../protocol/types.js";
import type { DeviceIdentity, DeviceStore } from "../security/device-store.js";
import { RateLimiter } from "../security/rate-limiter.js";
import type { UploadStore } from "../machine/upload-store.js";
import type { RuntimeRegistry } from "../sessions/runtime-registry.js";
import type { BlobByteRange } from "../sessions/blob-store.js";
import type { AuthBroker } from "../admin/auth-broker.js";
import type { GatewayLogger } from "./logger.js";
import { GATEWAY_CONNECTION_POLICY } from "./connection-policy.js";
import { formatStallEvidence, StallSampler } from "./stall-diagnostics.js";
import { GatewayService, type ClientContext } from "./gateway-service.js";
import { MIN_PROTOCOL_VERSION, PROTOCOL_VERSION } from "../version.js";
import { SessionSyncBarrier, type BufferedSessionEncoding, type BufferedSessionEvent } from "./session-sync.js";
import type { BrowserLiveViewRegistry } from "../display/browser-live-view.js";

// Retain only recent former IDs while an active subscription is rekeyed. Older
// IDs are stale control paths and may safely require a fresh session.open.
export const MAXIMUM_REKEYED_SESSION_IDS = 64;
export const MAXIMUM_UNANSWERED_HEARTBEATS = GATEWAY_CONNECTION_POLICY.missedHeartbeatLimit;
/** Application-defined close code for a socket replaced by its own identity. */
export const SUPERSEDED_CLOSE_CODE = 4000;

function diagnosticRequestID(value: string): string {
  return value.replace(/[^A-Za-z0-9._:-]/gu, "_").slice(0, 160);
}

// A caller mistake or expected backpressure is handled (warning); only an
// unexpected fault or an internal error means someone should look (error).
function rpcFailureLevel(error: unknown): "warning" | "error" {
  return error instanceof GatewayError && error.code !== "internal" ? "warning" : "error";
}

/** Per-RPC completions under this bound are debug detail; slower ones warn. */
const SLOW_RPC_WARNING_MS = 1_000;

function diagnosticErrorCode(error: unknown): string {
  if (error instanceof GatewayError) return error.code;
  if (error instanceof Error) return "exception";
  return "unknown";
}

// HTTP admission is intentionally independent from route payload limits: it
// bounds the lifetime of transport requests while UploadStore, BlobStore and
// live-view leases retain ownership of their own staged bytes/readers/viewers.
export const HTTP_REQUEST_IDLE_TIMEOUT_MS = 30_000;
export const HTTP_HEADERS_TIMEOUT_MS = 15_000;
// Preserve Node's finite five-minute body allowance for large slow uploads;
// request receipt and transport inactivity are different bounds.
export const HTTP_REQUEST_TIMEOUT_MS = 300_000;
export const HTTP_SHUTDOWN_GRACE_MS = 1_000;
export const HTTP_MAXIMUM_CONNECTIONS = 128;
export const HTTP_MAXIMUM_CONNECTIONS_PER_ADDRESS = 64;
export const HTTP_MAXIMUM_REQUESTS = 128;
export const HTTP_MAXIMUM_REQUESTS_PER_IDENTITY = 16;
export const HTTP_MAXIMUM_REQUESTS_PER_ADDRESS = 32;
export const HTTP_MAXIMUM_REQUESTS_PER_CONNECTION = 8;

export interface HttpTransportLease {
  identify(identity: string): void;
  release(): void;
}

interface HttpLeaseState {
  identity?: string;
  released: boolean;
}

/** One bounded admission owner for authenticated and pre-auth HTTP requests. */
export class HttpTransportAdmission {
  private active = 0;
  private readonly identities = new Map<string, number>();
  private readonly addresses = new Map<string, number>();
  private readonly connections = new Map<object, number>();

  constructor(
    private readonly maximumRequests = HTTP_MAXIMUM_REQUESTS,
    private readonly maximumRequestsPerIdentity = HTTP_MAXIMUM_REQUESTS_PER_IDENTITY,
  ) {
    if (!Number.isSafeInteger(maximumRequests) || maximumRequests < 1
      || !Number.isSafeInteger(maximumRequestsPerIdentity) || maximumRequestsPerIdentity < 1) {
      throw new Error("HTTP admission bounds are invalid");
    }
  }

  admit(address: string, connection: object): HttpTransportLease | undefined {
    if (this.active >= this.maximumRequests
      || (this.addresses.get(address) ?? 0) >= HTTP_MAXIMUM_REQUESTS_PER_ADDRESS
      || (this.connections.get(connection) ?? 0) >= HTTP_MAXIMUM_REQUESTS_PER_CONNECTION) return undefined;
    this.active += 1;
    this.addresses.set(address, (this.addresses.get(address) ?? 0) + 1);
    this.connections.set(connection, (this.connections.get(connection) ?? 0) + 1);
    const state: HttpLeaseState = { released: false };
    return {
      identify: (nextIdentity: string): void => {
        if (state.released) return;
        if (state.identity === nextIdentity) return;
        if (state.identity !== undefined) throw new Error("HTTP request identity was already assigned");
        const count = this.identities.get(nextIdentity) ?? 0;
        if (count >= this.maximumRequestsPerIdentity) {
          throw new GatewayError("busy", "HTTP request capacity for this device is full", true);
        }
        state.identity = nextIdentity;
        this.identities.set(nextIdentity, count + 1);
      },
      release: (): void => {
        if (state.released) return;
        state.released = true;
        this.active -= 1;
        this.releaseCount(this.addresses, address);
        this.releaseCount(this.connections, connection);
        if (state.identity !== undefined) this.releaseCount(this.identities, state.identity);
      },
    };
  }

  private releaseCount<Key>(counts: Map<Key, number>, key: Key): void {
    const count = counts.get(key)!;
    if (count === 1) counts.delete(key);
    else counts.set(key, count - 1);
  }

  snapshot(address?: string, connection?: object) {
    return {
      activeRequests: this.active,
      maximumRequests: this.maximumRequests,
      identities: this.identities.size,
      maximumRequestsPerIdentity: this.maximumRequestsPerIdentity,
      addressRequests: address === undefined ? 0 : this.addresses.get(address) ?? 0,
      maximumRequestsPerAddress: HTTP_MAXIMUM_REQUESTS_PER_ADDRESS,
      connectionRequests: connection === undefined ? 0 : this.connections.get(connection) ?? 0,
      maximumRequestsPerConnection: HTTP_MAXIMUM_REQUESTS_PER_CONNECTION,
    };
  }
}

export function shouldTerminateHeartbeat(unansweredHeartbeats: number): boolean {
  return unansweredHeartbeats >= MAXIMUM_UNANSWERED_HEARTBEATS;
}

function progressAge(at: number | null, now: number): string {
  return at === null ? "unknown" : String(Math.max(0, Math.round(now - at)));
}

export function heartbeatTimerDelay(elapsedMs: number, intervalMs = GATEWAY_CONNECTION_POLICY.heartbeatIntervalMs): number {
  return Math.max(0, Math.round(elapsedMs - intervalMs));
}

export function parseBlobByteRange(value: string | string[] | undefined): BlobByteRange | undefined {
  if (value === undefined) return undefined;
  if (Array.isArray(value)) throw new GatewayError("invalid_request", "Only one blob byte range may be requested");
  const match = /^bytes=(\d+)-(\d*)$/.exec(value.trim());
  if (!match) throw new GatewayError("invalid_request", "Blob byte range must use bytes=start-end syntax");
  const start = Number(match[1]);
  const end = match[2] ? Number(match[2]) : undefined;
  if (!Number.isSafeInteger(start) || start < 0
    || (end !== undefined && (!Number.isSafeInteger(end) || end < start))) {
    throw new GatewayError("invalid_request", "Blob byte range is not satisfiable");
  }
  return end === undefined ? { start } : { start, end };
}

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
  sessionId: string,
): string | undefined {
  // Only genuinely in-flight opens are rejected. An installed subscription is
  // not an open owner: beginSynchronization replaces it deterministically so
  // reconnecting clients always converge instead of deadlocking on conflict.
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
  subscriptionTokens: ReadonlyMap<string, string>,
  terminalId: string,
  belongsToSession: (terminalId: string, sessionId: string) => boolean,
): boolean {
  return [...subscriptionTokens.keys()].some((sessionId) => belongsToSession(terminalId, sessionId));
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

export interface OrderedOutboundQueueSnapshot {
  queuedFrames: number;
  queuedBytes: number;
  writeActive: boolean;
  acceptedFrames: number;
  completedFrames: number;
  maximumFrames: number;
  maximumBytes: number;
  frameHighWater: number;
  byteHighWater: number;
}

interface QueuedOutboundFrame {
  encoded: string;
  bytes: number;
}

type OutboundWrite = (encoded: string, completion: (error?: Error) => void) => void;

/**
 * A connection-local ordered writer. Encoded frames remain bounded in
 * application memory and exactly one frame is handed to ws at a time, so a
 * legitimate same-turn synchronization burst cannot fill ws.bufferedAmount.
 */
export class OrderedOutboundQueue {
  private readonly frames: Array<QueuedOutboundFrame | undefined> = [];
  private head = 0;
  private queuedBytes = 0;
  private writeActive = false;
  private retired = false;
  private acceptedFrames = 0;
  private completedFrames = 0;
  private frameHighWater = 0;
  private byteHighWater = 0;
  private readonly idleWaiters: Array<() => void> = [];

  constructor(
    private readonly maximumBytes: number,
    private readonly write: OutboundWrite,
    private readonly overflow: (snapshot: OrderedOutboundQueueSnapshot, nextBytes: number) => void,
    private readonly writeFailed: (error: Error, snapshot: OrderedOutboundQueueSnapshot) => void,
    private readonly maximumFrames = 4_096,
  ) {}

  enqueue(frame: string | { readonly encoded: string; readonly bytes: number }): boolean {
    if (this.retired) return false;
    const encoded = typeof frame === "string" ? frame : frame.encoded;
    const bytes = typeof frame === "string" ? Buffer.byteLength(encoded, "utf8") : frame.bytes;
    if (this.frames.length - this.head >= this.maximumFrames
      || bytes > this.maximumBytes || this.queuedBytes > this.maximumBytes - bytes) {
      const snapshot = this.snapshot();
      this.retire();
      this.overflow(snapshot, bytes);
      return false;
    }
    this.frames.push({ encoded, bytes });
    this.queuedBytes += bytes;
    this.acceptedFrames += 1;
    this.frameHighWater = Math.max(this.frameHighWater, this.frames.length - this.head);
    this.byteHighWater = Math.max(this.byteHighWater, this.queuedBytes);
    this.drain();
    return true;
  }

  snapshot(): OrderedOutboundQueueSnapshot {
    return {
      queuedFrames: this.frames.length - this.head,
      queuedBytes: this.queuedBytes,
      writeActive: this.writeActive,
      acceptedFrames: this.acceptedFrames,
      completedFrames: this.completedFrames,
      maximumFrames: this.maximumFrames,
      maximumBytes: this.maximumBytes,
      frameHighWater: this.frameHighWater,
      byteHighWater: this.byteHighWater,
    };
  }

  whenIdle(waiter: () => void): void {
    if (this.retired || (!this.writeActive && this.head === this.frames.length)) {
      waiter();
      return;
    }
    this.idleWaiters.push(waiter);
  }

  retire(): void {
    if (this.retired) return;
    this.retired = true;
    this.frames.length = 0;
    this.head = 0;
    this.queuedBytes = 0;
    this.writeActive = false;
    this.finishIdleWaiters();
  }

  private drain(): void {
    if (this.retired || this.writeActive) return;
    const frame = this.frames[this.head];
    if (!frame) return;
    this.writeActive = true;
    let completed = false;
    const completion = (error?: Error): void => {
      if (completed) return;
      completed = true;
      if (this.retired) return;
      // Release the payload at the same boundary as its byte reservation.
      // Waiting for array compaction retained up to 1,023 completed large frames
      // outside the queue budget on a continuously busy connection.
      this.frames[this.head] = undefined;
      this.head += 1;
      this.queuedBytes = Math.max(0, this.queuedBytes - frame.bytes);
      this.writeActive = false;
      if (this.head === this.frames.length) {
        this.frames.length = 0;
        this.head = 0;
      } else if (this.head >= 1_024 && this.head * 2 >= this.frames.length) {
        // Payloads are already released; compact only the empty array slots.
        this.frames.splice(0, this.head);
        this.head = 0;
      }
      if (error) {
        const snapshot = this.snapshot();
        this.retire();
        this.writeFailed(error, snapshot);
        return;
      }
      this.completedFrames += 1;
      this.drain();
      if (!this.writeActive && this.head === this.frames.length) this.finishIdleWaiters();
    };
    try {
      this.write(frame.encoded, completion);
    } catch (error) {
      completion(error instanceof Error ? error : new Error(String(error)));
    }
  }

  private finishIdleWaiters(): void {
    const waiters = this.idleWaiters.splice(0);
    for (const waiter of waiters) waiter();
  }
}

interface Connection {
  id: string;
  identity: string;
  isLocal: boolean;
  socket: WebSocket;
  unansweredHeartbeats: number;
  ready: boolean;
  presentationOnly: boolean;
  terminals: Set<string>;
  inFlight: Set<string>;
  requestControllers: Map<string, AbortController>;
  synchronizations: Map<string, ActiveSessionSynchronization>;
  subscriptionTokens: Map<string, string>;
  // A fork may occur after session.open but before session.sync. Retain the
  // former ID only while its carried subscription remains current.
  rekeyedSessionIds: Map<string, string>;
  synchronizationBytes: number;
  // Reserved before asynchronous service invocation so overlapping opens for
  // the same connection/session are rejected deterministically.
  pendingSessionOpens: Map<string, string>;
  outbound: OrderedOutboundQueue;
  closeInitiated: boolean;
  workRetired: boolean;
  closeDeadline?: NodeJS.Timeout;
  revoked: boolean;
  revokeResponseRequestId?: string;
  revokeResponseQueued: boolean;
  revokeCloseScheduled: boolean;
  admittedAt: number;
  lastInboundAt: number | null;
  // Successful ordered application-frame callbacks, not send start or pong traffic.
  lastWriteProgressAt: number | null;
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

interface PreparedOutboundFrame extends BufferedSessionEncoding {
  readonly nodes?: number;
}

function prepareOutboundFrame(value: unknown, maximum: number): PreparedOutboundFrame | undefined {
  const encoded = JSON.stringify(value);
  if (encoded === undefined) return undefined;
  const bytes = Buffer.byteLength(encoded, "utf8");
  const nodes = jsonNodeCount(value);
  if (bytes <= maximum && nodes <= GATEWAY_JSON_MAXIMUM_NODES) {
    return { encoded, bytes, output: encoded, outputBytes: bytes, fallback: false, nodes };
  }
  const structural = nodes > GATEWAY_JSON_MAXIMUM_NODES
    ? { nodeCountAtLeast: nodes, maximumNodes: GATEWAY_JSON_MAXIMUM_NODES } : {};
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
          details: { bytes, maximum, ...structural },
        },
      }
    : {
        type: "event",
        topic: "transport.resyncRequired",
        ...(typeof frame.sessionId === "string" ? { sessionId: frame.sessionId } : {}),
        payload: { reason: "oversized projection", bytes, maximum, ...structural },
      };
  const fallback = JSON.stringify(replacement);
  if (fallback === undefined) return undefined;
  const outputBytes = Buffer.byteLength(fallback, "utf8");
  return outputBytes <= maximum
    ? { encoded, bytes, output: fallback, outputBytes, fallback: true, nodes }
    : undefined;
}

export function encodeOutboundFrame(value: unknown, maximum: number): string | undefined {
  return prepareOutboundFrame(value, maximum)?.output;
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
  private readonly httpSockets = new Set<Duplex>();
  private readonly httpConnectionsByAddress = new Map<string, number>();
  private readonly httpAdmission: HttpTransportAdmission;
  private readonly pairingLimiter = new RateLimiter(10, 10 * 60_000);
  private readonly heartbeat: NodeJS.Timeout;
  private lastHeartbeatAt = performance.now();
  private readonly stallSampler: StallSampler;
  private ready = false;
  private shuttingDown = false;
  private closeTask?: Promise<void>;
  private startupPhase: "starting" | "catalog-warming" | "attention-recovery" | "automation-recovery" | "storage-warming" = "starting";

  constructor(
    private readonly options: {
      host: string;
      port: number;
      maxFrameBytes: number;
      maximumConnections?: number;
      maximumConnectionsPerIdentity?: number;
      maximumSubscriptionsPerConnection?: number;
      maximumOutboundBytes?: number;
      maximumSynchronizationBytes?: number;
      synchronizationTimeoutMs?: number;
      maximumHttpConnections?: number;
      maximumHttpRequests?: number;
      maximumHttpRequestsPerIdentity?: number;
      devices: DeviceStore;
      uploads: UploadStore;
      sessions: RuntimeRegistry;
      auth: AuthBroker;
      service: GatewayService;
      logger: GatewayLogger;
      liveViews?: BrowserLiveViewRegistry;
      /** Synchronous canonical-branch admission inside the device credential cut. */
      authorizeBrowserLiveView?: (sessionId: string, viewId: string, generation: string) => boolean;
      stallSampler?: StallSampler;
    },
  ) {
    this.stallSampler = options.stallSampler ?? new StallSampler();
    const maximumHttpConnections = options.maximumHttpConnections ?? HTTP_MAXIMUM_CONNECTIONS;
    if (!Number.isSafeInteger(maximumHttpConnections) || maximumHttpConnections < 1) {
      throw new Error("HTTP connection bounds are invalid");
    }
    this.httpAdmission = new HttpTransportAdmission(
      options.maximumHttpRequests,
      options.maximumHttpRequestsPerIdentity,
    );
    this.server = createServer({
      headersTimeout: HTTP_HEADERS_TIMEOUT_MS,
      requestTimeout: HTTP_REQUEST_TIMEOUT_MS,
      connectionsCheckingInterval: 1_000,
    }, (request, response) => void this.handleHttp(request, response));
    this.server.timeout = HTTP_REQUEST_IDLE_TIMEOUT_MS;
    this.server.on("connection", (socket) => {
      const address = socket.remoteAddress ?? "unknown";
      const addressConnections = this.httpConnectionsByAddress.get(address) ?? 0;
      if (this.httpSockets.size >= maximumHttpConnections
        || addressConnections >= HTTP_MAXIMUM_CONNECTIONS_PER_ADDRESS || this.shuttingDown) {
        this.options.logger.log("warning", `Rejected HTTP connection at capacity (connections=${this.httpSockets.size} maximumConnections=${maximumHttpConnections} addressConnections=${addressConnections} maximumPerAddress=${HTTP_MAXIMUM_CONNECTIONS_PER_ADDRESS})`, {
          event: "http.connection-capacity", source: "transport",
        });
        socket.destroy();
        return;
      }
      this.httpSockets.add(socket);
      this.httpConnectionsByAddress.set(address, addressConnections + 1);
      socket.once("close", () => {
        this.httpSockets.delete(socket);
        const count = this.httpConnectionsByAddress.get(address)!;
        if (count === 1) this.httpConnectionsByAddress.delete(address);
        else this.httpConnectionsByAddress.set(address, count - 1);
      });
    });
    this.sockets = new WebSocketServer({ noServer: true, maxPayload: options.maxFrameBytes, perMessageDeflate: false });
    this.server.on("upgrade", (request, socket, head) => void this.handleUpgrade(request, socket, head));
    this.heartbeat = setInterval(() => {
      const heartbeatAt = performance.now();
      const timerDelayMs = heartbeatTimerDelay(heartbeatAt - this.lastHeartbeatAt);
      this.lastHeartbeatAt = heartbeatAt;
      // Every heartbeat closes a window, so a delayed record's GC and
      // utilization cover exactly the delayed interval.
      const stallWindow = this.stallSampler.closeWindow();
      if (timerDelayMs >= 1_000) {
        const pressure = this.pressureDiagnostic();
        void this.stallSampler.hostMemory().then((host) => {
          this.options.logger.log("warning", `Gateway event loop delayed heartbeat by ${timerDelayMs}ms (${pressure} ${formatStallEvidence(stallWindow, host)})`, {
            event: "gateway.event-loop-delay",
            source: "transport",
            durationMs: timerDelayMs,
          });
        });
      }
      for (const connection of this.clients.values()) {
        if (connection.closeInitiated || connection.socket.readyState !== WebSocket.OPEN) continue;
        // Retire only after three complete ping intervals received no response.
        // One delayed timer or transiently starved callback cannot destroy a
        // healthy epoch; the fourth tick observes and retires the three misses.
        if (shouldTerminateHeartbeat(connection.unansweredHeartbeats)) {
          const heartbeatQueue = connection.outbound.snapshot();
          this.options.logger.log(
            "warning",
            `Closing unresponsive client ${connection.id} after ${connection.unansweredHeartbeats} unanswered heartbeats (lastInboundAgeMs=${progressAge(connection.lastInboundAt, heartbeatAt)} lastWriteProgressAgeMs=${progressAge(connection.lastWriteProgressAt, heartbeatAt)} queuedFrames=${heartbeatQueue.queuedFrames} queuedBytes=${heartbeatQueue.queuedBytes} completedFrames=${heartbeatQueue.completedFrames})`,
            { event: "connection.heartbeat-timeout", source: "transport" },
          );
          connection.socket.terminate();
          continue;
        }
        connection.unansweredHeartbeats += 1;
        connection.socket.ping();
      }
    }, GATEWAY_CONNECTION_POLICY.heartbeatIntervalMs);
    this.heartbeat.unref();
  }

  setStartupPhase(phase: "catalog-warming" | "attention-recovery" | "automation-recovery" | "storage-warming"): void {
    if (this.ready || this.shuttingDown) return;
    this.startupPhase = phase;
    this.options.logger.log("info", `Gateway startup phase: ${phase}`, { event: "gateway.startup-phase", source: "lifecycle" });
  }

  async listen(afterBind: () => Promise<void> = async () => {}): Promise<void> {
    try {
      await new Promise<void>((resolve, reject) => {
        this.server.once("error", reject);
        this.server.listen(this.options.port, this.options.host, () => {
          this.server.off("error", reject);
          resolve();
        });
      });
      this.options.logger.log("info", "Gateway listener bound; startup warmup beginning", { event: "gateway.bound", source: "transport" });
      await afterBind();
      // A signal may close the transport while warmup is suspended. Never let
      // that in-flight callback publish readiness after shutdown has begun.
      if (this.shuttingDown) throw new GatewayError("busy", "Gateway shutdown began during startup", true);
      this.ready = true;
    } catch (error) {
      await this.close();
      throw error;
    }
    this.options.logger.log("info", `Gateway listening on ${this.options.host}:${this.options.port}`, { event: "gateway.listening", source: "transport" });
  }

  /** Move connection-local ownership with the registry's canonical rekey. */
  rekeySession(previousSessionId: string, nextSessionId: string): void {
    if (previousSessionId === nextSessionId) return;
    // Process identities include the canonical parent ID. Retire read-only
    // child leases instead of silently carrying stale authorization across a fork.
    this.options.service.releaseSessionProcessTranscripts(previousSessionId);
    for (const connection of this.clients.values()) {
      const sourceSynchronization = connection.synchronizations.get(previousSessionId);
      const sourceToken = connection.subscriptionTokens.get(previousSessionId);
      const pendingOwner = connection.pendingSessionOpens.get(previousSessionId);
      if (!sourceSynchronization && sourceToken === undefined && pendingOwner === undefined) continue;

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

      connection.subscriptionTokens.delete(previousSessionId);
      connection.synchronizations.delete(previousSessionId);
      releaseSessionTerminals(
        connection.terminals,
        previousSessionId,
        (terminalId, ownerSessionId) => this.options.service.terminalBelongsToSession(terminalId, ownerSessionId),
      );
      if (sourceToken !== undefined) connection.subscriptionTokens.set(nextSessionId, sourceToken);
      // session.open reserves its requested ID before the asynchronous acquire.
      // A fork can rekey that slot before beginSynchronization runs; retain the
      // old alias for duplicate-open rejection while moving the canonical owner
      // to the replacement ID used by synchronization admission and cleanup.
      if (pendingOwner !== undefined) connection.pendingSessionOpens.set(nextSessionId, pendingOwner);
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
    // Prepare once for this broadcast operation. Each connection still owns
    // admission, queue accounting, revocation, and write-failure isolation.
    const prepared = this.prepareBroadcastFrame(event);
    for (const client of this.clients.values()) {
      if (!client.ready || !client.subscriptionTokens.has(sessionId)) continue;
      // While a synchronization quarantine owns this session's catch-up, its
      // barrier is the only delivery path: the event is flushed exactly once
      // after the acknowledgement. Sending it here as well would deliver every
      // in-window event twice and break the client's contiguous replay.
      const barrier = client.synchronizations.get(sessionId)?.barrier;
      const deliverable = barrier ? barrier.offer(event, prepared ?? null) : event;
      if (deliverable) this.sendOutcome(client, deliverable, prepared ?? null);
    }
  }

  broadcast(topic: string, payload: JsonValue): void {
    const event = { type: "event" as const, topic, payload };
    const prepared = this.prepareBroadcastFrame(event);
    for (const client of this.clients.values()) {
      if (client.ready) this.sendOutcome(client, event, prepared ?? null);
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

  disconnectDevice(deviceId: string, origin?: { connectionId: string; requestId: string; deviceId: string }): void {
    // The durable device replacement has already happened. Fence transport
    // admission and observer ownership synchronously, while accepted RPCs are
    // allowed to finish independently of the socket's physical close.
    this.options.auth.cancelOwner(deviceId);
    this.options.liveViews?.closeViewerIdentity(deviceId);
    for (const client of this.clients.values()) {
      if (client.isLocal || client.identity !== deviceId) continue;
      client.revoked = true;
      for (const synchronization of client.synchronizations.values()) {
        clearTimeout(synchronization.timeout);
        synchronization.barrier.abort(synchronization.requestId);
      }
      client.synchronizations.clear();
      client.subscriptionTokens.clear();
      client.terminals.clear();
      client.pendingSessionOpens.clear();
      this.options.sessions.unsubscribeClient(client.id);
      const isInitiatingRequest = origin?.connectionId === client.id
        && origin.deviceId === deviceId
        && client.inFlight.has(origin.requestId);
      if (isInitiatingRequest) {
        // The initiating request must enqueue its successful response before
        // the close. An earlier queued frame is drained first by this queue.
        client.revokeResponseRequestId = origin.requestId;
        client.revokeResponseQueued = false;
      } else {
        client.socket.close(1008, "device revoked");
      }
      this.options.service.releaseClient(client.id);
    }
  }

  private async handleHttp(request: IncomingMessage, response: ServerResponse): Promise<void> {
    // Node's server timeout covers idle request/socket time, while this
    // response timeout also retires a stream stalled after its headers were
    // written. Route leases still own exact reader/viewer release.
    const readLifetime = new AbortController();
    response.setTimeout(HTTP_REQUEST_IDLE_TIMEOUT_MS, () => { readLifetime.abort(); response.destroy(); });
    const address = request.socket.remoteAddress ?? "unknown";
    const transportLease = this.httpAdmission.admit(address, request.socket);
    if (!transportLease) {
      const capacity = this.httpAdmission.snapshot(address, request.socket);
      this.options.logger.log("warning", `Rejected HTTP request at capacity (activeRequests=${capacity.activeRequests} maximumRequests=${capacity.maximumRequests} addressRequests=${capacity.addressRequests} maximumRequestsPerAddress=${capacity.maximumRequestsPerAddress} connectionRequests=${capacity.connectionRequests} maximumRequestsPerConnection=${capacity.maximumRequestsPerConnection})`, {
        event: "http.request-capacity", source: "transport",
      });
      if (!request.complete) {
        response.setHeader("connection", "close");
        response.once("finish", () => request.destroy());
      }
      sendJson(response, 503, { error: { code: "busy", message: "HTTP request capacity is full", retryable: true } });
      return;
    }
    // Auth/read owners bound physical work and remove cancelled queued waits.
    // Their late values release at that owner, so disposable transport tickets
    // can retire without freeing unaccounted filesystem work or accepted writes.
    let workSettled = false;
    const releaseTransportLease = (): void => {
      if (workSettled && (response.writableFinished || response.destroyed)) transportLease.release();
    };
    const retireAbortedRequest = (): void => {
      // An aborted request is a disposable stream cancellation. Destroy the
      // response as well so route pipelines release their reader/staging lease
      // before this transport capacity is returned.
      if (!response.destroyed && !response.writableFinished) response.destroy();
      releaseTransportLease();
    };
    const retireRead = (): void => { readLifetime.abort(); releaseTransportLease(); };
    response.once("finish", retireRead);
    response.once("close", retireRead);
    response.once("error", retireRead);
    request.once("aborted", retireAbortedRequest);
    request.once("error", retireAbortedRequest);
    try {
      const url = new URL(request.url ?? "/", `http://${request.headers.host ?? "localhost"}`);
      if (request.method === "GET" && url.pathname === "/health") {
        const info = this.options.service.info() as Record<string, JsonValue>;
        return sendJson(response, this.ready && !this.shuttingDown ? 200 : 503, {
          status: this.shuttingDown ? "stopping" : this.ready ? "ok" : this.startupPhase,
          gatewayVersion: info.gatewayVersion,
          protocolVersion: info.protocolVersion,
          minProtocolVersion: info.minProtocolVersion,
          ...(typeof info.sourceRevision === "string" ? { sourceRevision: info.sourceRevision } : {}),
          ...(typeof info.buildFingerprint === "string" ? { buildFingerprint: info.buildFingerprint } : {}),
          ...(typeof info.runtimeEpoch === "string" ? { runtimeEpoch: info.runtimeEpoch } : {}),
        });
      }
      if (!this.ready) {
        return sendJson(response, 503, { error: { code: "busy", message: "Gateway is starting", retryable: true } });
      }
      if (request.method === "POST" && url.pathname === "/v1/pair") {
        const key = request.socket.remoteAddress ?? "unknown";
        if (!this.pairingLimiter.admit(key)) throw new GatewayError("unauthenticated", "Too many pairing attempts; wait before retrying");
        const parsed: unknown = JSON.parse((await readBoundedBody(request, 16_384)).toString("utf8"));
        if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
          throw new GatewayError("invalid_request", "Pairing requires a JSON object body");
        }
        const body = parsed as Record<string, unknown>;
        if (typeof body.code !== "string" || typeof body.deviceName !== "string") throw new GatewayError("invalid_request", "Pairing requires code and deviceName");
        const result = await this.options.devices.pair(body.code.trim(), body.deviceName);
        return sendJson(response, 200, { ...result, ...this.options.service.info() as Record<string, JsonValue> });
      }

      let handler: Promise<void> | undefined;
      const admitted = await this.options.devices.authenticateAndAdmit(bearer(request), (authenticated) => {
        if (response.destroyed || response.writableEnded || request.aborted) return false;
        if (this.shuttingDown || !this.ready) {
          throw new GatewayError("busy", "Gateway shutdown began before HTTP admission", true);
        }
        const identity = authenticated.kind === "local" ? "local-wrapper" : authenticated.deviceId;
        // Authentication yielded while the transport lease remained held. The
        // identity cut is synchronous before route admission. Await route work
        // outside the credential owner's lock, retaining this transport lease.
        transportLease.identify(identity);
        handler = this.handleAuthenticatedHttp(request, response, url, authenticated, readLifetime.signal)
          .catch((error) => this.handleHttpError(request, response, error));
        return true;
      }, readLifetime.signal);
      if (admitted === null) return sendJson(response, 401, { error: { code: "unauthenticated", message: "Pairing token is invalid" } });
      // GETs, bounded staging bodies and viewer leases are disposable. Accepted
      // pairing/discard mutations retain their original settlement authority.
      const disposable = request.method === "GET"
        || request.method === "POST" && url.pathname === "/v1/uploads"
        || /^\/v1\/sessions\/[^/]+\/live-views\//.test(url.pathname);
      if (disposable) await abortableRead(readLifetime.signal, () => handler ?? Promise.resolve());
      else await handler;
    } catch (error) {
      this.handleHttpError(request, response, error);
    } finally {
      workSettled = true;
      releaseTransportLease();
    }
  }

  private handleHttpError(request: IncomingMessage, response: ServerResponse, error: unknown): void {
    if (response.destroyed || response.writableFinished) return;
    if (response.headersSent) {
      response.destroy(error instanceof Error ? error : undefined);
      return;
    }
    const failure = publicError(error);
    const status = failure.code === "unauthenticated" ? 401
      : failure.code === "not_found" ? 404
        : failure.code === "invalid_request" ? 400
          : failure.code === "conflict" ? 409
            : failure.code === "busy" ? 503
              : 500;
    if (!request.complete) {
      response.setHeader("connection", "close");
      response.once("finish", () => request.destroy());
    }
    sendJson(response, status, { error: failure });
  }

  private async handleAuthenticatedHttp(
    request: IncomingMessage,
    response: ServerResponse,
    url: URL,
    authenticated: { kind: "local" } | DeviceIdentity,
    signal: AbortSignal,
  ): Promise<void> {
    if (request.method === "POST" && url.pathname === "/v1/uploads") {
      await this.options.uploads.withBodyAdmission(async () => {
        const name = url.searchParams.get("name") ?? "attachment";
        const mimeType = request.headers["content-type"] ?? "application/octet-stream";
        const rawDeclared = request.headers["content-length"];
        const declaredBytes = rawDeclared === undefined ? undefined : Number(rawDeclared);
        const upload = await this.options.uploads.saveStream(name, mimeType, completeRequestBody(request), declaredBytes);
        try {
          if (response.destroyed) throw new GatewayError("busy", "Upload response was retired", true);
          sendJson(response, 201, { upload: { id: upload.id, name: upload.name, mimeType: upload.mimeType, size: upload.size } });
          await finished(response, { readable: false, cleanup: true });
        } catch (error) {
          // Body completion is not receipt publication. Drop only abandoned
          // staging; discard's serialized claim check protects an attachment
          // already owned by an accepted prompt, even in a close/claim race.
          try { await this.options.uploads.discard(upload.id); }
          catch (cleanupError) {
            if (!(cleanupError instanceof GatewayError && ["conflict", "not_found"].includes(cleanupError.code))) {
              this.options.logger.log("warning", "Abandoned upload cleanup failed", { event: "http.upload-cleanup", source: "transport" });
            }
          }
          throw error;
        }
      });
      return;
    }
    if (request.method === "DELETE" && url.pathname.startsWith("/v1/uploads/")) {
      const id = decodeURIComponent(url.pathname.slice("/v1/uploads/".length));
      await this.options.uploads.discard(id);
      response.writeHead(204, { "cache-control": "no-store" });
      response.end();
      return;
    }
    const liveRoute = /^\/v1\/sessions\/([^/]+)\/live-views\/([^/]+)(?:\/(frame))?$/.exec(url.pathname);
    if (liveRoute && this.options.liveViews) {
      const sessionId = decodeURIComponent(liveRoute[1]!);
      const viewId = decodeURIComponent(liveRoute[2]!);
      const viewerId = authenticated.kind === "local" ? "local-wrapper" : authenticated.deviceId;
      if (request.method === "POST" && liveRoute[3] === undefined) {
        const bytes = await readBoundedBody(request, 4_096);
        let body: unknown;
        try { body = JSON.parse(bytes.toString("utf8")); } catch { throw new GatewayError("invalid_request", "Live view body must be JSON"); }
        const generation = body && typeof body === "object" && !Array.isArray(body)
          ? (body as Record<string, unknown>).generation : undefined;
        if (typeof generation !== "string" || generation.length > 200) throw new GatewayError("invalid_request", "Live view generation is required");
        const openAndRespond = (): boolean => {
          if (request.readableAborted || request.socket.destroyed || response.destroyed) return true;
          if (this.shuttingDown || !this.ready) throw new GatewayError("busy", "Gateway is retiring browser observers", true);
          if (this.options.authorizeBrowserLiveView?.(sessionId, viewId, generation) !== true) {
            throw new GatewayError("not_found", "Browser view is not on the active session branch");
          }
          const lease = this.options.liveViews!.open(sessionId, viewId, generation, viewerId);
          const close = (): void => { this.options.liveViews!.close(lease.leaseId, viewerId, { sessionId, viewId, generation }); };
          response.once("close", () => { if (!response.writableFinished) close(); });
          try { sendJson(response, 200, lease); } catch (error) { close(); throw error; }
          return true;
        };
        // Body consumption yielded after initial authentication. Re-enter the
        // existing credential mutex, then authorize/create/publish synchronously.
        const admitted = authenticated.kind === "local" ? openAndRespond()
          : await this.options.devices.admitDevice(authenticated.deviceId, openAndRespond, signal);
        if (admitted === undefined) sendJson(response, 401, { error: { code: "unauthenticated", message: "Device was revoked" } });
        return;
      }
      const leaseId = request.headers["x-tron-live-lease"];
      if (typeof leaseId !== "string" || leaseId.length > 200) throw new GatewayError("unauthenticated", "Live view lease is required");
      const generation = request.headers["x-tron-live-generation"];
      if (typeof generation !== "string" || generation.length > 200) throw new GatewayError("invalid_request", "Live view generation is required");
      if (request.method === "DELETE" && liveRoute[3] === undefined) {
        if (!this.options.liveViews.close(leaseId, viewerId, { sessionId, viewId, generation })) throw new GatewayError("unauthenticated", "Live view lease is invalid");
        response.writeHead(204, { "cache-control": "no-store" });
        response.end();
        return;
      }
      if (request.method === "GET" && liveRoute[3] === "frame") {
        // No await on this path: initial authentication, branch check, lease
        // admission and publication share the same synchronous authority cut.
        if (request.readableAborted || request.socket.destroyed || response.destroyed) return;
        if (this.options.authorizeBrowserLiveView?.(sessionId, viewId, generation) !== true) {
          this.options.liveViews.retireView(sessionId, viewId, generation);
          throw new GatewayError("not_found", "Browser view is not on the active session branch");
        }
        const afterHeader = request.headers["x-tron-live-after"];
        if (afterHeader !== undefined && (typeof afterHeader !== "string" || !/^\d{1,16}$/.test(afterHeader))) {
          throw new GatewayError("invalid_request", "Frame sequence is invalid");
        }
        const delivery = this.options.liveViews.acquireFrame(sessionId, viewId, generation, leaseId, viewerId,
          () => { response.destroy(); }, Number(afterHeader ?? 0));
        const release = (): void => {
          response.off("finish", release); response.off("close", release); response.off("error", release);
          delivery.release();
        };
        response.once("finish", release); response.once("close", release); response.once("error", release);
        try {
          const frame = delivery.frame;
          if ("status" in frame) {
            response.writeHead(204, { "cache-control": "no-store", "x-tron-live-state": frame.status });
            response.end();
          } else {
            response.writeHead(200, {
              "content-type": frame.mimeType,
              "content-length": frame.data.length,
              "cache-control": "no-store",
              "x-content-type-options": "nosniff",
              "x-tron-live-width": String(frame.width),
              "x-tron-live-height": String(frame.height),
              "x-tron-live-sequence": String(frame.sequence),
            });
            response.end(frame.data);
          }
        } catch (error) { release(); throw error; }
        return;
      }
    }
    if (request.method === "GET" && url.pathname.startsWith("/v1/uploads/")) {
      const id = decodeURIComponent(url.pathname.slice("/v1/uploads/".length));
      const lease = await this.options.uploads.acquire(id, signal);
      try {
        response.writeHead(200, {
          "content-type": lease.mimeType,
          "content-length": lease.size,
          "content-disposition": `inline; filename*=UTF-8''${encodeURIComponent(lease.name)}`,
          "cache-control": "private, max-age=300",
          "x-content-type-options": "nosniff",
        });
        response.flushHeaders();
        await pipeline(lease.stream, response);
      } finally {
        await lease.release();
      }
      return;
    }
    const displayRoute = /^\/v1\/sessions\/([^/]+)\/display-artifacts\/([^/]+)$/.exec(url.pathname);
    if (request.method === "GET" && displayRoute) {
      const sessionID = decodeURIComponent(displayRoute[1]!);
      const artifactID = decodeURIComponent(displayRoute[2]!);
      let requestedRange: BlobByteRange | undefined;
      try {
        requestedRange = parseBlobByteRange(request.headers.range);
      } catch (error) {
        if (!(error instanceof GatewayError) || error.code !== "invalid_request") throw error;
        sendJson(response, 416, { error: publicError(error) });
        return;
      }
      let lease: Awaited<ReturnType<RuntimeRegistry["acquireDisplayArtifact"]>>;
      try {
        lease = await this.options.sessions.acquireDisplayArtifact(sessionID, artifactID, requestedRange, signal);
      } catch (error) {
        const details = error instanceof GatewayError && error.details && typeof error.details === "object"
          ? error.details as { rangeUnsatisfiable?: unknown; totalSize?: unknown }
          : undefined;
        if (error instanceof GatewayError && error.code === "invalid_request"
          && details?.rangeUnsatisfiable === true && Number.isSafeInteger(details.totalSize)) {
          response.setHeader("content-range", `bytes */${details.totalSize}`);
          sendJson(response, 416, { error: publicError(error) });
          return;
        }
        throw error;
      }
      const etag = `\"display-${artifactID}\"`;
      try {
        if (request.headers["if-none-match"] === etag) {
          response.writeHead(304, { etag, "cache-control": "private, immutable, max-age=31536000" });
          response.end();
          return;
        }
        response.writeHead(requestedRange ? 206 : 200, {
          "content-type": lease.mimeType,
          "content-length": lease.size,
          "accept-ranges": "bytes",
          etag,
          ...(requestedRange ? { "content-range": `bytes ${lease.rangeStart}-${lease.rangeEnd}/${lease.totalSize}` } : {}),
          "cache-control": "private, immutable, max-age=31536000",
          "x-content-type-options": "nosniff",
        });
        response.flushHeaders();
        await pipeline(lease.stream, response);
      } finally {
        await lease.release();
      }
      return;
    }
    if (request.method === "GET" && url.pathname.startsWith("/v1/blobs/")) {
      const id = decodeURIComponent(url.pathname.slice("/v1/blobs/".length));
      const requestedRange = parseBlobByteRange(request.headers.range);
      const lease = await this.options.sessions.acquireBlob(id, requestedRange, signal);
      try {
        response.writeHead(requestedRange ? 206 : 200, {
          "content-type": lease.mimeType,
          "content-length": lease.size,
          "accept-ranges": "bytes",
          ...(requestedRange ? { "content-range": `bytes ${lease.rangeStart}-${lease.rangeEnd}/${lease.totalSize}` } : {}),
          "cache-control": "private, max-age=300",
          "x-content-type-options": "nosniff",
        });
        response.flushHeaders();
        await pipeline(lease.stream, response);
      } finally {
        await lease.release();
      }
      return;
    }
    sendJson(response, 404, { error: { code: "not_found", message: "Route not found" } });
  }

  private async handleUpgrade(request: IncomingMessage, socket: Duplex, head: Buffer): Promise<void> {
    // Node relinquishes its HTTP parser on upgrade, before async credentials
    // return. Own EOF/error and the auth deadline until ws takes the socket;
    // otherwise a half-closed pre-handshake peer can live indefinitely.
    const readLifetime = new AbortController();
    const retirePendingUpgrade = (): void => { readLifetime.abort(); socket.destroy(); };
    socket.once("end", retirePendingUpgrade);
    socket.once("error", retirePendingUpgrade);
    socket.once("close", retirePendingUpgrade);
    const authenticationDeadline = setTimeout(() => {
      this.options.logger.log("warning", "Socket upgrade authentication timed out", { event: "http.authentication-timeout", source: "transport" });
      retirePendingUpgrade();
    }, HTTP_REQUEST_IDLE_TIMEOUT_MS);
    authenticationDeadline.unref();
    const releasePendingUpgrade = (): void => {
      clearTimeout(authenticationDeadline);
      socket.off("end", retirePendingUpgrade);
      socket.off("error", retirePendingUpgrade);
      socket.off("close", retirePendingUpgrade);
    };
    // An upgrade awaiting credentials is still an admitted HTTP operation.
    // Physical close alone cannot release its pending authentication budget.
    const transportLease = this.httpAdmission.admit(request.socket.remoteAddress ?? "unknown", socket);
    if (!transportLease) {
      this.options.logger.log("warning", "Rejected upgrade at HTTP authentication capacity", { event: "http.request-capacity", source: "transport" });
      socket.write("HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n");
      socket.destroy();
      releasePendingUpgrade();
      return;
    }
    try {
      const url = new URL(request.url ?? "/", `http://${request.headers.host ?? "localhost"}`);
      if (url.pathname !== "/v1/socket") {
        socket.destroy();
        return;
      }
      if (!this.ready || this.shuttingDown) {
        // Expected during startup warmup and shutdown; clients retry.
        this.options.logger.log("info", `Rejected socket upgrade while gateway is ${this.shuttingDown ? "shutting down" : "warming up"}`, {
          event: "connection.rejected", source: "transport", reason: this.shuttingDown ? "shutting_down" : "warming_up",
        });
        socket.write("HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n");
        socket.destroy();
        return;
      }
      const admission = await this.options.devices.authenticateAndAdmit(bearer(request), (authenticated) => {
        // Authentication can yield while shutdown starts. Recheck the
        // admission cut after that await so an upgrade cannot become a live
        // connection after the listener has begun retiring work.
        if (socket.destroyed) return false;
        if (this.shuttingDown || !this.ready) {
          socket.write("HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n");
          socket.destroy();
          return false;
        }
        const identity = authenticated.kind === "local" ? "local-wrapper" : authenticated.deviceId;
        const maximumConnections = this.options.maximumConnections ?? 32;
        const maximumPerIdentity = this.options.maximumConnectionsPerIdentity ?? GATEWAY_CONNECTION_POLICY.perIdentitySocketCap;
        // A closing connection has already retired its work and is terminated
        // within one second; it is not live capacity.
        const live = [...this.clients.values()].filter((client) => !client.closeInitiated);
        const identityConnections = live
          .filter((client) => client.identity === identity)
          .sort((left, right) => (left.lastInboundAt ?? left.admittedAt) - (right.lastInboundAt ?? right.admittedAt));
        // A roaming or suspended phone leaves half-open sockets that heartbeat
        // reaping only retires after minutes. The same authenticated identity
        // opening a new socket is stronger evidence than those stale epochs, so
        // the newest connection supersedes that identity's least recently active
        // ones instead of locking the device out. Other identities are never
        // displaced: global capacity still rejects them.
        let superseded = 0;
        while (superseded < identityConnections.length
          && (identityConnections.length - superseded >= maximumPerIdentity
            || live.length - superseded >= maximumConnections)) {
          superseded += 1;
        }
        if (live.length - superseded >= maximumConnections) {
          this.options.logger.log("warning", `Rejected socket upgrade at connection capacity (connections=${live.length} maximumConnections=${maximumConnections} identityConnections=${identityConnections.length} maximumPerIdentity=${maximumPerIdentity})`, { event: "connection.capacity", source: "transport" });
          socket.write("HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n");
          socket.destroy();
          return false;
        }
        const supersededAt = performance.now();
        for (const client of identityConnections.slice(0, superseded)) {
          this.options.logger.log("warning", `Superseding client ${client.id} with a newer connection from the same identity (lastInboundAgeMs=${progressAge(client.lastInboundAt, supersededAt)} identityConnections=${identityConnections.length} maximumPerIdentity=${maximumPerIdentity})`, { event: "connection.superseded", source: "transport" });
          this.closeFailedConnection(client, SUPERSEDED_CLOSE_CODE, "superseded by a newer connection");
        }
        this.sockets.handleUpgrade(request, socket, head, (webSocket) => {
          this.admit(webSocket, identity, authenticated.kind === "local");
        });
        return true;
      }, readLifetime.signal);
      if (admission === null) {
        this.options.logger.log("warning", "Rejected unauthenticated socket upgrade", { event: "connection.rejected", source: "transport" });
        socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n");
        socket.destroy();
      }
    } catch {
      socket.destroy();
    } finally {
      releasePendingUpgrade();
      transportLease.release();
    }
  }

  private admit(socket: WebSocket, identity: string, isLocal: boolean): void {
    let connection: Connection;
    const maximumOutboundBytes = this.options.maximumOutboundBytes ?? 8 * 1_048_576;
    const outbound = new OrderedOutboundQueue(
      maximumOutboundBytes,
      (encoded, completion) => socket.send(encoded, (error) => {
        if (!error) connection.lastWriteProgressAt = performance.now();
        completion(error);
      }),
      (snapshot, nextBytes) => {
        if (connection.closeInitiated) return;
        this.options.logger.log(
          "warning",
          `Closing client ${connection.id} at outbound queue capacity (queuedFrames=${snapshot.queuedFrames} queuedBytes=${snapshot.queuedBytes} maximumFrames=${snapshot.maximumFrames} maximumBytes=${snapshot.maximumBytes} frameHighWater=${snapshot.frameHighWater} byteHighWater=${snapshot.byteHighWater} wsBufferedBytes=${socket.bufferedAmount} nextBytes=${nextBytes}; ${this.pressureDiagnostic()})`,
          { event: "connection.outbound-capacity", source: "transport", connectionId: connection.id },
        );
        this.closeFailedConnection(connection, 1013, "client outbound capacity exceeded");
      },
      (error, snapshot) => {
        if (connection.closeInitiated) return;
        connection.closeInitiated = true;
        this.options.logger.log(
          "error",
          `Client ${connection.id} outbound write failed after ${snapshot.completedFrames}/${snapshot.acceptedFrames} frames`,
          { event: "connection.write-error", source: "transport", connectionId: connection.id, error },
        );
        this.retireConnectionWork(connection);
        socket.terminate();
      },
    );
    connection = {
      id: randomUUID(),
      identity,
      isLocal,
      socket,
      unansweredHeartbeats: 0,
      ready: false,
      presentationOnly: false,
      terminals: new Set(),
      inFlight: new Set(),
      requestControllers: new Map(),
      synchronizations: new Map(),
      subscriptionTokens: new Map(),
      rekeyedSessionIds: new Map(),
      synchronizationBytes: 0,
      pendingSessionOpens: new Map(),
      outbound,
      closeInitiated: false,
      workRetired: false,
      revoked: false,
      revokeResponseQueued: false,
      revokeCloseScheduled: false,
      admittedAt: performance.now(),
      lastInboundAt: null,
      lastWriteProgressAt: null,
      helloTimer: setTimeout(() => this.closeFailedConnection(connection, 1008, "hello required"), GATEWAY_CONNECTION_POLICY.helloDeadlineMs),
    };
    this.clients.set(connection.id, connection);
    socket.on("message", (data, binary) => {
      connection.unansweredHeartbeats = 0;
      connection.lastInboundAt = performance.now();
      void this.onMessage(connection, binary ? data : data.toString());
    });
    socket.on("ping", () => {
      connection.unansweredHeartbeats = 0;
      connection.lastInboundAt = performance.now();
    });
    socket.on("pong", () => {
      connection.unansweredHeartbeats = 0;
      connection.lastInboundAt = performance.now();
    });
    socket.on("close", (code, reason) => {
      const suffix = reason.length > 0 ? `: ${reason.toString("utf8")}` : "";
      this.disconnect(connection, `WebSocket close ${code}${suffix}`);
    });
    socket.on("error", (error) => this.disconnect(connection, `WebSocket error: ${error.message}`));
  }

  private async onMessage(connection: Connection, raw: unknown): Promise<void> {
    // A close handshake is not an admission lease. In particular, a peer that
    // overflowed the writer cannot submit more work while close is pending.
    if (connection.closeInitiated || connection.socket.readyState !== WebSocket.OPEN
      || !this.clients.has(connection.id)) return;
    let frame: Record<string, unknown>;
    try {
      const text = typeof raw === "string" ? raw : Buffer.from(raw as ArrayBuffer).toString("utf8");
      frame = JSON.parse(text) as Record<string, unknown>;
      if (typeof frame !== "object" || frame === null || Array.isArray(frame)) throw new Error();
    } catch {
      return this.closeFailedConnection(connection, 1007, "invalid JSON");
    }

    if (!connection.ready) {
      if (frame.type !== "hello" || !Number.isSafeInteger(frame.protocolVersion)) return this.closeFailedConnection(connection, 1008, "valid hello required");
      const protocol = frame.protocolVersion as number;
      if (protocol < MIN_PROTOCOL_VERSION || protocol > PROTOCOL_VERSION) return this.closeFailedConnection(connection, 1008, "protocol version mismatch");
      connection.ready = true;
      connection.presentationOnly = (frame as Record<string, unknown>).clientRole === "mobile";
      // Admission and handshake are one `connection.opened` record. The Mac
      // app's local probes reconnect constantly, so they are debug detail.
      this.options.logger.log(
        connection.isLocal ? "debug" : "info",
        `Client ${connection.id} connection opened (${connection.isLocal ? "local" : "paired"}, ${connection.presentationOnly ? "mobile" : "local"} role) after ${Math.max(0, Math.round(performance.now() - connection.admittedAt))}ms`,
        { event: "connection.opened", source: "transport", connectionId: connection.id },
      );
      clearTimeout(connection.helloTimer);
      this.send(connection, { type: "hello", ...this.options.service.info() as Record<string, JsonValue> });
      return;
    }

    if (connection.revoked) {
      if (frame.type === "request" && typeof frame.id === "string") {
        this.send(connection, {
          type: "response",
          id: frame.id,
          ok: false,
          error: publicError(new GatewayError("unauthenticated", "This device is no longer authorized")),
        });
      }
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
    const requestController = new AbortController();
    const admittedSubscriptionIds = new Set(connection.subscriptionTokens.keys());
    const admittedTerminalIds = new Set(connection.terminals);
    connection.requestControllers.set(frame.id, requestController);
    const requestId = frame.id;
    const diagnosticID = diagnosticRequestID(requestId);
    const rpcStartedAt = performance.now();
    const params = frame.params && typeof frame.params === "object" && !Array.isArray(frame.params)
      ? frame.params as Record<string, unknown>
      : {};
    // Correlation only: identifiers the client already chose, never payload.
    const rpcCorrelation = {
      ...(typeof params.sessionId === "string" ? { sessionId: params.sessionId } : {}),
      ...(typeof params.commandId === "string" ? { commandId: params.commandId } : {}),
    };
    let rpcOutcome: "success" | "failure" = "failure";
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
    const revokeInstalledSubscription = (sessionId: string, token: string): boolean => {
      sessionId = resolveSessionId(sessionId);
      // The installed token is the ownership proof. The synchronization map is
      // only a pending barrier and may already have been removed after a
      // compact resync fallback was enqueued.
      if (connection.subscriptionTokens.get(sessionId) !== token) return false;
      const synchronization = connection.synchronizations.get(sessionId);
      if (synchronization) {
        clearTimeout(synchronization.timeout);
        synchronization.barrier.abort(synchronization.requestId);
        connection.synchronizations.delete(sessionId);
      }
      connection.subscriptionTokens.delete(sessionId);
      clearRekeyedSessionIds(sessionId);
      releaseSessionTerminals(
        connection.terminals,
        sessionId,
        (terminalId, ownerSessionId) => this.options.service.terminalBelongsToSession(terminalId, ownerSessionId),
      );
      this.options.sessions.unsubscribe(connection.id, sessionId);
      this.options.service.releaseSessionProcessTranscripts?.(sessionId, connection.id, token);
      return true;
    };
    const revokeSynchronization = (sessionId: string, synchronization: ActiveSessionSynchronization): boolean => {
      sessionId = resolveSessionId(sessionId);
      // A later session.open may have replaced this request's owner. In that
      // case, only the current token may revoke the runtime subscription.
      if (connection.synchronizations.get(sessionId) !== synchronization
          || connection.subscriptionTokens.get(sessionId) !== synchronization.subscriptionToken) return false;
      return revokeInstalledSubscription(sessionId, synchronization.subscriptionToken);
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
      clearRekeyedSessionIds(sessionId);
      releaseSessionTerminals(
        connection.terminals,
        sessionId,
        (terminalId, ownerSessionId) => this.options.service.terminalBelongsToSession(terminalId, ownerSessionId),
      );
      this.options.sessions.unsubscribe(connection.id, sessionId);
      this.options.service.releaseSessionProcessTranscripts?.(sessionId, connection.id, token);
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
        signal: requestController.signal,
        beginSynchronization: (sessionId) => {
          if (connection.revoked) throw new GatewayError("unauthenticated", "This device is no longer authorized");
          if (connection.workRetired) throw new GatewayError("busy", "Connection is closed", true);
          // Runtime acquire may yield to a fork before this call. Resolve the
          // request's ID before installing the subscription and barrier so
          // ownership is attached to the canonical slot.
          sessionId = resolveSessionId(sessionId);
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
        setPresentationVisibility: (sessionId, subscriptionToken, revision, visible) => {
          if (connection.revoked) throw new GatewayError("unauthenticated", "This device is no longer authorized");
          sessionId = resolveSessionId(sessionId);
          if (!connection.presentationOnly) {
            throw new GatewayError("invalid_request", "Only a mobile presentation connection may publish chat visibility");
          }
          if (connection.subscriptionTokens.get(sessionId) !== subscriptionToken
            || connection.synchronizations.has(sessionId)) {
            throw new GatewayError("conflict", "Session presentation subscription is not current", true);
          }
          return this.options.sessions.setPresentationVisibility({
            clientId: connection.id,
            sessionId,
            subscriptionToken,
            revision,
            visible,
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
          this.options.sessions.unsubscribe(connection.id, sessionId);
          return true;
        },
        attachTerminal: (terminalId) => {
          if (connection.revoked) throw new GatewayError("unauthenticated", "This device is no longer authorized");
          if (connection.workRetired) throw new GatewayError("busy", "Connection is closed", true);
          if (!canAttachTerminal(
            connection.subscriptionTokens,
            terminalId,
            (id, sessionId) => this.options.service.terminalBelongsToSession(id, sessionId),
          )) {
            throw new GatewayError("invalid_request", "Open the terminal's session before attaching", false);
          }
          connection.terminals.add(terminalId);
        },
        detachTerminal: (terminalId) => connection.terminals.delete(terminalId),
        ownsTerminal: (terminalId) => connection.terminals.has(terminalId) || admittedTerminalIds.has(terminalId),
        isSubscribed: (sessionId) => connection.subscriptionTokens.has(sessionId) || admittedSubscriptionIds.has(sessionId),
        subscriptionToken: (sessionId) => connection.subscriptionTokens.get(resolveSessionId(sessionId)),
        isRevoked: () => connection.revoked,
        revokeDevice: (deviceId) => this.disconnectDevice(deviceId, {
          connectionId: connection.id,
          requestId,
          deviceId,
        }),
        sendEvent: (topic, sessionId, payload) => {
          this.send(connection, { type: "event", topic, sessionId, payload });
        },
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
      if (responseSentIntact) rpcOutcome = "success";
      if (responseSentIntact && connection.revoked && connection.revokeResponseRequestId === frame.id) {
        connection.revokeResponseQueued = true;
        this.closeRevokedConnectionAfterResponse(connection);
      }
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

          const revokeBeforeResync = (): void => {
            // resyncRequired is a terminal barrier: revoke every local and
            // runtime ownership before publishing it, otherwise a later event
            // can bypass the absent barrier while the client still believes it
            // has a subscription. The token check remains valid even after the
            // pending barrier was removed for a compact fallback.
            revokeInstalledSubscription(completion.sessionId, completion.subscriptionToken);
          };
          const sendResyncRequired = () => this.send(connection, {
            type: "event",
            topic: "transport.resyncRequired",
            sessionId: completion.sessionId,
            payload: { reason: "subscription catch-up overflow" },
          });
          if (recovery === undefined) {
            revokeBeforeResync();
            sendResyncRequired();
            continue;
          }

          active.barrier.establish(recovery);
          const recovered = active.barrier.commit(completion.syncToken);
          clearTimeout(active.timeout);
          if (recovered.overflowed) {
            // The recovery quarantine overflowed too; no snapshot or suffix is
            // trustworthy enough to publish. Revoke the installed token and
            // terminal attachments before the resync notice can be observed.
            revokeBeforeResync();
            sendResyncRequired();
            continue;
          }
          connection.synchronizations.delete(completion.sessionId);

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
            for (const event of recovered.events) {
              const preparedEvent = active.barrier.takeEncoding(event);
              this.sendOutcome(connection, event, preparedEvent);
            }
          } else {
            // Both an encoded fallback and a failed write are resync paths.
            // The fallback already carries the notice; a failed write gets a
            // best-effort direct notice after ownership is revoked.
            revokeBeforeResync();
            if (recoveryOutcome === "failed") sendResyncRequired();
          }
        } else {
          const completed = active.barrier.commit(completion.syncToken);
          clearTimeout(active.timeout);
          connection.synchronizations.delete(completion.sessionId);
          for (const event of completed.events) {
            const preparedEvent = active.barrier.takeEncoding(event);
            this.sendOutcome(connection, event, preparedEvent);
          }
        }
      }
    } catch (error) {
      if (!requestController.signal.aborted) {
        const level = rpcFailureLevel(error);
        this.options.logger.log(level, `RPC ${frame.method} for client ${connection.id} failed`, {
          event: "rpc.error", source: "transport", method: frame.method, requestID: diagnosticID,
          connectionId: connection.id, ...rpcCorrelation,
          code: diagnosticErrorCode(error), outcome: "failure",
          // Structured detail only for faults; a caller mistake keeps its code.
          ...(level === "error" ? { error } : {}),
          ...(error instanceof GatewayError && error.diagnosticReason ? { reason: error.diagnosticReason } : {}),
        });
      }
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
        const responseSent = this.send(connection, { type: "response", id: frame.id, ok: false, error: publicError(error) });
        if (responseSent && connection.revoked && connection.revokeResponseRequestId === frame.id) {
          connection.revokeResponseQueued = true;
          this.closeRevokedConnectionAfterResponse(connection);
        }
      }
    } finally {
      if (sessionOpenID !== undefined) {
        const resolvedOpenID = resolveSessionId(sessionOpenID);
        // Rekey retains an old duplicate-open alias but the canonical
        // reservation is the one that must be released after begin/response.
        if (connection.pendingSessionOpens.get(resolvedOpenID) === frame.id) {
          connection.pendingSessionOpens.delete(resolvedOpenID);
        }
        if (resolvedOpenID !== sessionOpenID
            && connection.pendingSessionOpens.get(sessionOpenID) === frame.id) {
          connection.pendingSessionOpens.delete(sessionOpenID);
        }
      }
      connection.inFlight.delete(frame.id);
      connection.requestControllers.delete(frame.id);
      const durationMs = Math.max(0, Math.round(performance.now() - rpcStartedAt));
      this.options.logger.log(
        rpcOutcome === "failure" || durationMs >= SLOW_RPC_WARNING_MS ? "warning" : "debug",
        `RPC ${frame.method} for client ${connection.id} completed in ${durationMs}ms (${rpcOutcome})`,
        {
          event: "rpc.completed", source: "transport", method: frame.method,
          requestID: diagnosticID, connectionId: connection.id, ...rpcCorrelation, outcome: rpcOutcome, durationMs,
        },
      );
    }
  }

  private send(connection: Connection, value: unknown): boolean {
    return this.sendOutcome(connection, value) === "sent";
  }

  private prepareBroadcastFrame(value: unknown): PreparedOutboundFrame | null {
    try {
      return prepareOutboundFrame(value, this.options.maxFrameBytes) ?? null;
    } catch {
      // Broadcast preparation is outside the per-connection failure boundary;
      // retain the old isolated failure behavior without allowing one malformed
      // producer value to abort the fanout loop.
      this.options.logger.log("error", "Outbound projection encoding failed", {
        event: "connection.projection-rejected", source: "transport",
      });
      return null;
    }
  }

  private closeRevokedConnectionAfterResponse(connection: Connection): void {
    if (!connection.revoked || !connection.revokeResponseQueued || connection.revokeCloseScheduled) return;
    connection.revokeCloseScheduled = true;
    let deadline!: NodeJS.Timeout;
    let closeRequested = false;
    const requestClose = (force: boolean): void => {
      if (closeRequested) return;
      closeRequested = true;
      clearTimeout(deadline);
      if (force) {
        connection.outbound.retire();
        // A stalled writer or close handshake must not retain capacity until
        // ws's longer close timeout. The close handler owns normal cleanup.
        if (connection.socket.readyState !== WebSocket.CLOSED) connection.socket.terminate();
      } else if (connection.socket.readyState === WebSocket.OPEN) {
        this.closeFailedConnection(connection, 1008, "device revoked");
      }
    };
    deadline = setTimeout(() => requestClose(true), 1_000);
    deadline.unref();
    connection.outbound.whenIdle(() => requestClose(false));
  }

  private sendOutcome(
    connection: Connection,
    value: unknown,
    prepared?: PreparedOutboundFrame | null,
  ): "sent" | "fallback" | "failed" {
    if (connection.closeInitiated || connection.socket.readyState !== WebSocket.OPEN) return "failed";
    if (connection.revoked) {
      const frame = value as { type?: unknown; id?: unknown };
      // Revocation retires events and observer delivery. Already queued frames
      // drain in order, but only the exact initiating self-revoke response may
      // be added after the durable cut; accepted work settles canonically.
      if (frame.type !== "response"
          || typeof frame.id !== "string"
          || frame.id !== connection.revokeResponseRequestId
          || !connection.inFlight.has(frame.id)) return "failed";
    }
    try {
      const frame = prepared === undefined ? prepareOutboundFrame(value, this.options.maxFrameBytes) : prepared;
      if (!frame) return "failed";
      if (frame.fallback) {
        const valueFrame = value as { type?: unknown; topic?: unknown };
        const type = valueFrame?.type === "response" ? "response" : valueFrame?.type === "event" ? "event" : "other";
        const topic = typeof valueFrame?.topic === "string"
          && ["session.snapshot", "session.rebaseline", "session.progress", "session.summary"].includes(valueFrame.topic)
          ? valueFrame.topic : "other";
        this.options.logger.log("warning", `Outbound projection exceeded frame limit (type=${type} topic=${topic} bytes=${frame.bytes} maximumBytes=${this.options.maxFrameBytes} nodeCountAtLeast=${frame.nodes ?? "unknown"} maximumNodes=${GATEWAY_JSON_MAXIMUM_NODES}; ${this.pressureDiagnostic()})`, {
          event: "connection.projection-rejected", source: "transport",
        });
      }

      // Enqueue acceptance is the ordering boundary. The connection-local
      // writer hands exactly one encoded frame to ws at a time, preserving a
      // response before its synchronization suffix without manufacturing
      // transport pressure from concurrent bounded RPC completions.
      if (!connection.outbound.enqueue({ encoded: frame.output, bytes: frame.outputBytes })) return "failed";
      return frame.fallback ? "fallback" : "sent";
    } catch {
      // Never log the exception or payload: serialization errors can contain
      // producer content. Failure must still be observable without killing the
      // broadcaster or unrelated clients.
      this.options.logger.log("error", "Outbound projection encoding failed", {
        event: "connection.projection-rejected", source: "transport",
      });
      return "failed";
    }
  }

  private disconnect(connection: Connection, detail = "WebSocket closed"): void {
    if (!this.clients.delete(connection.id)) return;
    const closedAt = performance.now();
    const outbound = connection.outbound.snapshot();
    connection.outbound.retire();
    this.options.logger.log(
      connection.isLocal ? "debug" : "info",
      `Client ${connection.id} connection closed after ${Math.max(0, Math.round(closedAt - connection.admittedAt))}ms (${detail}; ${outbound.completedFrames}/${outbound.acceptedFrames} outbound frames completed, ${outbound.queuedBytes} queued bytes; lastInboundAgeMs=${progressAge(connection.lastInboundAt, closedAt)} lastWriteProgressAgeMs=${progressAge(connection.lastWriteProgressAt, closedAt)} queuedFrames=${outbound.queuedFrames} queuedBytes=${outbound.queuedBytes} completedFrames=${outbound.completedFrames})`,
      { event: "connection.closed", source: "transport", connectionId: connection.id,
        durationMs: Math.max(0, closedAt - connection.admittedAt) },
    );
    clearTimeout(connection.closeDeadline);
    this.retireConnectionWork(connection);
  }

  private retireConnectionWork(connection: Connection): void {
    if (connection.workRetired) return;
    connection.workRetired = true;
    connection.ready = false;
    clearTimeout(connection.helloTimer);
    for (const synchronization of connection.synchronizations.values()) {
      clearTimeout(synchronization.timeout);
      synchronization.barrier.abort(synchronization.requestId);
    }
    connection.synchronizations.clear();
    connection.subscriptionTokens.clear();
    connection.terminals.clear();
    connection.pendingSessionOpens.clear();
    connection.rekeyedSessionIds.clear();
    // Revoked accepted requests retain their controller until their own
    // completion; ordinary disconnects still abort disposable work.
    if (!connection.revoked) for (const controller of connection.requestControllers.values()) controller.abort();
    connection.requestControllers.clear();
    this.options.sessions.unsubscribeClient(connection.id);
    this.options.service.releaseClient(connection.id);
    // The authenticated device identity owns provider login. A socket close
    // only detaches event delivery; auth.resume can bind a replacement socket.
    this.options.auth.detachClient(connection.id);
  }

  private closeFailedConnection(connection: Connection, code: number, reason: string): void {
    if (connection.closeInitiated) return;
    connection.closeInitiated = true;
    connection.outbound.retire();
    // Disposable observers/read waits retire now, not after a dead peer's close
    // handshake. Accepted domain commands still settle with their receipt owner.
    this.retireConnectionWork(connection);
    connection.closeDeadline = setTimeout(() => {
      if (connection.socket.readyState !== WebSocket.CLOSED) connection.socket.terminate();
    }, 1_000);
    connection.closeDeadline.unref();
    connection.socket.close(code, reason);
  }

  private pressureDiagnostic(): string {
    const memory = process.memoryUsage();
    let inFlightRequests = 0;
    let outboundQueuedBytes = 0;
    for (const connection of this.clients.values()) {
      inFlightRequests += connection.inFlight.size;
      outboundQueuedBytes += connection.outbound.snapshot().queuedBytes;
    }
    return `connections=${this.clients.size} inFlightRequests=${inFlightRequests} outboundQueuedBytes=${outboundQueuedBytes} rssBytes=${memory.rss} heapUsedBytes=${memory.heapUsed} externalBytes=${memory.external}`;
  }

  close(): Promise<void> {
    if (this.closeTask) return this.closeTask;
    this.shuttingDown = true;
    this.ready = false;
    // Install the shared receipt before callbacks run: concurrent close and
    // failed-startup cleanup join the same bounded retirement operation.
    this.closeTask = Promise.resolve().then(() => this.finishClose());
    return this.closeTask;
  }

  private async finishClose(): Promise<void> {
    this.options.liveViews?.dispose();
    await this.options.liveViews?.joinRetirements();
    this.options.logger.log("info", "Closing Gateway transport", { event: "gateway.transport-closing", source: "transport" });
    clearInterval(this.heartbeat);
    this.stallSampler.dispose();
    for (const client of this.clients.values()) {
      const stoppingAccepted = this.send(client, { type: "event", topic: "system.stopping", payload: {} });
      this.retireConnectionWork(client);
      if (!stoppingAccepted) {
        client.socket.close(1012, "gateway restarting");
        continue;
      }
      // The ordered queue's acceptance boundary may be ahead of an active
      // frame. Give the stopping event a short bounded flush opportunity, but
      // never let one stalled peer prevent supervised shutdown indefinitely.
      let closeRequested = false;
      const requestClose = (): void => {
        if (closeRequested) return;
        closeRequested = true;
        client.socket.close(1012, "gateway restarting");
      };
      const deadline = setTimeout(requestClose, 1_000);
      deadline.unref();
      client.outbound.whenIdle(() => {
        clearTimeout(deadline);
        requestClose();
      });
    }
    // `server.close` waits for active HTTP responses. A stalled body or
    // response stream is disposable transport work, so destroy tracked HTTP
    // sockets after the same one-second retirement bound used by WebSocket
    // close handshakes rather than waiting on Node indefinitely.
    let httpClosed = false;
    let forceHttpClose!: NodeJS.Timeout;
    const httpClosedPromise = new Promise<void>((resolve) => {
      this.server.close(() => {
        httpClosed = true;
        clearTimeout(forceHttpClose);
        resolve();
      });
    });
    forceHttpClose = setTimeout(() => {
      for (const socket of this.httpSockets) socket.destroy();
      if (httpClosed) clearTimeout(forceHttpClose);
    }, HTTP_SHUTDOWN_GRACE_MS);
    forceHttpClose.unref();
    await httpClosedPromise;
    this.sockets.close();
  }
}
