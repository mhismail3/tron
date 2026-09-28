import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { statSync, truncateSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { SessionSearchIndex, type SearchIndexDocument } from "./session-search-index.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });

function document(): SearchIndexDocument {
  return {
    sessionId: "session-1", title: "Search fixture", cwd: "/tmp/project", updatedAt: "2025-01-01T00:00:00Z", fileIdentity: "file-1", branchDigest: "branch-1",
    entries: [{ id: "entry-1", parentId: null, timestamp: "2025-01-01T00:00:00Z", role: "user", text: "The violet comet is a semantic fixture", ordinal: 0 }],
  };
}

const STAMP = { fileIdentity: "file-1", size: 4_096, mtimeMs: 1_759_000_000_123.5 };

/** Enough postings that one document's insert spans several write slices, so a
 * second writer can be issued while the first is still inside its transaction. */
function bulkDocument(sessionId: string): SearchIndexDocument {
  const text = Array.from({ length: 60 }, (_, index) => `word-${index % 17}`).join(" ");
  return {
    sessionId, title: "Lane fixture", cwd: "/tmp/project", updatedAt: "2025-01-01T00:00:00Z", fileIdentity: "file-1", branchDigest: "branch-1",
    entries: Array.from({ length: 200 }, (_, index) => ({
      id: `entry-${index}`, parentId: index === 0 ? null : `entry-${index - 1}`, timestamp: "2025-01-01T00:00:00Z", role: "user" as const, text, ordinal: index,
    })),
  };
}

describe("SessionSearchIndex", () => {
  it("discards an unreadable index file before constructing a fresh capability", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-search-corrupt-")); roots.push(root);
    const path = join(root, "index.sqlite");
    await writeFile(path, Buffer.from("not a sqlite database"));
    const index = await SessionSearchIndex.open(path);
    expect(index.stats()).toMatchObject({ state: "complete", sessionsIndexed: 0, passagesIndexed: 0, indexRevision: "empty" });
    expect(index.candidates("violet", 10)).toEqual([]);
    // The recreated file is owner-only like the one it replaced.
    expect(statSync(path).mode & 0o777).toBe(0o600);
    index.close();
  });

  it("keeps a populated index across a reopen and reports the facts it indexed", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-search-reopen-")); roots.push(root);
    const path = join(root, "index.sqlite");
    const stamp = { fileIdentity: "file-1", size: 4_096, mtimeMs: 1_759_000_000_123.5 };
    const original = await SessionSearchIndex.open(path);
    await original.replace(document(), stamp);
    // Negative control: the row's candidate and reuse key both survive a reopen.
    expect(original.candidates("violet", 10)).toHaveLength(1);
    const revision = original.stats().indexRevision;
    original.close();

    const reopened = await SessionSearchIndex.open(path);
    expect(reopened.stats()).toMatchObject({ state: "complete", sessionsIndexed: 1, passagesIndexed: 1, indexRevision: revision });
    expect(reopened.candidates("violet", 10)).toHaveLength(1);
    expect(reopened.sessionFacts()).toEqual([
      { sessionId: "session-1", fileIdentity: "file-1", branchDigest: "branch-1", reuse: stamp },
    ]);
    reopened.close();
  });

  it("reports an unstamped row as unreusable instead of trusting it", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-search-unstamped-")); roots.push(root);
    const path = join(root, "index.sqlite");
    const index = await SessionSearchIndex.open(path);
    await index.replace(document());
    expect(index.sessionFacts()).toEqual([
      { sessionId: "session-1", fileIdentity: "file-1", branchDigest: "branch-1", reuse: null },
    ]);
    index.close();
  });

  it("discards an index whose persisted rows this build cannot read", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-search-schema-")); roots.push(root);
    const path = join(root, "index.sqlite");
    const stale = new DatabaseSync(path);
    stale.exec("CREATE TABLE sessions (session_id TEXT PRIMARY KEY, title TEXT NOT NULL, cwd TEXT NOT NULL, updated_at TEXT NOT NULL, file_identity TEXT NOT NULL, branch_digest TEXT NOT NULL, leaf_entry_id TEXT, fork_boundary TEXT) WITHOUT ROWID;");
    stale.prepare("INSERT INTO sessions VALUES ('session-1','old','/tmp','2025-01-01T00:00:00Z','file-1','branch-1',NULL,NULL)").run();
    stale.close();

    const index = await SessionSearchIndex.open(path);
    expect(index.stats()).toMatchObject({ sessionsIndexed: 0, indexRevision: "empty" });
    expect(index.sessionFacts()).toEqual([]);
    await index.replace(document(), { fileIdentity: "file-1", size: 1, mtimeMs: 1 });
    expect(index.candidates("violet", 10)).toHaveLength(1);
    index.close();
  });

  it("returns bounded postings candidates without storing canonical body text", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-search-")); roots.push(root);
    const index = await SessionSearchIndex.open(join(root, "index.sqlite"));
    await index.replace(document());
    const results = index.candidates("violet comet", 10);
    expect(results).toHaveLength(1);
    expect(results[0]?.entryId).toBe("entry-1");
    expect(index.stats().passagesIndexed).toBe(1);
    expect(index.stats().bytes).toBe(statSync(join(root, "index.sqlite")).size);
    index.close();
  });

  it("recreates an oversized index file so later small replacements recover", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-search-overflow-")); roots.push(root);
    const path = join(root, "index.sqlite");
    const index = await SessionSearchIndex.open(path, { maxStorageBytes: 65_536 });
    truncateSync(path, statSync(path).size + 65_536);
    await expect(index.replace(document())).rejects.toThrow(/storage bound exceeded/iu);
    expect(index.stats().passagesIndexed).toBe(0);
    await index.replace(document());
    expect(index.candidates("violet", 10)).toHaveLength(1);
    expect(index.stats().state).toBe("complete");
    index.close();
  });

  it("deletes rows before rekey replacement", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-search-")); roots.push(root);
    const index = await SessionSearchIndex.open(join(root, "index.sqlite"));
    await index.replace(document());
    await index.remove("session-1");
    expect(index.candidates("violet", 10)).toEqual([]);
    index.close();
  });

  it("serializes writers that overlap one transaction instead of joining it", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-search-lane-")); roots.push(root);
    const index = await SessionSearchIndex.open(join(root, "index.sqlite"));
    await index.replace(bulkDocument("session-1"), STAMP);
    await index.replace(bulkDocument("session-2"), STAMP);
    // A rekey clears the dirty set while a search's refresh is mid-replace, so a
    // second search starts its own replace and a remove can land in between.
    // Each of these is issued while the one before it is still running.
    await Promise.all([
      index.replace(bulkDocument("session-1"), STAMP),
      index.replace(bulkDocument("session-2"), STAMP),
      index.remove("session-2"),
    ]);
    expect(index.stats()).toMatchObject({ sessionsIndexed: 1, passagesIndexed: 200 });
    const candidates = index.candidates("violet", 10);
    expect(candidates.map(candidate => candidate.sessionId)).toEqual(Array.from({ length: 10 }, () => "session-1"));
    expect(index.sessionFacts().map(facts => facts.sessionId)).toEqual(["session-1"]);
    index.close();
  });
});
