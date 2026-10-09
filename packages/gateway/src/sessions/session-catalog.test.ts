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
import { basename, dirname, join, relative } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { BackgroundWorkScheduler } from "../background-work.js";
import { RequestSpan, requestsCompetingForLoop, runInRequestSpan } from "../transport/request-span.js";
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
  CATALOG_EVENT_PENDING_PATH_LIMIT,
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
import { waitFor } from "../../test-support/wait-for.js";

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
// 22. A path that is gone and that no row was cut from (an atomic write's
//     temporary name, a scratch file, the Gateway's own quarantine rename): no
//     row and no whole-folder pass. A folder removed with its transcripts drops
//     its rows without a pass.
// 23. Unnameable events that never stop arriving: the whole-index pass still
//     runs once a second instead of the quiet spell being re-armed forever.
// 24. A burst of distinct transcript paths: pending watcher timers stay bounded
//     and overflow reconciles the canonical files.

const roots: string[] = [];
/** The scheduler each fixture's catalog registers its periodic reconcile with,
 * so a stopped test leaves no armed wake behind. */
const schedulers: BackgroundWorkScheduler[] = [];
const catalogs: SessionCatalog[] = [];

afterEach(async () => {
  // Dispose before removing the root: an owner whose slice or persist write is
  // still in flight would otherwise write into a directory being removed.
  for (const catalog of catalogs.splice(0)) await catalog.dispose();
  for (const scheduler of schedulers.splice(0)) scheduler.stop();
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

async function fixture(
  extra: Partial<SessionCatalogOptions> = {},
  requestsInFlight: () => boolean = () => false,
) {
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
  // G-9: the periodic reconcile is one of the scheduler's jobs. A test drives a
  // real scheduler with the loop and in-flight signals it wants to read.
  const scheduler = new BackgroundWorkScheduler();
  scheduler.start({ requestsInFlight, eventLoopP99Ms: () => 0 });
  schedulers.push(scheduler);
  const catalog = new SessionCatalog({
    catalogRoot: () => sessions, index, source, persistDebounceMs: 5, backgroundWork: scheduler,
    watchCatalog: manualWatch().backend, ...extra,
  });
  catalogs.push(catalog);
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

/** A folder watcher a test drives by hand: it delivers exactly the events the
 * test chose, so an event the platform would have dropped, a start failure and a
 * watcher that stops observing can each be reproduced. Every case that needs the
 * real backend explicitly selects the production watcher. The default-TMPDIR
 * macOS probe (#601) delivered relative file/directory names and the root's
 * basename identically through `/var` and `/private/var`; directory moves are
 * therefore injected as folder hints, not idealized per-transcript events.
 * Null models the platform's documented unnameable-event shape. */
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

  it("lets queued catalog refreshes yield while a request awaits a missing row", async () => {
    const state = { competing: false };
    const context = await fixture({}, () => state.competing);
    context.catalog.start();
    await context.catalog.settled();
    const file = join(context.sessions, "new-session.jsonl");
    await writeSession(file, "new-session", context.sessions, Array.from({ length: 600 }, (_, index) => `message-${index}`));

    void context.catalog.refresh(file);
    const span = new RequestSpan();
    await runInRequestSpan(span, async () => {
      state.competing = requestsCompetingForLoop();
      expect(state.competing).toBe(true);
      const [, identities] = await Promise.all([
        context.catalog.awaitQueuedChanges(),
        context.catalog.searchIdentities(),
      ]);
      expect(context.catalog.row(file)?.messageCount).toBe(600);
      expect(identities?.has("new-session")).toBe(true);
      span.breakdown(0);
    });
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

  it("publishes search identities only after a verified cut, and omits a duplicated ID", async () => {
    const { sessions, catalog } = await fixture();
    // No cut yet: a derived index must parse rather than reuse a durable row no
    // complete cut has re-verified against the folder.
    await expect(catalog.searchIdentities()).resolves.toBeUndefined();

    const written = join(sessions, "workspace", "a.jsonl");
    await writeSession(written, "id-a", sessions, ["first prompt"]);
    catalog.start();
    await catalog.settled();

    const facts = await stat(written);
    const identities = await catalog.searchIdentities();
    expect([...identities!.keys()]).toEqual(["id-a"]);
    expect(identities!.get("id-a")).toEqual({
      fileIdentity: `${facts.dev}:${facts.ino}`,
      size: facts.size,
      mtimeMs: facts.mtimeMs,
    });
    // An append the owner has not verified yet is not silently claimed: the
    // row's facts move with the file only once a pass proved them.
    await appendMessage(written, "second prompt", 1);
    await catalog.refresh(written);
    await catalog.settled();
    const appended = await stat(written);
    expect(await catalog.searchIdentities()).toEqual(new Map([["id-a", {
      fileIdentity: `${appended.dev}:${appended.ino}`,
      size: appended.size,
      mtimeMs: appended.mtimeMs,
    }]]));

    // A second file claiming the same ID is omitted: a reader must not resolve
    // it to either claimant.
    await writeSession(join(sessions, "other", "b.jsonl"), "id-a", sessions, ["two"]);
    await catalog.reconcile();
    await catalog.settled();
    expect((await catalog.searchIdentities())?.has("id-a")).toBe(false);
    // The watcher stops with the test, so no pass recreates the temp root while
    // the shared teardown removes it.
    await catalog.dispose();
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
    // Each parse stays parked until the test releases it. The first batch then
    // holds its 16 parses in flight for as long as the test needs, so the
    // dispose lands at a known batch boundary regardless of how late the test
    // observes the pass (a wall-clock parse delay raced the observer under load).
    const parses: string[] = [];
    let releaseParses!: () => void;
    const parseGate = new Promise<void>((resolve) => { releaseParses = resolve; });
    const summaryFor = vi.spyOn(source, "summaryFor").mockImplementation(async (path) => {
      parses.push(path);
      await parseGate;
      return realSummaryFor(path);
    });
    try {
      const restarted = new SessionCatalog({ catalogRoot: () => sessions, index, source });
      restarted.start();
      await waitFor(() => parses.length === 16, "the first batch to park its parses");
      // dispose() sets the shutdown flag before its first await, so the pass
      // sees it once the parked batch is released.
      const disposing = restarted.dispose();
      releaseParses();
      await disposing;
      // Exactly the parked batch (RECONCILE_CONCURRENCY candidates): a shutdown
      // that waited for the other three batches would parse all 64 files.
      expect(parses.length).toBe(16);
      // A stopped pass publishes nothing and owes no write, so the document the
      // next startup reads is the one the first owner left.
      expect(await readFile(indexPath, "utf8")).toBe(document);
    } finally {
      releaseParses();
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

  it("advances a row for an external append hint without walking the catalog", async () => {
    const watch = manualWatch();
    // No interval backstop: only the injected hint can publish this append.
    const { sessions, catalog, source } = await fixture({ watchCatalog: watch.backend, reconcileIntervalMs: 0 });
    const child = join(sessions, "parent", "producer", "run-1", "session.jsonl");
    await writeSession(join(sessions, "parent.jsonl"), "id-parent", sessions, ["parent prompt"]);
    await writeSession(child, "id-child", sessions, ["child prompt"]);
    catalog.start();
    await catalog.settled();
    expect(catalog.row(child)?.delegated).toBe(true);

    const walks = vi.spyOn(source, "scan");
    await appendMessage(child, "an external writer appended", 1);
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    try {
      watch.emit(relative(sessions, child));
      await vi.advanceTimersByTimeAsync(CATALOG_EVENT_DEBOUNCE_MS);
      await catalog.awaitQueuedChanges();
    } finally {
      vi.useRealTimers();
    }
    expect(catalog.row(child)?.messageCount).toBe(2);
    expect(walks).not.toHaveBeenCalled();
    await catalog.settled();
    expect(catalog.row(child)).toMatchObject({ messageCount: 2, size: (await stat(child)).size });
    expect(catalog.row(child)?.eofOffset).toBe((await stat(child)).size);
  });

  it("attaches the real watcher to the canonical root and repairs an external append", async () => {
    // Explicit undefined selects the production backend instead of the fixture's
    // default manual watcher. This is the only real-backend case in this file.
    const { sessions, catalog } = await fixture({ watchCatalog: undefined, reconcileIntervalMs: 0 });
    const file = join(sessions, "workspace", "a.jsonl");
    await writeSession(file, "id-a", sessions, ["one"]);
    // Observe the actual backend's registration, not FSEvents' delivery time.
    const backend = catalog as unknown as { watchCatalog: NonNullable<SessionCatalogOptions["watchCatalog"]> };
    const realWatch = backend.watchCatalog;
    const requests: SessionCatalogWatchRequest[] = [];
    backend.watchCatalog = (request) => {
      const handle = realWatch(request);
      requests.push(request);
      return handle;
    };
    catalog.start();
    await catalog.settled();
    expect(requests.map(({ root }) => root)).toEqual([sessions]);
    await appendMessage(file, "two", 2);
    // OS hints can be delayed or dropped. The owner's reconcile repairs either
    // case; the deterministic hint test above owns the no-walk requirement.
    await catalog.reconcile();
    await catalog.settled();
    expect(catalog.row(file)).toMatchObject({ messageCount: 2, size: (await stat(file)).size });
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
    // watcher-restarting event looks exactly like this. Observe the interval
    // before writing so a fast first pass cannot escape instrumentation.
    const walks = vi.spyOn(source, "scan");
    await appendMessage(file, "two", 2);
    await waitFor(() => catalog.row(file)?.messageCount === 2, "the file's second catalog message");
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
    await waitFor(() => watch.requests.length === 2, "the second watch request");
    expect(watch.closed[0]).toBe(true);
    expect(resets).toEqual([{ reason: "error" }]);
    await waitFor(() => walks.mock.calls.length >= 1, "a catalog walk");
    await catalog.settled();
    // Reads still come from the last good index, and the replacement watcher
    // sees the next external append.
    expect(catalog.row(file)?.messageCount).toBe(1);
    await appendMessage(file, "two", 1);
    watch.emit("workspace/a.jsonl");
    await waitFor(() => catalog.row(file)?.messageCount === 2, "the file's second catalog message");
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
    await waitFor(() => watch.requests.length === 1, "the first watch request");
    expect(resets).toHaveLength(1);
    // The attach is the first moment the folder can be read again, so the cut
    // that repairs everything the outage missed is read here and not earlier.
    await waitFor(() => walks.mock.calls.length >= 1, "a catalog walk");
    const file = join(sessions, "workspace", "a.jsonl");
    await writeSession(file, "id-a", sessions, ["one"]);
    watch.emit("workspace/a.jsonl");
    await waitFor(() => catalog.row(file)?.id === "id-a", "the file's catalog identity");
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
    await waitFor(() => catalog.row(file)?.id === "id-a", "the file's catalog identity");
    expect(walks).toHaveBeenCalledTimes(1);
  });

  it("re-derives the whole index once a second for unnameable events that never stop", async () => {
    const watch = manualWatch();
    const outcomes: SessionCatalogReconcileOutcome[] = [];
    const { sessions, catalog } = await fixture({
      watchCatalog: watch.backend, reconcileIntervalMs: 0,
      onReconciled: (outcome) => outcomes.push(outcome),
    });
    catalog.start();
    await catalog.settled();
    const before = outcomes.length;

    // A platform that keeps re-reporting an unnamed event every 100 ms re-arms
    // the quiet spell forever, so without a ceiling no pass would ever run.
    const ticker = setInterval(() => watch.emit(null), 100);
    try {
      await waitFor(() => outcomes.length > before, "the next reconcile outcome");
    } finally {
      clearInterval(ticker);
    }
    await catalog.dispose();
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
    const watch = manualWatch();
    const { sessions, catalog } = await fixture({ watchCatalog: watch.backend, reconcileIntervalMs: 0 });
    const file = join(sessions, "workspace", "a.jsonl");
    await writeSession(file, "id-a", sessions, ["one"]);
    catalog.start();
    await catalog.settled();
    const before = catalog.row(file)!;

    const replacement = join(sessions, "workspace", "replacement.jsonl");
    await writeSession(replacement, "id-a", sessions, ["one", "two", "three"]);
    await rename(replacement, file);
    watch.emit(relative(sessions, replacement));
    watch.emit(relative(sessions, file));
    await waitFor(() => catalog.row(file)?.messageCount === 3, "the file's third catalog message");

    const after = catalog.row(file)!;
    expect(after.fileIdentity).not.toBe(before.fileIdentity);
    expect(after).toMatchObject({ messageCount: 3, firstMessage: "one", size: (await stat(file)).size });
    expect(after.eofOffset).toBe(after.size);
    // The path the replacement was renamed away from is not a row.
    expect(catalog.row(replacement)).toBeUndefined();
  });

  it("publishes a folder moved into the root and the folder an in-root move renamed", async () => {
    // A directory move can name only the folder, not each transcript inside it.
    const watch = manualWatch();
    const { sessions, catalog } = await fixture({ watchCatalog: watch.backend, reconcileIntervalMs: 0 });
    catalog.start();
    await catalog.settled();

    const staged = await mkdtemp(join(tmpdir(), "tron-session-catalog-moved-"));
    roots.push(staged);
    const project = join(staged, "proj");
    await writeSession(join(project, "moved.jsonl"), "id-moved", sessions, ["moved prompt"]);
    await rename(project, join(sessions, "proj"));
    watch.emit("proj");
    await waitFor(() => catalog.row(join(sessions, "proj", "moved.jsonl"))?.id === "id-moved", "the moved file's catalog identity");

    // A subagent run folder renamed inside the root: the folder event names both
    // the folder and its new name, so the transcript under the new one is read
    // and the path that no longer exists is not.
    const child = join(sessions, "parent", "producer", "run-1", "session.jsonl");
    await writeSession(child, "id-child", sessions, ["child prompt"]);
    watch.emit(relative(sessions, dirname(child)));
    await waitFor(() => catalog.row(child)?.id === "id-child", "the child session's catalog row");
    const renamed = join(sessions, "parent", "producer", "run-2");
    await rename(dirname(child), renamed);
    watch.emit(relative(sessions, dirname(child)));
    watch.emit(relative(sessions, renamed));
    const movedChild = join(renamed, "session.jsonl");
    await waitFor(() => catalog.row(movedChild)?.id === "id-child", "the moved child's catalog identity");
    await waitFor(() => catalog.row(child) === undefined, "the old child path to leave the catalog");
    expect(catalog.row(movedChild)?.delegated).toBe(true);
    await catalog.dispose();
  });

  it("costs no whole-folder pass for a non-transcript name that is gone", async () => {
    // Real file operations: an atomic write's temporary name, a scratch file
    // created and deleted, and the Gateway's own quarantine rename and removal
    // all name a path no row was cut from. None is evidence about the folder,
    // so none may cost a structure walk.
    const watch = manualWatch();
    const { sessions, catalog, source } = await fixture({ watchCatalog: watch.backend, reconcileIntervalMs: 0 });
    const file = join(sessions, "workspace", "a.jsonl");
    await writeSession(file, "id-a", sessions, ["one"]);
    catalog.start();
    await catalog.settled();
    expect(catalog.row(file)?.id).toBe("id-a");

    const walks = vi.spyOn(source, "scan");
    const status = join(sessions, "workspace", "status.json");
    await writeFile(`${status}.tmp`, "{}");
    await rename(`${status}.tmp`, status);
    const scratch = join(sessions, "workspace", "scratch.txt");
    await writeFile(scratch, "x");
    await rm(scratch);
    watch.emit(relative(sessions, `${status}.tmp`));
    watch.emit(relative(sessions, status));
    watch.emit(relative(sessions, scratch));
    // The Gateway's own delete renames the transcript to a quarantine name and
    // then removes it; both names are non-transcript paths that are gone.
    const doomed = join(sessions, "workspace", "doomed.jsonl");
    await writeSession(doomed, "id-doomed", sessions, ["doomed"]);
    watch.emit(relative(sessions, doomed));
    await waitFor(() => catalog.row(doomed)?.id === "id-doomed", "the doomed file's catalog identity");
    const quarantine = `${doomed}.tron-delete-0f0f0f0f`;
    await rename(doomed, quarantine);
    await rm(quarantine);
    watch.emit(relative(sessions, doomed));
    watch.emit(relative(sessions, quarantine));
    await waitFor(() => catalog.row(doomed) === undefined, "the deleted row to leave the catalog");

    await appendMessage(file, "after", 1);
    watch.emit(relative(sessions, file));
    await waitFor(() => catalog.row(file)?.messageCount === 2, "the file's second catalog message");
    await catalog.settled();
    expect(walks).not.toHaveBeenCalled();
    expect(catalog.rows().map((row) => row.id)).toEqual(["id-a"]);
    await catalog.dispose();
  });

  it("drops the rows under a folder removed with its transcripts, without a whole-folder pass", async () => {
    // `rm -rf` of a subagent run folder can name the folder and its transcript.
    // The rows at or under the named path are the only rows that absence can
    // reach, so they are re-read and dropped without a walk.
    const watch = manualWatch();
    const { sessions, catalog, source } = await fixture({ watchCatalog: watch.backend, reconcileIntervalMs: 0 });
    const file = join(sessions, "workspace", "a.jsonl");
    await writeSession(file, "id-a", sessions, ["one"]);
    const child = join(sessions, "parent", "producer", "run-1", "session.jsonl");
    await writeSession(child, "id-child", sessions, ["child"]);
    catalog.start();
    await catalog.settled();
    expect(catalog.rows().map((row) => row.id).sort()).toEqual(["id-a", "id-child"]);

    const walks = vi.spyOn(source, "scan");
    await rm(dirname(dirname(child)), { recursive: true, force: true });
    watch.emit(relative(sessions, dirname(dirname(child))));
    watch.emit(relative(sessions, child));
    await waitFor(() => catalog.row(child) === undefined, "the removed folder's row to leave the catalog");
    await appendMessage(file, "after", 1);
    watch.emit(relative(sessions, file));
    await waitFor(() => catalog.row(file)?.messageCount === 2, "the file's second catalog message");
    await catalog.settled();
    expect(walks).not.toHaveBeenCalled();
    expect(catalog.rows().map((row) => row.id)).toEqual(["id-a"]);
    await catalog.dispose();
  });

  it("treats a folder removed while a named parent is walked as absence, without a whole-folder pass", async () => {
    // Linux reports the parent of an `rm -rf` while the removal is still in
    // progress, so the walk of that parent can list a folder that is gone by the
    // time it is read (#406). That folder is absent, not unreadable: its rows are
    // re-read and dropped instead of a whole-folder pass. The race is driven by
    // hand: each removal overlaps events naming the parent it empties.
    const watch = manualWatch();
    const { sessions, catalog, source } = await fixture({ watchCatalog: watch.backend, reconcileIntervalMs: 0 });
    const producers = Array.from({ length: 40 }, (_, attempt) => join(sessions, "parent", `producer-${attempt}`));
    for (const [attempt, producer] of producers.entries()) {
      await writeSession(join(producer, "run-1", "session.jsonl"), `id-child-${attempt}`, sessions, ["child"]);
      // Empty folders lengthen each removal, widening the window the walk races.
      for (let index = 0; index < 20; index += 1) await mkdir(join(producer, `empty-${index}`, "deep"), { recursive: true });
    }
    catalog.start();
    await catalog.settled();
    expect(catalog.rows()).toHaveLength(producers.length);

    const walks = vi.spyOn(source, "scan");
    const removals: Promise<void>[] = [];
    for (const producer of producers) {
      removals.push(rm(producer, { recursive: true, force: true }));
      for (let index = 0; index < 5; index += 1) {
        watch.emit("parent");
        await new Promise((resolve) => setImmediate(resolve));
      }
    }
    await Promise.all(removals);
    // The platform also names each removed folder once it is gone.
    for (const producer of producers) watch.emit(relative(sessions, producer));
    await waitFor(() => catalog.rows().length === 0, "the catalog to empty");
    // A whole-folder pass would follow the unnamed-event debounce.
    await new Promise((resolve) => setTimeout(resolve, CATALOG_EVENT_DEBOUNCE_MS + 200));
    await catalog.settled();
    expect(walks).not.toHaveBeenCalled();
    await catalog.dispose();
  });

  it("keeps its rows while the root itself is away, and a later cut republishes them", async () => {
    // A root move whose hint was dropped: no reconcile may publish a cut of
    // a folder that is not there. The adjacent case drives the root-name hint.
    const outcomes: SessionCatalogReconcileOutcome[] = [];
    const resets: SessionCatalogWatcherReset[] = [];
    const { sessions, catalog, index } = await fixture({
      reconcileIntervalMs: 100,
      watchRetryMs: 50,
      onWatcherReset: (reset) => resets.push(reset),
      onReconciled: (outcome) => outcomes.push(outcome),
    });
    const file = join(sessions, "workspace", "a.jsonl");
    await writeSession(file, "id-a", sessions, ["one"]);
    catalog.start();
    await catalog.settled();
    expect(catalog.row(file)?.id).toBe("id-a");

    const moved = `${sessions}-moved`;
    await rename(sessions, moved);
    await catalog.reconcile();
    await catalog.settled();
    expect(outcomes.at(-1)).toMatchObject({ outcome: "incomplete", added: 0, removed: 0 });
    expect(catalog.rows().map((row) => row.id)).toEqual(["id-a"]);
    expect((await index.load(sessions))?.map((row) => row.id)).toEqual(["id-a"]);
    expect(resets.every((reset) => reset.reason === "unavailable")).toBe(true);

    // Nothing watches a folder that is elsewhere, so the append is not a row
    // until a pass reads the folder again.
    await appendMessage(join(moved, "workspace", "a.jsonl"), "while unwatched", 1);
    await new Promise((resolve) => setTimeout(resolve, CATALOG_EVENT_DEBOUNCE_MS + 200));
    expect(catalog.row(file)?.messageCount).toBe(1);

    await rename(moved, sessions);
    await waitFor(() => catalog.row(file)?.messageCount === 2, "the file's second catalog message");
    await catalog.dispose();
  });

  it("records one outage for the root's own event when the folder is gone", async () => {
    // The event macOS delivers for the root's own move, on the injectable
    // backend that can emit it on demand: one outage, no cut of the missing
    // folder, and a replacement whose own cut repairs the gap.
    const watch = manualWatch();
    const resets: SessionCatalogWatcherReset[] = [];
    const { sessions, catalog, index } = await fixture({
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

    const moved = `${sessions}-moved`;
    await rename(sessions, moved);
    // The folder is gone, so the retry cannot attach to it either.
    watch.fail = true;
    const walks = vi.spyOn(catalog, "reconcile");
    watch.emit(basename(sessions));
    await waitFor(() => resets.length === 1, "the watcher reset");
    expect(resets).toEqual([{ reason: "unavailable" }]);
    // No cut ran for the event, and the row the folder proved stays published:
    // the file is not gone, the folder is.
    expect(walks).not.toHaveBeenCalled();
    expect(catalog.row(file)?.id).toBe("id-a");
    expect((await index.load(sessions))?.map((row) => row.id)).toEqual(["id-a"]);

    await appendMessage(join(moved, "workspace", "a.jsonl"), "while unwatched", 1);
    await rename(moved, sessions);
    watch.fail = false;
    await waitFor(() => watch.requests.length === 2, "the second watch request");
    // The replacement attaches to the folder that is back and its own cut is
    // what publishes the append the outage could not see.
    await waitFor(() => catalog.row(file)?.messageCount === 2, "the file's second catalog message");
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
    await waitFor(() => catalog.row(rolledBack) === undefined, "the rolled-back file to leave the catalog");
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
    await waitFor(() => catalog.row(child)?.id === "id-child", "the child session's catalog row");
    expect(catalog.row(child)?.delegated).toBe(true);

    const parent = join(sessions, "parent.jsonl");
    await writeSession(parent, "id-parent", sessions, ["parent prompt"]);
    watch.emit("parent.jsonl");
    await waitFor(() => catalog.row(parent)?.id === "id-parent", "the parent's catalog identity");
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
    await Promise.all(paths.map((path, ordinal) => writeSession(path, `id-${ordinal}`, sessions, ["one"])));
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

    await waitFor(() => catalog.rows().length === pathCount, "the catalog to reach every path");
    await catalog.settled();
    summary.mockRestore();
    expect(walks).not.toHaveBeenCalled();
    expect(catalog.duplicateSessionIds().size).toBe(0);
    expect([...reads.keys()].sort()).toEqual([...paths].sort());
    expect([...reads.values()]).toEqual(Array.from({ length: pathCount }, () => 1));
  });

  it("bounds overflow watcher events to one reconcile and the unnamed-event debounce", async () => {
    const watch = manualWatch();
    const outcomes: SessionCatalogReconcileOutcome[] = [];
    const { sessions, catalog, source } = await fixture({
      watchCatalog: watch.backend, reconcileIntervalMs: 0,
      onReconciled: (outcome) => outcomes.push(outcome),
    });
    catalog.start();
    await catalog.settled();
    const walks = vi.spyOn(source, "scan");
    const pathCount = CATALOG_EVENT_PENDING_PATH_LIMIT + 32;
    const paths = Array.from({ length: pathCount }, (_unused, index) => join(sessions, "workspace", `overflow-${index}.jsonl`));
    await Promise.all(paths.map((path, index) => writeSession(path, `overflow-${index}`, sessions, ["created"])));
    for (const path of paths) watch.emit(relative(sessions, path));

    await waitFor(() => catalog.rows().length === pathCount, "the catalog to reach every path");
    await catalog.settled();
    // Keep the watcher busy after the overflow pass has completed. An event storm
    // used to schedule another full scan for every event while a scan was active.
    // The storm window itself is the requirement here (the assertion counts the
    // scans one sustained storm may schedule), so this loop keeps an explicit
    // bound; it waits for no event that a host speed could delay.
    const end = Date.now() + 500;
    while (Date.now() < end) {
      watch.emit(relative(sessions, "workspace/live.jsonl"));
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    // At most one unnamed-event pass may follow the overflow pass during this
    // window; the old dirty loop scanned once per arriving event.
    expect(walks.mock.calls.length).toBeLessThanOrEqual(2);
    expect(outcomes.filter(({ trigger }) => trigger === "watcher-overflow")).toHaveLength(1);
    expect(catalog.duplicateSessionIds().size).toBe(0);
  });

  it("re-reads a path whose events never stop arriving", async () => {
    // The ceiling is measured on the catalog's own clock, which this test owns:
    // the oracle is that a row is re-read once its event window reaches the
    // ceiling even though events never stop. How long the read then takes in
    // wall time is host load, not the requirement (#406: 1.7–2.1 s under the
    // full suite against a 1.5 s wall bound).
    const watch = manualWatch();
    let catalogNow = Date.now();
    const { sessions, catalog } = await fixture({
      watchCatalog: watch.backend, reconcileIntervalMs: 0, now: () => catalogNow,
    });
    const file = join(sessions, "workspace", "a.jsonl");
    await writeSession(file, "id-a", sessions, ["one"]);
    catalog.start();
    await catalog.settled();

    await appendMessage(file, "two", 1);
    const windowStartedAt = catalogNow;
    // A writer that appends faster than the quiet spell re-arms the debounce on
    // every event; only the ceiling can reach the row. Each event advances the
    // catalog clock by one event gap until the window reaches the ceiling, so the
    // wait runs on the catalog's own clock and the shared hang bound only names a
    // ceiling that never released the row.
    await waitFor(async () => {
      catalogNow = Math.min(catalogNow + 50, windowStartedAt + CATALOG_EVENT_MAX_WAIT_MS);
      watch.emit("workspace/a.jsonl");
      await new Promise((resolve) => setTimeout(resolve, 50));
      return catalog.row(file)?.messageCount === 2;
    }, "the catalog clock ceiling to release the never-quiet row");
    expect(catalog.row(file)?.messageCount, "the ceiling never released the never-quiet path").toBe(2);
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
    await waitFor(() => changes.length === 1, "the first change record");
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
    await waitFor(() => changes.length === 2, "the second change record");
    expect(changes[1]).toMatchObject({ sessionId: "id-a", outcome: "rebuilt" });

    // A deletion the Gateway did not announce is a removal of the row it
    // published, so the change stream says so instead of going quiet.
    await rm(file);
    watch.emit("workspace/a.jsonl");
    await waitFor(() => changes.length === 3, "the third change record");
    expect(changes[2]).toMatchObject({ sessionId: "id-a", outcome: "removed" });
    expect(catalog.row(file)).toBeUndefined();
  });
});
