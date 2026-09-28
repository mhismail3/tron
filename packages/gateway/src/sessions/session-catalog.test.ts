import { existsSync } from "node:fs";
import {
  appendFile,
  chmod,
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rename,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, relative } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  CatalogDiscovery,
  DEFAULT_CATALOG_DISCOVERY_LIMITS,
  buildCatalogSessionInfo,
  type CatalogSessionInfo,
} from "./catalog-discovery.js";
import { CatalogMetadataIndex, type CatalogMetadataIndexSummary } from "./catalog-metadata-index.js";
import {
  CATALOG_EVENT_DEBOUNCE_MS,
  CATALOG_EVENT_MAX_WAIT_MS,
  SessionCatalog,
  type SessionCatalogChange,
  type SessionCatalogOptions,
  type SessionCatalogReconcileOutcome,
  type SessionCatalogSource,
  type SessionCatalogWatcherReset,
  type SessionCatalogWatcherResetReason,
  type SessionCatalogWatchHandle,
  type SessionCatalogWatchRequest,
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
// 8. Shutdown during a startup reconcile with a durable document present: the
//    owner must stop the pass within one batch instead of waiting for every
//    candidate to be verified, appended or parsed.
//
// G-1b's folder watcher and periodic reconciliation. Its failure modes, written
// before the watcher existed:
// 9. An event the platform never delivered (coalesced, dropped, or reported
//    while the watcher was restarting): the next periodic pass must publish the
//    row from the folder's own cut.
// 10. A file replaced with a new inode at the same path: the row's identity and
//     counts must be re-derived from the replacement, not advanced from the old
//     tail.
// 11. A child transcript that arrives before its parent: it is one row on its
//     own, classified as delegated by its path, and the parent arriving later
//     does not double it.
// 12. The root moved or unavailable: the owner records one outage, keeps
//     serving the last good index and watches the folder once it exists again.
// 13. A burst of events: one debounced read per path, no catalog walk, and no
//     read left armed.
// 14. A watcher that was observing and stopped: one `catalog.watcher-reset`,
//     a replacement watcher and a whole-folder reconciliation.
// 15. An event the platform could not name: the whole index is re-derived once,
//     because the hint covers the folder rather than one file.
// 16. An event for a path discovery would ignore (`subagent-artifacts`) or for
//     a file that is not a transcript: no row and no read.
// 17. A project folder moved into the root, or a subagent run folder renamed
//     inside it: the platform names the folder and not the transcripts inside
//     it, so the folder's own `.jsonl` files must reach their rows.
// 18. The root itself moved or removed: one outage instead of an empty cut (an
//     absent root proves no removal), and the folder's own cut once it is back.
// 19. A file the Gateway rolled back (a failed import, an uncommitted fork
//     artifact) deleted without announcing a removal: the row must go with the
//     file rather than stay until the next cut. A path that is present but
//     unreadable is not that evidence and keeps its row.
// 20. A path written faster than the quiet spell: the read must still arrive
//     within the ceiling instead of being re-armed forever.
// 21. A watcher that dies right after every attach: restarts are spaced by the
//     retry cadence, not immediate, and the outage is recorded once.

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

/** Wait for a condition the watcher's own timers produce. The watcher fires
 * outside the owner's lane, so `settled()` alone cannot observe it. */
async function waitFor(check: () => boolean, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!check() && Date.now() <= deadline) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  expect(check(), "condition was not met in time").toBe(true);
}

/** A folder watcher a test drives by hand: it delivers exactly the events the
 * test chose, so an event the platform would have dropped, a start failure and a
 * watcher that stops observing can each be reproduced. Every case that needs the
 * real backend uses the production watcher. */
interface ManualWatch {
  backend: (request: SessionCatalogWatchRequest) => SessionCatalogWatchHandle;
  requests: SessionCatalogWatchRequest[];
  closed: boolean[];
  fail: boolean;
  emit(filename: string | null): void;
  reset(reason: SessionCatalogWatcherResetReason): void;
}

function manualWatch(): ManualWatch {
  const requests: SessionCatalogWatchRequest[] = [];
  const closed: boolean[] = [];
  const watch: ManualWatch = {
    fail: false,
    requests,
    closed,
    backend: (request) => {
      if (watch.fail) throw new Error("catalog folder is unavailable");
      requests.push(request);
      const index = requests.length - 1;
      closed[index] = false;
      return { close: () => { closed[index] = true; } };
    },
    emit: (filename) => requests.at(-1)?.onEvent(filename),
    reset: (reason) => requests.at(-1)?.onReset(reason),
  };
  return watch;
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

  it("stops a startup reconcile within one batch when the owner is disposed", async () => {
    const { sessions, index, source, indexPath } = await fixture();
    const fileCount = 64;
    for (let ordinal = 0; ordinal < fileCount; ordinal += 1) {
      await writeSession(join(sessions, "workspace", `${ordinal}.jsonl`), `id-${ordinal}`, sessions, [`prompt ${ordinal}`]);
    }
    // A first owner leaves a durable document that covers every file, which is
    // the ordinary restart: the next owner reads the document instead of the
    // bodies.
    const first = new SessionCatalog({ catalogRoot: () => sessions, index, source });
    first.start();
    await first.settled();
    await first.dispose();
    const document = await readFile(indexPath, "utf8");

    // Every file grew outside the Gateway, so no durable row proves unchanged
    // and the restarted owner owes each candidate at least a tail append and,
    // once that cannot advance the row, a whole-body parse.
    for (let ordinal = 0; ordinal < fileCount; ordinal += 1) {
      await appendMessage(join(sessions, "workspace", `${ordinal}.jsonl`), "grown outside the owner", ordinal);
    }
    const append = vi.spyOn(index, "append").mockResolvedValue(undefined);
    const realSummaryFor = source.summaryFor.bind(source);
    const parses: string[] = [];
    const summaryFor = vi.spyOn(source, "summaryFor").mockImplementation(async (path) => {
      parses.push(path);
      await new Promise((resolve) => setTimeout(resolve, 20));
      return realSummaryFor(path);
    });
    try {
      const restarted = new SessionCatalog({ catalogRoot: () => sessions, index, source });
      restarted.start();
      while (parses.length === 0) await new Promise((resolve) => setImmediate(resolve));
      await restarted.dispose();
      // One batch (RECONCILE_CONCURRENCY candidates) at most: a shutdown that
      // waited for the other three batches would parse all 64 files.
      expect(parses.length).toBeLessThanOrEqual(16);
      // A stopped pass publishes nothing and owes no write, so the document the
      // next startup reads is the one the first owner left.
      expect(await readFile(indexPath, "utf8")).toBe(document);
    } finally {
      summaryFor.mockRestore();
      append.mockRestore();
    }
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
    // The removal's own lane work consumed the marker, so deletions cannot
    // accumulate in the owner's state for the life of the process.
    expect((catalog as unknown as { removalGenerations: Map<string, number> }).removalGenerations.size).toBe(0);

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

  it("advances a row for an external append within a second without walking the catalog", async () => {
    // No interval backstop: only the watcher can publish this append.
    const { sessions, catalog, source } = await fixture({ reconcileIntervalMs: 0 });
    const child = join(sessions, "parent", "producer", "run-1", "session.jsonl");
    await writeSession(join(sessions, "parent.jsonl"), "id-parent", sessions, ["parent prompt"]);
    await writeSession(child, "id-child", sessions, ["child prompt"]);
    catalog.start();
    await catalog.settled();
    expect(catalog.row(child)?.delegated).toBe(true);

    const walks = vi.spyOn(source, "scan");
    const appendedAt = Date.now();
    await appendMessage(child, "an external writer appended", 1);
    await waitFor(() => catalog.row(child)?.messageCount === 2, 5_000);
    const observedInMs = Date.now() - appendedAt;

    // The Done-when bound: an external append reaches its row within one second.
    expect(observedInMs).toBeLessThanOrEqual(1_000);
    expect(walks).not.toHaveBeenCalled();
    await catalog.settled();
    expect(catalog.row(child)).toMatchObject({ messageCount: 2, size: (await stat(child)).size });
    expect(catalog.row(child)?.eofOffset).toBe((await stat(child)).size);
  });

  it("repairs an event the platform never delivered at the next interval pass", async () => {
    const watch = manualWatch();
    const { sessions, catalog, source } = await fixture({
      watchCatalog: watch.backend, reconcileIntervalMs: 60,
    });
    const file = join(sessions, "workspace", "a.jsonl");
    await writeSession(file, "id-a", sessions, ["one"]);
    catalog.start();
    await catalog.settled();
    expect(watch.requests).toHaveLength(1);
    expect(catalog.row(file)?.messageCount).toBe(1);

    // The append's own event never arrives: a coalesced, dropped or
    // watcher-restarting event looks exactly like this.
    await appendMessage(file, "two", 2);
    const walks = vi.spyOn(source, "scan");
    await waitFor(() => catalog.row(file)?.messageCount === 2, 5_000);
    // The interval's own cut is what found it; no event was emitted.
    expect(walks).toHaveBeenCalled();
  });

  it("restarts the watcher and reconciles the whole folder after a watcher error", async () => {
    const watch = manualWatch();
    const resets: SessionCatalogWatcherReset[] = [];
    const { sessions, catalog, source } = await fixture({
      watchCatalog: watch.backend,
      reconcileIntervalMs: 0,
      watchRetryMs: 30,
      onWatcherReset: (reset) => resets.push(reset),
    });
    const file = join(sessions, "workspace", "a.jsonl");
    await writeSession(file, "id-a", sessions, ["one"]);
    catalog.start();
    await catalog.settled();
    expect(watch.requests).toHaveLength(1);
    expect(watch.closed[0]).toBe(false);

    // The watcher that was observing stops: every event from here on is missing.
    const walks = vi.spyOn(source, "scan");
    watch.reset("error");
    // The replacement waits for the retry cadence instead of restarting in
    // place, so a watcher that fails at every attach cannot spin.
    expect(watch.requests).toHaveLength(1);
    await waitFor(() => watch.requests.length === 2, 5_000);
    expect(watch.closed[0]).toBe(true);
    expect(resets).toEqual([{ reason: "error" }]);
    await waitFor(() => walks.mock.calls.length >= 1, 5_000);
    await catalog.settled();
    // Reads still come from the last good index, and the replacement watcher
    // sees the next external append.
    expect(catalog.row(file)?.messageCount).toBe(1);
    await appendMessage(file, "two", 1);
    watch.emit("workspace/a.jsonl");
    await waitFor(() => catalog.row(file)?.messageCount === 2, 5_000);
    await catalog.dispose();
  });

  it("spaces the restart of a watcher that dies right after every attach", async () => {
    const resets: SessionCatalogWatcherReset[] = [];
    const starts: number[] = [];
    const { catalog } = await fixture({
      reconcileIntervalMs: 0,
      watchRetryMs: 40,
      onWatcherReset: (reset) => resets.push(reset),
      watchCatalog: (request) => {
        starts.push(Date.now());
        setImmediate(() => request.onReset("error"));
        return { close: () => {} };
      },
    });
    catalog.start();
    await catalog.settled();
    await new Promise((resolve) => setTimeout(resolve, 400));

    // A watcher that dies at every attach is restarted on the retry cadence: a
    // fixed number of attempts in the window rather than an immediate loop, and
    // one record for the outage those failures are all part of.
    expect(starts.length).toBeGreaterThan(1);
    expect(starts.length).toBeLessThanOrEqual(20);
    expect(resets).toEqual([{ reason: "error" }]);
    await catalog.dispose();
  });

  it("records one outage when the root appears only after startup", async () => {
    const watch = manualWatch();
    const resets: SessionCatalogWatcherReset[] = [];
    const { sessions, catalog, source } = await fixture({
      watchCatalog: watch.backend,
      reconcileIntervalMs: 0,
      watchRetryMs: 30,
      onWatcherReset: (reset) => resets.push(reset),
    });
    watch.fail = true;
    catalog.start();
    await catalog.settled();
    // A root that is missing now (a fresh installation, a folder being moved
    // back) is not a crash and not a row: the index keeps serving what it has.
    expect(catalog.rows()).toEqual([]);
    expect(resets).toEqual([{ reason: "unavailable" }]);

    watch.fail = false;
    const walks = vi.spyOn(source, "scan");
    await waitFor(() => watch.requests.length === 1, 5_000);
    expect(resets).toHaveLength(1);
    // The attach is the first moment the folder can be read again, so the cut
    // that repairs everything the outage missed is read here and not earlier.
    await waitFor(() => walks.mock.calls.length >= 1, 5_000);
    const file = join(sessions, "workspace", "a.jsonl");
    await writeSession(file, "id-a", sessions, ["one"]);
    watch.emit("workspace/a.jsonl");
    await waitFor(() => catalog.row(file)?.id === "id-a", 5_000);
    await catalog.dispose();
  });

  it("re-derives the whole index for an event the platform could not name", async () => {
    const watch = manualWatch();
    const { sessions, catalog, source } = await fixture({
      watchCatalog: watch.backend, reconcileIntervalMs: 0,
    });
    catalog.start();
    await catalog.settled();
    const file = join(sessions, "workspace", "a.jsonl");
    await writeSession(file, "id-a", sessions, ["one"]);

    const walks = vi.spyOn(source, "scan");
    watch.emit(null);
    await waitFor(() => catalog.row(file)?.id === "id-a", 5_000);
    expect(walks).toHaveBeenCalledTimes(1);
  });

  it("ignores the paths discovery ignores and the files that are not transcripts", async () => {
    const watch = manualWatch();
    const { sessions, catalog, source } = await fixture({
      watchCatalog: watch.backend, reconcileIntervalMs: 0,
    });
    catalog.start();
    await catalog.settled();
    const artifact = join(sessions, "workspace", "subagent-artifacts", "diagnostic.jsonl");
    await writeSession(artifact, "id-artifact", sessions, ["ignored"]);
    // A scratch file the folder really holds: an event for it is not a row and
    // not a reason to re-read the folder.
    await writeFile(join(sessions, "workspace", "notes.txt"), "scratch\n");

    const reads = vi.spyOn(source, "summaryFor");
    const walks = vi.spyOn(source, "scan");
    watch.emit("workspace/subagent-artifacts/diagnostic.jsonl");
    watch.emit("workspace/notes.txt");
    await new Promise((resolve) => setTimeout(resolve, CATALOG_EVENT_DEBOUNCE_MS + 100));
    // The watcher arms no read for a path the walk would not call a session, and
    // no folder pass for a scratch file that is there.
    expect(catalog.rows()).toEqual([]);
    expect(reads).not.toHaveBeenCalled();
    expect(walks).not.toHaveBeenCalled();
    await catalog.dispose();
  });

  it("replaces a row when the file is replaced by a new inode", async () => {
    // The production watcher: an atomic rename delivers a file event.
    const { sessions, catalog } = await fixture({ reconcileIntervalMs: 0 });
    const file = join(sessions, "workspace", "a.jsonl");
    await writeSession(file, "id-a", sessions, ["one"]);
    catalog.start();
    await catalog.settled();
    const before = catalog.row(file)!;

    const replacement = join(sessions, "workspace", "replacement.jsonl");
    await writeSession(replacement, "id-a", sessions, ["one", "two", "three"]);
    await rename(replacement, file);
    await waitFor(() => catalog.row(file)?.messageCount === 3, 5_000);

    const after = catalog.row(file)!;
    expect(after.fileIdentity).not.toBe(before.fileIdentity);
    expect(after).toMatchObject({ messageCount: 3, firstMessage: "one", size: (await stat(file)).size });
    expect(after.eofOffset).toBe(after.size);
    // The path the replacement was renamed away from is not a row.
    expect(catalog.row(replacement)).toBeUndefined();
  });

  it("publishes a folder moved into the root and the folder an in-root move renamed", async () => {
    // The production watcher: moving a directory in gives the watcher one event
    // for the folder, and none for the transcript inside it.
    const { sessions, catalog } = await fixture({ reconcileIntervalMs: 0 });
    catalog.start();
    await catalog.settled();

    const staged = await mkdtemp(join(tmpdir(), "tron-session-catalog-moved-"));
    roots.push(staged);
    const project = join(staged, "proj");
    await writeSession(join(project, "moved.jsonl"), "id-moved", sessions, ["moved prompt"]);
    await rename(project, join(sessions, "proj"));
    await waitFor(() => catalog.row(join(sessions, "proj", "moved.jsonl"))?.id === "id-moved", 10_000);

    // A subagent run folder renamed inside the root: the folder event names both
    // the folder and its new name, so the transcript under the new one is read
    // and the path that no longer exists is not.
    const child = join(sessions, "parent", "producer", "run-1", "session.jsonl");
    await writeSession(child, "id-child", sessions, ["child prompt"]);
    await waitFor(() => catalog.row(child)?.id === "id-child", 10_000);
    const renamed = join(sessions, "parent", "producer", "run-2");
    await rename(dirname(child), renamed);
    const movedChild = join(renamed, "session.jsonl");
    await waitFor(() => catalog.row(movedChild)?.id === "id-child", 10_000);
    expect(catalog.row(child)).toBeUndefined();
    expect(catalog.row(movedChild)?.delegated).toBe(true);
    await catalog.dispose();
  });

  it("treats the root's own removal as one outage instead of an empty cut", async () => {
    const resets: SessionCatalogWatcherReset[] = [];
    const { sessions, catalog } = await fixture({
      reconcileIntervalMs: 0, watchRetryMs: 50, onWatcherReset: (reset) => resets.push(reset),
    });
    const file = join(sessions, "workspace", "a.jsonl");
    await writeSession(file, "id-a", sessions, ["one"]);
    catalog.start();
    await catalog.settled();
    expect(catalog.row(file)?.id).toBe("id-a");

    // The root itself is renamed away: the platform reports the root's own name
    // and no error, and an absent root proves no removal.
    const moved = `${sessions}-moved`;
    await rename(sessions, moved);
    await waitFor(() => resets.length === 1, 10_000);
    expect(resets).toEqual([{ reason: "unavailable" }]);
    expect(catalog.row(file)?.id).toBe("id-a");

    // Nothing is watched while the folder is elsewhere: the append below is not
    // published, and it is the cut that follows the re-attach that repairs it.
    await appendMessage(join(moved, "workspace", "a.jsonl"), "while unwatched", 1);
    await new Promise((resolve) => setTimeout(resolve, CATALOG_EVENT_DEBOUNCE_MS + 200));
    expect(catalog.row(file)?.messageCount).toBe(1);

    await rename(moved, sessions);
    await waitFor(() => catalog.row(file)?.messageCount === 2, 15_000);
    await catalog.dispose();
  });

  it("drops the row for a canonical file deleted outside the Gateway", async () => {
    const watch = manualWatch();
    const { sessions, catalog, index, source } = await fixture({
      watchCatalog: watch.backend, reconcileIntervalMs: 0,
    });
    const rolledBack = join(sessions, "workspace", "rolled-back.jsonl");
    const kept = join(sessions, "workspace", "kept.jsonl");
    await writeSession(rolledBack, "id-rolled-back", sessions, ["import candidate"]);
    await writeSession(kept, "id-kept", sessions, ["kept"]);
    catalog.start();
    await catalog.settled();
    expect(catalog.rows().map((row) => row.id).sort()).toEqual(["id-kept", "id-rolled-back"]);

    const reads = vi.spyOn(source, "summaryFor");
    const appends = vi.spyOn(index, "append");
    await rm(rolledBack);
    watch.emit("workspace/rolled-back.jsonl");
    await waitFor(() => catalog.row(rolledBack) === undefined, 5_000);
    await catalog.settled();

    // An absent path is not read at all: no tail read and no whole-file parse,
    // so a canonical file that is gone cannot be reported as a failure that a
    // rebuild would repair (there is nothing left to rebuild).
    expect(reads).not.toHaveBeenCalled();
    expect(appends).not.toHaveBeenCalled();
    expect(catalog.rows().map((row) => row.id)).toEqual(["id-kept"]);
    // The document is the index again: the row left it with the file.
    expect((await index.load(sessions))?.map((row) => row.id)).toEqual(["id-kept"]);
    await catalog.dispose();
  });

  it("keeps a row for a path it can see but cannot read", async () => {
    const watch = manualWatch();
    const { sessions, catalog } = await fixture({
      watchCatalog: watch.backend, reconcileIntervalMs: 0,
    });
    const directory = join(sessions, "workspace");
    const file = join(directory, "a.jsonl");
    await writeSession(file, "id-a", sessions, ["one"]);
    catalog.start();
    await catalog.settled();
    expect(catalog.row(file)?.id).toBe("id-a");

    // An unreadable path is not absence: it proves neither presence nor absence,
    // so the row the last good read published stays (G-1a's rule).
    await chmod(directory, 0o000);
    try {
      watch.emit("workspace/a.jsonl");
      await new Promise((resolve) => setTimeout(resolve, CATALOG_EVENT_DEBOUNCE_MS + 200));
      expect(catalog.row(file)?.id).toBe("id-a");
    } finally {
      await chmod(directory, 0o755);
    }
    await catalog.dispose();
  });

  it("publishes a child transcript that arrives before its parent", async () => {
    const watch = manualWatch();
    const { sessions, catalog } = await fixture({
      watchCatalog: watch.backend, reconcileIntervalMs: 0,
    });
    catalog.start();
    await catalog.settled();

    const child = join(sessions, "parent", "producer", "run-1", "session.jsonl");
    await writeSession(child, "id-child", sessions, ["child prompt"]);
    watch.emit("parent/producer/run-1/session.jsonl");
    await waitFor(() => catalog.row(child)?.id === "id-child", 5_000);
    expect(catalog.row(child)?.delegated).toBe(true);

    const parent = join(sessions, "parent.jsonl");
    await writeSession(parent, "id-parent", sessions, ["parent prompt"]);
    watch.emit("parent.jsonl");
    await waitFor(() => catalog.row(parent)?.id === "id-parent", 5_000);
    await catalog.settled();
    expect(catalog.rows().map((row) => row.id).sort()).toEqual(["id-child", "id-parent"]);
    expect(catalog.row(parent)?.delegated).toBe(false);
  });

  it("coalesces a burst of events into one read per path", async () => {
    const watch = manualWatch();
    const { sessions, catalog, source } = await fixture({
      watchCatalog: watch.backend, reconcileIntervalMs: 0,
    });
    catalog.start();
    await catalog.settled();

    const pathCount = 25;
    const eventsPerPath = 40;
    const paths = Array.from({ length: pathCount }, (_unused, ordinal) => join(sessions, "workspace", `${ordinal}.jsonl`));
    // Bounded batches: 25 concurrent writers would exhaust the process's
    // descriptor allowance before the watcher ever sees an event.
    for (let start = 0; start < pathCount; start += 25) {
      await Promise.all(paths.slice(start, start + 25)
        .map((path, offset) => writeSession(path, `id-${start + offset}`, sessions, ["one"])));
    }
    // Every path is written once and then reported `eventsPerPath` times: a
    // platform that reports create, write and close separately looks like this,
    // and each path must cost exactly one read.
    const realSummaryFor = source.summaryFor.bind(source);
    const reads = new Map<string, number>();
    const summary = vi.spyOn(source, "summaryFor").mockImplementation(async (path) => {
      reads.set(path, (reads.get(path) ?? 0) + 1);
      return realSummaryFor(path);
    });
    const walks = vi.spyOn(source, "scan");
    for (const path of paths) {
      for (let event = 0; event < eventsPerPath; event += 1) watch.emit(relative(sessions, path));
    }

    await waitFor(() => catalog.rows().length === pathCount, 30_000);
    await catalog.settled();
    summary.mockRestore();
    expect(walks).not.toHaveBeenCalled();
    expect(catalog.duplicateSessionIds().size).toBe(0);
    expect([...reads.keys()].sort()).toEqual([...paths].sort());
    expect([...reads.values()]).toEqual(Array.from({ length: pathCount }, () => 1));
  });

  it("re-reads a path whose events never stop arriving", async () => {
    const watch = manualWatch();
    const { sessions, catalog } = await fixture({
      watchCatalog: watch.backend, reconcileIntervalMs: 0,
    });
    const file = join(sessions, "workspace", "a.jsonl");
    await writeSession(file, "id-a", sessions, ["one"]);
    catalog.start();
    await catalog.settled();

    await appendMessage(file, "two", 1);
    const appendedAt = Date.now();
    // A writer that appends faster than the quiet spell re-arms the debounce on
    // every event; the ceiling is what reaches the row.
    const deadline = appendedAt + 4_000;
    while (Date.now() < deadline && catalog.row(file)?.messageCount !== 2) {
      watch.emit("workspace/a.jsonl");
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    expect(catalog.row(file)?.messageCount).toBe(2);
    expect(Date.now() - appendedAt).toBeLessThanOrEqual(CATALOG_EVENT_MAX_WAIT_MS + 500);
  });

  it("reports one catalog.changed per row the watcher changed, and how it was derived", async () => {
    const changes: SessionCatalogChange[] = [];
    const watch = manualWatch();
    const { sessions, catalog } = await fixture({
      watchCatalog: watch.backend,
      reconcileIntervalMs: 0,
      onChanged: (change) => changes.push(change),
    });
    const file = join(sessions, "workspace", "a.jsonl");
    await writeSession(file, "id-a", sessions, ["one"]);
    catalog.start();
    await catalog.settled();
    // A whole cut is a reconcile, not a single-row change.
    expect(changes).toEqual([]);

    await appendMessage(file, "two", 1);
    watch.emit("workspace/a.jsonl");
    await waitFor(() => changes.length === 1, 5_000);
    expect(changes[0]).toMatchObject({ sessionId: "id-a", outcome: "appended" });

    // The Gateway's own change at its commit point is not this record: it is
    // attributable to the commit that made it, and every persist of every
    // session would otherwise fill the debug buffer.
    await appendMessage(file, "three", 2);
    await catalog.refresh(file);
    await catalog.settled();
    expect(catalog.row(file)?.messageCount).toBe(3);
    expect(changes).toHaveLength(1);

    // An event for a file whose row did not change reports nothing.
    watch.emit("workspace/a.jsonl");
    await new Promise((resolve) => setTimeout(resolve, CATALOG_EVENT_DEBOUNCE_MS + 150));
    expect(changes).toHaveLength(1);

    // A replacement cannot be advanced from the old tail, so the row is rebuilt.
    const replacement = join(sessions, "workspace", "replacement.jsonl");
    await writeSession(replacement, "id-a", sessions, ["one", "two", "three"]);
    await rename(replacement, file);
    watch.emit("workspace/a.jsonl");
    await waitFor(() => changes.length === 2, 5_000);
    expect(changes[1]).toMatchObject({ sessionId: "id-a", outcome: "rebuilt" });

    // A deletion the Gateway did not announce is a removal of the row it
    // published, so the change stream says so instead of going quiet.
    await rm(file);
    watch.emit("workspace/a.jsonl");
    await waitFor(() => changes.length === 3, 5_000);
    expect(changes[2]).toMatchObject({ sessionId: "id-a", outcome: "removed" });
    expect(catalog.row(file)).toBeUndefined();
  });
});
