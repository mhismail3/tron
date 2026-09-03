import { createHash } from "node:crypto";
import type { AutomationMisfirePolicy, AutomationTrigger } from "./types.js";

interface LocalDateTime {
  year: number;
  month: number;
  day: number;
  hour: number;
  minute: number;
  weekday: number;
}

const formatters = new Map<string, Intl.DateTimeFormat>();

function formatter(timezone: string): Intl.DateTimeFormat {
  const existing = formatters.get(timezone);
  if (existing) return existing;
  const created = new Intl.DateTimeFormat("en-CA", {
    timeZone: timezone,
    calendar: "iso8601",
    numberingSystem: "latn",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
    weekday: "short",
  });
  formatters.set(timezone, created);
  return created;
}

function localParts(instant: number, timezone: string): LocalDateTime {
  const parts = formatter(timezone).formatToParts(instant);
  const value = (type: Intl.DateTimeFormatPartTypes): string => parts.find((part) => part.type === type)?.value ?? "";
  const weekdays: Record<string, number> = { Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6, Sun: 7 };
  return {
    year: Number(value("year")),
    month: Number(value("month")),
    day: Number(value("day")),
    hour: Number(value("hour")),
    minute: Number(value("minute")),
    weekday: weekdays[value("weekday")] ?? 0,
  };
}

function localKey(value: Omit<LocalDateTime, "weekday">): number {
  return Date.UTC(value.year, value.month - 1, value.day, value.hour, value.minute);
}

function sameMinute(left: LocalDateTime, right: Omit<LocalDateTime, "weekday">): boolean {
  return left.year === right.year && left.month === right.month && left.day === right.day
    && left.hour === right.hour && left.minute === right.minute;
}

/** Resolve a local wall-clock minute. Repeated times choose the earlier instant;
 * nonexistent times advance to the first valid local minute on that date. */
function localMinuteToInstant(target: Omit<LocalDateTime, "weekday">, timezone: string): number {
  const naive = localKey(target);
  const offsets = new Set<number>();
  for (const delta of [-36, -24, -12, 0, 12, 24, 36]) {
    const sample = naive + delta * 60 * 60_000;
    offsets.add(localKey(localParts(sample, timezone)) - sample);
  }
  const matches = [...offsets]
    .map((offset) => naive - offset)
    .filter((candidate) => sameMinute(localParts(candidate, timezone), target))
    .sort((left, right) => left - right);
  if (matches[0] !== undefined) return matches[0];

  // DST gaps are small and rare. Scan a bounded UTC window and choose the
  // earliest instant whose local wall time has advanced past the missing minute.
  let best: { instant: number; local: number } | undefined;
  for (let candidate = naive - 18 * 60 * 60_000; candidate <= naive + 18 * 60 * 60_000; candidate += 60_000) {
    const parts = localParts(candidate, timezone);
    if (parts.year !== target.year || parts.month !== target.month || parts.day !== target.day) continue;
    const key = localKey(parts);
    if (key < naive || (best && key > best.local)) continue;
    if (!best || key < best.local || candidate < best.instant) best = { instant: candidate, local: key };
  }
  if (!best) throw new Error("Calendar occurrence could not be resolved in its timezone");
  return best.instant;
}

function addLocalDays(date: Pick<LocalDateTime, "year" | "month" | "day">, days: number): Pick<LocalDateTime, "year" | "month" | "day"> {
  const value = new Date(Date.UTC(date.year, date.month - 1, date.day + days));
  return { year: value.getUTCFullYear(), month: value.getUTCMonth() + 1, day: value.getUTCDate() };
}

function calendarOccurrenceAfter(trigger: Extract<AutomationTrigger, { kind: "calendar" }>, afterMs: number): number {
  const [hour, minute] = trigger.localTime.split(":").map(Number) as [number, number];
  const local = localParts(afterMs, trigger.timezone);
  for (let dayOffset = 0; dayOffset <= 14; dayOffset += 1) {
    const date = addLocalDays(local, dayOffset);
    const noon = localMinuteToInstant({ ...date, hour: 12, minute: 0 }, trigger.timezone);
    const weekday = localParts(noon, trigger.timezone).weekday;
    if (!trigger.weekdays.includes(weekday)) continue;
    const candidate = localMinuteToInstant({ ...date, hour, minute }, trigger.timezone);
    if (candidate > afterMs) return candidate;
  }
  throw new Error("Calendar trigger did not produce a bounded next occurrence");
}

function calendarOccurrenceAtOrBefore(
  trigger: Extract<AutomationTrigger, { kind: "calendar" }>,
  boundaryMs: number,
): number {
  const [hour, minute] = trigger.localTime.split(":").map(Number) as [number, number];
  const local = localParts(boundaryMs, trigger.timezone);
  for (let dayOffset = 0; dayOffset >= -14; dayOffset -= 1) {
    const date = addLocalDays(local, dayOffset);
    const noon = localMinuteToInstant({ ...date, hour: 12, minute: 0 }, trigger.timezone);
    const weekday = localParts(noon, trigger.timezone).weekday;
    if (!trigger.weekdays.includes(weekday)) continue;
    const candidate = localMinuteToInstant({ ...date, hour, minute }, trigger.timezone);
    if (candidate <= boundaryMs) return candidate;
  }
  throw new Error("Calendar trigger did not produce a bounded prior occurrence");
}

/** Returns the UTC boundaries of the local calendar day containing the instant. */
export function automationLocalDayBounds(instantMs: number, timezone: string): { start: number; end: number } {
  if (!Number.isFinite(instantMs)) throw new Error("Schedule boundary is invalid");
  const local = localParts(instantMs, timezone);
  const date = { year: local.year, month: local.month, day: local.day };
  const start = localMinuteToInstant({ ...date, hour: 0, minute: 0 }, timezone);
  // A timezone transition can skip an entire civil date. Advance to the next
  // representable local day instead of treating a valid IANA window as an
  // internal scheduling failure.
  for (let offset = 1; offset <= 8; offset += 1) {
    const next = addLocalDays(date, offset);
    try {
      const end = localMinuteToInstant({ ...next, hour: 0, minute: 0 }, timezone);
      if (end > start) return { start, end };
    } catch {
      // Continue across a fully skipped civil date.
    }
  }
  throw new Error("Schedule local-day boundary did not advance");
}

/** Returns the UTC instant at the start of the local calendar day containing the instant. */
export function automationLocalDayStart(instantMs: number, timezone: string): string {
  return new Date(automationLocalDayBounds(instantMs, timezone).start).toISOString();
}

/** Returns the local calendar day key for deterministic grouping and tests. */
export function automationLocalDayKey(instantMs: number, timezone: string): string {
  if (!Number.isFinite(instantMs)) throw new Error("Schedule boundary is invalid");
  const local = localParts(instantMs, timezone);
  return `${String(local.year).padStart(4, "0")}-${String(local.month).padStart(2, "0")}-${String(local.day).padStart(2, "0")}`;
}

export function nextAutomationOccurrence(trigger: AutomationTrigger, afterMs: number): string | undefined {
  if (!Number.isFinite(afterMs)) throw new Error("Schedule boundary is invalid");
  if (trigger.kind === "once") {
    const instant = Date.parse(trigger.at);
    return instant > afterMs ? new Date(instant).toISOString() : undefined;
  }
  if (trigger.kind === "interval") {
    const anchor = Date.parse(trigger.anchorAt);
    const interval = trigger.everySeconds * 1_000;
    const periods = afterMs < anchor ? 0 : Math.floor((afterMs - anchor) / interval) + 1;
    return new Date(anchor + periods * interval).toISOString();
  }
  return new Date(calendarOccurrenceAfter(trigger, afterMs)).toISOString();
}

export function firstAutomationOccurrence(trigger: AutomationTrigger, nowMs: number): string | undefined {
  if (trigger.kind === "once") return new Date(Date.parse(trigger.at)).toISOString();
  if (trigger.kind === "interval") {
    const anchor = Date.parse(trigger.anchorAt);
    if (anchor >= nowMs) return new Date(anchor).toISOString();
    return nextAutomationOccurrence(trigger, nowMs - 1);
  }
  return nextAutomationOccurrence(trigger, nowMs - 1);
}

export function advanceAfterOccurrence(trigger: AutomationTrigger, scheduledFor: string): string | undefined {
  return nextAutomationOccurrence(trigger, Date.parse(scheduledFor));
}

export function classifyDueOccurrence(
  trigger: AutomationTrigger,
  nextOccurrenceAt: string,
  nowMs: number,
  policy: AutomationMisfirePolicy,
): { dispatchAt?: string; nextOccurrenceAt?: string; skipped: string[] } {
  const due = Date.parse(nextOccurrenceAt);
  if (due > nowMs) return { nextOccurrenceAt, skipped: [] };
  if (trigger.kind === "once") {
    return policy === "latest" ? { dispatchAt: nextOccurrenceAt, skipped: [] } : { skipped: [nextOccurrenceAt] };
  }

  let latest = nextOccurrenceAt;
  const skipped: string[] = [];
  // The result retains at most one materialized skipped occurrence. Advancing
  // remains bounded even after long downtime by interval arithmetic below.
  if (trigger.kind === "interval") {
    const interval = trigger.everySeconds * 1_000;
    const dueCount = Math.floor((nowMs - due) / interval) + 1;
    latest = new Date(due + (dueCount - 1) * interval).toISOString();
    const next = new Date(due + dueCount * interval).toISOString();
    if (policy === "skip") return { nextOccurrenceAt: next, skipped: [latest] };
    return { dispatchAt: latest, nextOccurrenceAt: next, skipped: [] };
  }

  latest = new Date(calendarOccurrenceAtOrBefore(trigger, nowMs)).toISOString();
  const next = nextAutomationOccurrence(trigger, nowMs)!;
  if (policy === "skip") skipped.push(latest);
  return policy === "latest"
    ? { dispatchAt: latest, nextOccurrenceAt: next, skipped: [] }
    : { nextOccurrenceAt: next, skipped };
}

export function automationOccurrenceId(automationId: string, revision: number, scheduledFor: string): string {
  return createHash("sha256").update(automationId).update("\0").update(String(revision)).update("\0").update(scheduledFor).digest("base64url");
}
