import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it, onTestFinished, vi } from "vitest";
import { SessionArchiveStore } from "./session-archive-store.js";

const T0 = "2026-01-01T00:00:00.000Z";
const T1 = "2026-01-01T00:00:01.000Z";

it("session-archive-paths: archive, rekey, prune, remove and admission", async () => {
  const home = await mkdtemp(join(tmpdir(), "tron-session-archive-"));
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(Date.parse(T0));
  onTestFinished(async () => { vi.useRealTimers(); await rm(home, { recursive: true, force: true }); });
  const path = join(home, "state", "session-archive.json");
  const committed = async () => readFile(path, "utf8").then((text) => JSON.parse(text) as unknown,
    (error: NodeJS.ErrnoException) => { if (error.code === "ENOENT") return undefined; throw error; });
  const sessions = (records: Record<string, string>) =>
    ({ version: 1, sessions: Object.fromEntries(Object.entries(records).map(([id, archivedAt]) => [id, { archivedAt }])) });
  let store = new SessionArchiveStore(home);
  const view = (...ids: string[]) => ({ revision: store.revision, archivedAt: Object.fromEntries(ids.map((id) => [id, store.archivedAt(id) ?? null])) });

  expect(view("a"), "read before initialize").toEqual({ revision: 0, archivedAt: { a: null } });
  await expect(store.archive("a"), "archive before initialize").rejects.toThrow(expect.objectContaining({ message: "Session archive store is not initialized" }));
  expect(await committed()).toBeUndefined();
  await mkdir(join(home, "state"), { recursive: true });
  await store.initialize();
  expect(view("a"), "initialize empty").toEqual({ revision: 1, archivedAt: { a: null } });
  expect(await committed()).toEqual(sessions({}));

  expect(await store.archive("a")).toBe(T0);
  expect(view("a")).toEqual({ revision: 2, archivedAt: { a: T0 } });
  expect(await committed()).toEqual(sessions({ a: T0 }));
  vi.setSystemTime(Date.parse(T1));
  expect(await store.archive("a"), "archive a again keeps its first time").toBe(T0);
  expect(view("a"), "and does not change the revision").toEqual({ revision: 2, archivedAt: { a: T0 } });
  expect(await store.archive("b")).toBe(T1);
  expect(view("a", "b")).toEqual({ revision: 3, archivedAt: { a: T0, b: T1 } });
  expect(await committed()).toEqual(sessions({ a: T0, b: T1 }));

  expect(await store.rekey("a", "c"), "rekey a to c").toBe(true);
  expect(view("a", "c"), "keeps a's archive time").toEqual({ revision: 4, archivedAt: { a: null, c: T0 } });
  expect(await committed()).toEqual(sessions({ b: T1, c: T0 }));
  expect(await store.rekey("a", "c"), "rekey the absent a again").toBe(false);
  expect(await store.rekey("c", "c"), "rekey c to itself").toBe(false);
  expect(store.revision).toBe(4);
  await expect(store.rekey("c", "b"), "rekey c onto b").rejects.toThrow(expect.objectContaining({ message: "Replacement session already has archive state" }));
  await expect(store.assertAbsent("b")).rejects.toThrow(expect.objectContaining({ message: "New session identity already has archive state" }));
  await expect(store.assertAbsent("d")).resolves.toBeUndefined();
  expect(await committed(), "refusals commit nothing").toEqual(sessions({ b: T1, c: T0 }));

  expect(await store.prune(new Set(["b", "c"])), "prune keeping b and c").toEqual([]);
  expect(store.revision, "an empty prune is unchanged").toBe(4);
  expect(await store.archive("d")).toBe(T1);
  expect(await committed()).toEqual(sessions({ b: T1, c: T0, d: T1 }));
  expect(await store.prune(new Set(["c"])), "prune keeping c names the dropped ids").toEqual(["b", "d"]);
  expect(view("b", "c", "d")).toEqual({ revision: 6, archivedAt: { b: null, c: T0, d: null } });
  expect(await committed()).toEqual(sessions({ c: T0 }));

  store = new SessionArchiveStore(home);
  await store.initialize();
  expect(view("b", "c"), "reopen reads the committed document").toEqual({ revision: 0, archivedAt: { b: null, c: T0 } });
  expect(await store.remove("c")).toBe(true);
  expect(view("c")).toEqual({ revision: 1, archivedAt: { c: null } });
  expect(await committed()).toEqual(sessions({}));
  expect(await store.remove("c"), "remove c again").toBe(false);
  expect(store.revision).toBe(1);

  const reopen = async (document: unknown) => {
    await writeFile(path, JSON.stringify(document));
    const reopened = new SessionArchiveStore(home);
    await reopened.initialize();
    return reopened.archivedAt("x") ?? null;
  };
  expect(await reopen(sessions({ x: T0 })), "admit a valid hand-written record").toBe(T0);
  for (const document of [{ version: 2, sessions: {} }, { version: 1, sessions: [] }, [1], null, "sessions",
    { version: 1, sessions: null }, { version: 1, sessions: "x" }]) {
    await expect(reopen(document), JSON.stringify(document)).rejects.toThrow(expect.objectContaining({ message: "Invalid session archive document" }));
    expect(await committed(), "a refused document is kept, never reset to empty").toEqual(document);
  }
  for (const record of [{ x: { archivedAt: "never" } }, { x: { archivedAt: T0, by: "me" } }, { "": { archivedAt: T0 } },
    { x: null }, { x: [] }, { x: T0 }]) {
    await expect(reopen({ version: 1, sessions: record }), JSON.stringify(record)).rejects.toThrow(expect.objectContaining({ message: "Invalid session archive record" }));
    expect(await committed(), "a refused document is kept, never reset to empty").toEqual({ version: 1, sessions: record });
  }
});
