interface OrderedOutboundQueueSnapshot {
  queuedFrames: number;
  queuedBytes: number;
  writeActive: boolean;
  acceptedFrames: number;
  completedFrames: number;
  maximumFrames: number;
  maximumBytes: number;
  frameHighWater: number;
  byteHighWater: number;
  oldestTopic: string;
}

export interface OutboundFrame {
  readonly encoded: string;
  readonly bytes: number;
  readonly topic: string;
  readonly key?: string;
  readonly sessionId?: string;
  readonly sequence?: number;
  readonly runtimeGeneration?: string;
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

function snapshotRestates(queued: QueuedOutboundFrame, frame: OutboundFrame): boolean {
  return queued.runtimeGeneration === frame.runtimeGeneration
    && queued.sequence !== undefined
    && frame.sequence !== undefined
    && queued.sequence <= frame.sequence
    && SNAPSHOT_STATED_TOPICS.has(queued.topic);
}

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
    private readonly accepted: (bytes: number) => void = () => {},
    private readonly replaced: (bytes: number) => void = () => {},
    private readonly maximumFrames = 4_096,
  ) {}

  enqueue(frame: OutboundFrame): boolean {
    if (this.retired) return false;
    const candidates = this.supersededIndices(frame);
    const replacement = candidates.length > 0 && frame.sequence !== undefined ? frame.rebaseline?.() : undefined;
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
    let removed = 0;
    for (const index of superseded) {
      const dropped = this.frames[index - removed];
      if (dropped === undefined) continue;
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

  private supersededIndices(frame: OutboundFrame): number[] {
    const first = this.writeActive ? this.head + 1 : this.head;
    if (frame.sessionId !== undefined && frame.sequence !== undefined) {
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
      this.frames[this.head] = undefined;
      this.head += 1;
      this.queuedBytes = Math.max(0, this.queuedBytes - frame.bytes);
      this.writeActive = false;
      if (this.head === this.frames.length) {
        this.frames.length = 0;
        this.head = 0;
      } else if (this.head >= 1_024 && this.head * 2 >= this.frames.length) {
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
