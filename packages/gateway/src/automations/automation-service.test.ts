import { describe, expect, it } from "vitest";
import { AutomationService } from "./automation-service.js";

function service(): AutomationService {
  return new AutomationService(
    {} as any,
    {} as any,
    {} as any,
  );
}

describe("AutomationService schedule preview", () => {
  it("returns canonical bounded future occurrences", () => {
    expect(service().schedulePreview({
      kind: "interval", everySeconds: 60, anchorAt: "2026-01-01T00:00:00.000Z",
    }, "2026-01-01T00:01:00.000Z", 3)).toEqual({ occurrences: [
      "2026-01-01T00:02:00.000Z",
      "2026-01-01T00:03:00.000Z",
      "2026-01-01T00:04:00.000Z",
    ] });
  });

  it("applies the strict trigger, timestamp, and limit contracts", () => {
    expect(() => service().schedulePreview({ kind: "shell" }, "2026-01-01T00:00:00.000Z", 5))
      .toThrow(/trigger is invalid/);
    expect(() => service().schedulePreview({ kind: "once", at: "2026-01-02T00:00:00.000Z" }, "tomorrow", 5))
      .toThrow(/Gateway timestamp/);
    expect(() => service().schedulePreview({ kind: "once", at: "2026-01-02T00:00:00.000Z" }, "2026-01-01T00:00:00.000Z", 21))
      .toThrow(/between 1 and 20/);
  });

  it("resolves calendar preview through the canonical DST schedule engine", () => {
    expect(service().schedulePreview({
      kind: "calendar", timezone: "America/New_York", localTime: "09:00", weekdays: [7],
    }, "2026-03-07T00:00:00.000Z", 1)).toEqual({ occurrences: ["2026-03-08T13:00:00.000Z"] });
  });
});
