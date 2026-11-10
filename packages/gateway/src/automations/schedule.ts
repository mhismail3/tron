import { createHash } from "node:crypto";
import { core as calendar, type Calendar, type Zone } from "../core/schedule/calendar/facade.js";
import { core as occurrence, type Opt, type Trigger } from "../core/schedule/occurrence/facade.js";
import type { AutomationMisfirePolicy, AutomationTrigger } from "./types.js";
import { zoneTable } from "./zone-table.js";

type CalendarTrigger = Extract<AutomationTrigger, { kind: "calendar" }>;
type TimedTrigger = Exclude<AutomationTrigger, CalendarTrigger>;

function timed(trigger: TimedTrigger): Trigger {
  return trigger.kind === "once" ? { $: "Once", at: Date.parse(trigger.at) }
    : { $: "Interval", anchor: Date.parse(trigger.anchorAt), every: trigger.everySeconds * 1_000 };
}

function calendarOf(trigger: CalendarTrigger): Calendar {
  const [hour, minute] = trigger.localTime.split(":").map(Number) as [number, number];
  return { minute: hour * 60 + minute, weekdays: trigger.weekdays };
}

function zone(trigger: CalendarTrigger, at: number): Zone {
  if (!Number.isFinite(at)) throw new Error("Schedule boundary is invalid");
  return zoneTable(trigger.timezone, at);
}

function timestamp(at: Opt): string | undefined {
  return at.$ === "Some" ? new Date(at.v).toISOString() : undefined;
}

export function nextAutomationOccurrence(trigger: AutomationTrigger, afterMs: number): string | undefined {
  if (!Number.isFinite(afterMs)) throw new Error("Schedule boundary is invalid");
  return timestamp(trigger.kind === "calendar"
    ? calendar.Next(zone(trigger, afterMs), calendarOf(trigger), afterMs)
    : occurrence.Next(timed(trigger), afterMs));
}

export function firstAutomationOccurrence(trigger: AutomationTrigger, nowMs: number): string | undefined {
  return timestamp(trigger.kind === "calendar"
    ? calendar.First(zone(trigger, nowMs), calendarOf(trigger), nowMs)
    : occurrence.First(timed(trigger), nowMs));
}

export function classifyDueOccurrence(
  trigger: AutomationTrigger,
  nextOccurrenceAt: string,
  nowMs: number,
  policy: AutomationMisfirePolicy,
): { dispatchAt?: string; nextOccurrenceAt?: string; skipped: string[] } {
  const stored = Date.parse(nextOccurrenceAt);
  const p = policy === "latest" ? "Latest" : "Skip";
  const result = trigger.kind === "calendar"
    ? calendar.Classify(zone(trigger, nowMs), calendarOf(trigger), stored, nowMs, p)
    : occurrence.Classify(timed(trigger), stored, nowMs, p);
  // The stored occurrence keeps its stored text when it is kept (not yet due) or is a once trigger's own time;
  // other due and next occurrences are written anew.
  const due = stored <= nowMs;
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

export function automationOccurrenceId(automationId: string, revision: number, scheduledFor: string): string {
  return createHash("sha256").update(automationId).update("\0").update(String(revision)).update("\0").update(scheduledFor).digest("base64url");
}
