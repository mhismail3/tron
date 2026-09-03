import { randomUUID } from "node:crypto";
import { GatewayError } from "../errors.js";
import { isGatewayTimestamp } from "../util/timestamp.js";
import { automationLocalDayBounds, automationLocalDayStart, automationOccurrenceId, nextAutomationOccurrence } from "./schedule.js";
import type { AutomationSummary } from "./types.js";

export const MAXIMUM_TIMELINE_DAYS = 7;
export const MAXIMUM_TIMELINE_ITEMS = 8_192;
export const MAXIMUM_TIMELINE_SOURCE_BYTES = 2 * 1_048_576;
export const MAXIMUM_TIMELINE_PAGE_BYTES = 700 * 1_024;
export const MAXIMUM_TIMELINE_RAW_OCCURRENCES = 100_000;
export const MAXIMUM_TIMELINE_LEASES = 64;
export const MAXIMUM_TIMELINE_LEASES_PER_CLIENT = 8;
export const TIMELINE_LEASE_TTL_MS = 60_000;
export const MAXIMUM_TIMELINE_PAGE_SIZE = 200;

export type AutomationTimelineItem =
  | {
      kind: "occurrence";
      automationId: string;
      automationRevision: number;
      occurrenceId: string;
      scheduledFor: string;
    }
  | {
      kind: "series";
      automationId: string;
      automationRevision: number;
      dayStart: string;
      firstAt: string;
      lastAt: string;
      count: number;
    };

export interface AutomationTimelineSource {
  catalogRevision: number;
  items: AutomationTimelineItem[];
}

export interface AutomationTimelinePage {
  catalogRevision: number;
  items: AutomationTimelineItem[];
  nextCursor?: string;
}

function encodedBytes(value: unknown): number {
  return Buffer.byteLength(JSON.stringify(value));
}

function requireTimelineTimezone(value: string): void {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: value }).format(0);
  } catch {
    throw new GatewayError("invalid_request", "displayTimezone is not a valid IANA timezone");
  }
}

export function validateTimelineWindow(from: string, through: string, displayTimezone: string): void {
  if (!isGatewayTimestamp(from) || !isGatewayTimestamp(through)) {
    throw new GatewayError("invalid_request", "Timeline boundaries must be Gateway timestamps");
  }
  const fromMs = Date.parse(from);
  const throughMs = Date.parse(through);
  if (!Number.isFinite(fromMs) || !Number.isFinite(throughMs) || throughMs <= fromMs) {
    throw new GatewayError("invalid_request", "Timeline through must be after from");
  }
  if (throughMs - fromMs > MAXIMUM_TIMELINE_DAYS * 24 * 60 * 60_000) {
    throw new GatewayError("invalid_request", "Timeline windows may span at most seven days");
  }
  if (displayTimezone.length === 0 || Buffer.byteLength(displayTimezone) > 128) {
    throw new GatewayError("invalid_request", "displayTimezone is invalid or exceeds its bound");
  }
  requireTimelineTimezone(displayTimezone);
}

/**
 * Builds an immutable, revision-scoped agenda from canonical automation
 * summaries. It retains no more than a bounded number of raw occurrences;
 * exceeding that bound fails explicitly rather than silently dropping agenda
 * entries.
 */
export function buildAutomationTimeline(
  summaries: readonly AutomationSummary[],
  catalogRevision: number,
  from: string,
  through: string,
  displayTimezone: string,
): AutomationTimelineSource {
  validateTimelineWindow(from, through, displayTimezone);
  const fromMs = Date.parse(from);
  const throughMs = Date.parse(through);
  const buckets = new Map<string, {
    automationId: string;
    automationRevision: number;
    dayStart: string;
    firstAt: string;
    lastAt: string;
    count: number;
    occurrences: { occurrenceId: string; scheduledFor: string }[];
  }>();
  let rawOccurrences = 0;

  const appendBucket = (
    summary: AutomationSummary,
    dayStart: string,
    firstAt: string,
    lastAt: string,
    count: number,
    occurrences: string[],
  ): void => {
    const key = `${summary.id}\0${dayStart}`;
    const bucket = buckets.get(key) ?? {
      automationId: summary.id,
      automationRevision: summary.revision,
      dayStart,
      firstAt,
      lastAt,
      count: 0,
      occurrences: [],
    };
    bucket.count += count;
    if (firstAt < bucket.firstAt) bucket.firstAt = firstAt;
    if (lastAt > bucket.lastAt) bucket.lastAt = lastAt;
    if (bucket.occurrences.length <= 12) {
      for (const scheduledFor of occurrences) {
        if (bucket.occurrences.length > 12) break;
        bucket.occurrences.push({
          occurrenceId: automationOccurrenceId(summary.id, summary.revision, scheduledFor),
          scheduledFor,
        });
      }
    }
    buckets.set(key, bucket);
  };

  for (const summary of summaries) {
    if (summary.activation !== "enabled") continue;
    if (summary.trigger.kind === "interval") {
      const anchor = Date.parse(summary.trigger.anchorAt);
      const interval = summary.trigger.everySeconds * 1_000;
      let dayCursor = fromMs;
      while (dayCursor < throughMs) {
        const day = automationLocalDayBounds(dayCursor, displayTimezone);
        const rangeStart = Math.max(fromMs, day.start);
        const rangeEnd = Math.min(throughMs, day.end);
        const period = Math.max(0, Math.ceil((rangeStart - anchor) / interval));
        const first = anchor + period * interval;
        if (first < rangeEnd) {
          const count = Math.floor((rangeEnd - 1 - first) / interval) + 1;
          const last = first + (count - 1) * interval;
          const occurrences = count > 12
            ? []
            : Array.from({ length: count }, (_, index) => new Date(first + index * interval).toISOString());
          appendBucket(
            summary,
            new Date(day.start).toISOString(),
            new Date(first).toISOString(),
            new Date(last).toISOString(),
            count,
            occurrences,
          );
        }
        if (day.end <= dayCursor) throw new Error("Timeline local-day traversal did not advance");
        dayCursor = day.end;
      }
      continue;
    }

    let afterMs = fromMs - 1;
    while (true) {
      const scheduledFor = nextAutomationOccurrence(summary.trigger, afterMs);
      if (scheduledFor === undefined) break;
      const scheduledMs = Date.parse(scheduledFor);
      if (!Number.isFinite(scheduledMs) || scheduledMs >= throughMs) break;
      if (scheduledMs < fromMs) {
        afterMs = Math.max(afterMs + 1, scheduledMs);
        continue;
      }
      rawOccurrences += 1;
      if (rawOccurrences > MAXIMUM_TIMELINE_RAW_OCCURRENCES) {
        throw new GatewayError(
          "busy",
          "Timeline contains too many occurrences; narrow the date range or filter automations",
          true,
        );
      }
      appendBucket(
        summary,
        automationLocalDayStart(scheduledMs, displayTimezone),
        scheduledFor,
        scheduledFor,
        1,
        [scheduledFor],
      );
      afterMs = scheduledMs;
    }
  }

  const items: AutomationTimelineItem[] = [];
  for (const bucket of buckets.values()) {
    if (bucket.count > 12) {
      items.push({
        kind: "series",
        automationId: bucket.automationId,
        automationRevision: bucket.automationRevision,
        dayStart: bucket.dayStart,
        firstAt: bucket.firstAt,
        lastAt: bucket.lastAt,
        count: bucket.count,
      });
    } else {
      for (const occurrence of bucket.occurrences) {
        items.push({
          kind: "occurrence",
          automationId: bucket.automationId,
          automationRevision: bucket.automationRevision,
          occurrenceId: occurrence.occurrenceId,
          scheduledFor: occurrence.scheduledFor,
        });
      }
    }
  }
  items.sort((left, right) => {
    const leftAt = left.kind === "series" ? left.firstAt : left.scheduledFor;
    const rightAt = right.kind === "series" ? right.firstAt : right.scheduledFor;
    return Date.parse(leftAt) - Date.parse(rightAt)
      || left.automationId.localeCompare(right.automationId)
      || left.kind.localeCompare(right.kind);
  });
  if (items.length > MAXIMUM_TIMELINE_ITEMS || encodedBytes({ catalogRevision, items }) > MAXIMUM_TIMELINE_SOURCE_BYTES) {
    throw new GatewayError(
      "busy",
      "Timeline projection exceeds its bounded capacity; narrow the date range or filter automations",
      true,
    );
  }
  return { catalogRevision, items };
}

interface TimelineLease extends AutomationTimelineSource {
  id: string;
  clientId: string;
  queryKey: string;
  offset: number;
  expiresAt: number;
}

/** Bounded opaque cursor leases for one immutable timeline materialization. */
export class AutomationTimelinePaginationStore {
  private readonly leases = new Map<string, TimelineLease>();

  constructor(private readonly now: () => number = Date.now) {}

  page(
    clientId: string,
    source: AutomationTimelineSource,
    cursor: string | undefined,
    limit: number,
    queryKey = "",
  ): AutomationTimelinePage {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > MAXIMUM_TIMELINE_PAGE_SIZE) {
      throw new GatewayError("invalid_request", "Timeline limit must be between 1 and 200");
    }
    this.prune();
    let lease: TimelineLease;
    if (cursor !== undefined) {
      if (Buffer.byteLength(cursor) > 64 || cursor.length === 0) {
        throw new GatewayError("invalid_request", "Timeline cursor is invalid or exceeds its bound");
      }
      const existing = this.leases.get(cursor);
      if (!existing || existing.clientId !== clientId) {
        throw new GatewayError("conflict", "Timeline page expired or belongs to another client; reload", true);
      }
      if (existing.catalogRevision !== source.catalogRevision) {
        this.leases.delete(cursor);
        throw new GatewayError("conflict", "Timeline changed while loading; reload from the first page", true);
      }
      if (existing.queryKey !== queryKey) {
        this.leases.delete(cursor);
        throw new GatewayError("conflict", "Timeline cursor does not match the requested window; reload", true);
      }
      this.leases.delete(cursor);
      lease = existing;
    } else {
      lease = {
        ...source,
        id: randomUUID(),
        clientId,
        queryKey,
        offset: 0,
        expiresAt: this.now() + TIMELINE_LEASE_TTL_MS,
      };
    }
    const items = lease.items.slice(lease.offset, lease.offset + limit);
    const nextOffset = lease.offset + items.length;
    const nextCursor = nextOffset < lease.items.length ? lease.id : undefined;
    const page: AutomationTimelinePage = {
      catalogRevision: lease.catalogRevision,
      items,
      ...(nextCursor === undefined ? {} : { nextCursor }),
    };
    if (encodedBytes(page) > MAXIMUM_TIMELINE_PAGE_BYTES) {
      throw new GatewayError("busy", "Timeline page exceeds its bounded wire capacity; request a smaller limit", true);
    }
    if (nextCursor !== undefined) {
      lease.offset = nextOffset;
      lease.expiresAt = this.now() + TIMELINE_LEASE_TTL_MS;
      this.reserveLease(lease);
    }
    return page;
  }

  releaseClient(clientId: string): void {
    for (const [id, lease] of this.leases) if (lease.clientId === clientId) this.leases.delete(id);
  }

  private reserveLease(lease: TimelineLease): void {
    const clientLeases = [...this.leases.values()].filter((candidate) => candidate.clientId === lease.clientId);
    if (clientLeases.length >= MAXIMUM_TIMELINE_LEASES_PER_CLIENT) {
      const oldest = clientLeases.sort((left, right) => left.expiresAt - right.expiresAt)[0];
      if (oldest) this.leases.delete(oldest.id);
    }
    if (this.leases.size >= MAXIMUM_TIMELINE_LEASES) {
      const oldest = [...this.leases.values()].sort((left, right) => left.expiresAt - right.expiresAt)[0];
      if (oldest) this.leases.delete(oldest.id);
    }
    this.leases.set(lease.id, lease);
  }

  private prune(): void {
    const now = this.now();
    for (const [id, lease] of this.leases) if (lease.expiresAt <= now) this.leases.delete(id);
  }
}
