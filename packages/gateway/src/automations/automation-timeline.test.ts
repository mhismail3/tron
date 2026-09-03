import { describe, expect, it } from "vitest";
import { GatewayError } from "../errors.js";
import { automationOccurrenceId } from "./schedule.js";
import {
  AutomationTimelinePaginationStore,
  buildAutomationTimeline,
  MAXIMUM_TIMELINE_RAW_OCCURRENCES,
} from "./automation-timeline.js";
import type { AutomationSummary } from "./types.js";

const trigger = (value: AutomationSummary["trigger"]): AutomationSummary => ({
  id: "automation-one", revision: 2, stateRevision: 3, name: "One", activation: "enabled",
  actionKind: "sessionPrompt", target: { kind: "existingSession", sessionId: "session-one" }, trigger: value,
  consecutiveFailureCount: 0, createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z",
});

const source = (count = 3) => ({
  catalogRevision: 7,
  items: Array.from({ length: count }, (_, index) => ({
    kind: "occurrence" as const,
    automationId: `automation-${index}`,
    automationRevision: 1,
    occurrenceId: `occurrence-${index}`,
    scheduledFor: `2026-01-01T00:0${index}:00.000Z`,
  })),
});

describe("Automation timeline projection", () => {
  it("sorts occurrences by instant and automation identity", () => {
    const items = buildAutomationTimeline([
      trigger({ kind: "once", at: "2026-01-01T12:00:00.000Z" }),
      { ...trigger({ kind: "once", at: "2026-01-01T11:00:00.000Z" }), id: "automation-two" },
    ], 4, "2026-01-01T00:00:00.000Z", "2026-01-02T00:00:00.000Z", "UTC").items;
    expect(items.map((item) => item.automationId)).toEqual(["automation-two", "automation-one"]);
    expect(items[0]).toMatchObject({
      kind: "occurrence",
      occurrenceId: automationOccurrenceId("automation-two", 2, "2026-01-01T11:00:00.000Z"),
    });
  });

  it("groups a dense automation into one local-day series", () => {
    const result = buildAutomationTimeline([
      trigger({ kind: "interval", everySeconds: 60, anchorAt: "2026-01-01T00:00:00.000Z" }),
    ], 4, "2026-01-01T00:00:00.000Z", "2026-01-01T01:00:00.000Z", "UTC");
    expect(result.items).toHaveLength(1);
    expect(result.items[0]).toMatchObject({
      kind: "series", dayStart: "2026-01-01T00:00:00.000Z", firstAt: "2026-01-01T00:00:00.000Z",
      lastAt: "2026-01-01T00:59:00.000Z", count: 60,
    });
  });

  it("counts dense interval series across display-timezone DST day boundaries", () => {
    const result = buildAutomationTimeline([
      trigger({ kind: "interval", everySeconds: 60, anchorAt: "2026-03-08T00:00:00.000Z" }),
    ], 4, "2026-03-08T05:00:00.000Z", "2026-03-09T04:00:00.000Z", "America/New_York");
    expect(result.items).toEqual([expect.objectContaining({
      kind: "series", dayStart: "2026-03-08T05:00:00.000Z", count: 1_380,
      firstAt: "2026-03-08T05:00:00.000Z", lastAt: "2026-03-09T03:59:00.000Z",
    })]);
  });

  it("does not project interval occurrences before a future anchor", () => {
    const result = buildAutomationTimeline([
      trigger({ kind: "interval", everySeconds: 60, anchorAt: "2026-01-02T00:00:00.000Z" }),
    ], 4, "2026-01-01T00:00:00.000Z", "2026-01-02T00:00:00.000Z", "UTC");
    expect(result.items).toEqual([]);
  });

  it("groups by display timezone day and preserves DST-resolved instants", () => {
    const result = buildAutomationTimeline([
      trigger({ kind: "calendar", timezone: "America/New_York", localTime: "09:00", weekdays: [7] }),
    ], 4, "2026-03-08T00:00:00.000Z", "2026-03-10T00:00:00.000Z", "America/Los_Angeles");
    expect(result.items).toHaveLength(1);
    expect(result.items[0]).toMatchObject({
      kind: "occurrence", scheduledFor: "2026-03-08T13:00:00.000Z",
    });
  });

  it("rejects invalid windows instead of silently truncating", () => {
    expect(() => buildAutomationTimeline([], 1, "2026-01-02T00:00:00.000Z", "2026-01-01T00:00:00.000Z", "UTC"))
      .toThrow(GatewayError);
    expect(() => buildAutomationTimeline([], 1, "2026-01-01T00:00:00.000Z", "2026-01-09T00:00:00.000Z", "UTC"))
      .toThrow(/seven days/);
  });

  it("counts many dense intervals analytically without exhausting raw traversal", () => {
    const dense = Array.from({ length: 11 }, (_, index) => ({
      ...trigger({ kind: "interval", everySeconds: 60, anchorAt: "2026-01-01T00:00:00.000Z" }),
      id: `automation-${index}`,
    }));
    const result = buildAutomationTimeline(
      dense, 1, "2026-01-01T00:00:00.000Z", "2026-01-08T00:00:00.000Z", "UTC",
    );
    expect(result.items).toHaveLength(77);
    expect(result.items.every((item) => item.kind === "series" && item.count === 1_440)).toBe(true);
    expect(MAXIMUM_TIMELINE_RAW_OCCURRENCES).toBeGreaterThan(0);
  });
});

describe("Automation timeline pagination", () => {
  it("keeps continuations bound to client and catalog revision", () => {
    let now = 0;
    const pages = new AutomationTimelinePaginationStore(() => now);
    const first = pages.page("client-one", source(), undefined, 1);
    expect(first.nextCursor).toBeTruthy();
    expect(() => pages.page("client-two", source(), first.nextCursor, 1)).toThrow(/another client/);
    expect(() => pages.page("client-one", { ...source(), catalogRevision: 8 }, first.nextCursor, 1)).toThrow(/changed/);
  });

  it("rejects a continuation reused for a different timeline query", () => {
    const pages = new AutomationTimelinePaginationStore();
    const first = pages.page("client-one", source(), undefined, 1, "window-one");
    expect(() => pages.page("client-one", source(), first.nextCursor, 1, "window-two"))
      .toThrow(/does not match/);
  });

  it("expires cursors and bounds per-client lease retention", () => {
    let now = 0;
    const pages = new AutomationTimelinePaginationStore(() => now);
    const cursors: string[] = [];
    for (let index = 0; index < 9; index += 1) {
      const page = pages.page("client-one", source(3), undefined, 1);
      cursors.push(page.nextCursor!);
    }
    expect(() => pages.page("client-one", source(2), cursors[0], 1)).toThrow(/expired/);
    const valid = pages.page("client-one", source(3), cursors[8], 1);
    expect(valid.items).toHaveLength(1);
    now = 60_001;
    expect(() => pages.page("client-one", source(3), valid.nextCursor, 1)).toThrow(/expired/);
  });

  it("evicts the oldest lease at the global capacity bound", () => {
    const pages = new AutomationTimelinePaginationStore();
    const first = pages.page("client-0", source(2), undefined, 1);
    for (let index = 1; index <= 64; index += 1) {
      pages.page(`client-${index}`, source(2), undefined, 1);
    }
    expect(() => pages.page("client-0", source(2), first.nextCursor, 1)).toThrow(/expired/);
  });

  it("rejects oversized page limits", () => {
    const pages = new AutomationTimelinePaginationStore();
    expect(() => pages.page("client-one", source(), undefined, 201)).toThrow(/between 1 and 200/);
  });
});
