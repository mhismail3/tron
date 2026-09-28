import { existsSync } from "node:fs";
import { mkdir, mkdtemp, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  CatalogDiscovery,
  DEFAULT_CATALOG_DISCOVERY_LIMITS,
  buildCatalogSessionInfo,
  type CatalogSessionInfo,
} from "./catalog-discovery.js";
import { CatalogMetadataIndex, type CatalogMetadataIndexSummary } from "./catalog-metadata-index.js";
import { SessionCatalog, type SessionCatalogSource } from "./session-catalog.js";

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

async function fixture() {
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
      const info = await buildCatalogSessionInfo(path);
      return info ? summaryFor(info) : undefined;
    },
  };
  const catalog = new SessionCatalog({ catalogRoot: () => sessions, index, source, persistDebounceMs: 5 });
  return {
    root,
    // macOS temp roots are reached through a symlink; the walk canonicalizes it,
    // so the test works in the same path form the index publishes.
    sessions: await realpath(sessions),
    state,
    index,
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
    const { sessions, state, index, catalog, indexPath } = await fixture();
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

    // A corrupt document is equally unusable.
    await writeFile(indexPath, "{ not a catalog document");
    expect(await index.load(sessions)).toBeUndefined();
    const restarted = new SessionCatalog({
      catalogRoot: () => sessions,
      index,
      source: {
        scan: async () => ({ complete: true, candidates: [] }),
        summaryFor: async () => undefined,
      },
    });
    expect(restarted.rows()).toEqual([]);
    await restarted.dispose();
  });
});
