import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { it } from "vitest";
import { storePathLock } from "../../test-support/store-path-lock.js";
import { SessionArchiveStore } from "./session-archive-store.js";

/**
 * `gateway/session-catalog` mutation-path lock for the session archive store (plan §6.5
 * V4, §6.6; test-support/store-path-lock.ts): every write path, its refusals, the
 * change revision and the exact document it commits.
 */
it("session-archive-paths: archive, rekey, prune, remove and admission", async () => {
  const log = await storePathLock({ module: "gateway/session-catalog", name: "session-archive-paths", testFileUrl: import.meta.url, owned: "gateway/session-archive.json" });
  const path = join(log.home, "gateway", "session-archive.json");
  let store = new SessionArchiveStore(log.home);
  const view = (...ids: string[]) => ({ revision: store.revision, archivedAt: Object.fromEntries(ids.map((id) => [id, store.archivedAt(id) ?? null])) });
  await log.step("read before initialize", () => view("a"));
  await log.step("archive before initialize", () => store.archive("a"));
  await mkdir(join(log.home, "gateway"), { recursive: true });
  await log.step("initialize empty", async () => { await store.initialize(); return view("a"); });
  await log.step("archive a", async () => ({ archivedAt: await store.archive("a"), ...view("a") }));
  log.advance(1_000);
  await log.step("archive a again keeps its first time", async () => ({ archivedAt: await store.archive("a"), ...view("a") }));
  await log.step("archive b later", async () => ({ archivedAt: await store.archive("b"), ...view("a", "b") }));
  await log.step("rekey a to c", async () => ({ rekeyed: await store.rekey("a", "c"), ...view("a", "c") }));
  await log.step("rekey the absent a again", async () => ({ rekeyed: await store.rekey("a", "c"), ...view("a", "c") }));
  await log.step("rekey c to itself", () => store.rekey("c", "c"));
  await log.step("rekey c onto b is refused", () => store.rekey("c", "b"));
  await log.step("assert b absent is refused", () => store.assertAbsent("b"));
  await log.step("assert d absent", () => store.assertAbsent("d"));
  await log.step("prune keeping b and c is unchanged", async () => ({ pruned: await store.prune(new Set(["b", "c"])), ...view("b", "c") }));
  await log.step("archive d", () => store.archive("d"));
  await log.step("prune keeping c names the dropped ids", async () => ({ pruned: await store.prune(new Set(["c"])), ...view("b", "c", "d") }));
  await log.step("reopen reads the committed document", async () => {
    store = new SessionArchiveStore(log.home);
    await store.initialize();
    return view("b", "c");
  });
  await log.step("remove c", async () => ({ removed: await store.remove("c"), ...view("c") }));
  await log.step("remove c again", async () => ({ removed: await store.remove("c"), ...view("c") }));
  const refused = async (label: string, document: unknown) => log.step(label, async () => {
    await writeFile(path, JSON.stringify(document));
    const reopened = new SessionArchiveStore(log.home);
    await reopened.initialize();
    return reopened.archivedAt("x") ?? null;
  });
  await refused("admit a valid hand-written record", { version: 1, sessions: { x: { archivedAt: "2026-01-01T00:00:00.000Z" } } });
  await refused("refuse another version", { version: 2, sessions: {} });
  await refused("refuse a bad time", { version: 1, sessions: { x: { archivedAt: "never" } } });
  await refused("refuse an extra record key", { version: 1, sessions: { x: { archivedAt: "2026-01-01T00:00:00.000Z", by: "me" } } });
  await refused("refuse an empty session id", { version: 1, sessions: { "": { archivedAt: "2026-01-01T00:00:00.000Z" } } });
  await refused("refuse an array of sessions", { version: 1, sessions: [] });
  await refused("refuse a non-object document", [1]);
  await refused("refuse a null document", null);
  await refused("refuse a string document", "sessions");
  await refused("refuse null sessions", { version: 1, sessions: null });
  await refused("refuse string sessions", { version: 1, sessions: "x" });
  await refused("refuse a null record", { version: 1, sessions: { x: null } });
  await refused("refuse an array record", { version: 1, sessions: { x: [] } });
  await refused("refuse a string record", { version: 1, sessions: { x: "2026-01-01T00:00:00.000Z" } });
  await log.finish();
});
