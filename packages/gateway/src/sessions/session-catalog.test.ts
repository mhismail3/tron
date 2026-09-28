import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readFile, realpath, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  CatalogDiscovery,
  DEFAULT_CATALOG_DISCOVERY_LIMITS,
  buildCatalogSessionInfo,
  type CatalogSessionInfo,
} from "./catalog-discovery.js";
import { CatalogMetadataIndex, type CatalogMetadataIndexSummary } from "./catalog-metadata-index.js";
import {
  SessionCatalog,
  type SessionCatalogOptions,
  type SessionCatalogReconcileOutcome,
  type SessionCatalogSource,
} from "./session-catalog.js";

// Failure modes this file covers, written before the owner existed:
// 1. A canonical file written while the index was not watching (a crash between
//    the file write and the index update): the next owner's startup reconcile
//    must produce the row the folder proves.
// 2. Two canonical files claiming one session ID: the index keeps one row per
//    file and reports the ID as duplicated instead of merging the claimants.
// 3. A rekey/append while a reader holds a row: published rows are replaced,
//    never mutated, so the held row stays the value that was read.
// 4. A durable document that is corrupt, or saved for another root: the index
//    is rebuilt from canonical files rather than publishing foreign rows.
// 5. Shutdown before the load, or inside it: the owner has no canonical cut, so
//    it must leave the prior durable document alone instead of writing an empty
//    or partial one that the next startup would rebuild by parsing every file.
// 6. A deletion the Gateway commits while a reconcile is reading the folder: the
//    stale pass must not publish the removed row back.
// 7. An append that lands between a summary's parse and its stamp: the row must
//    not claim an offset past a message it never counted.

const roots: string[] = [];

afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

function summaryFor(info: CatalogSessionInfo): CatalogMetadataIndexSummary {
  return {
    id: info.id,
    path: info.path,
    cwd: info.cwd,
    ...(info.parentSessionPath ? { parentSessionPath: info.parentSessionPath } : {}),
    ...(info.creationOrigin ? { creationOrigin: info.creationOrigin } : {}),
    ...(info.name ? { name: info.name } : {}),
    firstMessage: info.firstMessage,
    createdAt: info.created.toISOString(),
    updatedAt: info.modified.toISOString(),
    messageCount: info.messageCount,
  };
}

async function writeSession(
  path: string,
  id: string,
  cwd: string,
  messages: readonly string[],
  name?: string,
): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  const lines = [JSON.stringify({ type: "session", version: 3, id, timestamp: "2026-09-27T00:00:00.000Z", cwd })];
  if (name) lines.push(JSON.stringify({ type: "session_info", name }));
  messages.forEach((content, index) => lines.push(JSON.stringify({
    type: "message",
    id: `m${index}`,
    timestamp: Date.parse("2026-09-27T00:00:00.000Z") + index,
    message: { role: "user", content },
  })));
  await writeFile(path, `${lines.join("\n")}\n`);
}

async function appendMessage(path: string, content: string, ordinal: number): Promise<void> {
  await writeFile(path, `${JSON.stringify({
    type: "message",
    id: `appended-${ordinal}`,
    timestamp: Date.parse("2026-09-27T01:00:00.000Z") + ordinal,
    message: { role: "assistant", content },
  })}\n`, { flag: "a" });
}

async function fixture(extra: Partial<SessionCatalogOptions> = {}) {
  const root = await mkdtemp(join(tmpdir(), "tron-session-catalog-"));
  roots.push(root);
  const sessions = join(root, "sessions");
  const state = join(root, "state");
  await Promise.all([mkdir(sessions, { recursive: true }), mkdir(state, { recursive: true })]);
  const discovery = new CatalogDiscovery({
    limits: DEFAULT_CATALOG_DISCOVERY_LIMITS,
    catalogDirectory: () => sessions,
    catalogCapacityExceeded: () => { throw new Error("catalog capacity exceeded"); },
    isLiveRuntimeOwnedPath: () => false,
    canonicalSessionPath: async (path) => path,
    delegatedTopologyParentPath: () => undefined,
  });
  const index = new CatalogMetadataIndex(state);
  const source: SessionCatalogSource = {
    scan: async () => {
      const evidence = await discovery.catalogStructureEvidence();
      return {
        complete: evidence.complete,
        candidates: [...evidence.identitiesByPath].map(([path, identity]) => ({
          path,
          id: identity.id,
          cwd: identity.cwd,
          fileIdentity: identity.fileIdentity,
          size: identity.size,
          mtimeMs: identity.mtimeMs,
        })),
      };
    },
    summaryFor: async (path) => {
      // Production's source reports the exact size its counts cover, so a row
      // is never stamped with a size the parse did not see.
      const before = await stat(path).catch(() => undefined);
      const info = await buildCatalogSessionInfo(path);
      const after = await stat(path).catch(() => undefined);
      if (!info || !before || !after || after.size !== before.size || after.mtimeMs !== before.mtimeMs) return undefined;
      return { ...summaryFor(info), parsedSize: after.size };
    },
  };
  const catalog = new SessionCatalog({
    catalogRoot: () => sessions, index, source, persistDebounceMs: 5, ...extra,
  });
  return {
    root,
    // macOS temp roots are reached through a symlink; the walk canonicalizes it,
    // so the test works in the same path form the index publishes.
    sessions: await realpath(sessions),
    state,
    index,
    source,
    catalog,
    indexPath: join(state, "catalog-metadata-v2.json"),
  };
}

describe("SessionCatalog", () => {
  it("repairs a canonical file the durable index never saw", async () => {
    const { sessions, catalog, indexPath } = await fixture();
    // The file exists and the durable document does not: this is the state a
    // crash between a canonical write and the index update leaves behind.
    const written = join(sessions, "workspace", "a.jsonl");
    await writeSession(written, "id-a", sessions, ["first prompt"], "kept name");
    expect(existsSync(indexPath)).toBe(false);

    catalog.start();
    await catalog.settled();

    expect(catalog.rows()).toEqual([expect.objectContaining({
      id: "id-a",
      path: written,
      cwd: sessions,
      name: "kept name",
      firstMessage: "first prompt",
      messageCount: 1,
      delegated: false,
      createdAt: "2026-09-27T00:00:00.000Z",
    })]);
    // The repaired cut is durable, so the next start does not need the bodies.
    expect(existsSync(indexPath)).toBe(true);
  });

  it("keeps one row per canonical file when two files claim one session ID", async () => {
    const { sessions, catalog } = await fixture();
    const first = join(sessions, "workspace", "one.jsonl");
    const second = join(sessions, "other", "two.jsonl");
    await writeSession(first, "id-dup", sessions, ["one"]);
    await writeSession(second, "id-dup", sessions, ["two"]);

    catalog.start();
    await catalog.settled();

    expect(catalog.rows().map((row) => row.path).sort()).toEqual([first, second].sort());
    expect([...catalog.duplicateSessionIds()]).toEqual(["id-dup"]);
  });

  it("replaces a published row instead of mutating it across an append and a rekey", async () => {
    const { sessions, catalog } = await fixture();
    const previous = join(sessions, "workspace", "previous.jsonl");
    await writeSession(previous, "id-previous", sessions, ["one"]);
    catalog.start();
    await catalog.settled();

    const held = catalog.rows()[0]!;
    await appendMessage(previous, "two", 1);
    await catalog.refresh(previous);
    await catalog.settled();
    // The row is replaced: the value a reader already holds cannot change.
    expect(held.messageCount).toBe(1);
    expect(catalog.row(previous)?.messageCount).toBe(2);

    // A rekey (a fork) commits a second canonical file while a reader still
    // holds the previous row.
    const forked = join(sessions, "workspace", "previous", "forks", "fork.jsonl");
    await writeSession(forked, "id-fork", sessions, ["one", "two"]);
    await catalog.refresh(previous);
    await catalog.refresh(forked);
    await catalog.settled();

    expect(held.messageCount).toBe(1);
    expect(catalog.row(previous)?.messageCount).toBe(2);
    expect(catalog.row(forked)?.messageCount).toBe(2);
    expect(catalog.row(previous)?.delegated).toBe(false);
    expect(catalog.row(forked)?.delegated).toBe(true);
  });

  it("rebuilds from canonical files when the durable document is corrupt or foreign", async () => {
    const { sessions, state, index, catalog, indexPath, source } = await fixture();
    const written = join(sessions, "workspace", "a.jsonl");
    await writeSession(written, "id-a", sessions, ["first prompt"]);
    // A document bound to another root is not this catalog's membership.
    const otherRoot = join(state, "elsewhere");
    await mkdir(otherRoot, { recursive: true });
    await index.save(otherRoot, []);
    expect(await index.load(sessions)).toBeUndefined();

    catalog.start();
    await catalog.settled();
    expect(catalog.rows().map((row) => row.id)).toEqual(["id-a"]);

    // A corrupt document is equally unusable: a restarted owner must rebuild the
    // row from its canonical file rather than publish an empty catalog.
    await writeFile(indexPath, "{ not a catalog document");
    expect(await index.load(sessions)).toBeUndefined();
    const restarted = new SessionCatalog({ catalogRoot: () => sessions, index, source });
    restarted.start();
    await restarted.settled();
    expect(restarted.rows().map((row) => row.id)).toEqual(["id-a"]);
    await restarted.dispose();
  });

  it("keeps the prior durable document when shutdown precedes or interrupts the load", async () => {
    const { sessions, catalog, index, indexPath, source } = await fixture();
    const written = join(sessions, "workspace", "a.jsonl");
    await writeSession(written, "id-a", sessions, ["first prompt"]);
    catalog.start();
    await catalog.settled();
    const document = await readFile(indexPath, "utf8");

    // A shutdown while the storage upgrade runs: `initialize()` has not called
    // `start()`, so this owner has never loaded or reconciled a row and has no
    // canonical cut to write.
    const neverStarted = new SessionCatalog({ catalogRoot: () => sessions, index, source });
    await neverStarted.dispose();
    expect(await readFile(indexPath, "utf8")).toBe(document);

    // A shutdown inside the load: the rows are in hand but the owner is closing,
    // so they are dropped rather than published and the document stays whole.
    const realLoad = index.load.bind(index);
    const load = vi.spyOn(index, "load");
    load.mockImplementation(async (root: string) => {
      const rows = await realLoad(root);
      await new Promise((resolve) => setImmediate(resolve));
      return rows;
    });
    const duringLoad = new SessionCatalog({ catalogRoot: () => sessions, index, source });
    duringLoad.start();
    await duringLoad.dispose();
    load.mockRestore();
    expect(duringLoad.rows()).toEqual([]);
    expect(await readFile(indexPath, "utf8")).toBe(document);
    expect(await index.load(sessions)).toHaveLength(1);
  });

  it("does not publish a row back after a removal announced during its read", async () => {
    const { sessions, catalog, index, source } = await fixture();
    const removed = join(sessions, "workspace", "a.jsonl");
    const kept = join(sessions, "other", "b.jsonl");
    await writeSession(removed, "id-a", sessions, ["a"]);
    await writeSession(kept, "id-b", sessions, ["b"]);
    catalog.start();
    await catalog.settled();
    expect(catalog.rows().map((row) => row.id).sort()).toEqual(["id-a", "id-b"]);

    // The Gateway commits a deletion while the reconcile is reading the folder.
    // Its cut still lists the file, and publishing that cut would resurrect the
    // removed session until the next restart.
    const realScan = source.scan.bind(source);
    const scan = vi.spyOn(source, "scan").mockImplementation(async () => {
      const cut = await realScan();
      catalog.remove(removed);
      return cut;
    });
    await catalog.reconcile();
    await catalog.settled();
    scan.mockRestore();
    expect(catalog.rows().map((row) => row.id)).toEqual(["id-b"]);
    expect((await index.load(sessions))?.map((row) => row.id)).toEqual(["id-b"]);

    // The guard covers the pass that read before the removal; a later pass
    // proves membership from the folder again, and the file is still there.
    await catalog.reconcile();
    await catalog.settled();
    expect(catalog.rows().map((row) => row.id).sort()).toEqual(["id-a", "id-b"]);
  });

  it("reports one reconcile per cut with the rows it actually changed", async () => {
    const outcomes: SessionCatalogReconcileOutcome[] = [];
    const { sessions, catalog, source } = await fixture({ onReconciled: (outcome) => outcomes.push(outcome) });
    const first = join(sessions, "workspace", "a.jsonl");
    await writeSession(first, "id-a", sessions, ["one"]);
    catalog.start();
    await catalog.settled();
    expect(outcomes).toHaveLength(1);
    expect(outcomes[0]).toMatchObject({ outcome: "reconciled", files: 1, added: 1, removed: 0, modified: 0, unproven: 0 });

    // A second canonical file appears: the pass covers two files and adds one row.
    await writeSession(join(sessions, "other", "b.jsonl"), "id-b", sessions, ["two"]);
    await catalog.reconcile();
    await catalog.settled();
    expect(outcomes[1]).toMatchObject({ outcome: "reconciled", files: 2, added: 1, removed: 0, modified: 0, unproven: 0 });

    // A file whose last line is incomplete cannot be proven, but it is counted
    // as unproven and keeps the row it had rather than leaving the catalog.
    const partial = join(sessions, "other", "b.jsonl");
    await writeFile(partial, `${await readFile(partial, "utf8")}{"type":"message"`);
    await catalog.reconcile();
    await catalog.settled();
    expect(outcomes[2]).toMatchObject({ outcome: "reconciled", files: 2, added: 0, removed: 0, modified: 0, unproven: 1 });
    expect(catalog.row(partial)?.messageCount).toBe(1);

    // An incomplete cut publishes no membership, and a failed walk reads nothing:
    // both are reported instead of being silent.
    const incomplete = vi.spyOn(source, "scan").mockResolvedValue({ complete: false, candidates: [] });
    await catalog.reconcile();
    await catalog.settled();
    incomplete.mockRestore();
    expect(outcomes[3]).toMatchObject({ outcome: "incomplete", files: 0, added: 0, removed: 0, modified: 0 });
    const failed = vi.spyOn(source, "scan").mockRejectedValue(new Error("catalog walk failed"));
    await catalog.reconcile();
    await catalog.settled();
    failed.mockRestore();
    expect(outcomes[4]).toMatchObject({ outcome: "failed", files: 0 });
    expect(catalog.rows().map((row) => row.id).sort()).toEqual(["id-a", "id-b"]);
  });

  it("does not stamp a row with an offset past content it never counted", async () => {
    const { sessions, catalog, index, source } = await fixture();
    const written = join(sessions, "workspace", "a.jsonl");
    await writeSession(written, "id-a", sessions, ["one"]);
    catalog.start();
    await catalog.settled();
    const counted = (await stat(written)).size;
    expect(catalog.row(written)).toMatchObject({ messageCount: 1, eofOffset: counted, size: counted });

    // The tail read loses its race with a Pi append, so the owner falls back to
    // the summary — and the file grows again after that summary was parsed. The
    // row must keep the facts it counted, not claim the later size.
    const realSummaryFor = source.summaryFor.bind(source);
    const append = vi.spyOn(index, "append").mockResolvedValue(undefined);
    const summary = vi.spyOn(source, "summaryFor").mockImplementation(async (path) => {
      const built = await realSummaryFor(path);
      if (built) await appendMessage(written, "grew between the reads", 7);
      return built;
    });
    await catalog.refresh(written);
    await catalog.settled();
    summary.mockRestore();
    append.mockRestore();
    expect(catalog.row(written)).toMatchObject({ messageCount: 1, eofOffset: counted, size: counted });

    // Once the tail read is not racing, the same row advances over the appended
    // bytes exactly.
    await catalog.refresh(written);
    await catalog.settled();
    const appended = (await stat(written)).size;
    expect(catalog.row(written)).toMatchObject({ messageCount: 2, eofOffset: appended, size: appended });
  });
});
