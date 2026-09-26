import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { SessionArchiveStore } from "./session-archive-store.js";

/**
 * Isolated store coverage exists only for failure modes the WebSocket
 * lifecycle test in `packages/gateway/src/transport/session-archive.integration.test.ts`
 * structurally cannot reproduce:
 *
 * 1. A corrupt, oversized or wrong-version document must fail instead of
 *    resetting to empty, which would silently surface every archived session.
 * 2. A failed durable write must leave the in-memory projection unchanged, so a
 *    reported archive is never one that did not land.
 * 3. The session capacity bound must reject, not truncate or exceed.
 * 4. Re-archiving an existing record keeps its original timestamp, so a replayed
 *    command cannot reorder the archived list.
 * 5. `prune` removes exactly the IDs absent from complete retained evidence.
 * 6. `rekey` moves one record and refuses to overwrite an existing target.
 * 7. `assertAbsent` fails a rebind to an identity that already carries state.
 * 8. The change revision advances only for a committed change.
 */
const documentPath = (home: string) => join(home, "gateway", "session-archive.json");

async function store(home: string, options: ConstructorParameters<typeof SessionArchiveStore>[1] = {}) {
  const archive = new SessionArchiveStore(home, options);
  await archive.initialize();
  return archive;
}

describe("SessionArchiveStore", () => {
  it("archives once, keeps its timestamp, and reports one change per commit", async () => {
    const home = await mkdtemp(join(tmpdir(), "tron-archive-store-"));
    let now = Date.parse("2026-09-26T00:00:00.000Z");
    const archive = await store(home, { now: () => new Date(now) });

    const initialRevision = archive.revision;
    const first = await archive.archive("session-1");
    expect(first).toBe("2026-09-26T00:00:00.000Z");
    expect(archive.revision).toBe(initialRevision + 1);
    now += 60_000;
    expect(await archive.archive("session-1")).toBe("2026-09-26T00:00:00.000Z");
    expect(archive.revision).toBe(initialRevision + 1);
    expect(archive.archivedAt("session-1")).toBe("2026-09-26T00:00:00.000Z");
    expect(archive.archivedAt("session-2")).toBeUndefined();
    expect(await archive.remove("session-2")).toBe(false);
    expect(archive.revision).toBe(initialRevision + 1);
    expect(await archive.remove("session-1")).toBe(true);
    expect(archive.revision).toBe(initialRevision + 2);
  });

  it("reloads committed state and never resets a corrupt or wrong-version document to empty", async () => {
    const home = await mkdtemp(join(tmpdir(), "tron-archive-corrupt-"));
    const archive = await store(home);
    await archive.archive("session-1");
    const persisted = JSON.parse(await readFile(documentPath(home), "utf8"));
    expect(persisted).toMatchObject({ version: 1, sessions: { "session-1": { archivedAt: expect.any(String) } } });

    const reloaded = await store(home);
    expect(reloaded.archivedAt("session-1")).toBe(persisted.sessions["session-1"].archivedAt);

    for (const invalid of [
      "{",
      "[]",
      JSON.stringify({ version: 2, sessions: {} }),
      JSON.stringify({ version: 1, sessions: { "session-1": { archivedAt: "not-a-timestamp" } } }),
      JSON.stringify({ version: 1, sessions: { "session-1": { archivedAt: "2026-01-01T00:00:00.000Z", extra: 1 } } }),
      JSON.stringify({ version: 1, sessions: { "": { archivedAt: "2026-01-01T00:00:00.000Z" } } }),
      JSON.stringify({ version: 1 }),
    ]) {
      await writeFile(documentPath(home), invalid);
      await expect(store(home)).rejects.toThrow();
      // A failed admission leaves the file exactly as it was. Nothing is
      // rewritten to an empty store, which would silently surface every
      // archived session.
      expect(await readFile(documentPath(home), "utf8")).toBe(invalid);
    }
    const oversized = "x".repeat(2 * 1_048_576 + 1);
    await writeFile(documentPath(home), oversized);
    await expect(store(home)).rejects.toThrow(/exceeds/);
    expect(await readFile(documentPath(home), "utf8")).toBe(oversized);
  });

  it("keeps the in-memory projection unchanged when the durable write fails", async () => {
    const home = await mkdtemp(join(tmpdir(), "tron-archive-write-failure-"));
    let fail = false;
    const write = vi.fn(async (path: string, value: unknown) => {
      if (fail) throw new Error("simulated disk failure");
      await mkdir(dirname(path), { recursive: true, mode: 0o700 });
      await writeFile(path, `${JSON.stringify(value, null, 2)}\n`, "utf8");
    });
    const archive = await store(home, { write });
    await archive.archive("session-1");
    const revision = archive.revision;

    fail = true;
    await expect(archive.archive("session-2")).rejects.toThrow(/simulated disk failure/);
    expect(archive.archivedAt("session-2")).toBeUndefined();
    expect(archive.archivedAt("session-1")).toBeDefined();
    expect(archive.revision).toBe(revision);
    fail = false;
    // The rejected record is not half-applied: the next commit writes only the
    // state that was admitted.
    await archive.archive("session-2");
    const persisted = JSON.parse(await readFile(documentPath(home), "utf8"));
    expect(Object.keys(persisted.sessions).sort()).toEqual(["session-1", "session-2"]);
  });

  it("moves one record on rekey and refuses to overwrite a target", async () => {
    const home = await mkdtemp(join(tmpdir(), "tron-archive-rekey-"));
    const archive = await store(home);
    await archive.archive("previous");
    expect(await archive.rekey("previous", "next")).toBe(true);
    expect(archive.archivedAt("previous")).toBeUndefined();
    expect(archive.archivedAt("next")).toBeDefined();
    expect(await archive.rekey("previous", "next")).toBe(false);
    await archive.archive("occupied");
    await expect(archive.rekey("next", "occupied")).rejects.toThrow(/already has archive state/);
    expect(archive.archivedAt("next")).toBeDefined();
    expect(archive.archivedAt("occupied")).toBeDefined();
    await archive.assertAbsent("fresh");
    await expect(archive.assertAbsent("next")).rejects.toThrow(/already has archive state/);
  });

  it("prunes exactly the records absent from complete retained evidence", async () => {
    const home = await mkdtemp(join(tmpdir(), "tron-archive-prune-"));
    const archive = await store(home);
    await archive.archive("retained");
    await archive.archive("stale");
    const revision = archive.revision;
    expect(await archive.prune(new Set(["retained", "stale"]))).toBe(false);
    expect(archive.revision).toBe(revision);
    expect(await archive.prune(new Set(["retained"]))).toBe(true);
    expect(archive.archivedAt("stale")).toBeUndefined();
    expect(archive.archivedAt("retained")).toBeDefined();
    expect(archive.revision).toBe(revision + 1);
  });

  it("rejects a session beyond the capacity bound", async () => {
    const home = await mkdtemp(join(tmpdir(), "tron-archive-capacity-"));
    const archive = await store(home);
    const sessions = (archive as unknown as { document: { sessions: Record<string, { archivedAt: string }> } }).document.sessions;
    for (let index = 0; index < 50_000; index += 1) {
      sessions[`session-${index}`] = { archivedAt: "2026-01-01T00:00:00.000Z" };
    }
    await expect(archive.archive("session-overflow")).rejects.toThrow(/capacity exceeded/);
    // An existing record is still writable at the bound, because it adds no row.
    expect(await archive.archive("session-0")).toBe("2026-01-01T00:00:00.000Z");
  });
});
