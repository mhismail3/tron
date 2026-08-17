import type { JsonValue, SessionSnapshot } from "../protocol/types.js";

export interface BufferedSessionEvent {
  type: "event";
  topic: string;
  sessionId: string;
  payload: JsonValue;
}

export interface SessionSyncBaseline {
  runtimeGeneration: string;
  eventSequence: number;
}

interface Synchronization {
  requestId: string;
  baseline?: SessionSyncBaseline;
  events: BufferedSessionEvent[];
  bufferedBytes: number;
  overflowed: boolean;
}

export interface CompletedSessionSync {
  events: BufferedSessionEvent[];
  overflowed: boolean;
}

export const MAX_BUFFERED_SYNC_EVENTS = 1_024;
/**
 * One synchronization quarantine may retain at most one default transport
 * frame. A larger burst resynchronizes from a fresh authoritative snapshot
 * instead of multiplying memory across concurrent session opens.
 */
export const MAX_BUFFERED_SYNC_BYTES = 1_048_576;

function serializedBytes(event: BufferedSessionEvent): number | undefined {
  try {
    const encoded = JSON.stringify(event);
    return encoded === undefined ? undefined : Buffer.byteLength(encoded, "utf8");
  } catch {
    return undefined;
  }
}

function sequence(event: BufferedSessionEvent): SessionSyncBaseline | undefined {
  const payload = event.payload as unknown as Record<string, unknown>;
  const runtimeGeneration = payload.runtimeGeneration;
  const eventSequence = payload.eventSequence;
  if (typeof runtimeGeneration === "string" && Number.isSafeInteger(eventSequence)) {
    return { runtimeGeneration, eventSequence: eventSequence as number };
  }
  return undefined;
}

/**
 * Per-connection subscription state. While a baseline response is in flight,
 * later events are quarantined so the response is always observed first.
 */
export class SessionSyncBarrier {
  private synchronization: Synchronization | undefined;

  begin(requestId: string): void {
    if (this.synchronization) throw new Error("session synchronization is already in progress");
    this.synchronization = { requestId, events: [], bufferedBytes: 0, overflowed: false };
  }

  establish(snapshot: SessionSnapshot): void {
    const synchronization = this.synchronization;
    if (!synchronization) throw new Error("session synchronization has not begun");
    synchronization.baseline = {
      runtimeGeneration: snapshot.runtimeGeneration,
      eventSequence: snapshot.eventSequence,
    };
  }

  offer(event: BufferedSessionEvent): BufferedSessionEvent | undefined {
    const synchronization = this.synchronization;
    if (!synchronization) return event;
    if (synchronization.overflowed) return undefined;

    const bytes = serializedBytes(event);
    if (bytes === undefined
        || bytes > MAX_BUFFERED_SYNC_BYTES
        || synchronization.events.length >= MAX_BUFFERED_SYNC_EVENTS
        || synchronization.bufferedBytes > MAX_BUFFERED_SYNC_BYTES - bytes) {
      synchronization.events.length = 0;
      synchronization.bufferedBytes = 0;
      synchronization.overflowed = true;
      return undefined;
    }
    synchronization.events.push(event);
    synchronization.bufferedBytes += bytes;
    return undefined;
  }

  /** Discard a failed or retired synchronization and its byte accounting. */
  abort(requestId: string): boolean {
    const synchronization = this.synchronization;
    if (!synchronization || synchronization.requestId !== requestId) return false;
    synchronization.events.length = 0;
    synchronization.bufferedBytes = 0;
    this.synchronization = undefined;
    return true;
  }

  commit(requestId: string): CompletedSessionSync {
    const synchronization = this.take(requestId);
    if (synchronization.overflowed) {
      synchronization.events.length = 0;
      synchronization.bufferedBytes = 0;
      return { events: [], overflowed: true };
    }
    if (!synchronization.baseline) throw new Error("session synchronization baseline was not established");
    const baseline = synchronization.baseline;
    return {
      events: synchronization.events.filter((event) => {
        const cursor = sequence(event);
        if (!cursor) return true;
        if (cursor.runtimeGeneration !== baseline.runtimeGeneration) return true;
        return cursor.eventSequence > baseline.eventSequence;
      }),
      overflowed: false,
    };
  }

  private take(requestId: string): Synchronization {
    const synchronization = this.synchronization;
    if (!synchronization || synchronization.requestId !== requestId) {
      throw new Error("session synchronization transaction does not match");
    }
    this.synchronization = undefined;
    synchronization.bufferedBytes = 0;
    return synchronization;
  }
}
