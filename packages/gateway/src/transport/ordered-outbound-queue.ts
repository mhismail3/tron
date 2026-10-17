/**
 * The connection-local ordered outbound queue: the frame and snapshot contracts
 * it accepts and reports, and the coalescing rules that drop a superseded unsent
 * frame. Socket admission, broadcast and the close decision stay in GatewayServer.
 */

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

export const UNKNOWN_OUTBOUND_TOPIC = "other";

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
  "session.configuration",
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
    // An entry larger than the whole budget also fails the aggregate byte bound:
    // released bytes are part of queuedBytes, so the left side is never negative.
    if (this.frames.length - this.head - superseded.length + 1 > this.maximumFrames
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
