import { describe, expect, it } from "vitest";
import { classifyDueOccurrence, firstAutomationOccurrence, nextAutomationOccurrence } from "./schedule.js";

/**
 * What callers of schedule.ts see for once and interval triggers. Proof block schedule/occurrence decides the
 * instants; these cases pin the text around it: an occurrence the functions compute is written as a canonical UTC
 * timestamp, a stored occurrence that is kept (not yet due, or a once trigger's own time) keeps its stored text,
 * and each result has exactly the keys its case has. Run identifiers hash these strings, so their form is behaviour.
 */
const ANCHOR = Date.parse("2026-03-01T10:00:00.000Z");
const HOUR = 3_600_000;
// The same instant as ANCHOR, as a store may hold it: any Gateway timestamp form is admitted.
const OFFSET_TEXT = "2026-03-01T12:00:00+02:00";
const once = { kind: "once" as const, at: OFFSET_TEXT };
const hourly = { kind: "interval" as const, anchorAt: OFFSET_TEXT, everySeconds: 3_600 };

describe("once and interval occurrences", () => {
  it("names the next occurrence strictly after a time", () => {
    expect(nextAutomationOccurrence(once, ANCHOR - 1)).toBe("2026-03-01T10:00:00.000Z");
    expect(nextAutomationOccurrence(once, ANCHOR)).toBeUndefined();
    expect(nextAutomationOccurrence(hourly, ANCHOR - 86_400_000)).toBe("2026-03-01T10:00:00.000Z");
    expect(nextAutomationOccurrence(hourly, ANCHOR - 1)).toBe("2026-03-01T10:00:00.000Z");
    expect(nextAutomationOccurrence(hourly, ANCHOR)).toBe("2026-03-01T11:00:00.000Z");
    expect(nextAutomationOccurrence(hourly, ANCHOR + HOUR - 1)).toBe("2026-03-01T11:00:00.000Z");
    expect(nextAutomationOccurrence(hourly, ANCHOR + HOUR)).toBe("2026-03-01T12:00:00.000Z");
    expect(() => nextAutomationOccurrence(hourly, Number.NaN)).toThrow("Schedule boundary is invalid");
  });

  it("names the first occurrence at creation: a once trigger's own time even when past, an interval's first at or after now", () => {
    expect(firstAutomationOccurrence(once, ANCHOR + 365 * 24 * HOUR)).toBe("2026-03-01T10:00:00.000Z");
    expect(firstAutomationOccurrence(hourly, ANCHOR - 5)).toBe("2026-03-01T10:00:00.000Z");
    expect(firstAutomationOccurrence(hourly, ANCHOR)).toBe("2026-03-01T10:00:00.000Z");
    expect(firstAutomationOccurrence(hourly, ANCHOR + 1)).toBe("2026-03-01T11:00:00.000Z");
    expect(firstAutomationOccurrence(hourly, ANCHOR + HOUR)).toBe("2026-03-01T11:00:00.000Z");
  });

  it("keeps a stored occurrence that is not due, text unchanged", () => {
    const stored = "2026-03-01T13:00:00+02:00";
    for (const trigger of [once, hourly]) {
      for (const policy of ["latest", "skip"] as const) {
        expect(classifyDueOccurrence(trigger, stored, ANCHOR + HOUR - 1, policy)).toStrictEqual({ nextOccurrenceAt: stored, skipped: [] });
      }
    }
  });

  it("dispatches or skips a due once trigger under its stored text, with no next occurrence", () => {
    for (const now of [ANCHOR, ANCHOR + 400 * 24 * HOUR]) {
      expect(classifyDueOccurrence(once, OFFSET_TEXT, now, "latest")).toStrictEqual({ dispatchAt: OFFSET_TEXT, skipped: [] });
      expect(classifyDueOccurrence(once, OFFSET_TEXT, now, "skip")).toStrictEqual({ skipped: [OFFSET_TEXT] });
    }
  });

  it("acts on the latest due interval occurrence only and stores the one after now, both written anew", () => {
    // Due this very millisecond: the stored occurrence itself, rewritten as canonical UTC.
    expect(classifyDueOccurrence(hourly, OFFSET_TEXT, ANCHOR, "latest"))
      .toStrictEqual({ dispatchAt: "2026-03-01T10:00:00.000Z", nextOccurrenceAt: "2026-03-01T11:00:00.000Z", skipped: [] });
    // Two occurrences missed: the earlier ones leave no trace.
    const late = ANCHOR + 2 * HOUR + 17;
    expect(classifyDueOccurrence(hourly, OFFSET_TEXT, late, "latest"))
      .toStrictEqual({ dispatchAt: "2026-03-01T12:00:00.000Z", nextOccurrenceAt: "2026-03-01T13:00:00.000Z", skipped: [] });
    expect(classifyDueOccurrence(hourly, OFFSET_TEXT, late, "skip"))
      .toStrictEqual({ nextOccurrenceAt: "2026-03-01T13:00:00.000Z", skipped: ["2026-03-01T12:00:00.000Z"] });
    // 400 days of downtime on a one-minute interval: 576,000 missed occurrences, one result.
    const minutely = { kind: "interval" as const, anchorAt: "2026-03-01T10:00:00Z", everySeconds: 60 };
    expect(classifyDueOccurrence(minutely, "2026-03-01T10:00:00.000Z", ANCHOR + 400 * 24 * HOUR + 30_000, "skip"))
      .toStrictEqual({ nextOccurrenceAt: "2027-04-05T10:01:00.000Z", skipped: ["2027-04-05T10:00:00.000Z"] });
  });

  it("refuses a time that is not a finite instant instead of computing with it", () => {
    // No caller can pass one (the clock is finite and stored timestamps are validated); the block's façade
    // checks every number before the proven arithmetic runs.
    for (const now of [Number.NaN, Number.POSITIVE_INFINITY, 0.5]) {
      expect(() => classifyDueOccurrence(hourly, OFFSET_TEXT, now, "latest")).toThrow(RangeError);
      expect(() => firstAutomationOccurrence(hourly, now)).toThrow(RangeError);
    }
    expect(() => classifyDueOccurrence(hourly, "not a timestamp", ANCHOR, "latest")).toThrow(RangeError);
  });
});

describe("calendar occurrences", () => {
  const calendar = (timezone: string, localTime: string, weekdays: number[]) => ({ kind: "calendar" as const, timezone, localTime, weekdays });
  const daily = [1, 2, 3, 4, 5, 6, 7];

  it("resolves a local time skipped by clocks set forward to the first minute after the jump, and a repeated one to its first instant", () => {
    expect(nextAutomationOccurrence(calendar("America/New_York", "02:30", daily), Date.parse("2026-03-08T05:00:00Z")))
      .toBe("2026-03-08T07:00:00.000Z");
    expect(nextAutomationOccurrence(calendar("America/New_York", "01:30", daily), Date.parse("2026-11-01T04:00:00Z")))
      .toBe("2026-11-01T05:30:00.000Z");
    expect(firstAutomationOccurrence(calendar("Europe/Berlin", "09:00", [1]), Date.parse("2026-11-09T08:00:00Z")))
      .toBe("2026-11-09T08:00:00.000Z");
  });

  it("keeps a stored occurrence that is not due, and writes a due one's latest and next occurrences anew", () => {
    const trigger = calendar("Europe/Berlin", "09:00", [1, 3]);
    const now = Date.parse("2026-11-10T12:00:00Z");
    expect(classifyDueOccurrence(trigger, "2026-11-11T09:00:00+01:00", now, "skip"))
      .toStrictEqual({ nextOccurrenceAt: "2026-11-11T09:00:00+01:00", skipped: [] });
    expect(classifyDueOccurrence(trigger, "2026-11-02T08:00:00.000Z", now, "latest"))
      .toStrictEqual({ dispatchAt: "2026-11-09T08:00:00.000Z", nextOccurrenceAt: "2026-11-11T08:00:00.000Z", skipped: [] });
    expect(classifyDueOccurrence(trigger, "2026-11-02T08:00:00.000Z", now, "skip"))
      .toStrictEqual({ nextOccurrenceAt: "2026-11-11T08:00:00.000Z", skipped: ["2026-11-09T08:00:00.000Z"] });
    expect(() => nextAutomationOccurrence(trigger, Number.NaN)).toThrow("Schedule boundary is invalid");
    expect(() => firstAutomationOccurrence(trigger, Number.NaN)).toThrow("Schedule boundary is invalid");
    expect(() => classifyDueOccurrence(trigger, "2026-11-02T08:00:00.000Z", Number.NaN, "latest")).toThrow("Schedule boundary is invalid");
  });

  it("skips a civil date the timezone skips entirely and keeps scheduling on the dates that exist (#2382)", () => {
    const fridays = calendar("Pacific/Apia", "09:00", [5]);
    expect(nextAutomationOccurrence(fridays, Date.parse("2011-12-23T19:00:00Z"))).toBe("2012-01-05T19:00:00.000Z");
    expect(nextAutomationOccurrence(calendar("Pacific/Apia", "09:00", daily), Date.parse("2011-12-29T21:00:00Z")))
      .toBe("2011-12-30T19:00:00.000Z");
    expect(classifyDueOccurrence(fridays, "2011-12-23T19:00:00.000Z", Date.parse("2012-01-01T00:00:00Z"), "latest"))
      .toStrictEqual({ dispatchAt: "2011-12-23T19:00:00.000Z", nextOccurrenceAt: "2012-01-05T19:00:00.000Z", skipped: [] });
  });
});
