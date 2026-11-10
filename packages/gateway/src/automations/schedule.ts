import { createHash } from "node:crypto";
import { core as occurrence, type Opt, type Trigger } from "../core/schedule/occurrence/facade.js";
import { recordSeam } from "../proof/traffic-recorder.js";
import type { AutomationMisfirePolicy, AutomationTrigger } from "./types.js";

type CalendarTrigger = Extract<AutomationTrigger, { kind: "calendar" }>;
type TimedTrigger = Exclude<AutomationTrigger, CalendarTrigger>;

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

function calendarOccurrenceAfter(trigger: CalendarTrigger, afterMs: number): number {
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

function calendarOccurrenceAtOrBefore(trigger: CalendarTrigger, boundaryMs: number): number {
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

// Once and interval triggers are decided by proof block schedule/occurrence (packages/core): this file gives it
// times in milliseconds and writes its answers as timestamps. Calendar triggers are decided here; their calls
// are the seams of block schedule/calendar, recorded on an opted-in Debug Gateway for its shadow (nested calls
// are not seams).
function timed(trigger: TimedTrigger): Trigger {
  return trigger.kind === "once" ? { $: "Once", at: Date.parse(trigger.at) }
    : { $: "Interval", anchor: Date.parse(trigger.anchorAt), every: trigger.everySeconds * 1_000 };
}

function timestamp(at: Opt): string | undefined {
  return at.$ === "Some" ? new Date(at.v).toISOString() : undefined;
}

export function nextAutomationOccurrence(trigger: AutomationTrigger, afterMs: number): string | undefined {
  const output = nextOccurrence(trigger, afterMs);
  if (trigger.kind === "calendar") recordSeam("schedule/calendar", "next", { trigger, afterMs }, output);
  return output;
}

export function firstAutomationOccurrence(trigger: AutomationTrigger, nowMs: number): string | undefined {
  if (trigger.kind !== "calendar") return timestamp(occurrence.First(timed(trigger), nowMs));
  const output = nextOccurrence(trigger, nowMs - 1);
  recordSeam("schedule/calendar", "first", { trigger, nowMs }, output);
  return output;
}

export function classifyDueOccurrence(
  trigger: AutomationTrigger,
  nextOccurrenceAt: string,
  nowMs: number,
  policy: AutomationMisfirePolicy,
): { dispatchAt?: string; nextOccurrenceAt?: string; skipped: string[] } {
  if (trigger.kind !== "calendar") return classifyTimed(trigger, nextOccurrenceAt, nowMs, policy);
  const output = classifyCalendar(trigger, nextOccurrenceAt, nowMs, policy);
  recordSeam("schedule/calendar", "classify", { trigger, nextOccurrenceAt, nowMs, policy }, output);
  return output;
}

function nextOccurrence(trigger: AutomationTrigger, afterMs: number): string | undefined {
  if (!Number.isFinite(afterMs)) throw new Error("Schedule boundary is invalid");
  if (trigger.kind !== "calendar") return timestamp(occurrence.Next(timed(trigger), afterMs));
  return new Date(calendarOccurrenceAfter(trigger, afterMs)).toISOString();
}

function classifyTimed(
  trigger: TimedTrigger,
  nextOccurrenceAt: string,
  nowMs: number,
  policy: AutomationMisfirePolicy,
): { dispatchAt?: string; nextOccurrenceAt?: string; skipped: string[] } {
  const result = occurrence.Classify(timed(trigger), Date.parse(nextOccurrenceAt), nowMs, policy === "latest" ? "Latest" : "Skip");
  // The stored occurrence keeps its stored text when it is kept (not yet due) or is a once trigger's own time;
  // an interval's due and next occurrences are written anew.
  const due = result.dispatchAt.$ === "Some" || result.skipped.$ === "Some";
  const text = (at: Opt) => at.$ === "None" ? undefined : !due || trigger.kind === "once" ? nextOccurrenceAt : timestamp(at);
  const dispatchAt = text(result.dispatchAt);
  const next = text(result.next);
  const skipped = text(result.skipped);
  return {
    ...(dispatchAt === undefined ? {} : { dispatchAt }),
    ...(next === undefined ? {} : { nextOccurrenceAt: next }),
    skipped: skipped === undefined ? [] : [skipped],
  };
}

function classifyCalendar(
  trigger: CalendarTrigger,
  nextOccurrenceAt: string,
  nowMs: number,
  policy: AutomationMisfirePolicy,
): { dispatchAt?: string; nextOccurrenceAt?: string; skipped: string[] } {
  if (Date.parse(nextOccurrenceAt) > nowMs) return { nextOccurrenceAt, skipped: [] };
  const latest = new Date(calendarOccurrenceAtOrBefore(trigger, nowMs)).toISOString();
  const next = nextOccurrence(trigger, nowMs)!;
  return policy === "latest"
    ? { dispatchAt: latest, nextOccurrenceAt: next, skipped: [] }
    : { nextOccurrenceAt: next, skipped: policy === "skip" ? [latest] : [] };
}

export function automationOccurrenceId(automationId: string, revision: number, scheduledFor: string): string {
  return createHash("sha256").update(automationId).update("\0").update(String(revision)).update("\0").update(scheduledFor).digest("base64url");
}
