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
  overflowed: boolean;
}

export interface CompletedSessionSync {
  events: BufferedSessionEvent[];
  overflowed: boolean;
}

const MAX_BUFFERED_SYNC_EVENTS = 1_024;

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
    this.synchronization = { requestId, events: [], overflowed: false };
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
    if (synchronization.events.length >= MAX_BUFFERED_SYNC_EVENTS) {
      synchronization.events.length = 0;
      synchronization.overflowed = true;
      return undefined;
    }
    if (!synchronization.overflowed) synchronization.events.push(event);
    return undefined;
  }

  commit(requestId: string): CompletedSessionSync {
    const synchronization = this.take(requestId);
    if (synchronization.overflowed) return { events: [], overflowed: true };
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
    return synchronization;
  }
}
