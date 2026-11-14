import { createServer, type IncomingMessage, type Server as HTTPServer, type ServerResponse } from "node:http";
import { GATEWAY_JSON_MAXIMUM_NODES, jsonNodeCount } from "../protocol/json-budget.js";
import type { Duplex } from "node:stream";
import { pipeline } from "node:stream/promises";
import { abortableRead } from "../util/abortable-read.js";
import { randomUUID } from "node:crypto";
import { WebSocketServer, WebSocket, type PerMessageDeflateOptions } from "ws";
import { GatewayError, publicError } from "../errors.js";
import type { JsonValue } from "../protocol/types.js";
import type { DeviceIdentity, DeviceStore } from "../security/device-store.js";
import { RateLimiter } from "../security/rate-limiter.js";
import type { UploadStore } from "../machine/upload-store.js";
import type { RuntimeRegistry } from "../kernel/session/runtime-registry.js";
import type { DisplayOwner } from "../display/display-modules.js";
import type { BlobByteRange } from "../sessions/blob-store.js";
import type { AuthBroker } from "../admin/auth-broker.js";
import type { GatewayLogger, LogLevel } from "./logger.js";
import { GATEWAY_CONNECTION_POLICY } from "./connection-policy.js";
import { formatHostEvidence, formatStallEvidence, formatResourceSample, ResourceSampler, RESOURCE_SAMPLE_INTERVAL_MS, StallSampler } from "./stall-diagnostics.js";
import { GatewayService, type ClientContext } from "./gateway-service.js";
import { MIN_PROTOCOL_VERSION, PROTOCOL_MISMATCH_CLOSE_CODE, PROTOCOL_VERSION } from "../version.js";
import { SessionSyncBarrier, type BufferedSessionEncoding, type BufferedSessionEvent } from "./session-sync.js";
import type { BrowserLiveViewRegistry } from "../display/browser-live-view.js";
import { bytes, RequestSpan, runInRequestSpan, stage, wait } from "../util/request-span.js";
import { TailscalePeerPaths, type PeerPathLookup, type PeerPathReader } from "./tailscale-peer.js";
import { LanEndpoint, httpListenerOptions, type LanAdvertisement, type LanEndpointConfig, type LanListenerLimits } from "./lan-endpoint.js";
import { isTailscaleAddress } from "../config.js";
import { OrderedOutboundQueue, UNKNOWN_OUTBOUND_TOPIC, type OutboundFrame } from "./ordered-outbound-queue.js";
import { handleUploadHttp } from "./upload-http.js";

export const MAXIMUM_REKEYED_SESSION_IDS = 64;
const MAXIMUM_UNANSWERED_HEARTBEATS = GATEWAY_CONNECTION_POLICY.missedHeartbeatLimit;
export const SUPERSEDED_CLOSE_CODE = 4000;

const PAIRED_PER_MESSAGE_DEFLATE: PerMessageDeflateOptions = {
  zlibDeflateOptions: { level: 6, memLevel: 8 },
  concurrencyLimit: 2,
};

function diagnosticRequestID(value: string): string {
  return value.replace(/[^A-Za-z0-9._:-]/gu, "_").slice(0, 160);
}

function transportFailureLevel(error: unknown): "warning" | "error" {
  return error instanceof GatewayError && error.code !== "internal" && !Object.hasOwn(error, "cause") ? "warning" : "error";
}

const SLOW_RPC_WARNING_MS = 1_000;
const SLOW_PROMPT_WARNING_MS = 250;
export const DISPOSABLE_READ_METHODS: ReadonlySet<string> = new Set([
  "session.open",
  "session.list",
  "session.transcript",
  "session.history.list",
  "session.history.entry",
  "home.memory.view",
  "home.memory.evidence",
  "projects.list",
  "projects.inspect",
  "model.list",
  "provider.list",
  "provider.usage",
]);
const DISPOSABLE_READ_DEADLINE_MS = 5_000;
const SESSION_OPEN_DEADLINE_MS = 10_000;
const SHED_RETRY_AFTER_MS = 1_000;
export const DISPOSABLE_READ_DEADLINES_MS: ReadonlyMap<string, number> = new Map([
  ["session.open", SESSION_OPEN_DEADLINE_MS],
  ["session.list", DISPOSABLE_READ_DEADLINE_MS],
  ["session.transcript", DISPOSABLE_READ_DEADLINE_MS],
  ["session.history.list", DISPOSABLE_READ_DEADLINE_MS],
  ["session.history.entry", DISPOSABLE_READ_DEADLINE_MS],
  ["home.memory.view", DISPOSABLE_READ_DEADLINE_MS],
  ["home.memory.evidence", DISPOSABLE_READ_DEADLINE_MS],
]);
const UPGRADE_SLOW_WARNING_MS = 1_000;
const INBOUND_SILENCE_WARNING_MS = 12_000;
const EVENT_LOOP_DELAY_WARNING_MS = 1_000;

function diagnosticErrorCode(error: unknown): string {
  if (error instanceof GatewayError) return error.code;
  if (error instanceof Error) return "exception";
  return "unknown";
}

function diagnosticErrorDetails(error: unknown): { operationId?: string; ageMs?: number; cause?: string } {
  if (!(error instanceof GatewayError) || !error.details || typeof error.details !== "object" || Array.isArray(error.details)) return {};
  const details = error.details as Record<string, unknown>;
  if (error.diagnosticReason === "home-memory-source-unavailable") return typeof details.cause === "string" ? { cause: details.cause } : {};
  if (error.diagnosticReason !== "attention-pending") return {};
  return {
    ...(typeof details.operationId === "string" ? { operationId: details.operationId } : {}),
    ...(typeof details.ageMs === "number" && Number.isFinite(details.ageMs) ? { ageMs: details.ageMs } : {}),
  };
}

export const HTTP_REQUEST_IDLE_TIMEOUT_MS = 30_000;
export const HTTP_HEADERS_TIMEOUT_MS = 15_000;
const HTTP_REQUEST_TIMEOUT_MS = 300_000;
const HTTP_SHUTDOWN_GRACE_MS = 1_000;
const HTTP_MAXIMUM_CONNECTIONS = 128;
export const HTTP_MAXIMUM_CONNECTIONS_PER_ADDRESS = 64;
const HTTP_MAXIMUM_REQUESTS = 128;
const HTTP_MAXIMUM_REQUESTS_PER_IDENTITY = 16;
const HTTP_MAXIMUM_REQUESTS_PER_ADDRESS = 32;
export const HTTP_MAXIMUM_REQUESTS_PER_CONNECTION = 8;
export const HTTP_LISTENER_LIMITS: LanListenerLimits = {
  headersTimeout: HTTP_HEADERS_TIMEOUT_MS,
  requestTimeout: HTTP_REQUEST_TIMEOUT_MS,
  connectionsCheckingInterval: 1_000,
  handshakeTimeout: HTTP_HEADERS_TIMEOUT_MS,
  idleTimeout: HTTP_REQUEST_IDLE_TIMEOUT_MS,
};

interface HttpTransportLease {
  identify(identity: string): void;
  release(): void;
}

interface HttpLeaseState {
  identity?: string;
  released: boolean;
}

class HttpTransportAdmission {
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

function shouldTerminateHeartbeat(unansweredHeartbeats: number): boolean {
  return unansweredHeartbeats >= MAXIMUM_UNANSWERED_HEARTBEATS;
}

function progressAge(at: number | null, now: number): string {
  return at === null ? "unknown" : String(Math.max(0, Math.round(now - at)));
}

function heartbeatTimerDelay(elapsedMs: number, intervalMs = GATEWAY_CONNECTION_POLICY.heartbeatIntervalMs): number {
  return Math.max(0, Math.round(elapsedMs - intervalMs));
}

function parseBlobByteRange(value: string | string[] | undefined): BlobByteRange | undefined {
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

interface ActiveSessionSynchronization {
  barrier: SessionSyncBarrier;
  timeout: NodeJS.Timeout;
  requestId: string;
  subscriptionToken: string;
  sessionId: string;
  deliveredRequests: Set<string>;
}

interface SessionOpenFlight {
  readonly requestId: string;
  readonly controller: AbortController;
  attempt?: Promise<JsonValue>;
  waiters: number;
  answered?: boolean;
  releaseAbandoned?: () => void;
}

interface InFlightRpc {
  readonly controller: AbortController;
  readonly method: string;
  readonly startedAt: number;
  readonly span: RequestSpan;
  cancelledStage?: string;
  shedReason?: "deadline";
}

interface SynchronizationCompletion {
  sessionId: string;
  syncToken: string;
  requestId: string;
  subscriptionToken: string;
}

type SynchronizationOwner = SynchronizationCompletion;

function existingSessionOpenOwner(
  pendingSessionOpens: ReadonlyMap<string, { readonly requestId: string }>,
  synchronizations: ReadonlyMap<string, ActiveSessionSynchronization>,
  sessionId: string,
): string | undefined {
  return pendingSessionOpens.get(sessionId)?.requestId
    ?? synchronizations.get(sessionId)?.requestId;
}

function clearRequestSynchronizations(
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

const PEER_DIAGNOSTIC_TOKEN = /^[A-Za-z0-9-]{1,64}$/u;

interface PeerDiagnostics {
  peerClientId?: string;
  peerAttemptId?: string;
  peerEpoch?: string;
}

type UpgradePhase = "request" | "auth" | "handshake" | "hello";

type ConnectionTransport = "lan" | "tailscale" | "primary";

interface HttpConnectionTrace {
  acceptedAt: number;
  handled: boolean;
  transportEnd: "reset" | "timeout" | "fin" | "none";
  code?: string;
  tlsFailed?: boolean;
}

interface UpgradeTrace {
  transport: ConnectionTransport;
  acceptAt: number;
  transportTrace: HttpConnectionTrace | undefined;
  startedAt: number;
  authMs: number | null;
  handshakeAt: number | null;
  connectionId?: string;
  reported: boolean;
}

function isFrameRefusal(error: Error): boolean {
  const code: unknown = (error as { code?: unknown }).code;
  return typeof code === "string" && code.startsWith("WS_ERR_");
}

interface UpgradeEnding {
  reason:
    | "request_capacity" | "unexpected_path" | "warming_up" | "shutting_down"
    | "connection_capacity" | "unauthenticated" | "unreadable_request" | "peer_closed"
    | "superseded" | "device_revoked"
    | "authentication_timeout" | "handshake_refused" | "hello_timeout" | "hello_required"
    | "protocol_mismatch" | "invalid_frame" | "hello";
  peer?: PeerDiagnostics;
  peerProtocolVersion?: number;
  level?: LogLevel;
}

function protocolMismatchCloseReason(): string {
  return JSON.stringify({ code: "protocol_mismatch", gatewayProtocol: PROTOCOL_VERSION, minProtocol: MIN_PROTOCOL_VERSION });
}

interface SilenceEpisode {
  startedAt: number;
  resumedAt?: number;
  reported: boolean;
  detectedMs: number;
  detectedPingMs: number | null;
  peer: Promise<PeerPathLookup>;
}

function peerDiagnostics(value: unknown): PeerDiagnostics {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return {};
  const fields = value as Record<string, unknown>;
  const token = (candidate: unknown): string | undefined =>
    typeof candidate === "string" && PEER_DIAGNOSTIC_TOKEN.test(candidate) ? candidate : undefined;
  const peerClientId = token(fields.clientId);
  const peerAttemptId = token(fields.attemptId);
  const peerEpoch = token(fields.epoch);
  return {
    ...(peerClientId ? { peerClientId } : {}),
    ...(peerAttemptId ? { peerAttemptId } : {}),
    ...(peerEpoch ? { peerEpoch } : {}),
  };
}

interface Connection {
  id: string;
  admission: number;
  identity: string;
  isLocal: boolean;
  socket: WebSocket;
  remoteAddress: string;
  upgrade: UpgradeTrace;
  peer: PeerDiagnostics;
  silence?: SilenceEpisode | undefined;
  unansweredHeartbeats: number;
  pingOutstandingSince: number | null;
  ready: boolean;
  presentationOnly: boolean;
  inFlight: Set<string>;
  requestControllers: Map<string, InFlightRpc>;
  synchronizations: Map<string, ActiveSessionSynchronization>;
  subscriptionTokens: Map<string, string>;
  rekeyedSessionIds: Map<string, string>;
  synchronizationBytes: number;
  pendingSessionOpens: Map<string, SessionOpenFlight>;
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
  lastClientInitiatedInboundAt: number | null;
  lastClientPingAt: number | null;
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

interface OutboundFrameIdentity {
  readonly topic: string;
  readonly key?: string;
  readonly sessionId?: string;
  readonly sequence?: number;
  readonly runtimeGeneration?: string;
  readonly rebaseline?: () => OutboundFrame | undefined;
}

function outboundFrameIdentity(
  connection: Connection,
  value: unknown,
  prepared: PreparedOutboundFrame,
  maximumBytes: number,
): OutboundFrameIdentity {
  if (prepared.fallback) return { topic: "transport.resyncRequired" };
  const frame = typeof value === "object" && value !== null ? value as Record<string, unknown> : {};
  const topic = typeof frame.topic === "string" ? frame.topic : typeof frame.type === "string" ? frame.type : UNKNOWN_OUTBOUND_TOPIC;
  const payload = typeof frame.payload === "object" && frame.payload !== null ? frame.payload as Record<string, unknown> : {};
  const sessionId = typeof frame.sessionId === "string" ? frame.sessionId : undefined;
  if (topic === "session.summary") {
    const summarySessionId = typeof payload.sessionId === "string" ? payload.sessionId : undefined;
    return summarySessionId === undefined ? { topic } : { topic, key: `session.summary:${summarySessionId}` };
  }
  if (sessionId === undefined) return { topic };
  const sequence = typeof payload.eventSequence === "number" ? payload.eventSequence : undefined;
  if (sequence === undefined) return { topic };
  const runtimeGeneration = typeof payload.runtimeGeneration === "string" ? payload.runtimeGeneration : undefined;
  const sequenced: OutboundFrameIdentity = {
    topic, sessionId, sequence,
    ...(runtimeGeneration === undefined ? {} : { runtimeGeneration }),
  };
  if (topic !== "session.snapshot") return sequenced;
  const subscriptionToken = connection.subscriptionTokens.get(sessionId);
  if (subscriptionToken === undefined) return sequenced;
  const rebaseline = (): OutboundFrame | undefined => {
    const encoded = stage("frame.serialize", () => prepareOutboundFrame({
      type: "event",
      topic: "session.rebaseline",
      sessionId,
      payload: { reason: "superseded snapshot", subscriptionToken, snapshot: payload },
    }, maximumBytes));
    if (!encoded) return undefined;
    bytes("frame.serialize", encoded.outputBytes);
    return {
      encoded: encoded.output,
      bytes: encoded.outputBytes,
      topic: encoded.fallback ? "transport.resyncRequired" : "session.rebaseline",
      sessionId,
      sequence,
      ...(runtimeGeneration === undefined ? {} : { runtimeGeneration }),
    };
  };
  return { ...sequenced, rebaseline };
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

function acceptedSocketAddress(socket: Duplex): string {
  const address = (socket as { remoteAddress?: unknown }).remoteAddress;
  return typeof address === "string" ? address : "unknown";
}

function acceptedSocketPort(socket: Duplex): number | undefined {
  const port = (socket as { remotePort?: unknown }).remotePort;
  return typeof port === "number" ? port : undefined;
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
  private readonly localSockets: WebSocketServer;
  private readonly pairedSockets: WebSocketServer;
  private readonly clients = new Map<string, Connection>();
  private connectionAdmissions = 0;
  private readonly httpSockets = new Set<Duplex>();
  private readonly pendingUpgrades = new Set<() => void>();
  private readonly httpConnectionsByAddress = new Map<string, number>();
  private readonly httpSocketTraces = new WeakMap<object, HttpConnectionTrace>();
  private readonly httpAdmission: HttpTransportAdmission;
  private readonly peerPaths: PeerPathReader;
  private readonly pairingLimiter = new RateLimiter(10, 10 * 60_000);
  private readonly heartbeat: NodeJS.Timeout;
  private lastHeartbeatAt = performance.now();
  private readonly stallSampler: StallSampler;
  private readonly disposableReadDeadlines: ReadonlyMap<string, number>;
  private readonly resourceSampler: ResourceSampler;
  private readonly resourceTimer: NodeJS.Timeout;
  private resourceSampleInFlight = false;
  private readonly lanEndpoint: LanEndpoint | undefined;
  private readonly primaryTransport: ConnectionTransport;
  private resourceSampleFailureReported = false;
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
      disposableReadDeadlinesMs?: ReadonlyMap<string, number>;
      maximumHttpConnections?: number;
      maximumHttpRequests?: number;
      maximumHttpRequestsPerIdentity?: number;
      devices: DeviceStore;
      uploads: UploadStore;
      sessions: RuntimeRegistry;
      display: Pick<DisplayOwner, "acquireArtifact">;
      auth: AuthBroker;
      service: GatewayService;
      logger: GatewayLogger;
      liveViews?: BrowserLiveViewRegistry;
      authorizeBrowserLiveView?: (sessionId: string, viewId: string, generation: string) => boolean;
      stallSampler?: StallSampler;
      resourceSampler?: ResourceSampler;
      peerPathReader?: PeerPathReader;
      lanEndpoint?: LanEndpointConfig;
    },
  ) {
    this.stallSampler = options.stallSampler ?? new StallSampler();
    this.disposableReadDeadlines = options.disposableReadDeadlinesMs ?? DISPOSABLE_READ_DEADLINES_MS;
    this.resourceSampler = options.resourceSampler ?? new ResourceSampler();
    this.peerPaths = options.peerPathReader ?? new TailscalePeerPaths();
    this.primaryTransport = isTailscaleAddress(options.host) ? "tailscale" : "primary";
    this.stallSampler.refreshHostSample();
    const maximumHttpConnections = options.maximumHttpConnections ?? HTTP_MAXIMUM_CONNECTIONS;
    if (!Number.isSafeInteger(maximumHttpConnections) || maximumHttpConnections < 1) {
      throw new Error("HTTP connection bounds are invalid");
    }
    this.httpAdmission = new HttpTransportAdmission(
      options.maximumHttpRequests,
      options.maximumHttpRequestsPerIdentity,
    );
    const listenerLimits = HTTP_LISTENER_LIMITS;
    this.server = createServer(httpListenerOptions(listenerLimits), (request, response) => void this.handleHttp(request, response, this.primaryTransport));
    this.server.timeout = listenerLimits.idleTimeout;
    this.server.on("connection", (socket) => this.admitHttpConnection(socket, maximumHttpConnections, this.primaryTransport));
    this.server.on("clientError", (error, socket) => this.httpClientError(error, socket));
    if (options.lanEndpoint) {
      this.lanEndpoint = new LanEndpoint({
        ...options.lanEndpoint,
        logger: options.logger,
        port: options.port,
        listenerLimits,
        onConnection: (socket) => this.admitHttpConnection(socket, maximumHttpConnections, "lan"),
        onSecureConnection: (socket) => { this.adoptAcceptedSocketTrace(socket); },
        onClientError: (error, socket) => this.httpClientError(error, socket),
        onTlsClientError: (error, socket) => this.noteTransportError(error, socket, true),
        onRequest: (request, response) => void this.handleHttp(request, response, "lan"),
        onUpgrade: (request, socket, head) => void this.handleUpgrade(request, socket, head, "lan"),
      });
    }
    this.localSockets = new WebSocketServer({ noServer: true, maxPayload: options.maxFrameBytes, perMessageDeflate: false });
    this.pairedSockets = new WebSocketServer({
      noServer: true, maxPayload: options.maxFrameBytes, perMessageDeflate: PAIRED_PER_MESSAGE_DEFLATE,
    });
    this.server.on("upgrade", (request, socket, head) => void this.handleUpgrade(request, socket, head, this.primaryTransport));
    this.heartbeat = setInterval(() => {
      const heartbeatAt = performance.now();
      const timerDelayMs = heartbeatTimerDelay(heartbeatAt - this.lastHeartbeatAt);
      this.lastHeartbeatAt = heartbeatAt;
      const stallWindow = this.stallSampler.closeWindow();
      if (timerDelayMs >= EVENT_LOOP_DELAY_WARNING_MS) {
        const pressure = this.pressureDiagnostic();
        void this.stallSampler.hostMemory().then((host) => {
          this.options.logger.log("warning", `Gateway event loop delayed heartbeat by ${timerDelayMs}ms (${pressure} ${formatStallEvidence(stallWindow, host)})`, {
            event: "gateway.event-loop-delay",
            source: "transport",
            durationMs: timerDelayMs,
          });
        });
      }
      this.stallSampler.refreshHostSample();
      for (const connection of this.clients.values()) {
        if (connection.closeInitiated || connection.socket.readyState !== WebSocket.OPEN) continue;
        this.observeInboundSilence(connection, heartbeatAt);
        if (shouldTerminateHeartbeat(connection.unansweredHeartbeats)) {
          const heartbeatQueue = connection.outbound.snapshot();
          this.options.logger.log(
            "warning",
            `Closing unresponsive client ${connection.id} after ${connection.unansweredHeartbeats} unanswered heartbeats (lastInboundAgeMs=${progressAge(connection.lastInboundAt, heartbeatAt)} lastWriteProgressAgeMs=${progressAge(connection.lastWriteProgressAt, heartbeatAt)} queuedFrames=${heartbeatQueue.queuedFrames} queuedBytes=${heartbeatQueue.queuedBytes} completedFrames=${heartbeatQueue.completedFrames})`,
            { event: "connection.heartbeat-timeout", source: "transport", connectionId: connection.id, ...connection.peer },
          );
          connection.socket.terminate();
          continue;
        }
        connection.unansweredHeartbeats += 1;
        const clientInitiatedAt = connection.lastClientInitiatedInboundAt;
        if (clientInitiatedAt === null
          || heartbeatAt - clientInitiatedAt >= GATEWAY_CONNECTION_POLICY.heartbeatIntervalMs) {
          connection.pingOutstandingSince = heartbeatAt;
          connection.socket.ping();
        }
      }
    }, GATEWAY_CONNECTION_POLICY.heartbeatIntervalMs);
    this.heartbeat.unref();
    this.resourceTimer = setInterval(() => void this.publishResources(), RESOURCE_SAMPLE_INTERVAL_MS);
    this.resourceTimer.unref();
  }

  private admitHttpConnection(socket: Duplex, maximumHttpConnections: number, transport: ConnectionTransport): void {
    const address = acceptedSocketAddress(socket);
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
    const trace: HttpConnectionTrace = { acceptedAt: performance.now(), handled: false, transportEnd: "none" };
    this.httpSocketTraces.set(socket, trace);
    this.observeTransportEnd(socket, trace);
    this.httpConnectionsByAddress.set(address, addressConnections + 1);
    socket.once("close", () => {
      this.httpSockets.delete(socket);
      if (!trace.handled) {
        const bytesRead = (socket as { bytesRead?: number }).bytesRead ?? 0;
        const reason = trace.tlsFailed ? "tls_error"
          : trace.code && trace.code !== "HPE_INVALID_EOF_STATE" && trace.code !== "ERR_HTTP_REQUEST_TIMEOUT" ? "invalid_http"
          : bytesRead === 0 ? "silent" : transport === "lan" ? "incomplete_tls_or_http" : "partial_http";
        this.options.logger.log("warning", "Accepted connection closed before an HTTP handler", {
          event: "http.connection-unused", source: "transport", transport, reason,
          acceptToCloseMs: performance.now() - trace.acceptedAt, bytesRead,
          transportEnd: trace.transportEnd, ...(trace.code ? { code: trace.code } : {}),
        });
      }
      const count = this.httpConnectionsByAddress.get(address)!;
      if (count === 1) this.httpConnectionsByAddress.delete(address);
      else this.httpConnectionsByAddress.set(address, count - 1);
    });
  }

  private adoptAcceptedSocketTrace(socket: Duplex): HttpConnectionTrace | undefined {
    const existing = this.httpSocketTraces.get(socket);
    if (existing) return existing;
    const address = acceptedSocketAddress(socket);
    const port = acceptedSocketPort(socket);
    if (port === undefined) return undefined;
    for (const accepted of this.httpSockets) {
      if (acceptedSocketPort(accepted) !== port || acceptedSocketAddress(accepted) !== address) continue;
      const trace = this.httpSocketTraces.get(accepted);
      if (trace) {
        this.httpSocketTraces.set(socket, trace);
        this.observeTransportEnd(socket, trace);
      }
      return trace;
    }
    return undefined;
  }

  private observeTransportEnd(socket: Duplex, trace: HttpConnectionTrace): void {
    socket.on("error", (error) => this.noteTransportError(error, socket));
    socket.once("timeout", () => { if (trace.transportEnd !== "reset") trace.transportEnd = "timeout"; });
    socket.once("end", () => { if (trace.transportEnd === "none") trace.transportEnd = "fin"; });
  }

  private noteTransportError(error: Error, socket: Duplex, tls = false): void {
    const trace = this.adoptAcceptedSocketTrace(socket);
    if (!trace) return;
    const code = (error as NodeJS.ErrnoException).code;
    if (code && /^[A-Z][A-Z0-9_]{0,63}$/u.test(code)) trace.code = code;
    if (code === "ECONNRESET") trace.transportEnd = "reset";
    else if (code === "ETIMEDOUT" || code === "ERR_HTTP_REQUEST_TIMEOUT" || code === "ERR_TLS_HANDSHAKE_TIMEOUT") trace.transportEnd = "timeout";
    if (tls) trace.tlsFailed = true;
  }

  private httpClientError(error: Error, socket: Duplex): void {
    this.noteTransportError(error, socket);
    const code = (error as NodeJS.ErrnoException).code;
    const activeResponse = (socket as Duplex & { _httpMessage?: ServerResponse })._httpMessage;
    if (socket.writable && !activeResponse?.headersSent && (code?.startsWith("HPE_") || code === "ERR_HTTP_REQUEST_TIMEOUT")) {
      const status = code === "HPE_HEADER_OVERFLOW" ? "431 Request Header Fields Too Large"
        : code === "HPE_CHUNK_EXTENSIONS_OVERFLOW" ? "413 Payload Too Large"
        : code === "ERR_HTTP_REQUEST_TIMEOUT" ? "408 Request Timeout" : "400 Bad Request";
      socket.write(`HTTP/1.1 ${status}\r\nConnection: close\r\n\r\n`);
    }
    socket.destroy(error);
  }

  private async publishResources(): Promise<void> {
    if (this.shuttingDown) return;
    if (this.resourceSampleInFlight) {
      if (!this.resourceSampleFailureReported) {
        this.resourceSampleFailureReported = true;
        this.options.logger.log("warning", "Gateway resource sample skipped; the previous sample is still running", {
          event: "gateway.resources-failed", source: "transport", reason: "previous sample still running",
        });
      }
      return;
    }
    this.resourceSampleInFlight = true;
    try {
      const sample = await this.resourceSampler.sample();
      const level = this.resourceSampler.level(sample);
      const message = formatResourceSample(sample);
      this.options.logger.log(level.level, level.reason === undefined ? message : `${message} (${level.reason})`, {
        event: "gateway.resources", source: "transport",
      });
      this.resourceSampleFailureReported = false;
    } catch (error) {
      if (!this.resourceSampleFailureReported) {
        this.resourceSampleFailureReported = true;
        this.options.logger.log("warning", "Gateway resource sample failed; the next window retries", {
          event: "gateway.resources-failed", source: "transport", error,
        });
      }
    } finally {
      this.resourceSampleInFlight = false;
    }
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
      await this.lanEndpoint?.start();
      await afterBind();
      if (this.shuttingDown) throw new GatewayError("busy", "Gateway shutdown began during startup", true);
      this.ready = true;
    } catch (error) {
      await this.close();
      throw error;
    }
    this.options.logger.log("info", `Gateway listening on ${this.options.host}:${this.options.port}`, { event: "gateway.listening", source: "transport" });
  }

  rekeySession(previousSessionId: string, nextSessionId: string): void {
    if (previousSessionId === nextSessionId) return;
    this.options.service.releaseSessionProcessTranscripts(previousSessionId);
    for (const connection of this.clients.values()) {
      const sourceSynchronization = connection.synchronizations.get(previousSessionId);
      const sourceToken = connection.subscriptionTokens.get(previousSessionId);
      const pendingOwner = connection.pendingSessionOpens.get(previousSessionId);
      if (!sourceSynchronization && sourceToken === undefined && pendingOwner === undefined) continue;

      const destinationSynchronization = connection.synchronizations.get(nextSessionId);
      if (destinationSynchronization && destinationSynchronization !== sourceSynchronization) {
        clearTimeout(destinationSynchronization.timeout);
        destinationSynchronization.barrier.abort(destinationSynchronization.requestId);
        connection.synchronizations.delete(nextSessionId);
      }
      connection.subscriptionTokens.delete(nextSessionId);

      connection.subscriptionTokens.delete(previousSessionId);
      connection.synchronizations.delete(previousSessionId);
      if (sourceToken !== undefined) connection.subscriptionTokens.set(nextSessionId, sourceToken);
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

  private resolveSessionId(connection: Connection, sessionId: string): string {
    const seen = new Set<string>();
    let current = sessionId;
    while (!seen.has(current)) {
      seen.add(current);
      const replacement = connection.rekeyedSessionIds.get(current);
      if (replacement === undefined) return current;
      current = replacement;
    }
    return sessionId;
  }

  private clearRekeyedSessionIds(connection: Connection, sessionId: string): void {
    for (const [former, current] of connection.rekeyedSessionIds) {
      if (former === sessionId || current === sessionId) connection.rekeyedSessionIds.delete(former);
    }
  }

  private revokeInstalledSubscription(connection: Connection, sessionId: string, token: string): boolean {
    sessionId = this.resolveSessionId(connection, sessionId);
    if (connection.subscriptionTokens.get(sessionId) !== token) return false;
    const synchronization = connection.synchronizations.get(sessionId);
    if (synchronization) {
      clearTimeout(synchronization.timeout);
      synchronization.barrier.abort(synchronization.requestId);
      connection.synchronizations.delete(sessionId);
    }
    connection.subscriptionTokens.delete(sessionId);
    this.clearRekeyedSessionIds(connection, sessionId);
    this.options.sessions.unsubscribe(connection.id, sessionId);
    this.options.service.releaseSessionProcessTranscripts?.(sessionId, connection.id, token);
    return true;
  }

  private revokeSynchronization(
    connection: Connection,
    sessionId: string,
    synchronization: ActiveSessionSynchronization,
  ): boolean {
    sessionId = this.resolveSessionId(connection, sessionId);
    if (connection.synchronizations.get(sessionId) !== synchronization
        || connection.subscriptionTokens.get(sessionId) !== synchronization.subscriptionToken) return false;
    return this.revokeInstalledSubscription(connection, sessionId, synchronization.subscriptionToken);
  }

  broadcastSession(sessionId: string, topic: string, payload: JsonValue): void {
    let recipients = 0;
    for (const client of this.clients.values()) {
      if (client.ready && client.subscriptionTokens.has(sessionId)) recipients += 1;
    }
    if (topic === "session.snapshot") this.resourceSampler.recordSnapshotBuild(recipients);
    if (recipients === 0) return;
    const event: BufferedSessionEvent = { type: "event", topic, sessionId, payload };
    const prepared = this.prepareBroadcastFrame(event);
    for (const client of this.clients.values()) {
      if (!client.ready || !client.subscriptionTokens.has(sessionId)) continue;
      const barrier = client.synchronizations.get(sessionId)?.barrier;
      const deliverable = barrier ? barrier.offer(event, prepared ?? null) : event;
      if (deliverable) this.sendOutcome(client, deliverable, prepared ?? null);
    }
    this.resourceSampler.recordTopicFrame(topic, prepared?.outputBytes ?? 0, recipients);
  }

  broadcast(topic: string, payload: JsonValue): void {
    let recipients = 0;
    for (const client of this.clients.values()) {
      if (client.ready) recipients += 1;
    }
    if (recipients === 0) return;
    const event = { type: "event" as const, topic, payload };
    const prepared = this.prepareBroadcastFrame(event);
    for (const client of this.clients.values()) {
      if (!client.ready) continue;
      this.sendOutcome(client, event, prepared ?? null);
    }
    this.resourceSampler.recordTopicFrame(topic, prepared?.outputBytes ?? 0, recipients);
  }

  emitToClient(clientId: string, topic: string, payload: JsonValue): void {
    const client = this.clients.get(clientId);
    if (client?.ready) this.send(client, { type: "event", topic, payload });
  }

  notifySessionListChanged(): void {
    this.broadcast("session.listChanged", {});
  }

  disconnectDevice(deviceId: string, origin?: { connectionId: string; requestId: string; deviceId: string }): void {
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
      client.pendingSessionOpens.clear();
      this.options.sessions.unsubscribeClient(client.id);
      const isInitiatingRequest = origin?.connectionId === client.id
        && origin.deviceId === deviceId
        && client.inFlight.has(origin.requestId);
      if (isInitiatingRequest) {
        client.revokeResponseRequestId = origin.requestId;
        client.revokeResponseQueued = false;
      } else {
        if (!client.ready) {
          this.finishUpgrade(client.upgrade, "abandoned", "handshake", "device revoked", { reason: "device_revoked" });
        }
        client.socket.close(1008, "device revoked");
      }
      this.options.service.releaseClient(client.id);
    }
  }

  private async handleHttp(request: IncomingMessage, response: ServerResponse, transport: ConnectionTransport): Promise<void> {
    const trace = this.adoptAcceptedSocketTrace(request.socket);
    if (trace) trace.handled = true;
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
    let workSettled = false;
    const releaseTransportLease = (): void => {
      if (workSettled && (response.writableFinished || response.destroyed)) transportLease.release();
    };
    const retireAbortedRequest = (): void => {
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
        const status = this.shuttingDown ? "stopping" : this.ready ? "ok" : this.startupPhase;
        if (transport === "lan") return sendJson(response, this.ready && !this.shuttingDown ? 200 : 503, { status });
        const info = this.options.service.info() as Record<string, JsonValue>;
        return sendJson(response, this.ready && !this.shuttingDown ? 200 : 503, {
          status,
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
        if (transport === "lan") return sendJson(response, 404, { error: { code: "not_found", message: "Route not found" } });
        const key = request.socket.remoteAddress ?? "unknown";
        if (!this.pairingLimiter.admit(key)) throw new GatewayError("unauthenticated", "Too many pairing attempts; wait before retrying");
        const parsed: unknown = JSON.parse((await readBoundedBody(request, 16_384)).toString("utf8"));
        if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
          throw new GatewayError("invalid_request", "Pairing requires a JSON object body");
        }
        const body = parsed as Record<string, unknown>;
        if (typeof body.code !== "string" || typeof body.deviceName !== "string") throw new GatewayError("invalid_request", "Pairing requires code and deviceName");
        const result = await this.options.devices.pair(body.code.trim(), body.deviceName);
        return sendJson(response, 200, { ...result, ...this.options.service.info() as Record<string, JsonValue>, ...this.lanAdvertising() });
      }

      let handler: Promise<void> | undefined;
      const admitted = await this.options.devices.authenticateAndAdmit(bearer(request), (authenticated) => {
        if (response.destroyed || response.writableEnded || request.aborted) return false;
        if (this.shuttingDown || !this.ready) {
          throw new GatewayError("busy", "Gateway shutdown began before HTTP admission", true);
        }
        const identity = authenticated.kind === "local" ? "local-wrapper" : authenticated.deviceId;
        transportLease.identify(identity);
        handler = this.handleAuthenticatedHttp(request, response, url, authenticated, readLifetime.signal)
          .catch((error) => this.handleHttpError(request, response, error));
        return true;
      }, readLifetime.signal);
      if (admitted === null) return sendJson(response, 401, { error: { code: "unauthenticated", message: "Pairing token is invalid" } });
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
    if (transportFailureLevel(error) === "error") {
      this.options.logger.log("error", "HTTP request failed", {
        event: "http.error", source: "transport", code: failure.code, error,
      });
    }
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

  private lanAdvertising(): Record<string, JsonValue> {
    const advertisement: LanAdvertisement | undefined = this.lanEndpoint?.advertisement();
    if (advertisement === undefined) return {};
    return {
      lanEndpoints: advertisement.endpoints.map((endpoint) => ({ host: endpoint.host, port: endpoint.port })),
      ...(advertisement.pin === undefined ? {} : { lanPin: advertisement.pin }),
    };
  }

  private async handleAuthenticatedHttp(
    request: IncomingMessage,
    response: ServerResponse,
    url: URL,
    authenticated: { kind: "local" } | DeviceIdentity,
    signal: AbortSignal,
  ): Promise<void> {
    const uploadWork = handleUploadHttp(request, response, url, signal, {
      options: this.options,
      completeRequestBody,
      sendJson,
    });
    if (uploadWork !== undefined) {
      await uploadWork;
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
      let lease: Awaited<ReturnType<DisplayOwner["acquireArtifact"]>>;
      try {
        lease = await this.options.display.acquireArtifact(sessionID, artifactID, requestedRange, signal);
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

  private async handleUpgrade(request: IncomingMessage, socket: Duplex, head: Buffer, transport: ConnectionTransport): Promise<void> {
    const transportTrace = this.adoptAcceptedSocketTrace(socket);
    if (transportTrace) transportTrace.handled = true;
    const remoteAddress = request.socket.remoteAddress ?? "unknown";
    const trace: UpgradeTrace = {
      transport,
      acceptAt: transportTrace?.acceptedAt ?? performance.now(),
      transportTrace,
      startedAt: performance.now(),
      authMs: null,
      handshakeAt: null,
      reported: false,
    };
    const readLifetime = new AbortController();
    let retireCause: "peer" | "timeout" | null = null;
    const endPendingUpgradeAtShutdown = (): void => {
      trace.authMs ??= performance.now() - trace.startedAt;
      this.finishUpgrade(trace, "abandoned", "auth", "Gateway shutdown during authentication", { reason: "shutting_down" });
    };
    this.pendingUpgrades.add(endPendingUpgradeAtShutdown);
    const retirePendingUpgrade = (cause: "peer" | "timeout"): void => {
      retireCause ??= cause;
      readLifetime.abort();
      socket.destroy();
    };
    const retireForPeer = (): void => retirePendingUpgrade("peer");
    socket.once("end", retireForPeer);
    socket.once("error", retireForPeer);
    socket.once("close", retireForPeer);
    const authenticationDeadline = setTimeout(() => retirePendingUpgrade("timeout"), HTTP_REQUEST_IDLE_TIMEOUT_MS);
    authenticationDeadline.unref();
    const releasePendingUpgrade = (): void => {
      this.pendingUpgrades.delete(endPendingUpgradeAtShutdown);
      clearTimeout(authenticationDeadline);
      socket.off("end", retireForPeer);
      socket.off("error", retireForPeer);
      socket.off("close", retireForPeer);
    };
    const transportLease = this.httpAdmission.admit(remoteAddress, socket);
    if (!transportLease) {
      this.finishUpgrade(trace, "rejected", "request", "http admission capacity", { reason: "request_capacity" });
      socket.write("HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n");
      socket.destroy();
      releasePendingUpgrade();
      return;
    }
    try {
      const url = new URL(request.url ?? "/", `http://${request.headers.host ?? "localhost"}`);
      if (url.pathname !== "/v1/socket") {
        this.finishUpgrade(trace, "rejected", "request", "unexpected upgrade path", { reason: "unexpected_path" });
        socket.destroy();
        return;
      }
      if (!this.ready || this.shuttingDown) {
        const reason = this.shuttingDown ? "shutting_down" : "warming_up";
        this.finishUpgrade(trace, "rejected", "request", `Gateway is ${reason.replace("_", " ")}`, { reason, level: "info" });
        socket.write("HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n");
        socket.destroy();
        return;
      }
      const admission = await this.options.devices.authenticateAndAdmit(bearer(request), (authenticated) => {
        trace.authMs ??= performance.now() - trace.startedAt;
        if (socket.destroyed) {
          this.finishUpgrade(trace, "abandoned", "auth", "peer socket closed during authentication", { reason: "peer_closed" });
          return false;
        }
        if (this.shuttingDown || !this.ready) {
          const reason = this.shuttingDown ? "shutting_down" : "warming_up";
          this.finishUpgrade(trace, "rejected", "auth", `Gateway is ${reason.replace("_", " ")}`, { reason, level: "info" });
          socket.write("HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n");
          socket.destroy();
          return false;
        }
        const identity = authenticated.kind === "local" ? "local-wrapper" : authenticated.deviceId;
        const maximumConnections = this.options.maximumConnections ?? 32;
        const maximumPerIdentity = this.options.maximumConnectionsPerIdentity ?? GATEWAY_CONNECTION_POLICY.perIdentitySocketCap;
        const live = [...this.clients.values()].filter((client) => !client.closeInitiated);
        const identityConnections = live
          .filter((client) => client.identity === identity)
          .sort((left, right) => (left.lastInboundAt ?? left.admittedAt) - (right.lastInboundAt ?? right.admittedAt));
        let superseded = 0;
        while (superseded < identityConnections.length
          && (identityConnections.length - superseded >= maximumPerIdentity
            || live.length - superseded >= maximumConnections)) {
          superseded += 1;
        }
        if (live.length - superseded >= maximumConnections) {
          this.finishUpgrade(trace, "rejected", "auth",
            `connection capacity (connections=${live.length} maximumConnections=${maximumConnections} identityConnections=${identityConnections.length} maximumPerIdentity=${maximumPerIdentity})`,
            { reason: "connection_capacity" });
          socket.write("HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n");
          socket.destroy();
          return false;
        }
        const supersededAt = performance.now();
        for (const client of identityConnections.slice(0, superseded)) {
          this.options.logger.log("warning", `Superseding client ${client.id} with a newer connection from the same identity (lastInboundAgeMs=${progressAge(client.lastInboundAt, supersededAt)} identityConnections=${identityConnections.length} maximumPerIdentity=${maximumPerIdentity})`, { event: "connection.superseded", source: "transport", connectionId: client.id, ...client.peer });
          this.closeFailedConnection(client, SUPERSEDED_CLOSE_CODE, "superseded by a newer connection", { reason: "superseded" });
        }
        const isLocal = authenticated.kind === "local";
        (isLocal ? this.localSockets : this.pairedSockets).handleUpgrade(request, socket, head, (webSocket) => {
          trace.handshakeAt = performance.now();
          this.admit(webSocket, identity, isLocal, remoteAddress, trace);
        });
        if (trace.handshakeAt === null) {
          this.finishUpgrade(trace, "rejected", "handshake", "WebSocket handshake refused", { reason: "handshake_refused" });
        }
        return true;
      }, readLifetime.signal);
      trace.authMs ??= performance.now() - trace.startedAt;
      if (admission === null) {
        this.finishUpgrade(trace, "rejected", "auth", "unauthenticated credential", { reason: "unauthenticated" });
        socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n");
        socket.destroy();
      }
    } catch {
      if (retireCause === null) {
        this.finishUpgrade(trace, "rejected", "request", "upgrade request could not be read", { reason: "unreadable_request" });
      } else {
        const abandoned = retireCause === "peer";
        trace.authMs ??= performance.now() - trace.startedAt;
        this.finishUpgrade(trace, abandoned ? "abandoned" : "rejected", "auth",
          abandoned ? "peer socket closed during authentication" : "authentication timed out",
          { reason: abandoned ? "peer_closed" : "authentication_timeout" });
      }
      socket.destroy();
    } finally {
      releasePendingUpgrade();
      transportLease.release();
    }
  }

  private finishUpgrade(
    trace: UpgradeTrace,
    outcome: "opened" | "abandoned" | "rejected",
    phaseReached: UpgradePhase,
    detail: string,
    ending: UpgradeEnding,
  ): void {
    if (trace.reported) return;
    trace.reported = true;
    const at = performance.now();
    const acceptToUpgradeMs = Math.max(0, Math.round(trace.startedAt - trace.acceptAt));
    const authMs = Math.max(0, Math.round(trace.authMs ?? 0));
    const handshakeAt = trace.handshakeAt;
    const handshakeMs = handshakeAt === null ? 0 : Math.max(0, Math.round(handshakeAt - trace.startedAt - authMs));
    const helloMs = handshakeAt === null ? 0 : Math.max(0, Math.round(at - handshakeAt));
    const totalMs = Math.max(0, Math.round(at - trace.acceptAt));
    const slow = totalMs >= UPGRADE_SLOW_WARNING_MS;
    this.options.logger.log(ending.level ?? (outcome === "opened" && !slow ? "debug" : "warning"),
      `Socket upgrade ${outcome} at ${phaseReached} after ${totalMs}ms (acceptToUpgrade=${acceptToUpgradeMs}ms auth=${authMs}ms handshake=${handshakeMs}ms hello=${helloMs}ms; ${detail})`,
      {
        event: "http.upgrade", source: "transport", outcome, phaseReached, reason: ending.reason,
        transport: trace.transport,
        acceptToUpgradeMs, authMs, handshakeMs, helloMs,
        ...(trace.connectionId === undefined ? {} : { connectionId: trace.connectionId }),
        ...ending.peer,
        ...(ending.peerProtocolVersion === undefined ? {} : { peerProtocolVersion: ending.peerProtocolVersion }),
      });
  }

  private admit(socket: WebSocket, identity: string, isLocal: boolean, remoteAddress: string, upgrade: UpgradeTrace): void {
    let connection: Connection;
    const maximumOutboundBytes = this.options.maximumOutboundBytes ?? 8 * 1_048_576;
    const outbound = new OrderedOutboundQueue(
      maximumOutboundBytes,
      (encoded, completion) => socket.send(encoded, (error) => {
        if (!error) connection.lastWriteProgressAt = performance.now();
        completion(error);
      }),
      (snapshot, nextBytes, nextTopic) => {
        if (connection.closeInitiated) return;
        this.options.logger.log(
          "warning",
          `Closing client ${connection.id} at outbound queue capacity (queuedFrames=${snapshot.queuedFrames} queuedBytes=${snapshot.queuedBytes} maximumFrames=${snapshot.maximumFrames} maximumBytes=${snapshot.maximumBytes} frameHighWater=${snapshot.frameHighWater} byteHighWater=${snapshot.byteHighWater} oldestTopic=${snapshot.oldestTopic} nextTopic=${nextTopic} nextBytes=${nextBytes} wsBufferedBytes=${socket.bufferedAmount}; ${this.pressureDiagnostic()})`,
          { event: "connection.outbound-capacity", source: "transport", connectionId: connection.id, ...connection.peer },
        );
        this.closeFailedConnection(connection, 1013, "client outbound capacity exceeded");
      },
      (error, snapshot) => {
        if (connection.closeInitiated) return;
        connection.closeInitiated = true;
        this.options.logger.log(
          "error",
          `Client ${connection.id} outbound write failed after ${snapshot.completedFrames}/${snapshot.acceptedFrames} frames`,
          { event: "connection.write-error", source: "transport", connectionId: connection.id, ...connection.peer, error },
        );
        this.retireConnectionWork(connection);
        socket.terminate();
      },
      (bytes) => this.resourceSampler.recordOutboundBytes(bytes),
      (bytes) => this.resourceSampler.recordOutboundCoalesced(bytes),
    );
    connection = {
      id: randomUUID(),
      admission: ++this.connectionAdmissions,
      identity,
      isLocal,
      socket,
      remoteAddress,
      upgrade,
      peer: {},
      unansweredHeartbeats: 0,
      ready: false,
      presentationOnly: false,
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
      lastClientInitiatedInboundAt: null,
      lastClientPingAt: null,
      lastWriteProgressAt: null,
      pingOutstandingSince: null,
      helloTimer: setTimeout(() => {
        this.finishUpgrade(connection.upgrade, "abandoned", "handshake", "hello deadline", { reason: "hello_timeout" });
        this.closeFailedConnection(connection, 1008, "hello required");
      }, GATEWAY_CONNECTION_POLICY.helloDeadlineMs),
    };
    this.clients.set(connection.id, connection);
    upgrade.connectionId = connection.id;
    socket.on("message", (data, binary) => {
      this.noteInbound(connection, true);
      void this.onMessage(connection, binary ? data : data.toString());
    });
    socket.on("ping", () => {
      this.noteInbound(connection, true);
      connection.lastClientPingAt = performance.now();
    });
    socket.on("pong", () => this.noteInbound(connection, false));
    socket.on("close", (code, reason) => {
      const suffix = reason.length > 0 ? `: ${reason.toString("utf8")}` : "";
      this.disconnect(connection, `WebSocket close ${code}${suffix}`);
    });
    socket.on("error", (error) => {
      if (!connection.ready && isFrameRefusal(error)) {
        this.finishUpgrade(connection.upgrade, "rejected", "hello", `WebSocket error: ${error.message}`, { reason: "invalid_frame" });
      }
      this.disconnect(connection, `WebSocket error: ${error.message}`);
    });
  }

  private async onMessage(connection: Connection, raw: unknown): Promise<void> {
    if (connection.closeInitiated || connection.socket.readyState !== WebSocket.OPEN
      || !this.clients.has(connection.id)) return;
    let frame: Record<string, unknown>;
    try {
      const text = typeof raw === "string" ? raw : Buffer.from(raw as ArrayBuffer).toString("utf8");
      frame = JSON.parse(text) as Record<string, unknown>;
      if (typeof frame !== "object" || frame === null || Array.isArray(frame)) throw new Error();
    } catch {
      if (!connection.ready) {
        this.finishUpgrade(connection.upgrade, "rejected", "hello", "invalid JSON", { reason: "invalid_frame" });
      }
      return this.closeFailedConnection(connection, 1007, "invalid JSON");
    }

    if (!connection.ready) {
      if (frame.type !== "hello" || !Number.isSafeInteger(frame.protocolVersion)) {
        this.finishUpgrade(connection.upgrade, "rejected", "hello", "valid hello required", { reason: "hello_required" });
        return this.closeFailedConnection(connection, 1008, "valid hello required");
      }
      const protocol = frame.protocolVersion as number;
      if (protocol < MIN_PROTOCOL_VERSION || protocol > PROTOCOL_VERSION) {
        this.finishUpgrade(connection.upgrade, "rejected", "hello",
          `protocol version mismatch: peer ${protocol}, Gateway accepts ${MIN_PROTOCOL_VERSION}-${PROTOCOL_VERSION}`,
          { reason: "protocol_mismatch", peerProtocolVersion: protocol });
        return this.closeFailedConnection(
          connection, PROTOCOL_MISMATCH_CLOSE_CODE, "protocol version mismatch", undefined, protocolMismatchCloseReason());
      }
      connection.ready = true;
      connection.presentationOnly = (frame as Record<string, unknown>).clientRole === "mobile";
      connection.peer = peerDiagnostics(frame.diagnostics);
      this.finishUpgrade(connection.upgrade, "opened", "hello", "hello accepted", { reason: "hello", peer: connection.peer });
      const openHostEvidence = connection.isLocal ? "" : ` ${formatHostEvidence(this.stallSampler.hostSample())}`;
      this.options.logger.log(
        connection.isLocal ? "debug" : "info",
        `Client ${connection.id} connection opened (${connection.isLocal ? "local" : "paired"}, ${connection.presentationOnly ? "mobile" : "local"} role, compression=${connection.socket.extensions || "none"}) after ${Math.max(0, Math.round(performance.now() - connection.admittedAt))}ms${openHostEvidence}`,
        { event: "connection.opened", source: "transport", connectionId: connection.id, ...connection.peer },
      );
      clearTimeout(connection.helloTimer);
      this.send(connection, {
        type: "hello", ...this.options.service.info() as Record<string, JsonValue>,
        ...this.lanAdvertising(), connectionId: connection.id,
      });
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
      if (frame.type === "cancel") {
        if (typeof frame.id === "string") this.cancelInflightRequest(connection, frame.id);
        return;
      }
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
    let sessionOpenFlight: SessionOpenFlight | undefined;
    if (sessionOpenID !== undefined) {
      const pending = connection.pendingSessionOpens.get(sessionOpenID);
      if (pending !== undefined && pending.requestId !== frame.id) {
        return this.joinSessionOpen(connection, frame, pending);
      }
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
      sessionOpenFlight = { requestId: frame.id, controller: new AbortController(), waiters: 1 };
      connection.pendingSessionOpens.set(sessionOpenID, sessionOpenFlight);
    }
    connection.inFlight.add(frame.id);
    const requestController = new AbortController();
    const admittedSubscriptionIds = new Set(connection.subscriptionTokens.keys());
    const requestId = frame.id;
    const diagnosticID = diagnosticRequestID(requestId);
    const rpcStartedAt = performance.now();
    const requestSpan = new RequestSpan();
    const inFlightRpc: InFlightRpc = {
      controller: requestController,
      method: frame.method,
      startedAt: rpcStartedAt,
      span: requestSpan,
    };
    connection.requestControllers.set(frame.id, inFlightRpc);
    const deadlineTimer = this.armDisposableReadDeadline(frame.method, inFlightRpc);
    const clearDeadline = (): void => { if (deadlineTimer !== undefined) clearTimeout(deadlineTimer); };
    const params = frame.params && typeof frame.params === "object" && !Array.isArray(frame.params)
      ? frame.params as Record<string, unknown>
      : {};
    const rpcCorrelation = {
      ...(typeof params.sessionId === "string" ? { sessionId: params.sessionId } : {}),
      ...(typeof params.commandId === "string" ? { commandId: params.commandId } : {}),
    };
    let rpcOutcome: "success" | "failure" = "failure";
    let attemptSucceeded = false;
    const synchronizationOwners: SynchronizationOwner[] = [];
    const synchronizationCompletions: SynchronizationCompletion[] = [];
    let responseAttempted = false;
    const resolveSessionId = (sessionId: string): string => this.resolveSessionId(connection, sessionId);
    const clearRekeyedSessionIds = (sessionId: string): void => this.clearRekeyedSessionIds(connection, sessionId);
    const revokeInstalledSubscription = (sessionId: string, token: string): boolean => this.revokeInstalledSubscription(connection, sessionId, token);
    const revokeSynchronization = (sessionId: string, synchronization: ActiveSessionSynchronization): boolean => this.revokeSynchronization(connection, sessionId, synchronization);
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
        admission: connection.admission,
        identity: connection.identity,
        isLocal: connection.isLocal,
        signal: sessionOpenFlight?.controller.signal ?? requestController.signal,
        beginSynchronization: (sessionId) => {
          if (connection.revoked) throw new GatewayError("unauthenticated", "This device is no longer authorized");
          if (connection.workRetired) throw new GatewayError("busy", "Connection is closed", true);
          sessionId = resolveSessionId(sessionId);
          if (connection.presentationOnly
              && connection.pendingSessionOpens.get(sessionId)?.requestId !== requestId) {
            throw new GatewayError("conflict", "This mobile presentation open was retired", true);
          }
          if (connection.presentationOnly) revokePresentationOwners(sessionId);
          if (!connection.subscriptionTokens.has(sessionId)
              && connection.subscriptionTokens.size >= (this.options.maximumSubscriptionsPerConnection ?? 64)) {
            throw new GatewayError("busy", "Connection subscription capacity is full", true);
          }
          if (connection.synchronizations.has(sessionId)) {
            throw new GatewayError("conflict", "A session synchronization is already in progress for this connection", true);
          }
          const installedToken = connection.subscriptionTokens.get(sessionId);
          if (installedToken !== undefined) {
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
          installed = { barrier, timeout, requestId, subscriptionToken: syncToken, sessionId, deliveredRequests: new Set() };
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
            requestId: active.requestId,
            subscriptionToken: active.subscriptionToken,
          });
        },
        setPresentationVisibility: (sessionId, subscriptionToken, revision, visible) => {
          if (connection.revoked) throw new GatewayError("unauthenticated", "This device is no longer authorized");
          sessionId = resolveSessionId(sessionId);
          if (!connection.presentationOnly && !connection.isLocal) {
            throw new GatewayError("invalid_request", "Only a mobile presentation or local connection may publish chat visibility");
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
      const method = frame.method;
      const invoke = (): Promise<JsonValue> => runInRequestSpan(
        requestSpan,
        (): Promise<JsonValue> => this.options.service.invoke(context, method, frame.params ?? {}),
      );
      let result: JsonValue;
      if (sessionOpenFlight === undefined) {
        result = deadlineTimer === undefined
          ? await invoke()
          : await abortableRead(requestController.signal, invoke);
        attemptSucceeded = true;
      } else {
        const attempt = invoke();
        sessionOpenFlight.attempt = attempt;
        void attempt.catch(() => {});
        const leaveAttemptStage = requestSpan.enterStage("session.open.attempt");
        try {
          result = await abortableRead(requestController.signal, () => attempt);
        } finally {
          leaveAttemptStage();
        }
        attemptSucceeded = true;
      }
      if (requestController.signal.aborted) return;
      for (const owner of synchronizationOwners) {
        const active = connection.synchronizations.get(resolveSessionId(owner.sessionId));
        if (!active
            || active.requestId !== owner.requestId
            || active.subscriptionToken !== owner.subscriptionToken) {
          throw new GatewayError("conflict", "Session synchronization ownership changed before acknowledgement", true);
        }
      }
      for (const completion of synchronizationCompletions) {
        const active = connection.synchronizations.get(resolveSessionId(completion.sessionId));
        if (!active
            || active.requestId !== completion.requestId
            || active.subscriptionToken !== completion.subscriptionToken
            || completion.syncToken !== active.subscriptionToken) {
          throw new GatewayError("conflict", "Session synchronization ownership changed before acknowledgement", true);
        }
      }
      const responseSentIntact = runInRequestSpan(requestSpan, () => stage("frame.write", () => this.send(connection, { type: "response", id: frame.id, ok: true, result })));
      if (responseSentIntact && sessionOpenFlight !== undefined) {
        sessionOpenFlight.answered = true;
        this.markSessionOpenDelivered(connection, requestId, requestId);
      }
      responseAttempted = true;
      clearDeadline();
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
      if (responseSentIntact) for (const completion of synchronizationCompletions) {
        completion.sessionId = resolveSessionId(completion.sessionId);
        const active = connection.synchronizations.get(completion.sessionId);
        if (!active
            || active.requestId !== completion.requestId
            || active.subscriptionToken !== completion.subscriptionToken
            || completion.syncToken !== active.subscriptionToken) continue;
        if (active.barrier.isOverflowed(completion.syncToken)) {
          if (!active.barrier.beginRecovery(completion.syncToken)) continue;
          const recoveryToken = connection.subscriptionTokens.get(completion.sessionId);
          const recovery = recoveryToken === completion.subscriptionToken
            ? await this.options.service.recoverySnapshot(completion.sessionId)
            : undefined;
          const stillOwned = connection.synchronizations.get(completion.sessionId) === active
            && connection.subscriptionTokens.get(completion.sessionId) === completion.subscriptionToken;
          if (!stillOwned) continue;

          const revokeBeforeResync = (): void => {
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
            revokeBeforeResync();
            sendResyncRequired();
            continue;
          }
          connection.synchronizations.delete(completion.sessionId);

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
        const level = transportFailureLevel(error);
        this.options.logger.log(level, `RPC ${frame.method} for client ${connection.id} failed`, {
          event: "rpc.error", source: "transport", method: frame.method, requestID: diagnosticID,
          connectionId: connection.id, ...rpcCorrelation,
          code: diagnosticErrorCode(error), outcome: "failure",
          ...(level === "error" ? { error } : {}),
          ...(error instanceof GatewayError && error.diagnosticReason ? { reason: error.diagnosticReason } : {}),
          ...diagnosticErrorDetails(error),
        });
      }
      if (!responseAttempted && inFlightRpc.cancelledStage === undefined) {
        responseAttempted = true;
        clearDeadline();
        const responseSent = runInRequestSpan(requestSpan, () => this.send(connection, { type: "response", id: frame.id, ok: false, error: publicError(error) }));
        if (responseSent && connection.revoked && connection.revokeResponseRequestId === frame.id) {
          connection.revokeResponseQueued = true;
          this.closeRevokedConnectionAfterResponse(connection);
        }
      }
    } finally {
      clearDeadline();
      const otherOpenWaiters = (sessionOpenFlight?.waiters ?? 1) > 1;
      const releaseOwnSynchronizations = (): void => {
        const ownerRequestIDs = new Set([
          requestId,
          ...synchronizationCompletions.map((completion) => completion.requestId),
        ]);
        for (const ownerRequestID of ownerRequestIDs) {
          clearRequestSynchronizations(connection.synchronizations, ownerRequestID, (sessionId, synchronization) => {
            revokeSynchronization(sessionId, synchronization);
          });
        }
      };
      if (otherOpenWaiters && sessionOpenFlight !== undefined) {
        sessionOpenFlight.releaseAbandoned = releaseOwnSynchronizations;
      } else if (!(attemptSucceeded && rpcOutcome === "success")) {
        releaseOwnSynchronizations();
      }
      if (sessionOpenFlight !== undefined) {
        this.releaseSessionOpenFlight(connection, sessionOpenFlight);
      }
      connection.inFlight.delete(frame.id);
      connection.requestControllers.delete(frame.id);
      const loggedOutcome = inFlightRpc.cancelledStage !== undefined
        ? "cancelled"
        : rpcOutcome === "failure" && requestController.signal.aborted ? "connectionClosed" : rpcOutcome;
      this.logRequestOutcome(connection, {
        method: frame.method,
        requestId: diagnosticID,
        correlation: rpcCorrelation,
        startedAt: rpcStartedAt,
        span: requestSpan,
        outcome: loggedOutcome,
        cancelledStage: inFlightRpc.cancelledStage,
        shedReason: inFlightRpc.shedReason,
      });
    }
  }

  private async joinSessionOpen(
    connection: Connection,
    frame: Record<string, unknown>,
    flight: SessionOpenFlight,
  ): Promise<void> {
    const requestId = frame.id as string;
    connection.inFlight.add(requestId);
    const rpcStartedAt = performance.now();
    const requestSpan = new RequestSpan();
    const inFlightRpc: InFlightRpc = {
      controller: new AbortController(),
      method: frame.method as string,
      startedAt: rpcStartedAt,
      span: requestSpan,
    };
    connection.requestControllers.set(requestId, inFlightRpc);
    const deadlineTimer = this.armDisposableReadDeadline(frame.method as string, inFlightRpc);
    const clearDeadline = (): void => { if (deadlineTimer !== undefined) clearTimeout(deadlineTimer); };
    const params = frame.params && typeof frame.params === "object" && !Array.isArray(frame.params)
      ? frame.params as Record<string, unknown>
      : {};
    const rpcCorrelation = {
      ...(typeof params.sessionId === "string" ? { sessionId: params.sessionId } : {}),
      ...(typeof params.commandId === "string" ? { commandId: params.commandId } : {}),
    };
    let rpcOutcome: "success" | "failure" = "failure";
    flight.waiters += 1;
    try {
      const attempt = flight.attempt;
      if (attempt === undefined) throw new GatewayError("busy", "Session open is no longer in flight", true);
      const result = await runInRequestSpan(requestSpan, () => wait(
        "session.open.join",
        () => abortableRead(inFlightRpc.controller.signal, () => attempt),
      ));
      if (inFlightRpc.controller.signal.aborted) return;
      if (runInRequestSpan(requestSpan, () => this.send(connection, { type: "response", id: requestId, ok: true, result }))) {
        flight.answered = true;
        this.markSessionOpenDelivered(connection, flight.requestId, requestId);
        rpcOutcome = "success";
        clearDeadline();
      }
    } catch (error) {
      if (inFlightRpc.shedReason !== undefined) {
        runInRequestSpan(requestSpan, () => this.send(connection, { type: "response", id: requestId, ok: false, error: publicError(error) }));
      } else if (!inFlightRpc.controller.signal.aborted) {
        const level = transportFailureLevel(error);
        this.options.logger.log(level, `RPC ${frame.method as string} for client ${connection.id} failed`, {
          event: "rpc.error", source: "transport", method: frame.method as string, requestID: diagnosticRequestID(requestId),
          connectionId: connection.id, ...rpcCorrelation,
          code: diagnosticErrorCode(error), outcome: "failure",
          ...(level === "error" ? { error } : {}),
          ...(error instanceof GatewayError && error.diagnosticReason ? { reason: error.diagnosticReason } : {}),
          ...diagnosticErrorDetails(error),
        });
        runInRequestSpan(requestSpan, () => this.send(connection, { type: "response", id: requestId, ok: false, error: publicError(error) }));
      }
    } finally {
      clearDeadline();
      connection.inFlight.delete(requestId);
      connection.requestControllers.delete(requestId);
      this.releaseSessionOpenFlight(connection, flight);
      const loggedOutcome = inFlightRpc.cancelledStage !== undefined
        ? "cancelled"
        : rpcOutcome === "failure" && inFlightRpc.controller.signal.aborted ? "connectionClosed" : rpcOutcome;
      this.logRequestOutcome(connection, {
        method: frame.method as string,
        requestId: diagnosticRequestID(requestId),
        correlation: rpcCorrelation,
        startedAt: rpcStartedAt,
        span: requestSpan,
        outcome: loggedOutcome,
        cancelledStage: inFlightRpc.cancelledStage,
        shedReason: inFlightRpc.shedReason,
      });
    }
  }

  private armDisposableReadDeadline(
    method: string,
    inFlight: InFlightRpc,
  ): NodeJS.Timeout | undefined {
    const deadlineMs = this.disposableReadDeadlines.get(method);
    if (deadlineMs === undefined) return undefined;
    const timer = setTimeout(() => {
      if (inFlight.shedReason !== undefined || inFlight.controller.signal.aborted) return;
      inFlight.shedReason = "deadline";
      inFlight.controller.abort(new GatewayError(
        "busy",
        `${method} did not answer within ${deadlineMs}ms`,
        true,
        { retryAfterMs: SHED_RETRY_AFTER_MS },
      ));
    }, deadlineMs);
    timer.unref();
    return timer;
  }

  private cancelInflightRequest(connection: Connection, requestId: string): void {
    const inFlight = connection.requestControllers.get(requestId);
    if (inFlight === undefined) {
      this.revokeAbandonedOpen(connection, requestId);
      return;
    }
    if (!DISPOSABLE_READ_METHODS.has(inFlight.method)) return;
    if (inFlight.cancelledStage !== undefined) return;
    inFlight.cancelledStage = inFlight.span.currentStage() ?? "admitted";
    inFlight.controller.abort(new GatewayError("cancelled", "The client cancelled this request", true));
  }

  private revokeAbandonedOpen(connection: Connection, requestId: string): void {
    for (const [sessionId, synchronization] of connection.synchronizations) {
      if (!synchronization.deliveredRequests.delete(requestId)) continue;
      if (synchronization.deliveredRequests.size > 0) return;
      this.revokeSynchronization(connection, sessionId, synchronization);
      return;
    }
  }

  private markSessionOpenDelivered(connection: Connection, ownerRequestId: string, deliveredRequestId: string): void {
    for (const synchronization of connection.synchronizations.values()) {
      if (synchronization.requestId === ownerRequestId) synchronization.deliveredRequests.add(deliveredRequestId);
    }
  }

  private releaseSessionOpenFlight(connection: Connection, flight: SessionOpenFlight): void {
    flight.waiters -= 1;
    if (flight.waiters > 0) return;
    flight.controller.abort(new GatewayError("cancelled", "No request waits for this session open anymore", true));
    for (const [sessionId, pending] of connection.pendingSessionOpens) {
      if (pending === flight) connection.pendingSessionOpens.delete(sessionId);
    }
    if (!flight.answered) flight.releaseAbandoned?.();
  }

  private logRequestOutcome(
    connection: Connection,
    request: {
      readonly method: string;
      readonly requestId: string;
      readonly correlation: Record<string, string>;
      readonly startedAt: number;
      readonly span: RequestSpan;
      readonly outcome: "success" | "failure" | "connectionClosed" | "cancelled";
      readonly cancelledStage: string | undefined;
      readonly shedReason: "deadline" | undefined;
    },
  ): void {
    const durationMs = Math.max(0, Math.round(performance.now() - request.startedAt));
    const breakdown = request.span.breakdown(durationMs, request.outcome !== "success");
    if (request.shedReason !== undefined) {
      this.options.logger.log(
        "warning",
        `Shed ${request.method} for client ${connection.id} at its deadline after ${durationMs}ms`,
        {
          event: "gateway.shed", source: "transport", reason: request.shedReason, method: request.method,
          requestID: request.requestId, connectionId: connection.id, ...request.correlation,
          outcome: request.outcome, durationMs, counts: { retryAfterMs: SHED_RETRY_AFTER_MS },
          ...(breakdown ?? {}),
        },
      );
      return;
    }
    if (request.cancelledStage !== undefined) {
      this.options.logger.log(
        durationMs >= SLOW_RPC_WARNING_MS ? "warning" : "debug",
        `RPC ${request.method} for client ${connection.id} was cancelled in ${request.cancelledStage} after ${durationMs}ms`,
        {
          event: "rpc.cancelled", source: "transport", method: request.method, requestID: request.requestId,
          connectionId: connection.id, ...request.correlation, outcome: "cancelled",
          stage: request.cancelledStage, durationMs, ...(breakdown ?? {}),
        },
      );
      return;
    }
    const slowWarningMs = request.method === "session.prompt" ? SLOW_PROMPT_WARNING_MS : SLOW_RPC_WARNING_MS;
    this.options.logger.log(
      request.outcome !== "success" || durationMs >= slowWarningMs ? "warning" : "debug",
      `RPC ${request.method} for client ${connection.id} completed in ${durationMs}ms (${request.outcome})`,
      {
        event: "rpc.completed", source: "transport", method: request.method,
        requestID: request.requestId, connectionId: connection.id, ...request.correlation,
        outcome: request.outcome, durationMs, ...(breakdown ?? {}),
      },
    );
  }

  private send(connection: Connection, value: unknown): boolean {
    return this.sendOutcome(connection, value) === "sent";
  }

  private prepareBroadcastFrame(value: unknown): PreparedOutboundFrame | null {
    try {
      const frame = stage("frame.serialize", () => prepareOutboundFrame(value, this.options.maxFrameBytes) ?? null);
      if (frame) bytes("frame.serialize", frame.outputBytes);
      return frame;
    } catch {
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
      if (frame.type !== "response"
          || typeof frame.id !== "string"
          || frame.id !== connection.revokeResponseRequestId
          || !connection.inFlight.has(frame.id)) return "failed";
    }
    try {
      const frame = prepared === undefined
        ? stage("frame.serialize", () => prepareOutboundFrame(value, this.options.maxFrameBytes))
        : prepared;
      if (!frame) return "failed";
      if (prepared === undefined) bytes("frame.serialize", frame.outputBytes);
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

      if (!connection.outbound.enqueue({
        encoded: frame.output, bytes: frame.outputBytes,
        ...outboundFrameIdentity(connection, value, frame, this.options.maxFrameBytes),
      })) return "failed";
      return frame.fallback ? "fallback" : "sent";
    } catch {
      this.options.logger.log("error", "Outbound projection encoding failed", {
        event: "connection.projection-rejected", source: "transport",
      });
      return "failed";
    }
  }

  private disconnect(connection: Connection, detail = "WebSocket closed"): void {
    if (!this.clients.delete(connection.id)) return;
    const closedAt = performance.now();
    if (!connection.closeInitiated) {
      this.finishUpgrade(connection.upgrade, "abandoned", "handshake", detail, { reason: "peer_closed" });
    }
    const outbound = connection.outbound.snapshot();
    connection.outbound.retire();
    const closeHostEvidence = connection.isLocal ? "" : ` ${formatHostEvidence(this.stallSampler.hostSample())}`;
    this.options.logger.log(
      connection.isLocal ? "debug" : "info",
      `Client ${connection.id} connection closed after ${Math.max(0, Math.round(closedAt - connection.admittedAt))}ms (${detail}; ${outbound.completedFrames}/${outbound.acceptedFrames} outbound frames completed, ${outbound.queuedBytes} queued bytes; lastInboundAgeMs=${progressAge(connection.lastInboundAt, closedAt)} lastWriteProgressAgeMs=${progressAge(connection.lastWriteProgressAt, closedAt)} queuedFrames=${outbound.queuedFrames} queuedBytes=${outbound.queuedBytes} completedFrames=${outbound.completedFrames})${closeHostEvidence}`,
      { event: "connection.closed", source: "transport", connectionId: connection.id, ...connection.peer,
        durationMs: Math.max(0, closedAt - connection.admittedAt),
        transportEnd: connection.upgrade.transportTrace?.transportEnd ?? "none" },
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
    for (const flight of connection.pendingSessionOpens.values()) {
      flight.controller.abort(new GatewayError("cancelled", "The connection retired during this session open", true));
    }
    connection.pendingSessionOpens.clear();
    connection.rekeyedSessionIds.clear();
    if (!connection.revoked) for (const request of connection.requestControllers.values()) request.controller.abort();
    connection.requestControllers.clear();
    this.options.sessions.unsubscribeClient(connection.id);
    this.options.service.releaseClient(connection.id);
    this.options.auth.detachClient(connection.id);
  }

  private closeFailedConnection(
    connection: Connection,
    code: number,
    reason: string,
    ending?: UpgradeEnding,
    closeReason?: string,
  ): void {
    if (connection.closeInitiated) return;
    connection.closeInitiated = true;
    if (ending !== undefined && !connection.ready) {
      this.finishUpgrade(connection.upgrade, "abandoned", "handshake", reason, ending);
    }
    connection.outbound.retire();
    this.retireConnectionWork(connection);
    connection.closeDeadline = setTimeout(() => {
      if (connection.socket.readyState !== WebSocket.CLOSED) connection.socket.terminate();
    }, 1_000);
    connection.closeDeadline.unref();
    connection.socket.close(code, closeReason ?? reason);
  }

  private noteInbound(connection: Connection, clientInitiated: boolean): void {
    const inboundAt = performance.now();
    connection.unansweredHeartbeats = 0;
    connection.pingOutstandingSince = null;
    connection.lastInboundAt = inboundAt;
    if (clientInitiated) connection.lastClientInitiatedInboundAt = inboundAt;
    const episode = connection.silence;
    if (episode === undefined) return;
    connection.silence = undefined;
    episode.resumedAt = inboundAt;
    if (episode.reported) this.logInboundResumed(connection, episode);
  }

  private observeInboundSilence(connection: Connection, heartbeatAt: number): void {
    if (connection.silence !== undefined) return;
    const startedAt = connection.lastInboundAt ?? connection.admittedAt;
    if (heartbeatAt - startedAt < INBOUND_SILENCE_WARNING_MS) return;
    const pingUnanswered = connection.pingOutstandingSince !== null;
    const clientPingsOnItsOwn = connection.lastClientPingAt !== null;
    if (!pingUnanswered && !clientPingsOnItsOwn) return;
    const episode: SilenceEpisode = {
      startedAt,
      reported: false,
      detectedMs: Math.max(0, Math.round(heartbeatAt - startedAt)),
      detectedPingMs: connection.pingOutstandingSince === null
        ? null
        : Math.max(0, Math.round(heartbeatAt - connection.pingOutstandingSince)),
      peer: this.peerPaths.lookup(connection.remoteAddress)
        .catch((): PeerPathLookup => ({ peerPath: "unknown", peerPathSource: "cli-failed", peerRelay: "" })),
    };
    connection.silence = episode;
    void episode.peer.then((peer) => {
      if (episode.reported) return;
      episode.reported = true;
      this.options.logger.log("warning", `Client ${connection.id} has sent nothing for ${episode.detectedMs}ms (unansweredPingMs=${episode.detectedPingMs ?? "none"} peerPath=${peer.peerPath} peerPathSource=${peer.peerPathSource} peerRelay=${peer.peerRelay || "none"})`, {
        event: "connection.inbound-silent", source: "transport", connectionId: connection.id, ...connection.peer,
        peerPath: peer.peerPath, peerPathSource: peer.peerPathSource, peerRelay: peer.peerRelay,
        ...(peer.peerLastHandshake !== undefined ? { peerLastHandshake: peer.peerLastHandshake } : {}),
        ...(peer.peerRxBytes !== undefined ? { peerRxBytes: peer.peerRxBytes } : {}),
        ...(peer.peerTxBytes !== undefined ? { peerTxBytes: peer.peerTxBytes } : {}),
      });
      if (episode.resumedAt !== undefined) this.logInboundResumed(connection, episode);
    });
  }

  private logInboundResumed(connection: Connection, episode: SilenceEpisode): void {
    const silentMs = Math.max(0, Math.round((episode.resumedAt ?? performance.now()) - episode.startedAt));
    this.options.logger.log("info", `Client ${connection.id} inbound resumed after ${silentMs}ms of silence`, {
      event: "connection.inbound-resumed", source: "transport", connectionId: connection.id, ...connection.peer, silentMs,
    });
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
    this.closeTask = Promise.resolve().then(() => this.finishClose());
    return this.closeTask;
  }

  private async finishClose(): Promise<void> {
    this.options.liveViews?.dispose();
    await this.options.liveViews?.joinRetirements();
    this.options.logger.log("info", "Closing Gateway transport", { event: "gateway.transport-closing", source: "transport" });
    clearInterval(this.heartbeat);
    const lanRetirement = this.lanEndpoint?.stop();
    clearInterval(this.resourceTimer);
    this.stallSampler.dispose();
    this.resourceSampler.dispose();
    for (const client of this.clients.values()) {
      if (!client.ready) {
        this.finishUpgrade(client.upgrade, "abandoned", "handshake", "Gateway shutdown before hello", { reason: "shutting_down" });
      }
      const stoppingAccepted = this.send(client, { type: "event", topic: "system.stopping", payload: {} });
      this.retireConnectionWork(client);
      if (!stoppingAccepted) {
        client.socket.close(1012, "gateway restarting");
        continue;
      }
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
      for (const endPendingUpgrade of this.pendingUpgrades) endPendingUpgrade();
      for (const socket of this.httpSockets) socket.destroy();
      if (httpClosed) clearTimeout(forceHttpClose);
    }, HTTP_SHUTDOWN_GRACE_MS);
    forceHttpClose.unref();
    await httpClosedPromise;
    await lanRetirement;
    this.localSockets.close();
    this.pairedSockets.close();
  }
}
