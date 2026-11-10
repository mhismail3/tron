import { lstat, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it, onTestFinished, vi } from "vitest";
import { SessionAttentionStore } from "./session-attention-store.js";

const T0 = "2026-01-01T00:00:00.000Z";
const T1 = "2026-01-01T00:01:00.000Z";

it("session-attention-paths: complete, set, acknowledge, rekey, prune, remove and admission", async () => {
  const home = await mkdtemp(join(tmpdir(), "tron-session-attention-"));
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(Date.parse(T0));
  onTestFinished(async () => { vi.useRealTimers(); await rm(home, { recursive: true, force: true }); });
  const path = join(home, "gateway", "session-attention.json");
  const committed = async () => readFile(path, "utf8").then((text) => JSON.parse(text) as unknown,
    (error: NodeJS.ErrnoException) => { if (error.code === "ENOENT") return undefined; throw error; });
  let store = new SessionAttentionStore(home);
  const view = (...ids: string[]) => Object.fromEntries(ids.map((id) => [id, {
    ...store.projection(id), unacknowledged: store.hasUnacknowledgedCompletion(id) }]));
  const projection = (completionRevision: number, attentionRevision: number, isUnread: boolean) => ({ completionRevision, attentionRevision, isUnread });
  const mutation = (changed: boolean, completionRevision: number, attentionRevision: number, isUnread: boolean) =>
    ({ changed, projection: projection(completionRevision, attentionRevision, isUnread) });
  const record = (completionRevision: number, readThroughRevision: number, manualUnread: boolean, recentCompletionIds: string[], attentionRevision: number) =>
    ({ completionRevision, readThroughRevision, manualUnread, recentCompletionIds, attentionRevision });
  const stored = (sessions: Record<string, unknown>, reconciledThrough = T0) => ({ version: 1, reconciledThrough, sessions });
  const none = { ...projection(0, 0, false), unacknowledged: false };

  await expect(store.complete("a", "a-1"), "mutation before initialize").rejects.toThrow(expect.objectContaining({ message: "Session attention store is not initialized" }));
  expect(await committed()).toBeUndefined();
  await mkdir(join(home, "gateway"), { recursive: true });
  await store.initialize();
  expect({ cursor: store.reconciliationCursor(), ...view("a") }, "initialize empty").toEqual({ cursor: T0, a: none });
  expect(await committed()).toEqual(stored({}));

  expect(await store.complete("a", "a-1")).toEqual(mutation(true, 1, 1, true));
  expect(await committed()).toEqual(stored({ a: record(1, 0, false, ["a-1"], 1) }));
  expect(await store.complete("a", "a-1"), "replayed a-1 is not admitted again").toEqual(mutation(false, 1, 1, true));
  expect(await store.complete("a", "a-2", true), "complete a-2 observed").toEqual(mutation(true, 2, 2, false));
  expect(await committed()).toEqual(stored({ a: record(2, 2, false, ["a-1", "a-2"], 2) }));
  expect(await store.complete("a", "a-3"), "complete a-3 unobserved").toEqual(mutation(true, 3, 3, true));
  expect(view("a")).toEqual({ a: { ...projection(3, 3, true), unacknowledged: true } });
  expect(await committed()).toEqual(stored({ a: record(3, 2, false, ["a-1", "a-2", "a-3"], 3) }));
  expect(await store.set("a", true), "mark a unread").toEqual(mutation(true, 3, 4, true));
  expect(await committed()).toEqual(stored({ a: record(3, 2, true, ["a-1", "a-2", "a-3"], 4) }));
  expect(await store.set("a", true), "mark a unread again is unchanged").toEqual(mutation(false, 3, 4, true));
  expect(await store.set("a", false, 2), "mark a read through revision 2 keeps revision 3 unread").toEqual(mutation(true, 3, 5, true));
  expect(view("a")).toEqual({ a: { ...projection(3, 5, true), unacknowledged: true } });
  expect(await committed()).toEqual(stored({ a: record(3, 2, false, ["a-1", "a-2", "a-3"], 5) }));
  expect(await store.set("a", false, 99), "mark a read through a future revision clamps to the latest").toEqual(mutation(true, 3, 6, false));
  expect(view("a")).toEqual({ a: { ...projection(3, 6, false), unacknowledged: false } });
  const aRead = record(3, 3, false, ["a-1", "a-2", "a-3"], 6);
  expect(await committed()).toEqual(stored({ a: aRead }));
  expect(await store.set("a", false), "mark a read again is unchanged").toEqual(mutation(false, 3, 6, false));
  expect(await store.set("b", false), "mark unknown b read is unchanged").toEqual(mutation(false, 0, 0, false));
  expect(await committed(), "unchanged marks commit nothing").toEqual(stored({ a: aRead }));

  for (let index = 1; index <= 18; index += 1) await store.complete("b", `b-${index}`);
  const newest = (from: number) => Array.from({ length: 16 }, (_value, offset) => `b-${from + offset}`);
  expect(view("b"), "eighteen completions of b").toEqual({ b: { ...projection(18, 18, true), unacknowledged: true } });
  expect(await committed(), "keep the newest sixteen ids").toEqual(stored({ a: aRead, b: record(18, 0, false, newest(3), 18) }));
  expect(await store.complete("b", "b-1"), "an evicted completion id is admitted again").toEqual(mutation(true, 19, 19, true));
  const bIds = [...newest(4).slice(0, 15), "b-1"];
  expect(await committed()).toEqual(stored({ a: aRead, b: record(19, 0, false, bIds, 19) }));
  expect(await store.complete("b", "b-18"), "a retained completion id is not").toEqual(mutation(false, 19, 19, true));
  expect(await store.set("b", true), "mark b unread").toEqual(mutation(true, 19, 20, true));
  expect(await committed()).toEqual(stored({ a: aRead, b: record(19, 0, true, bIds, 20) }));
  expect(await store.acknowledgeCompletions("b"), "acknowledge b completions keeps the manual mark").toEqual(mutation(true, 19, 21, true));
  expect(view("b")).toEqual({ b: { ...projection(19, 21, true), unacknowledged: false } });
  const bAcknowledged = record(19, 19, true, bIds, 21);
  expect(await committed()).toEqual(stored({ a: aRead, b: bAcknowledged }));
  expect(await store.acknowledgeCompletions("b"), "acknowledge b again is unchanged").toEqual(mutation(false, 19, 21, true));
  expect(await store.acknowledgeCompletions("c"), "acknowledge unknown c is unchanged").toEqual(mutation(false, 0, 0, false));

  expect(await store.rekey("a", "c"), "rekey a to c").toBe(true);
  expect(view("a", "c"), "keeps a's attention under c").toEqual({ a: none, c: { ...projection(3, 6, false), unacknowledged: false } });
  expect(await committed()).toEqual(stored({ b: bAcknowledged, c: aRead }));
  expect(await store.rekey("a", "c"), "rekey the absent a again").toBe(false);
  expect(await store.rekey("c", "c"), "rekey c to itself").toBe(false);
  await expect(store.rekey("c", "b"), "rekey c onto b").rejects.toThrow(expect.objectContaining({ message: "Replacement session already has attention state" }));
  await expect(store.assertAbsent("b")).rejects.toThrow(expect.objectContaining({ message: "New session identity already has attention state" }));
  await expect(store.assertAbsent("d")).resolves.toBeUndefined();
  expect(await committed(), "refusals commit nothing").toEqual(stored({ b: bAcknowledged, c: aRead }));

  vi.setSystemTime(Date.parse(T1));
  await store.advanceReconciliationCursor("2025-12-31T00:00:00.000Z");
  expect(store.reconciliationCursor(), "advance cursor backwards is ignored").toBe(T0);
  await store.advanceReconciliationCursor(T1);
  expect(store.reconciliationCursor(), "advance cursor").toBe(T1);
  expect(await committed()).toEqual(stored({ b: bAcknowledged, c: aRead }, T1));
  const published = (await lstat(path)).ino;
  await store.advanceReconciliationCursor(T1);
  expect((await lstat(path)).ino, "advancing the cursor to its current value does not republish the document").toBe(published);
  expect(await store.prune(new Set(["b", "c"])), "prune keeping b and c is unchanged").toBe(false);
  expect(await store.prune(new Set(["c"])), "prune keeping c").toBe(true);
  expect(view("b", "c")).toEqual({ b: none, c: { ...projection(3, 6, false), unacknowledged: false } });
  expect(await committed()).toEqual(stored({ c: aRead }, T1));

  store = new SessionAttentionStore(home);
  await store.initialize();
  expect({ cursor: store.reconciliationCursor(), ...view("b", "c") }, "reopen reads the committed document")
    .toEqual({ cursor: T1, b: none, c: { ...projection(3, 6, false), unacknowledged: false } });
  expect(await store.remove("c"), "remove c").toBe(true);
  expect(await committed()).toEqual(stored({}, T1));
  expect(await store.remove("c"), "remove c again").toBe(false);
  expect(await store.set("e", true), "mark e unread").toEqual(mutation(true, 0, 1, true));
  expect(await store.complete("e", "e-1", true), "an observed completion clears the manual mark").toEqual(mutation(true, 1, 2, false));
  expect(await committed()).toEqual(stored({ e: record(1, 1, false, ["e-1"], 2) }, T1));

  const reopen = async (document: unknown) => { await writeFile(path, JSON.stringify(document)); await new SessionAttentionStore(home).initialize(); };
  const valid = record(2, 1, false, ["x-1", "x-2"], 3);
  const document = (sessions: unknown, extra: Record<string, unknown> = {}) => ({ version: 1, reconciledThrough: T0, sessions, ...extra });
  await expect(reopen(document({ x: valid })), "admit a valid hand-written record").resolves.toBeUndefined();
  for (const [refused, message] of [
    [document({ x: valid }, { version: 2 }), "Invalid session attention document"],
    [document({ x: valid }, { reconciledThrough: "not a time" }), "Invalid session attention document"],
    [document({ x: { ...valid, readThroughRevision: 3 } }), "Invalid session attention record"],
    [document({ x: { ...valid, attentionRevision: -1 } }), "Invalid session attention record"],
    [document({ x: { ...valid, recentCompletionIds: ["x-1", "x-1"] } }), "Invalid session attention record"],
    [document({ x: { ...valid, recentCompletionIds: Array.from({ length: 17 }, (_v, i) => `x-${i}`) } }), "Invalid session attention record"],
    [document({ x: { ...valid, manualUnread: "yes" } }), "Invalid session attention record"],
    [document({ "": valid }), "Invalid session attention record"],
    [document([valid]), "Invalid session attention document"],
    [null, "Invalid session attention document"],
    [[document({})], "Invalid session attention document"],
    [document(null), "Invalid session attention document"],
    [document("x"), "Invalid session attention document"],
    [document({ x: null }), "Invalid session attention record"],
    [document({ x: [] }), "Invalid session attention record"],
    [document({ x: "unread" }), "Invalid session attention record"],
  ] as const) {
    await expect(reopen(refused), JSON.stringify(refused).slice(0, 120)).rejects.toThrow(expect.objectContaining({ message: message }));
    expect(await committed(), "a refused document is kept as written").toEqual(refused);
  }
});
