import { describe, expect, it } from "vitest";
import { AutomationPaginationStore } from "./automation-pagination.js";
import type { AutomationSummary } from "./types.js";

function summary(index: number): AutomationSummary {
  return {
    id: `10000000-0000-4000-8000-${String(index).padStart(12, "0")}`,
    revision: 1, stateRevision: 1, name: `Automation ${index}`, activation: "draft",
    actionKind: "sessionPrompt", target: { kind: "existingSession", sessionId: "session-one" },
    trigger: { kind: "once", at: "2026-01-01T00:00:00.000Z" },
    consecutiveFailureCount: 0,
    createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z",
  };
}

describe("AutomationPaginationStore", () => {
  it("binds opaque continuation leases to one client and catalog revision", () => {
    const pages = new AutomationPaginationStore();
    const source = { catalogRevision: 4, items: [summary(1), summary(2), summary(3)] };
    const first = pages.page("client-one", source, undefined, 2);
    expect(first.items.map((item) => item.name)).toEqual(["Automation 1", "Automation 2"]);
    expect(first.nextCursor).toBeTruthy();
    expect(() => pages.page("client-two", source, first.nextCursor, 2)).toThrow("expired");
    expect(() => pages.page("client-one", { ...source, catalogRevision: 5 }, first.nextCursor, 2)).toThrow("changed");
  });

  it("releases client-owned cursors on disconnect", () => {
    const pages = new AutomationPaginationStore();
    const source = { catalogRevision: 1, items: [summary(1), summary(2)] };
    const first = pages.page("client-one", source, undefined, 1);
    pages.releaseClient("client-one");
    expect(() => pages.page("client-one", source, first.nextCursor, 1)).toThrow("expired");
  });
});
