import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { statSync, truncateSync } from "node:fs";
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

describe("SessionSearchIndex", () => {
  it("rebuilds a corrupt disposable index while preserving an honest empty capability", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-search-corrupt-")); roots.push(root);
    const path = join(root, "index.sqlite");
    await writeFile(path, Buffer.from("not a sqlite database"));
    const index = await SessionSearchIndex.open(path);
    expect(index.stats()).toMatchObject({ state: "complete", sessionsIndexed: 0, passagesIndexed: 0, indexRevision: "empty" });
    expect(index.candidates("violet", 10)).toEqual([]);
    index.close();
  });

  it("returns bounded postings candidates without storing canonical body text", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-search-")); roots.push(root);
    const index = await SessionSearchIndex.open(join(root, "index.sqlite"));
    index.replace(document());
    const results = index.candidates("violet comet", 10);
    expect(results).toHaveLength(1);
    expect(results[0]?.entryId).toBe("entry-1");
    expect(index.stats().passagesIndexed).toBe(1);
    expect(index.stats().bytes).toBe(statSync(join(root, "index.sqlite")).size);
    index.close();
  });

  it("recreates an oversized disposable file so later small replacements recover", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-search-overflow-")); roots.push(root);
    const path = join(root, "index.sqlite");
    const index = await SessionSearchIndex.open(path, { maxStorageBytes: 65_536 });
    truncateSync(path, statSync(path).size + 65_536);
    expect(() => index.replace(document())).toThrow(/storage bound exceeded/iu);
    expect(index.stats().passagesIndexed).toBe(0);
    index.replace(document());
    expect(index.candidates("violet", 10)).toHaveLength(1);
    expect(index.stats().state).toBe("complete");
    index.close();
  });

  it("deletes rows before rekey replacement", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-search-")); roots.push(root);
    const index = await SessionSearchIndex.open(join(root, "index.sqlite"));
    index.replace(document());
    index.remove("session-1");
    expect(index.candidates("violet", 10)).toEqual([]);
    index.close();
  });
});
