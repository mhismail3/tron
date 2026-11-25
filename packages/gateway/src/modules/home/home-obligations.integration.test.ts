import { fauxAssistantMessage, fauxToolCall, type AssistantMessage } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import type { SessionEntry } from "../../kernel/pi/coding-agent.js";
import { disposeFixtures, fixture } from "../../../test-support/home-task-fixture.js";
import { homeOwnerOf } from "../../../test-support/gateway-registry.js";
import { waitFor } from "../../../test-support/wait-for.js";
import { setHomeMemoryModels } from "../../../test-support/settings-dependencies.js";
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
afterEach(async () => { await disposeFixtures(); });
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
      [{ id: "a", action: "verified", evidence: true }],
      [{ id: "a", action: "reopened" }],
      [{ id: "a", action: "request", text: "A" }, { id: "a", action: "reported-done" }, { id: "a", action: "reported-done" }],
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

  it("Home writes admit only legal transitions from the current maintainer turn and append nothing on refusal", async () => {
    const f = await fixture();
    await setHomeMemoryModels(f.registry, [{ provider: f.model.provider, id: f.model.id }]);
    const owner = homeOwnerOf(f.registry);
    const home = await f.registry.acquire(f.home.sessionId);
    const call = (request: Record<string, unknown>, id: string) => fauxAssistantMessage([fauxToolCall("obligation", request, { id })], { stopReason: "toolUse" });
    const turn = async (text: string, script: AssistantMessage[]) => {
      f.faux.setResponses([...script, fauxAssistantMessage("Recorded")]);
      await home.prompt(text);
      await waitFor(() => home.snapshot().operation === undefined, "maintainer turn settled");
    };
    const results = () => home.canonicalSessionEntries().flatMap(entry => entry.type === "message" && entry.message.role === "toolResult" && entry.message.toolName === "obligation" ? [!entry.message.isError] : []);
    const ledger = () => home.canonicalSessionEntries().flatMap(entry => entry.type === "custom" && entry.customType === HOME_OBLIGATION ? [(entry.data as { action: string }).action] : []);
    await turn("I will rotate the key.", [
      call({ action: "request", id: "key", text: "Rotate the key", quote: "I will rotate the key." }, "open"),
      call({ action: "reopened", id: "key", quote: "I will rotate the key." }, "reopen-owed"),
      call({ action: "verified", id: "missing", quote: "I will rotate the key.", evidenceEntryId: "x", evidenceQuote: "x" }, "close-absent"),
    ]);
    await turn("The key is rotated.", [
      call({ action: "reported-done", id: "key", quote: "The key is rotated." }, "done"),
      call({ action: "reported-done", id: "key", quote: "The key is rotated." }, "done-again"),
      call({ action: "reopened", id: "key", quote: "The key is rotated." }, "reopen-same-message"),
      call({ action: "request", id: "key", text: "Recreated", quote: "The key is rotated." }, "recreate"),
    ]);
    await turn("It failed; reopen the key rotation.", [call({ action: "reopened", id: "key", quote: "reopen the key rotation" }, "reopen")]);
    expect(results()).toEqual([true, false, false, true, false, false, false, true]);
    expect(ledger()).toEqual(["request", "reported-done", "reopened"]);
    expect(((await owner.obligationTool(home.id, "owed", { action: "list" })) as { items: Array<{ id: string }> }).items.map(item => item.id)).toEqual(["key"]);
    await expect(owner.obligationTool(home.id, "no-turn", { action: "reported-done", id: "key", quote: "It failed" })).rejects.toMatchObject({ code: "invalid_request" });
    expect(ledger()).toHaveLength(3);
  }, 60_000);
});
