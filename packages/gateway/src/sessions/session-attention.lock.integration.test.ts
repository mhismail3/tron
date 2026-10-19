import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { it } from "vitest";
import { storePathLock } from "../../test-support/store-path-lock.js";
import { SessionAttentionStore } from "./session-attention-store.js";

/**
 * `gateway/projection` mutation-path lock for the session attention store (plan §6.5 V4,
 * §6.6; test-support/store-path-lock.ts): every write path, its refusals, the projection
 * it leaves and the exact document it commits.
 */
it("session-attention-paths: complete, set, acknowledge, rekey, prune, remove and admission", async () => {
  const log = await storePathLock({ module: "gateway/projection", name: "session-attention-paths", testFileUrl: import.meta.url, owned: "gateway/session-attention.json" });
  const path = join(log.home, "gateway", "session-attention.json");
  let store = new SessionAttentionStore(log.home);
  const view = (...ids: string[]) => Object.fromEntries(ids.map((id) => [id, {
    ...store.projection(id), unacknowledged: store.hasUnacknowledgedCompletion(id) }]));
  await log.step("mutation before initialize", () => store.complete("a", "a-1"));
  await mkdir(join(log.home, "gateway"), { recursive: true });
  await log.step("initialize empty", async () => { await store.initialize(); return { cursor: store.reconciliationCursor(), ...view("a") }; });
  await log.step("complete a-1", () => store.complete("a", "a-1"));
  await log.step("replayed a-1 is not admitted again", () => store.complete("a", "a-1"));
  await log.step("complete a-2 observed", () => store.complete("a", "a-2", true));
  await log.step("complete a-3 unobserved", async () => ({ mutation: await store.complete("a", "a-3"), ...view("a") }));
  await log.step("mark a unread", () => store.set("a", true));
  await log.step("mark a unread again is unchanged", () => store.set("a", true));
  await log.step("mark a read through revision 2 keeps revision 3 unread", async () => ({ mutation: await store.set("a", false, 2), ...view("a") }));
  await log.step("mark a read through a future revision clamps to the latest", async () => ({ mutation: await store.set("a", false, 99), ...view("a") }));
  await log.step("mark a read again is unchanged", () => store.set("a", false));
  await log.step("mark unknown b read is unchanged", () => store.set("b", false));
  for (let index = 1; index <= 18; index += 1) {
    await store.complete("b", `b-${index}`);
  }
  await log.step("eighteen completions of b keep the newest sixteen ids", () => view("b"));
  await log.step("an evicted completion id is admitted again", () => store.complete("b", "b-1"));
  await log.step("a retained completion id is not", () => store.complete("b", "b-18"));
  await log.step("mark b unread", () => store.set("b", true));
  await log.step("acknowledge b completions keeps the manual mark", async () => ({ mutation: await store.acknowledgeCompletions("b"), ...view("b") }));
  await log.step("acknowledge b again is unchanged", () => store.acknowledgeCompletions("b"));
  await log.step("acknowledge unknown c is unchanged", () => store.acknowledgeCompletions("c"));
  await log.step("rekey a to c", async () => ({ rekeyed: await store.rekey("a", "c"), ...view("a", "c") }));
  await log.step("rekey the absent a again", () => store.rekey("a", "c"));
  await log.step("rekey c to itself", () => store.rekey("c", "c"));
  await log.step("rekey c onto b is refused", () => store.rekey("c", "b"), "refused");
  await log.step("assert b absent is refused", () => store.assertAbsent("b"), "refused");
  await log.step("assert d absent", () => store.assertAbsent("d"));
  log.advance(60_000);
  await log.step("advance cursor backwards is ignored", async () => { await store.advanceReconciliationCursor("2025-12-31T00:00:00.000Z"); return store.reconciliationCursor(); });
  await log.step("advance cursor", async () => { await store.advanceReconciliationCursor("2026-01-01T00:01:00.000Z"); return store.reconciliationCursor(); });
  await log.step("prune keeping b and c is unchanged", () => store.prune(new Set(["b", "c"])));
  await log.step("prune keeping c", async () => ({ pruned: await store.prune(new Set(["c"])), ...view("b", "c") }));
  await log.step("reopen reads the committed document", async () => {
    store = new SessionAttentionStore(log.home);
    await store.initialize();
    return { cursor: store.reconciliationCursor(), ...view("b", "c") };
  });
  await log.step("remove c", () => store.remove("c"));
  await log.step("remove c again", () => store.remove("c"));
  const refused = async (label: string, document: unknown) => log.step(label, async () => {
    await writeFile(path, JSON.stringify(document));
    await new SessionAttentionStore(log.home).initialize();
    return "admitted";
  }, label.startsWith("admit") ? "result" : "refused");
  const record = { completionRevision: 2, readThroughRevision: 1, manualUnread: false, recentCompletionIds: ["x-1", "x-2"], attentionRevision: 3 };
  const document = (sessions: unknown, extra: Record<string, unknown> = {}) => ({ version: 1, reconciledThrough: "2026-01-01T00:00:00.000Z", sessions, ...extra });
  await refused("admit a valid hand-written record", document({ x: record }));
  await refused("refuse another version", document({ x: record }, { version: 2 }));
  await refused("refuse a bad cursor", document({ x: record }, { reconciledThrough: "not a time" }));
  await refused("refuse read-through past completion", document({ x: { ...record, readThroughRevision: 3 } }));
  await refused("refuse a negative revision", document({ x: { ...record, attentionRevision: -1 } }));
  await refused("refuse duplicate completion ids", document({ x: { ...record, recentCompletionIds: ["x-1", "x-1"] } }));
  await refused("refuse seventeen completion ids", document({ x: { ...record, recentCompletionIds: Array.from({ length: 17 }, (_v, i) => `x-${i}`) } }));
  await refused("refuse a non-boolean manual mark", document({ x: { ...record, manualUnread: "yes" } }));
  await refused("refuse an empty session id", document({ "": record }));
  await refused("refuse an array of sessions", document([record]));
  await refused("refuse a null document", null);
  await refused("refuse an array document", [document({})]);
  await refused("refuse null sessions", document(null));
  await refused("refuse string sessions", document("x"));
  await refused("refuse a null record", document({ x: null }));
  await refused("refuse an array record", document({ x: [] }));
  await refused("refuse a string record", document({ x: "unread" }));
  await log.finish();
});
