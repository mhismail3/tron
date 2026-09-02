import { describe, expect, it } from "vitest";
import { advanceAfterOccurrence, automationOccurrenceId, classifyDueOccurrence, firstAutomationOccurrence, nextAutomationOccurrence } from "./schedule.js";

describe("automation schedules", () => {
  it("anchors intervals rather than drifting from completion", () => {
    const trigger = { kind: "interval", everySeconds: 300, anchorAt: "2026-01-01T00:00:00.000Z" } as const;
    expect(nextAutomationOccurrence(trigger, Date.parse("2026-01-01T00:06:30Z"))).toBe("2026-01-01T00:10:00.000Z");
    expect(advanceAfterOccurrence(trigger, "2026-01-01T00:10:00.000Z")).toBe("2026-01-01T00:15:00.000Z");
  });

  it("materializes at most the latest interval after long downtime", () => {
    const trigger = { kind: "interval", everySeconds: 60, anchorAt: "2026-01-01T00:00:00.000Z" } as const;
    expect(classifyDueOccurrence(trigger, trigger.anchorAt, Date.parse("2026-02-01T00:00:30Z"), "latest")).toEqual({
      dispatchAt: "2026-02-01T00:00:00.000Z",
      nextOccurrenceAt: "2026-02-01T00:01:00.000Z",
      skipped: [],
    });
    expect(classifyDueOccurrence(trigger, trigger.anchorAt, Date.parse("2026-02-01T00:00:30Z"), "skip")).toEqual({
      nextOccurrenceAt: "2026-02-01T00:01:00.000Z",
      skipped: ["2026-02-01T00:00:00.000Z"],
    });
  });

  it("moves a nonexistent local time through the spring DST gap", () => {
    const trigger = { kind: "calendar", timezone: "America/New_York", localTime: "02:30", weekdays: [7] } as const;
    expect(nextAutomationOccurrence(trigger, Date.parse("2026-03-08T05:00:00Z"))).toBe("2026-03-08T07:00:00.000Z");
  });

  it("chooses the earlier instant for a repeated fall local time", () => {
    const trigger = { kind: "calendar", timezone: "America/New_York", localTime: "01:30", weekdays: [7] } as const;
    expect(nextAutomationOccurrence(trigger, Date.parse("2026-11-01T04:00:00Z"))).toBe("2026-11-01T05:30:00.000Z");
    expect(nextAutomationOccurrence(trigger, Date.parse("2026-11-01T05:30:00Z"))).toBe("2026-11-08T06:30:00.000Z");
  });

  it("keeps occurrence identities stable and definition-revision specific", () => {
    const first = automationOccurrenceId("automation", 1, "2026-01-01T00:00:00.000Z");
    expect(first).toHaveLength(43);
    expect(automationOccurrenceId("automation", 1, "2026-01-01T00:00:00.000Z")).toBe(first);
    expect(automationOccurrenceId("automation", 2, "2026-01-01T00:00:00.000Z")).not.toBe(first);
  });

  it("retains an overdue one-time occurrence for latest and skips it otherwise", () => {
    const trigger = { kind: "once", at: "2026-01-01T00:00:00.000Z" } as const;
    expect(firstAutomationOccurrence(trigger, Date.parse("2025-01-01T00:00:00Z"))).toBe(trigger.at);
    expect(classifyDueOccurrence(trigger, trigger.at, Date.parse("2026-01-02T00:00:00Z"), "latest")).toEqual({
      dispatchAt: trigger.at,
      skipped: [],
    });
    expect(classifyDueOccurrence(trigger, trigger.at, Date.parse("2026-01-02T00:00:00Z"), "skip")).toEqual({
      skipped: [trigger.at],
    });
  });
});
