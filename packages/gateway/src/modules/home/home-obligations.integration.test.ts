import { describe, expect, it } from "vitest";
import type { SessionEntry } from "../../kernel/pi/coding-agent.js";
import { HOME_OBLIGATION, owed, replayObligations, type ObligationItem } from "./home-obligations.js";

const SESSION = "home-chapter";
let serial = 0;
function history(events: Array<{ id: string; action: string; text?: string; evidence?: boolean }>): SessionEntry[] {
  return events.flatMap(({ id, action, text, evidence }) => {
    const n = serial++;
    const user = { type: "message", id: `u${n}`, message: { role: "user", content: `maintainer ${n}` } };
    const tool = { type: "message", id: `t${n}`, message: { role: "toolResult", content: [{ type: "text", text: `proof ${n}` }], isError: false } };
    const event = { type: "custom", customType: HOME_OBLIGATION, id: `c${n}`, data: { receiptId: `r${n}`, id, action,
      source: { sessionId: SESSION, entryId: `u${n}`, quote: `maintainer ${n}` }, ...(text ? { text } : {}),
      ...(evidence ? { evidence: { sessionId: SESSION, entryId: `t${n}`, quote: `proof ${n}` } } : {}) } };
    return [user, tool, event] as unknown as SessionEntry[];
  });
}
const owedIds = (items: Map<string, ObligationItem>) => [...items.values()].filter(owed).map(item => item.id);

describe("Home obligation ledger replay (home/obligations block)", () => {
  it("owes exactly requested and reopened items; a reported-done or verified item is never owed again by replay", () => {
    const items = replayObligations(history([
      { id: "a", action: "request", text: "A" }, { id: "b", action: "request", text: "B" }, { id: "c", action: "request", text: "C" },
      { id: "d", action: "request", text: "D" },
      { id: "a", action: "reported-done" }, { id: "b", action: "reported-done" }, { id: "b", action: "verified", evidence: true },
      { id: "c", action: "verified", evidence: true }, { id: "d", action: "reported-done" }, { id: "d", action: "reopened" },
    ]), SESSION);
    expect(Object.fromEntries([...items].map(([id, item]) => [id, item.state]))).toEqual({ a: "reported-done", b: "verified", c: "verified", d: "reopened" });
    expect(owedIds(items)).toEqual(["d"]);
  });

  it("refuses every contradictory transition instead of reporting a ledger", () => {
    for (const events of [
      [{ id: "a", action: "request", text: "A" }, { id: "a", action: "request", text: "again" }],
      [{ id: "a", action: "reported-done" }],
      [{ id: "a", action: "request", text: "A" }, { id: "a", action: "reopened" }],
      [{ id: "a", action: "request", text: "A" }, { id: "a", action: "verified", evidence: true }, { id: "a", action: "reported-done" }],
      [{ id: "a", action: "request", text: "A" }, { id: "a", action: "verified", evidence: true }, { id: "a", action: "verified", evidence: true }],
    ]) expect(() => replayObligations(history(events), SESSION), JSON.stringify(events)).toThrow(/contradictory/);
  });

  it("holds the 1000-item cap: the 1000th item is admitted and the 1001st refuses the whole ledger", () => {
    const requests = Array.from({ length: 1000 }, (_, k) => ({ id: `item${k}`, action: "request", text: `T${k}` }));
    expect(replayObligations(history(requests), SESSION).size).toBe(1000);
    expect(() => replayObligations(history([...requests, { id: "over", action: "request", text: "over" }]), SESSION)).toThrow(/exceeds 1000 items/);
  });
});
