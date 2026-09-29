import { createServer, type IncomingMessage, type Server as HTTPServer, type ServerResponse } from "node:http";
import { GATEWAY_JSON_MAXIMUM_NODES, jsonNodeCount } from "../protocol/json-budget.js";
import type { Duplex } from "node:stream";
import { finished, pipeline } from "node:stream/promises";
import { abortableRead } from "../util/abortable-read.js";
import { randomUUID } from "node:crypto";
import { WebSocketServer, WebSocket, type PerMessageDeflateOptions } from "ws";
import { GatewayError, publicError } from "../errors.js";
import type { JsonValue } from "../protocol/types.js";
import type { DeviceIdentity, DeviceStore } from "../security/device-store.js";
import { RateLimiter } from "../security/rate-limiter.js";
import type { UploadStore } from "../machine/upload-store.js";
import type { RuntimeRegistry } from "../sessions/runtime-registry.js";
import type { BlobByteRange } from "../sessions/blob-store.js";
import type { AuthBroker } from "../admin/auth-broker.js";
import type { GatewayLogger, LogLevel } from "./logger.js";
import { GATEWAY_CONNECTION_POLICY } from "./connection-policy.js";
import { formatHostEvidence, formatStallEvidence, formatResourceSample, ResourceSampler, RESOURCE_SAMPLE_INTERVAL_MS, StallSampler } from "./stall-diagnostics.js";
import { GatewayService, type ClientContext } from "./gateway-service.js";
import { MIN_PROTOCOL_VERSION, PROTOCOL_VERSION } from "../version.js";
import { SessionSyncBarrier, type BufferedSessionEncoding, type BufferedSessionEvent } from "./session-sync.js";
import type { BrowserLiveViewRegistry } from "../display/browser-live-view.js";
import { bytes, RequestSpan, runInRequestSpan, stage, wait } from "./request-span.js";
import { TailscalePeerPaths, type PeerPathLookup, type PeerPathReader } from "./tailscale-peer.js";
import { LanEndpoint, httpListenerOptions, type LanAdvertisement, type LanEndpointConfig, type LanListenerLimits } from "./lan-endpoint.js";
import { isTailscaleAddress } from "../config.js";

// Retain only recent former IDs while an active subscription is rekeyed. Older
// IDs are stale control paths and may safely require a fresh session.open.
export const MAXIMUM_REKEYED_SESSION_IDS = 64;
export const MAXIMUM_UNANSWERED_HEARTBEATS = GATEWAY_CONNECTION_POLICY.missedHeartbeatLimit;
/** Application-defined close code for a socket replaced by its own identity. */
export const SUPERSEDED_CLOSE_CODE = 4000;

/**
 * permessage-deflate for paired devices, which reach the Gateway over a radio.
 * Local-credential clients (Mac app, CLI) stay uncompressed. Measurements and
 * bounds: packages/gateway/docs/connection-resilience.md#frame-compression.
 * Context takeover and window bits stay at ws defaults on purpose: setting
 * serverNoContextTakeover or a numeric window option makes ws answer a legal
 * offer (including URLSession's parameterless one) with HTTP 400.
 */
export const PAIRED_PER_MESSAGE_DEFLATE: PerMessageDeflateOptions = {
  zlibDeflateOptions: { level: 6, memLevel: 8 },
  // ws's zlib limiter is process-global and shared by inflate and deflate;
  // two slots leave the rest of libuv's four-thread pool to file I/O.
  concurrencyLimit: 2,
};

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
/**
 * The only methods a `cancel` frame may end (`C-6`). A disposable read computes
 * an answer nothing consumes once its client stops waiting for it; an accepted
 * mutation, an admitted prompt and `session.sync` all have an owner that must
 * settle them whatever the client does with its wait, so a cancel for any other
 * method is ignored. Mirrors the phone's disposable read policy, and the
 * protocol section of the Gateway README lists exactly this set.
 */
const DISPOSABLE_READ_METHODS: ReadonlySet<string> = new Set([
  "session.open",
  "session.list",
  "session.transcript",
  "session.history.list",
  "session.history.entry",
  "session.search",
  "model.list",
  "provider.list",
  "provider.usage",
]);
/** A projection that cannot answer within this bound is answering nobody: the
 * client already stopped waiting or will, so the Gateway stops the read. */
const DISPOSABLE_READ_DEADLINE_MS = 5_000;
/** A cold `session.open` may parse a large transcript before its subscription
 * commits, so it is the one disposable read with a longer bound. */
const SESSION_OPEN_DEADLINE_MS = 10_000;
/** What a shed response tells the client to wait. The pressure that shed the
 * read is still there, so a retry without a pause would be shed again; the
 * phone bounds this hint to 10 s of its own. */
const SHED_RETRY_AFTER_MS = 1_000;
/**
 * Server-side deadline per disposable read (`G-12`): one table, so a read that
 * has no entry has no deadline. Every entry is a `DISPOSABLE_READ_METHODS`
 * member — those still keep their cancel policy — and an admitted mutation or
 * prompt is deliberately absent: its owner settles it durably whatever the
 * client does with its wait.
 *
 * Four disposable reads are absent because their own owners allow longer than
 * any bound a client would tolerate, and shedding below the owner's own bound
 * would throw away an answer the owner is about to produce: `session.search`
 * spends up to Jev's 20 s on a remote-ranked evaluation the user paid for, and
 * `provider.usage` answers a typed "timed out" snapshot after up to 10 s per
 * fetch. A read outside this table is never shed, so the phone's single retry
 * after a shed hint can never buy a second paid search.
 */
export const DISPOSABLE_READ_DEADLINES_MS: ReadonlyMap<string, number> = new Map([
  ["session.open", SESSION_OPEN_DEADLINE_MS],
  ["session.list", DISPOSABLE_READ_DEADLINE_MS],
  ["session.transcript", DISPOSABLE_READ_DEADLINE_MS],
  ["session.history.list", DISPOSABLE_READ_DEADLINE_MS],
  ["session.history.entry", DISPOSABLE_READ_DEADLINE_MS],
]);
/** An upgrade that reaches hello within this bound is debug detail; every
 * abandoned or rejected upgrade, and any slower one, warns. */
const UPGRADE_SLOW_WARNING_MS = 1_000;
/** A socket this long without an inbound frame has missed at least one of the
 * phone's 10-second pings, and liveness was expected: one record per silence
 * episode says so, where a per-tick record would repeat for as long as the path
 * stays down. */
const INBOUND_SILENCE_WARNING_MS = 12_000;
/** A heartbeat this late means the event loop stalled long enough for clients
 * to notice; shorter timer jitter is normal and not recorded. */
const EVENT_LOOP_DELAY_WARNING_MS = 1_000;

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
// Both listeners this transport owns — the main one and the LAN lane — take
// their bounds from here: the lane serves the same routes to the same peers out
// of the same connection budget, so a slower bound there would let a peer that
// has not signed in hold slots the phone's own leg needs.
export const HTTP_LISTENER_LIMITS: LanListenerLimits = {
  headersTimeout: HTTP_HEADERS_TIMEOUT_MS,
  requestTimeout: HTTP_REQUEST_TIMEOUT_MS,
  connectionsCheckingInterval: 1_000,
  handshakeTimeout: HTTP_HEADERS_TIMEOUT_MS,
  idleTimeout: HTTP_REQUEST_IDLE_TIMEOUT_MS,
};

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
  /** Request IDs whose delivered response carried this barrier's token. A
   * cancel for a `session.open` that was already answered revokes the barrier
   * only once no other delivered response still carries it (`C-6`). */
  deliveredRequests: Set<string>;
}

/**
 * One shared `session.open` attempt per connection and session (`C-6`). A
 * retried open joins it instead of failing as a duplicate, so the answer the
 * first attempt is already computing is the one the retry receives, and the
 * attempt is abandoned only when its last waiting request leaves: a cancellation
 * that arrives while a retry still waits must not throw the retry's answer away.
 */
export interface SessionOpenFlight {
  /** The request whose synchronization this attempt installs and owns. */
  readonly requestId: string;
  /** The shared attempt's signal; aborted when its last waiter leaves. */
  readonly controller: AbortController;
  /** The shared invocation, published by the request that created the flight. */
  attempt?: Promise<JsonValue>;
  /** Requests still waiting for this attempt's answer. */
  waiters: number;
  /** Set once a response carrying this attempt's result reached the client. */
  answered?: boolean;
  /** Releases the synchronization this attempt installed, registered by the
   * request that owns its barrier while another request may still deliver it. */
  releaseAbandoned?: () => void;
}

/** One admitted request, the owner of its abort signal and its span. */
interface InFlightRpc {
  readonly controller: AbortController;
  readonly method: string;
  readonly startedAt: number;
  readonly span: RequestSpan;
  /** Set with the stage it was in when an explicit `cancel` frame arrived. A
   * socket retirement leaves it unset: that request reports `connectionClosed`. */
  cancelledStage?: string;
  /** Set with the reason when this read outlived its own deadline, so the one
   * record for the request is `gateway.shed` instead of `rpc.completed` and the
   * abort is answered instead of silently dropped (`G-12`). */
  shedReason?: "deadline";
}

interface SynchronizationCompletion {
  sessionId: string;
  syncToken: string;
  requestId: string;
  subscriptionToken: string;
}

type SynchronizationOwner = SynchronizationCompletion;

export function existingSessionOpenOwner(
  pendingSessionOpens: ReadonlyMap<string, { readonly requestId: string }>,
  synchronizations: ReadonlyMap<string, ActiveSessionSynchronization>,
  sessionId: string,
): string | undefined {
  // Only genuinely in-flight opens are rejected. An installed subscription is
  // not an open owner: beginSynchronization replaces it deterministically so
  // reconnecting clients always converge instead of deadlocking on conflict.
  return pendingSessionOpens.get(sessionId)?.requestId
    ?? synchronizations.get(sessionId)?.requestId;
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
  /** The topic of the oldest frame in the queue: the one the socket is writing
   * or will write next, i.e. what everything behind it is waiting on. */
  oldestTopic: string;
}

/** One encoded frame with the wire topic it carries and, when a newer frame can
 * replace it in an unsent queue, what identifies the state it carries (`G-4`). */
export interface OutboundFrame {
  readonly encoded: string;
  readonly bytes: number;
  readonly topic: string;
  /** Whole state a newer frame of the same kind replaces without covering a
   * sequence: only a `session.summary`, which states its own revision. */
  readonly key?: string;
  /** A sequenced session frame's session and its per-session `eventSequence`. */
  readonly sessionId?: string;
  readonly sequence?: number;
  /** The runtime generation that sequence belongs to. A replacement
   * `RuntimeSlot` restarts `eventSequence` from zero, so a newer snapshot only
   * covers the frames of its own generation. */
  readonly runtimeGeneration?: string;
  /** The gap-tolerant form of this frame. Superseding a sequenced frame is only
   * allowed together with this: the client admits a `session.rebaseline` whose
   * snapshot covers the sequences dropped with it
   * (`SessionRebaselineAdmission`), where an exact-next snapshot would arrive
   * as the gap the queue just made. */
  readonly rebaseline?: () => OutboundFrame | undefined;
}

interface QueuedOutboundFrame {
  encoded: string;
  bytes: number;
  topic: string;
  key?: string;
  sessionId?: string;
  sequence?: number;
  runtimeGeneration?: string;
}

type OutboundWrite = (encoded: string, completion: (error?: Error) => void) => void;

const UNKNOWN_OUTBOUND_TOPIC = "other";

/**
 * The wire topics a `session.snapshot` — or an earlier `session.rebaseline`
 * carrying one — fully re-states, so an unsent one may be dropped when a newer
 * snapshot covers its sequence (`G-4`). Every other sequenced session frame
 * does something installing a snapshot never does: a failure receipt restores
 * the composer's draft and retires a submission, a revision bump reloads
 * commands, context or the tree, and an editor directive pastes text. Those are
 * fences: the queue never drops one, or anything behind it, across.
 */
const SNAPSHOT_STATED_TOPICS: ReadonlySet<string> = new Set([
  "session.snapshot",
  "session.rebaseline",
  "session.progress",
  "session.toolProgress",
  "session.processActivity",
  "session.extensionActivity",
  "session.compaction",
]);

/** Whether a newer `session.snapshot`'s own state re-states one queued frame of
 * the same session: its topic is one a snapshot installs, it belongs to the
 * same runtime generation, and its sequence is one the snapshot covers. */
function snapshotRestates(queued: QueuedOutboundFrame, frame: OutboundFrame): boolean {
  return queued.runtimeGeneration === frame.runtimeGeneration
    && queued.sequence !== undefined
    && frame.sequence !== undefined
    && queued.sequence <= frame.sequence
    && SNAPSHOT_STATED_TOPICS.has(queued.topic);
}

/**
 * A connection-local ordered writer. Encoded frames remain bounded in
 * application memory and exactly one frame is handed to ws at a time, so a
 * legitimate same-turn synchronization burst cannot fill ws.bufferedAmount.
 *
 * A frame whose state a newer frame replaces queues once: the superseded frame
 * is dropped unsent and the newer one keeps its own place in the queue, so a
 * slow link is bounded by the state that is still worth sending rather than by
 * how long it took. A session's sequenced state is superseded only where the
 * `rebaseline` replacement that covers it re-states it, and only after the
 * newest unsent frame of that session whose effect no snapshot restores. The
 * backstop below is unchanged and still closes a connection that exceeds it.
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
    private readonly overflow: (snapshot: OrderedOutboundQueueSnapshot, nextBytes: number, nextTopic: string) => void,
    private readonly writeFailed: (error: Error, snapshot: OrderedOutboundQueueSnapshot) => void,
    /** One frame this queue accepted, with the bytes it queued: a coalescing
     * replacement reports itself, not the frame it replaced. */
    private readonly accepted: (bytes: number) => void = () => {},
    /** One superseded frame, reported where it is dropped. */
    private readonly replaced: (bytes: number) => void = () => {},
    private readonly maximumFrames = 4_096,
  ) {}

  enqueue(frame: OutboundFrame): boolean {
    if (this.retired) return false;
    // The frame ws is already writing cannot be recalled, so replacement looks
    // only at frames still queued behind it. The newest frame of a state is
    // appended where it was enqueued, after everything already queued: a
    // delivered sequence is therefore always a subsequence of the enqueue
    // sequence, and no frame ever overtakes an earlier one.
    const candidates = this.supersededIndices(frame);
    const replacement = candidates.length > 0 && frame.sequence !== undefined ? frame.rebaseline?.() : undefined;
    // A sequenced frame is dropped only together with the replacement that
    // covers it; an unsequenced one carries its own revision and needs no
    // cover. Without the replacement this queue keeps every frame, so nothing
    // it delivers can leave a gap it created.
    const superseded = frame.sequence === undefined || replacement !== undefined ? candidates : [];
    const entry = replacement ?? frame;
    const releasedBytes = superseded.reduce((total, index) => total + (this.frames[index]?.bytes ?? 0), 0);
    if (this.frames.length - this.head - superseded.length + 1 > this.maximumFrames
      || entry.bytes > this.maximumBytes
      || this.queuedBytes - releasedBytes > this.maximumBytes - entry.bytes) {
      const snapshot = this.snapshot();
      this.retire();
      this.overflow(snapshot, entry.bytes, entry.topic);
      return false;
    }
    // `superseded` is ascending, so each earlier splice shifts the next index
    // back by the frames already removed: drops are reported in queue order.
    let removed = 0;
    for (const index of superseded) {
      const dropped = this.frames[index - removed];
      if (dropped === undefined) continue;
      // Payload and byte reservation are released together, at the same
      // boundary the completed-frame path uses. A dropped frame is no longer
      // outstanding, so the close record's completed/accepted frame counts keep
      // describing frames this connection still owed its peer.
      this.frames.splice(index - removed, 1);
      this.queuedBytes -= dropped.bytes;
      this.acceptedFrames -= 1;
      this.replaced(dropped.bytes);
      removed += 1;
    }
    this.frames.push({
      encoded: entry.encoded,
      bytes: entry.bytes,
      topic: entry.topic,
      ...(entry.key === undefined ? {} : { key: entry.key }),
      ...(entry.sessionId === undefined ? {} : { sessionId: entry.sessionId }),
      ...(entry.sequence === undefined ? {} : { sequence: entry.sequence }),
      ...(entry.runtimeGeneration === undefined ? {} : { runtimeGeneration: entry.runtimeGeneration }),
    });
    this.queuedBytes += entry.bytes;
    this.acceptedFrames += 1;
    this.accepted(entry.bytes);
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
      oldestTopic: this.frames[this.head]?.topic ?? UNKNOWN_OUTBOUND_TOPIC,
    };
  }

  /** The unsent frames a newer frame replaces: a sequenced frame covers the
   * same session's frames its own state re-states, an unsequenced one the
   * newest frame with its key. */
  private supersededIndices(frame: OutboundFrame): number[] {
    // The frame ws is already writing cannot be recalled.
    const first = this.writeActive ? this.head + 1 : this.head;
    if (frame.sessionId !== undefined && frame.sequence !== undefined) {
      // A snapshot re-states whole state, not every effect. A frame nothing of
      // its state restores is a fence, and dropping anything before a fence
      // would deliver a later frame across it, so only the run of this
      // session's frames after the newest fence is covered.
      let fence = first;
      for (let index = first; index < this.frames.length; index += 1) {
        const queued = this.frames[index];
        if (queued === undefined || queued.sessionId !== frame.sessionId) continue;
        if (!snapshotRestates(queued, frame)) fence = index + 1;
      }
      const superseded: number[] = [];
      for (let index = fence; index < this.frames.length; index += 1) {
        if (this.frames[index]?.sessionId === frame.sessionId) superseded.push(index);
      }
      return superseded;
    }
    if (frame.key === undefined) return [];
    const index = this.unsentFrameWithKey(frame.key, first);
    return index < 0 ? [] : [index];
  }

  /** The newest unsent frame carrying `key`, searched from the tail: a frame
   * enqueued after the last frame of that state is what the search skips. */
  private unsentFrameWithKey(key: string, first: number): number {
    for (let index = this.frames.length - 1; index >= first; index -= 1) {
      if (this.frames[index]?.key === key) return index;
    }
    return -1;
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

/** Hello `diagnostics` tokens: bounded, and safe to write into records verbatim. */
const PEER_DIAGNOSTIC_TOKEN = /^[A-Za-z0-9-]{1,64}$/u;

/** The peer's O-1 correlation key, carried on every connection-scoped record. */
interface PeerDiagnostics {
  peerClientId?: string;
  peerAttemptId?: string;
  peerEpoch?: string;
}

/** How far an upgrade got, in the order its phases run. */
type UpgradePhase = "request" | "auth" | "handshake" | "hello";

/** Which listener accepted a connection: the LAN endpoint (E-3a), the main
 * listener at a Tailscale address, or the main listener at any other address
 * (the developer loopback default). The phone names the same two real legs. */
export type ConnectionTransport = "lan" | "tailscale" | "primary";

/** One `http.upgrade` record is written per upgrade, at whichever point it ends:
 * hello, a refusal, or the peer leaving before hello. */
interface UpgradeTrace {
  /** The listener the upgrade reached, so the record says which leg it used. */
  transport: ConnectionTransport;
  /** The TCP accept, before Node parsed the upgrade request. */
  acceptAt: number;
  /** The upgrade handler entry; the auth phase is measured from here. */
  startedAt: number;
  /** Null until the credential wait settles. */
  authMs: number | null;
  /** Null until the WebSocket handshake completes; the hello phase runs after. */
  handshakeAt: number | null;
  /** Set once the connection exists, so an upgrade that dies before hello still
   * joins its own `connection.closed` record. */
  connectionId?: string;
  reported: boolean;
}

/** A frame the ws library itself refused — an oversized payload or a malformed
 * frame — carries a `WS_ERR_*` code; a path failure carries a socket error code
 * or none. */
function isFrameRefusal(error: Error): boolean {
  const code: unknown = (error as { code?: unknown }).code;
  return typeof code === "string" && code.startsWith("WS_ERR_");
}

/** The structured ending of one upgrade. `reason` is what triage groups on; the
 * message carries the human detail. */
interface UpgradeEnding {
  reason:
    | "request_capacity" | "unexpected_path" | "warming_up" | "shutting_down"
    | "connection_capacity" | "unauthenticated" | "unreadable_request" | "peer_closed"
    | "superseded" | "device_revoked"
    | "authentication_timeout" | "handshake_refused" | "hello_timeout" | "hello_required"
    | "protocol_mismatch" | "invalid_frame" | "hello";
  /** The O-1 peer key, once hello named it. */
  peer?: PeerDiagnostics;
  /** The version a refused hello asked for: whether the phone or the Gateway is
   * the stale build. */
  peerProtocolVersion?: number;
  /** Overrides the level rule for an ending the Gateway expects and clients
   * retry: readiness and shutdown refusals are info, not a warning. */
  level?: LogLevel;
}

/** One episode of inbound silence, from its last frame to the next one. */
interface SilenceEpisode {
  startedAt: number;
  resumedAt?: number;
  reported: boolean;
  /** Silence already observed when this episode was detected. */
  detectedMs: number;
  /** How long the Gateway's unanswered ping had been waiting at detection, or
   * null when the client's own pings were the liveness signal that stopped. */
  detectedPingMs: number | null;
  /** The shared, bounded peer-path read; it never rejects and never blocks the
   * heartbeat. */
  peer: Promise<PeerPathLookup>;
}

/** Diagnostics only: an invalid token is dropped, never a reason to reject hello. */
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
  identity: string;
  isLocal: boolean;
  socket: WebSocket;
  /** The peer's socket address; joins it to its Tailscale peer, never logged. */
  remoteAddress: string;
  /** Set by the upgrade that created this connection; see `UpgradeTrace`. */
  upgrade: UpgradeTrace;
  /** Empty until hello; see `peerDiagnostics`. */
  peer: PeerDiagnostics;
  /** The open inbound-silence episode, if the socket is silent now. */
  silence?: SilenceEpisode | undefined;
  unansweredHeartbeats: number;
  // When the Gateway's own last ping went out, cleared by any inbound frame.
  // `unansweredHeartbeats` counts ticks, including ticks that skipped the ping
  // for a client that had just spoken, so only this field says a ping is
  // actually outstanding; the silent record reports how long it has waited.
  pingOutstandingSince: number | null;
  ready: boolean;
  presentationOnly: boolean;
  terminals: Set<string>;
  inFlight: Set<string>;
  requestControllers: Map<string, InFlightRpc>;
  synchronizations: Map<string, ActiveSessionSynchronization>;
  subscriptionTokens: Map<string, string>;
  // A fork may occur after session.open but before session.sync. Retain the
  // former ID only while its carried subscription remains current.
  rekeyedSessionIds: Map<string, string>;
  synchronizationBytes: number;
  // Reserved before asynchronous service invocation so overlapping opens for
  // the same connection/session share their attempt instead of both running.
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
  // Messages and client pings only. A pong answers the Gateway's own ping, so
  // it never proves that the client will speak again without being asked.
  lastClientInitiatedInboundAt: number | null;
  // The client's own WebSocket pings, the one signal that it speaks unprompted.
  lastClientPingAt: number | null;
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

/** What `outboundFrameIdentity` adds to one encoded frame (`G-4`). */
interface OutboundFrameIdentity {
  readonly topic: string;
  readonly key?: string;
  readonly sessionId?: string;
  readonly sequence?: number;
  readonly runtimeGeneration?: string;
  readonly rebaseline?: () => OutboundFrame | undefined;
}

/**
 * The wire topic of one outbound frame, and — when a newer frame can replace it
 * in an unsent queue — what identifies the state it carries (`G-4`). Only a
 * `session.snapshot` supersedes sequenced state: it is the one frame that
 * carries the whole current state of its session, so the newest of them can
 * stand in for the sequences the queue dropped with it. A session summary is
 * replaced by key alone, because it states its own revision and carries no
 * sequence. A frame with neither is always delivered.
 */
function outboundFrameIdentity(
  connection: Connection,
  value: unknown,
  prepared: PreparedOutboundFrame,
  maximumBytes: number,
): OutboundFrameIdentity {
  // An oversized projection is sent as a compact resync notice instead: that
  // notice is its own frame and is never superseded by the projection it
  // replaced.
  if (prepared.fallback) return { topic: "transport.resyncRequired" };
  const frame = typeof value === "object" && value !== null ? value as Record<string, unknown> : {};
  const topic = typeof frame.topic === "string" ? frame.topic : typeof frame.type === "string" ? frame.type : UNKNOWN_OUTBOUND_TOPIC;
  const payload = typeof frame.payload === "object" && frame.payload !== null ? frame.payload as Record<string, unknown> : {};
  const sessionId = typeof frame.sessionId === "string" ? frame.sessionId : undefined;
  if (topic === "session.summary") {
    // A summary is a global event; the session it describes is its payload.
    const summarySessionId = typeof payload.sessionId === "string" ? payload.sessionId : undefined;
    return summarySessionId === undefined ? { topic } : { topic, key: `session.summary:${summarySessionId}` };
  }
  if (sessionId === undefined) return { topic };
  const sequence = typeof payload.eventSequence === "number" ? payload.eventSequence : undefined;
  if (sequence === undefined) return { topic };
  // Every sequenced session frame is described by the session, the runtime
  // generation its sequence belongs to and that sequence, so a newer snapshot
  // knows which of its session's frames its own state re-states and which ones
  // are fences it must not be dropped across (`SNAPSHOT_STATED_TOPICS`).
  const runtimeGeneration = typeof payload.runtimeGeneration === "string" ? payload.runtimeGeneration : undefined;
  const sequenced: OutboundFrameIdentity = {
    topic, sessionId, sequence,
    ...(runtimeGeneration === undefined ? {} : { runtimeGeneration }),
  };
  if (topic !== "session.snapshot") return sequenced;
  // Superseding a snapshot is only safe when the client can still accept what
  // follows: the replacement is a `session.rebaseline`, which the phone admits
  // as fresh authority even when its `eventSequence` jumps forward
  // (`SessionRebaselineAdmission`). It needs the subscription credential the
  // client installed, so a session this connection holds no token for
  // supersedes nothing.
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
      // A rebaseline too large to encode is still the frame the client needs to
      // fail closed: the compact notice retires its subscription instead.
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

/** A server's `connection` event is typed as a `Duplex`, but the accepted
 * socket is the net.Socket whose address the per-address bound counts. */
function acceptedSocketAddress(socket: Duplex): string {
  const address = (socket as { remoteAddress?: unknown }).remoteAddress;
  return typeof address === "string" ? address : "unknown";
}

/** The source port of an accepted socket, or undefined when the socket is not a
 * TCP one. It joins a TLS socket to the socket it wrapped: the two report the
 * same peer, and only one live connection holds an address and port pair. */
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
  // ws negotiates extensions per server instance; the upgrade handler picks
  // one by the authenticated credential kind.
  private readonly localSockets: WebSocketServer;
  private readonly pairedSockets: WebSocketServer;
  private readonly clients = new Map<string, Connection>();
  private readonly httpSockets = new Set<Duplex>();
  /** Pending WebSocket upgrades, ended by shutdown with the Gateway as the
   * cause: a socket the Gateway destroys is not a peer departure. */
  private readonly pendingUpgrades = new Set<() => void>();
  private readonly httpConnectionsByAddress = new Map<string, number>();
  /** The TCP accept instant per HTTP socket, so an upgrade record can say how
   * long the request waited before Node dispatched it. */
  private readonly httpSocketAcceptedAt = new WeakMap<object, number>();
  private readonly httpAdmission: HttpTransportAdmission;
  /** The transport's only Tailscale reader; it shares one bounded status read
   * between every socket that goes silent in the same window. */
  private readonly peerPaths: PeerPathReader;
  private readonly pairingLimiter = new RateLimiter(10, 10 * 60_000);
  private readonly heartbeat: NodeJS.Timeout;
  private lastHeartbeatAt = performance.now();
  private readonly stallSampler: StallSampler;
  private readonly disposableReadDeadlines: ReadonlyMap<string, number>;
  private readonly resourceSampler: ResourceSampler;
  private readonly resourceTimer: NodeJS.Timeout;
  /** One resource sample reads the runtime inventory; a slow one must not
   * overlap the next minute's window. */
  private resourceSampleInFlight = false;
  /** The second, TLS-only listener for the private LAN; undefined when the
   * Gateway was composed without one. */
  private readonly lanEndpoint: LanEndpoint | undefined;
  /** The main listener's leg, named on every upgrade record. */
  private readonly primaryTransport: ConnectionTransport;
  /** Whether the current run of sampler faults has already been reported. */
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
      /** The disposable-read deadline table (`G-12`). The module table unless a
       * caller overrides it, like the other named bounds above. */
      disposableReadDeadlinesMs?: ReadonlyMap<string, number>;
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
      resourceSampler?: ResourceSampler;
      peerPathReader?: PeerPathReader;
      /** The pinned LAN listener (E-3a). Absent means no second listener. */
      lanEndpoint?: LanEndpointConfig;
    },
  ) {
    this.stallSampler = options.stallSampler ?? new StallSampler();
    this.disposableReadDeadlines = options.disposableReadDeadlinesMs ?? DISPOSABLE_READ_DEADLINES_MS;
    this.resourceSampler = options.resourceSampler ?? new ResourceSampler();
    this.peerPaths = options.peerPathReader ?? new TailscalePeerPaths();
    this.primaryTransport = isTailscaleAddress(options.host) ? "tailscale" : "primary";
    // Sampled off every record path: the heartbeat keeps this current, and a
    // phone that reconnects in the first interval still carries host evidence.
    this.stallSampler.refreshHostSample();
    const maximumHttpConnections = options.maximumHttpConnections ?? HTTP_MAXIMUM_CONNECTIONS;
    if (!Number.isSafeInteger(maximumHttpConnections) || maximumHttpConnections < 1) {
      throw new Error("HTTP connection bounds are invalid");
    }
    this.httpAdmission = new HttpTransportAdmission(
      options.maximumHttpRequests,
      options.maximumHttpRequestsPerIdentity,
    );
    // Both listeners take their bounds from one object: the lane serves the
    // same routes to the same peers out of the same connection budget.
    const listenerLimits = HTTP_LISTENER_LIMITS;
    this.server = createServer(httpListenerOptions(listenerLimits), (request, response) => void this.handleHttp(request, response, this.primaryTransport));
    this.server.timeout = listenerLimits.idleTimeout;
    this.server.on("connection", (socket) => this.admitHttpConnection(socket, maximumHttpConnections));
    // The LAN listener shares this transport's admission, capacity, heartbeat,
    // revocation and hello; only its address, its certificate and the routes it
    // refuses are its own.
    if (options.lanEndpoint) {
      this.lanEndpoint = new LanEndpoint({
        ...options.lanEndpoint,
        logger: options.logger,
        port: options.port,
        listenerLimits,
        onConnection: (socket) => this.admitHttpConnection(socket, maximumHttpConnections),
        onSecureConnection: (socket) => this.adoptAcceptedSocketTime(socket),
        onRequest: (request, response) => void this.handleHttp(request, response, "lan"),
        onUpgrade: (request, socket, head) => void this.handleUpgrade(request, socket, head, "lan"),
      });
    }
    // maxPayload bounds each inbound message after inflation as well as on the wire.
    this.localSockets = new WebSocketServer({ noServer: true, maxPayload: options.maxFrameBytes, perMessageDeflate: false });
    this.pairedSockets = new WebSocketServer({
      noServer: true, maxPayload: options.maxFrameBytes, perMessageDeflate: PAIRED_PER_MESSAGE_DEFLATE,
    });
    this.server.on("upgrade", (request, socket, head) => void this.handleUpgrade(request, socket, head, this.primaryTransport));
    this.heartbeat = setInterval(() => {
      const heartbeatAt = performance.now();
      const timerDelayMs = heartbeatTimerDelay(heartbeatAt - this.lastHeartbeatAt);
      this.lastHeartbeatAt = heartbeatAt;
      // Every heartbeat closes a window, so a delayed record's GC and
      // utilization cover exactly the delayed interval.
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
      // Keeps the host sample behind the connection records current. On a tick
      // that already probed the host for a stall this starts nothing extra.
      this.stallSampler.refreshHostSample();
      for (const connection of this.clients.values()) {
        if (connection.closeInitiated || connection.socket.readyState !== WebSocket.OPEN) continue;
        this.observeInboundSilence(connection, heartbeatAt);
        // Retire only after three complete heartbeat intervals received no frame.
        // One delayed timer or transiently starved callback cannot destroy a
        // healthy epoch; the fourth tick observes and retires the three misses.
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
        // Every tick counts, so a dead client is retired on the same tick
        // whether or not it was pinged. A client whose own frames arrived
        // within the last interval is already proving liveness (the phone pings
        // every 10 s); pinging it would only add a wakeup on both ends. Silent
        // and pong-only clients are still pinged on every tick.
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
    // The resource record is the Gateway's only periodic whole-process picture;
    // one minute is the cadence the sampler's volume estimate assumes.
    this.resourceTimer = setInterval(() => void this.publishResources(), RESOURCE_SAMPLE_INTERVAL_MS);
    this.resourceTimer.unref();
  }

  /** Every physical socket of every listener enters here, so the capacity bound
   * counts the Gateway's whole HTTP surface, not one address. */
  private admitHttpConnection(socket: Duplex, maximumHttpConnections: number): void {
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
    this.httpSocketAcceptedAt.set(socket, performance.now());
    this.httpConnectionsByAddress.set(address, addressConnections + 1);
    socket.once("close", () => {
      this.httpSockets.delete(socket);
      // `httpSocketAcceptedAt` is a WeakMap: the accept time it holds for this
      // socket's upgrade is released with the socket, so it needs no delete.
      const count = this.httpConnectionsByAddress.get(address)!;
      if (count === 1) this.httpConnectionsByAddress.delete(address);
      else this.httpConnectionsByAddress.set(address, count - 1);
    });
  }

  /** Carries the accept time recorded at `connection` to the `TLSSocket` a TLS
   * listener later hands the upgrade handler: `tls.Server` does not give the
   * wrapped socket back, and a lookup that misses reports zero elapsed time for
   * every lane upgrade — exactly the TLS handshake the field exists to show. */
  private adoptAcceptedSocketTime(socket: Duplex): void {
    const address = acceptedSocketAddress(socket);
    const port = acceptedSocketPort(socket);
    if (port === undefined) return;
    for (const accepted of this.httpSockets) {
      if (acceptedSocketPort(accepted) !== port || acceptedSocketAddress(accepted) !== address) continue;
      const acceptedAt = this.httpSocketAcceptedAt.get(accepted);
      if (acceptedAt !== undefined) this.httpSocketAcceptedAt.set(socket, acceptedAt);
      return;
    }
  }

  private async publishResources(): Promise<void> {
    if (this.shuttingDown) return;
    if (this.resourceSampleInFlight) {
      // A sample that never settles (a `stat` on a stuck filesystem, an
      // inventory read that hangs) would otherwise stop `gateway.resources` in
      // silence: every later tick returns here and the window it would have
      // closed is never reported. One record per run says so with the same
      // flag, so a skipped window cannot flood the log.
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
      // A sampler fault must never take the transport down, but a window that
      // keeps failing would otherwise stop `gateway.resources` in silence (the
      // histogram was already reset with the lost window). One record per run of
      // failures says so without flooding the log.
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
      // The LAN listener binds after the main one so a LAN failure can never
      // cost the Gateway its primary surface; `start` never throws.
      await this.lanEndpoint?.start();
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

  /** Resolve a session ID through this connection's rekey aliases. */
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

  /** Drop this connection's rekey aliases that name the given session. */
  private clearRekeyedSessionIds(connection: Connection, sessionId: string): void {
    for (const [former, current] of connection.rekeyedSessionIds) {
      if (former === sessionId || current === sessionId) connection.rekeyedSessionIds.delete(former);
    }
  }

  /** Revoke one installed subscription with its pending barrier and every
   * connection-local projection of that session. */
  private revokeInstalledSubscription(connection: Connection, sessionId: string, token: string): boolean {
    sessionId = this.resolveSessionId(connection, sessionId);
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
    this.clearRekeyedSessionIds(connection, sessionId);
    releaseSessionTerminals(
      connection.terminals,
      sessionId,
      (terminalId, ownerSessionId) => this.options.service.terminalBelongsToSession(terminalId, ownerSessionId),
    );
    this.options.sessions.unsubscribe(connection.id, sessionId);
    this.options.service.releaseSessionProcessTranscripts?.(sessionId, connection.id, token);
    return true;
  }

  /** Revoke one pending synchronization, if this connection still owns it. A
   * later session.open may have replaced this request's owner; in that case
   * only the current token may revoke the runtime subscription. */
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
    // No audience, no work: a frame nobody can receive is not prepared at all
    // (encoded, measured, fitted to a compression context), so a state change
    // for a session with no subscriber costs the summary and nothing else.
    let recipients = 0;
    for (const client of this.clients.values()) {
      if (client.ready && client.subscriptionTokens.has(sessionId)) recipients += 1;
    }
    // The snapshot build is counted here, where the recipients that can receive
    // it are known, and before the no-recipient return: a projection built for a
    // subscriber this transport has no ready socket for is recorded as
    // unaudienced, which is the window's lost-audience warning rather than a
    // normal minute. Serializing a frame the client cannot take is still skipped.
    if (topic === "session.snapshot") this.resourceSampler.recordSnapshotBuild(recipients);
    if (recipients === 0) return;
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
    this.resourceSampler.recordTopicFrame(topic, prepared?.outputBytes ?? 0, recipients);
  }

  broadcast(topic: string, payload: JsonValue): void {
    // The same no-audience rule as `broadcastSession`: a global event with no
    // ready client is not serialized.
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
        // The Gateway ends this socket because the device is gone, so a socket
        // that never said hello states that cause rather than the peer leaving.
        if (!client.ready) {
          this.finishUpgrade(client.upgrade, "abandoned", "handshake", "device revoked", { reason: "device_revoked" });
        }
        client.socket.close(1008, "device revoked");
      }
      this.options.service.releaseClient(client.id);
    }
  }

  private async handleHttp(request: IncomingMessage, response: ServerResponse, transport: ConnectionTransport): Promise<void> {
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
        const status = this.shuttingDown ? "stopping" : this.ready ? "ok" : this.startupPhase;
        // The LAN listener answers the health check with its status alone: any
        // device on the same network can reach it unauthenticated, and build
        // and revision metadata is not what a health check owes it (E-3a).
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
        // Pairing is first contact, and it stays on the main listener: the LAN
        // leg serves the socket and authenticated routes only (E-3a).
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

  /** The LAN lane's advertisement (E-3b): where a paired phone may race a
   * second leg and which certificate key it must find there. It is added to
   * the pairing response and hello alone — the two places a paired device
   * learns about this Mac — and never to `/health` or any other route that
   * anything on the network can reach. A Gateway composed without a lane
   * advertises nothing, which a phone reads as "no LAN leg". */
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

  private async handleUpgrade(request: IncomingMessage, socket: Duplex, head: Buffer, transport: ConnectionTransport): Promise<void> {
    const remoteAddress = request.socket.remoteAddress ?? "unknown";
    // One record per upgrade, written wherever this attempt ends.
    const trace: UpgradeTrace = {
      transport,
      acceptAt: this.httpSocketAcceptedAt.get(socket) ?? performance.now(),
      startedAt: performance.now(),
      authMs: null,
      handshakeAt: null,
      reported: false,
    };
    // Node relinquishes its HTTP parser on upgrade, before async credentials
    // return. Own EOF/error and the auth deadline until ws takes the socket;
    // otherwise a half-closed pre-handshake peer can live indefinitely.
    const readLifetime = new AbortController();
    // Both ends of the credential wait destroy this socket, but only the phase
    // record can say which one did: a peer that leaves is abandoned, an expired
    // authentication deadline is a refusal.
    let retireCause: "peer" | "timeout" | null = null;
    // Shutdown destroys this socket too. Registered so the record names the
    // Gateway as the cause instead of reporting the peer as leaving.
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
    // An upgrade awaiting credentials is still an admitted HTTP operation.
    // Physical close alone cannot release its pending authentication budget.
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
        // Expected during startup warmup and shutdown; clients retry.
        const reason = this.shuttingDown ? "shutting_down" : "warming_up";
        this.finishUpgrade(trace, "rejected", "request", `Gateway is ${reason.replace("_", " ")}`, { reason, level: "info" });
        socket.write("HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n");
        socket.destroy();
        return;
      }
      const admission = await this.options.devices.authenticateAndAdmit(bearer(request), (authenticated) => {
        // The credential callback runs at the auth boundary, and the WebSocket
        // handshake follows it on the same stack, so each phase is timed from
        // the point it actually ended.
        trace.authMs ??= performance.now() - trace.startedAt;
        // Authentication can yield while shutdown starts. Recheck the
        // admission cut after that await so an upgrade cannot become a live
        // connection after the listener has begun retiring work.
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
        // `abortHandshake` answers 400 without a callback: a bad
        // `Sec-WebSocket-Key` or version, or a refused extension negotiation.
        // The credential callback returns true, so only this check records it.
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
      // A credential wait cut short never reaches the callback above: the peer
      // left (`readLifetime` aborted by its own close) or the authentication
      // deadline expired. Both reached this Mac and stopped in the auth phase.
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

  /** Writes the one `http.upgrade` record for an upgrade, at whichever phase it
   * ended. `phaseReached` names the last phase the attempt actually reached, so
   * a missing `hello` phase means no hello frame arrived. This is the only
   * record a refused upgrade writes: `reason` names the bound or phase cause
   * that the separate bound-specific records used to restate. */
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
      identity,
      isLocal,
      socket,
      remoteAddress,
      upgrade,
      peer: {},
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
      lastClientInitiatedInboundAt: null,
      lastClientPingAt: null,
      lastWriteProgressAt: null,
      pingOutstandingSince: null,
      helloTimer: setTimeout(() => {
        // The Gateway's own deadline ended this attempt, so the record must not
        // name the peer as the cause.
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
      // A frame the ws library refused at the protocol level (an oversized
      // payload, a malformed frame) is the hello phase's refusal, not the peer
      // leaving the socket it opened. Later frames are already reported by the
      // upgrade's own ending.
      if (!connection.ready && isFrameRefusal(error)) {
        this.finishUpgrade(connection.upgrade, "rejected", "hello", `WebSocket error: ${error.message}`, { reason: "invalid_frame" });
      }
      this.disconnect(connection, `WebSocket error: ${error.message}`);
    });
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
      // A frame that is not JSON before hello is the Gateway refusing the
      // hello phase, not the peer leaving after the handshake.
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
        return this.closeFailedConnection(connection, 1008, "protocol version mismatch");
      }
      connection.ready = true;
      connection.presentationOnly = (frame as Record<string, unknown>).clientRole === "mobile";
      connection.peer = peerDiagnostics(frame.diagnostics);
      this.finishUpgrade(connection.upgrade, "opened", "hello", "hello accepted", { reason: "hello", peer: connection.peer });
      // Admission and handshake are one `connection.opened` record. The Mac
      // app's local probes reconnect constantly, so they are debug detail, and
      // only a paired device's reconnect carries host memory evidence.
      const openHostEvidence = connection.isLocal ? "" : ` ${formatHostEvidence(this.stallSampler.hostSample())}`;
      this.options.logger.log(
        connection.isLocal ? "debug" : "info",
        `Client ${connection.id} connection opened (${connection.isLocal ? "local" : "paired"}, ${connection.presentationOnly ? "mobile" : "local"} role, compression=${connection.socket.extensions || "none"}) after ${Math.max(0, Math.round(performance.now() - connection.admittedAt))}ms${openHostEvidence}`,
        { event: "connection.opened", source: "transport", connectionId: connection.id, ...connection.peer },
      );
      clearTimeout(connection.helloTimer);
      // `connectionId` lets the peer log the key of this connection's records.
      // The LAN advertisement rides on hello (E-3b): a paired device re-learns
      // the lane's endpoint and pin on every connection, so a Mac that moved or
      // rotated its certificate is corrected before the next race.
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
      // A `cancel` frame is a control frame with no answer: the peer already
      // stopped waiting for the request it names, so there is nobody to tell.
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
    const admittedTerminalIds = new Set(connection.terminals);
    const requestId = frame.id;
    const diagnosticID = diagnosticRequestID(requestId);
    const rpcStartedAt = performance.now();
    // One span per admitted request. Its breakdown rides on the rpc.completed
    // record below, so a slow request names the work that held it.
    const requestSpan = new RequestSpan();
    const inFlightRpc: InFlightRpc = {
      controller: requestController,
      method: frame.method,
      startedAt: rpcStartedAt,
      span: requestSpan,
    };
    connection.requestControllers.set(frame.id, inFlightRpc);
    // The deadline is armed at admission, so it bounds the whole request path
    // and not only the work the handler happens to be in (`G-12`).
    const deadlineTimer = this.armDisposableReadDeadline(frame.method, inFlightRpc);
    // The deadline owns this request only until a response is attempted: a timer
    // that fires while an answer's own catch-up is still being written must not
    // relabel an answered request as shed.
    const clearDeadline = (): void => { if (deadlineTimer !== undefined) clearTimeout(deadlineTimer); };
    const params = frame.params && typeof frame.params === "object" && !Array.isArray(frame.params)
      ? frame.params as Record<string, unknown>
      : {};
    // Correlation only: identifiers the client already chose, never payload.
    const rpcCorrelation = {
      ...(typeof params.sessionId === "string" ? { sessionId: params.sessionId } : {}),
      ...(typeof params.commandId === "string" ? { commandId: params.commandId } : {}),
    };
    let rpcOutcome: "success" | "failure" = "failure";
    // Whether the session-open attempt itself produced a result, before any
    // response of this request was written. A synchronization installed by an
    // attempt that produced nothing is this request's to release.
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
        // A `session.open` waits on the connection's shared attempt for its
        // session, so its signal is the attempt's: one waiter leaving must not
        // abandon the answer another waiter still waits for (`C-6`).
        signal: sessionOpenFlight?.controller.signal ?? requestController.signal,
        beginSynchronization: (sessionId) => {
          if (connection.revoked) throw new GatewayError("unauthenticated", "This device is no longer authorized");
          if (connection.workRetired) throw new GatewayError("busy", "Connection is closed", true);
          // Runtime acquire may yield to a fork before this call. Resolve the
          // request's ID before installing the subscription and barrier so
          // ownership is attached to the canonical slot.
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
      const method = frame.method;
      const invoke = (): Promise<JsonValue> => runInRequestSpan(
        requestSpan,
        (): Promise<JsonValue> => this.options.service.invoke(context, method, frame.params ?? {}),
      );
      let result: JsonValue;
      if (sessionOpenFlight === undefined) {
        // A read with a deadline is abandoned at that deadline instead of
        // waiting for work whose answer nobody will accept; its owner keeps
        // running and the abort answers the request (`G-12`).
        result = deadlineTimer === undefined
          ? await invoke()
          : await abortableRead(requestController.signal, invoke);
        attemptSucceeded = true;
      } else {
        const attempt = invoke();
        sessionOpenFlight.attempt = attempt;
        // One answer, shared with every request that joined it. A rejection the
        // last waiter left behind is not an unhandled rejection: nobody will
        // read it, and the abort that ends the shared work states why.
        void attempt.catch(() => {});
        // Named for the cancellation record; the attempt's own stages are what
        // measure it, and a second entry for the same interval would double it.
        const leaveAttemptStage = requestSpan.enterStage("session.open.attempt");
        try {
          result = await abortableRead(requestController.signal, () => attempt);
        } finally {
          leaveAttemptStage();
        }
        attemptSucceeded = true;
      }
      if (requestController.signal.aborted) return;
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
      const responseSentIntact = runInRequestSpan(requestSpan, () => this.send(connection, { type: "response", id: frame.id, ok: true, result }));
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

          // `fallback` means prepareOutboundFrame already produced the compact
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
      // An open keeps the synchronization it installed only when an answer for
      // it is out: this request's own delivered response, or a shared attempt a
      // waiting retry may still deliver. Everything else - a failure, a
      // cancellation, an undelivered response - releases the barrier and its
      // subscription here, so an abandoned open cannot block the retry that
      // follows it (`C-6`).
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
        // A waiting retry still needs whatever this attempt installed - including
        // a barrier this request created before it was cancelled. The retry owns
        // the delivery now, so the barrier is released only if it leaves without
        // answering (`C-6`).
        sessionOpenFlight.releaseAbandoned = releaseOwnSynchronizations;
      } else if (!(attemptSucceeded && rpcOutcome === "success")) {
        releaseOwnSynchronizations();
      }
      if (sessionOpenFlight !== undefined) {
        // Rekey retains an old duplicate-open alias, but both spellings point at
        // the same flight; releasing the flight releases every alias with it.
        this.releaseSessionOpenFlight(connection, sessionOpenFlight);
      }
      connection.inFlight.delete(frame.id);
      connection.requestControllers.delete(frame.id);
      // Closing a connection aborts its requests, yet accepted domain work
      // (a prompt held behind compaction) keeps running. Name the undelivered
      // response rather than reporting that work as failed.
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

  /**
   * Answer a `session.open` that arrived while this connection and session
   * already had one in flight: the retry joins that attempt, receives its exact
   * result, and leaves the shared work alone while it waits (`C-6`). Answering a
   * retry from a shared attempt is what turns the phone's 30-second timeout into
   * a slow open instead of a duplicate-open failure.
   */
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
    // Join before any await: the flight's waiter count pairs with its `finally`.
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
        // A retry delivered the shared attempt's answer, so the barrier it
        // installed is now the client's to acknowledge.
        flight.answered = true;
        this.markSessionOpenDelivered(connection, flight.requestId, requestId);
        rpcOutcome = "success";
        clearDeadline();
      }
    } catch (error) {
      // A shed join still owes its own answer: unlike a cancel, nobody stopped
      // waiting for it, so the busy response with the retry hint goes out
      // (`G-12`).
      if (inFlightRpc.shedReason !== undefined) {
        runInRequestSpan(requestSpan, () => this.send(connection, { type: "response", id: requestId, ok: false, error: publicError(error) }));
      } else if (!inFlightRpc.controller.signal.aborted) {
        const level = rpcFailureLevel(error);
        this.options.logger.log(level, `RPC ${frame.method as string} for client ${connection.id} failed`, {
          event: "rpc.error", source: "transport", method: frame.method as string, requestID: diagnosticRequestID(requestId),
          connectionId: connection.id, ...rpcCorrelation,
          code: diagnosticErrorCode(error), outcome: "failure",
          ...(level === "error" ? { error } : {}),
          ...(error instanceof GatewayError && error.diagnosticReason ? { reason: error.diagnosticReason } : {}),
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

  /**
   * Arm one disposable read's deadline (`G-12`). On expiry the request is marked
   * shed and aborted; the ordinary failure path answers `busy` with the retry
   * hint and the one record for it is `gateway.shed`. A method outside
   * `DISPOSABLE_READ_DEADLINES_MS` — every mutation, every prompt, `session.sync`
   * — has no deadline at all: those owners settle their work whatever the client
   * does with its wait.
   */
  private armDisposableReadDeadline(
    method: string,
    inFlight: InFlightRpc,
  ): NodeJS.Timeout | undefined {
    const deadlineMs = this.disposableReadDeadlines.get(method);
    if (deadlineMs === undefined) return undefined;
    const timer = setTimeout(() => {
      if (inFlight.shedReason !== undefined || inFlight.controller.signal.aborted) return;
      // A subscriber of a joined open still waits for its own answer, so only
      // this request is aborted; the shared attempt ends when its last waiter
      // leaves (`C-6`).
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

  /**
   * Record the `cancel` frame of a request this connection still owns: work only
   * a disposable read does stops, and the record names the stage it was in. A
   * cancel for an accepted mutation, an admitted prompt or a `session.sync` is
   * ignored: their owners settle them durably whatever the client does with its
   * wait (`C-6`).
   */
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

  /**
   * A cancel can cross a `session.open` answer still in transit on a slow link:
   * the phone stopped waiting, but the Gateway already delivered the response and
   * its barrier is still pending, so a retry in that window would fail as a
   * duplicate. Revoke the barrier the abandoned open delivered - unless another
   * delivered response carries the same token (a joined retry the phone may
   * still accept), which is what `deliveredRequests` records (`C-6`).
   */
  private revokeAbandonedOpen(connection: Connection, requestId: string): void {
    for (const [sessionId, synchronization] of connection.synchronizations) {
      // Removing the delivered request both detects it and consumes it: the
      // barrier belongs to the client only while one of its delivered responses
      // is unaccounted for.
      if (!synchronization.deliveredRequests.delete(requestId)) continue;
      if (synchronization.deliveredRequests.size > 0) return;
      this.revokeSynchronization(connection, sessionId, synchronization);
      return;
    }
  }

  /** Record that a delivered response carried this session's synchronization
   * token, so a later cancel can revoke the barrier only when no other delivered
   * response still carries it. The owner request installed the barrier; the
   * delivering request may be the retry that joined it. */
  private markSessionOpenDelivered(connection: Connection, ownerRequestId: string, deliveredRequestId: string): void {
    for (const synchronization of connection.synchronizations.values()) {
      if (synchronization.requestId === ownerRequestId) synchronization.deliveredRequests.add(deliveredRequestId);
    }
  }

  /** Release one waiter of a shared session-open attempt. The last one leaving
   * abandons the work: nobody computes an answer nobody waits for. */
  private releaseSessionOpenFlight(connection: Connection, flight: SessionOpenFlight): void {
    flight.waiters -= 1;
    if (flight.waiters > 0) return;
    flight.controller.abort(new GatewayError("cancelled", "No request waits for this session open anymore", true));
    for (const [sessionId, pending] of connection.pendingSessionOpens) {
      if (pending === flight) connection.pendingSessionOpens.delete(sessionId);
    }
    // Nobody waits for this attempt's answer and no response carried it: what
    // it installed is unreachable ownership, released by the request that owns
    // the barrier.
    if (!flight.answered) flight.releaseAbandoned?.();
  }

  /** One record per finished request: `rpc.completed` with its breakdown, or the
   * `rpc.cancelled` juncture record naming the stage a cancel interrupted. A read
   * the Gateway shed at its own deadline (`G-12`) writes one `gateway.shed`
   * record instead: the client is still waiting for that answer, and what it
   * needs to know is the reason and the retry hint. */
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
    const breakdown = request.span.breakdown(durationMs);
    if (request.shedReason !== undefined) {
      // A shed read is abnormal by definition: the Gateway refused work it had
      // admitted, so the record is a warning whether or not it was slow.
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
      // A cancellation is its own juncture, so it writes one record instead of a
      // completion: the stage it interrupted plus the stages it reached. Only a
      // read the peer abandoned after `SLOW_RPC_WARNING_MS` is worth a warning;
      // an ordinary retry cadence stays debug.
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
    this.options.logger.log(
      request.outcome !== "success" || durationMs >= SLOW_RPC_WARNING_MS ? "warning" : "debug",
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
      const frame = prepared === undefined
        ? stage("frame.serialize", () => prepareOutboundFrame(value, this.options.maxFrameBytes))
        : prepared;
      if (!frame) return "failed";
      // A frame prepared once for a broadcast is measured where it is built; a
      // fresh one is measured here. Bytes follow the serialization, not the
      // number of subscribers that receive it.
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

      // Enqueue acceptance is the ordering boundary. The connection-local
      // writer hands exactly one encoded frame to ws at a time, preserving a
      // response before its synchronization suffix without manufacturing
      // transport pressure from concurrent bounded RPC completions.
      if (!connection.outbound.enqueue({
        encoded: frame.output, bytes: frame.outputBytes,
        ...outboundFrameIdentity(connection, value, frame, this.options.maxFrameBytes),
      })) return "failed";
      // The queue reported the bytes it accepted: a frame it replaced with a
      // coalescing `session.rebaseline` is counted as that replacement.
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
    // A socket that never got past hello leaves through here when the peer
    // ended it: the upgrade reached this Mac and then went away before the
    // handshake finished. Every ending the Gateway itself starts records its
    // own `reason` before it closes the socket (`closeFailedConnection`, the
    // hello deadline, revocation, shutdown), so only a peer-driven ending can
    // still be unreported here.
    if (!connection.closeInitiated) {
      this.finishUpgrade(connection.upgrade, "abandoned", "handshake", detail, { reason: "peer_closed" });
    }
    const outbound = connection.outbound.snapshot();
    connection.outbound.retire();
    // A phone's drop is the incident boundary, so the close record states what
    // the host was doing; the local probes' debug records stay free of it.
    const closeHostEvidence = connection.isLocal ? "" : ` ${formatHostEvidence(this.stallSampler.hostSample())}`;
    this.options.logger.log(
      connection.isLocal ? "debug" : "info",
      `Client ${connection.id} connection closed after ${Math.max(0, Math.round(closedAt - connection.admittedAt))}ms (${detail}; ${outbound.completedFrames}/${outbound.acceptedFrames} outbound frames completed, ${outbound.queuedBytes} queued bytes; lastInboundAgeMs=${progressAge(connection.lastInboundAt, closedAt)} lastWriteProgressAgeMs=${progressAge(connection.lastWriteProgressAt, closedAt)} queuedFrames=${outbound.queuedFrames} queuedBytes=${outbound.queuedBytes} completedFrames=${outbound.completedFrames})${closeHostEvidence}`,
      { event: "connection.closed", source: "transport", connectionId: connection.id, ...connection.peer,
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
    // A retiring socket has no request left to receive a shared session-open
    // answer, so its attempts stop here instead of running for nobody.
    for (const flight of connection.pendingSessionOpens.values()) {
      flight.controller.abort(new GatewayError("cancelled", "The connection retired during this session open", true));
    }
    connection.pendingSessionOpens.clear();
    connection.rekeyedSessionIds.clear();
    // Revoked accepted requests retain their controller until their own
    // completion; ordinary disconnects still abort disposable work.
    if (!connection.revoked) for (const request of connection.requestControllers.values()) request.controller.abort();
    connection.requestControllers.clear();
    this.options.sessions.unsubscribeClient(connection.id);
    this.options.service.releaseClient(connection.id);
    // The authenticated device identity owns provider login. A socket close
    // only detaches event delivery; auth.resume can bind a replacement socket.
    this.options.auth.detachClient(connection.id);
  }

  private closeFailedConnection(connection: Connection, code: number, reason: string, ending?: UpgradeEnding): void {
    if (connection.closeInitiated) return;
    connection.closeInitiated = true;
    // The Gateway is ending this socket, so an attempt that never reached hello
    // states the Gateway's own cause here, before the close: `disconnect` would
    // otherwise report the peer as leaving.
    if (ending !== undefined && !connection.ready) {
      this.finishUpgrade(connection.upgrade, "abandoned", "handshake", reason, ending);
    }
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

  /** Any inbound frame proves liveness, and it closes a logged silence episode. */
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
    // The silent record is written when the shared peer-path read settles; a
    // silence that ends first still reports silence before its resume.
    if (episode.reported) this.logInboundResumed(connection, episode);
  }

  /** One warning per silence episode, not one per heartbeat tick. The peer's
   * Tailscale path is captured once per episode and never delays the tick. */
  private observeInboundSilence(connection: Connection, heartbeatAt: number): void {
    if (connection.silence !== undefined) return;
    const startedAt = connection.lastInboundAt ?? connection.admittedAt;
    if (heartbeatAt - startedAt < INBOUND_SILENCE_WARNING_MS) return;
    // A client that only answers the Gateway's pings is idle between them, not
    // cut off: its silence says nothing until a ping the Gateway actually sent
    // goes unanswered. A client that pings on its own (the phone, every ten
    // seconds) proves liveness without being asked, so silence past the
    // threshold is the path going quiet. Without this, a pong-only client
    // reports silence on every tick.
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
      // A reader that rejects must still leave a record: the silence is the
      // point, the path is the detail.
      peer: this.peerPaths.lookup(connection.remoteAddress)
        .catch((): PeerPathLookup => ({ peerPath: "unknown", peerRelay: "" })),
    };
    connection.silence = episode;
    void episode.peer.then((peer) => {
      if (episode.reported) return;
      episode.reported = true;
      // The message reports the silence observed at detection; the resume
      // record carries the episode's full duration.
      this.options.logger.log("warning", `Client ${connection.id} has sent nothing for ${episode.detectedMs}ms (unansweredPingMs=${episode.detectedPingMs ?? "none"} peerPath=${peer.peerPath} peerRelay=${peer.peerRelay || "none"})`, {
        event: "connection.inbound-silent", source: "transport", connectionId: connection.id, ...connection.peer,
        peerPath: peer.peerPath, peerRelay: peer.peerRelay,
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
    // The LAN leg retires first: no new connection reaches a Gateway that is
    // stopping. Sockets it accepted keep their own bounded grace.
    const lanRetirement = this.lanEndpoint?.stop();
    clearInterval(this.resourceTimer);
    this.stallSampler.dispose();
    this.resourceSampler.dispose();
    for (const client of this.clients.values()) {
      // The Gateway ends this socket, not its peer: a socket that never said
      // hello must not be recorded as a peer departure when the process stops.
      if (!client.ready) {
        this.finishUpgrade(client.upgrade, "abandoned", "handshake", "Gateway shutdown before hello", { reason: "shutting_down" });
      }
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
      // The Gateway stops these pending upgrades too, at whatever phase they
      // reached; each record is written before its socket is destroyed.
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
