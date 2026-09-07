import { mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { SessionManager, parseSessionEntries, type FileEntry, type SessionEntry } from "@earendil-works/pi-coding-agent";
import { describe, expect, it } from "vitest";
import { resolveForkBoundaryAnchor } from "./fork-boundary.js";
import { branchFromParsedSession } from "./session-branch.js";
import { projectTranscriptPage } from "./projection.js";
import { BlobStore } from "./blob-store.js";

const timestamp = "2026-01-01T00:00:00.000Z";
const message = (id: string, parentId: string | null, content = id) => ({
  type: "message", id, parentId, timestamp, message: { role: "user", content, timestamp: 0 },
});
const label = (id: string, parentId: string) => ({ type: "label", id, parentId, timestamp, targetId: "root", label: "checkpoint" });
function file(id: string, entries: unknown[]): FileEntry[] {
  return parseSessionEntries([
    { type: "session", id, version: 3, timestamp, cwd: "/tmp/fork-fixture", ...(id !== "parent" ? { parentSession: "/tmp/parent.jsonl" } : {}) },
    ...entries,
  ].map(entry => JSON.stringify(entry)).join("\n"));
}
function page(child: FileEntry[], parent: FileEntry[], before?: number, budget?: number) {
  const branch = branchFromParsedSession(child)!.branch;
  return projectTranscriptPage({ getBranch: () => branch }, new BlobStore(), before, budget,
    undefined, undefined, undefined, undefined, undefined,
    resolveForkBoundaryAnchor(child, parent, "subagentFork"));
}

describe("canonical fork boundaries", () => {
  it("uses full parent ancestry despite parent branch changes; skips regenerated labels and hidden child entries", () => {
    const parent = file("parent", [message("root", null), label("source-label", "root"), message("shared", "source-label"), message("other-branch", "root")]);
    const child = file("child", [message("root", null), message("shared", "root"), label("new-label", "shared"),
      { type: "custom", customType: "private-state", id: "hidden", parentId: "new-label", timestamp }, message("task", "hidden")]);
    expect(page(child, parent).forkBoundary).toEqual({ kind: "subagentFork", inheritedAnchorId: "shared", gapOrdinal: 2 });
  });

  it("pruned/sanitized payloads retain their inherited identity and never move the fork into parent history", () => {
    const parent = file("parent", [message("root", null, "Original large prompt"), message("shared", "root")]);
    const child = file("child", [message("root", null, "Pruned inherited summary"), message("shared", "root"), message("task", "shared")]);
    expect(page(child, parent).forkBoundary).toEqual({ kind: "subagentFork", inheritedAnchorId: "shared", gapOrdinal: 2 });
    expect(page(file("child", [message("root", null, "Pruned inherited summary")]), parent).forkBoundary).toEqual({
      kind: "subagentFork", inheritedAnchorId: "root", gapOrdinal: 1,
    });
  });

  it("retains one anchor before first child append without another parent read", () => {
    const parent = file("parent", [message("root", null)]);
    const child = file("child", [message("root", null)]);
    const anchor = resolveForkBoundaryAnchor(child, parent, "sessionFork");
    const branch = branchFromParsedSession(child)!.branch;
    const project = () => projectTranscriptPage({ getBranch: () => branch }, new BlobStore(), undefined, undefined,
      undefined, undefined, undefined, undefined, undefined, anchor);
    expect(project().forkBoundary).toEqual({ kind: "sessionFork", inheritedAnchorId: "root", gapOrdinal: 1 });
    const boundary = project().forkBoundary;
    branch.push(message("task", "root") as SessionEntry);
    expect(project().forkBoundary).toEqual(boundary);
  });

  it("annotates a proven hidden-only inherited tail at gap zero", () => {
    const hidden = (id: string, parentId: string | null) => ({
      type: "custom", customType: "private-state", id, parentId, timestamp,
    });
    const parent = file("parent", [hidden("hidden-root", null)]);
    const child = file("child", [hidden("hidden-root", null)]);
    expect(page(child, parent).forkBoundary).toEqual({
      kind: "subagentFork", inheritedAnchorId: "hidden-root", gapOrdinal: 0,
    });
    expect(page(child, parent).total).toBe(0);
  });

  it("keeps exact counts and page anchors across a boundary outside the initial page", () => {
    const parent = file("parent", [message("root", null)]);
    const child = file("child", [message("root", null), message("task", "root"), message("tail", "task")]);
    const tail = page(child, parent, undefined, 1);
    const earlier = page(child, parent, tail.start, 1);
    expect(tail.items.map(item => item.id)).toEqual(["tail"]);
    expect(earlier.items.map(item => item.id)).toEqual(["task"]);
    expect([tail.total, earlier.total, earlier.nextEntryId]).toEqual([3, 3, "tail"]);
    expect(earlier.forkBoundary).toEqual(tail.forkBoundary);
  });

  it("requires inherited context, not just a parentSession header", () => {
    const parent = file("parent", [message("root", null)]);
    expect(resolveForkBoundaryAnchor(file("child", [message("fresh", null)]), parent, "subagentFork")).toBeUndefined();
    expect(resolveForkBoundaryAnchor(file("child", []), parent, "sessionFork")).toBeUndefined();
    expect(resolveForkBoundaryAnchor(parent, parent, "sessionFork")).toBeUndefined();
  });

  it.each([
    [message("root", null), message("root", null)],
    [message("root", null), message("bad", "missing")],
    [message("root", null), message("a", "b"), message("b", "a"), message("task", "root")],
    [message("root", null), message("task", "root"), message("shared", "task")],
    [message("root", null), message("shared", "root")],
  ])("rejects duplicate, missing, cyclic, grafted, or conflicting ancestry", (...entries) => {
    const parent = file("parent", [message("root", null), message("middle", "root"), message("shared", "middle")]);
    expect(resolveForkBoundaryAnchor(file("child", entries), parent, "sessionFork")).toBeUndefined();
  });

  it("uses the runtime-selected leaf instead of the last file entry", () => {
    const parent = file("parent", [message("root", null), message("shared", "root")]);
    const child = file("child", [message("root", null), message("shared", "root"), message("task", "shared")]);
    expect(resolveForkBoundaryAnchor(child, parent, "sessionFork", "root")).toEqual({ kind: "sessionFork", inheritedEntryId: "root" });
    expect(resolveForkBoundaryAnchor(child, parent, "sessionFork", null)).toBeUndefined();
  });

  it("matches actual SDK copied IDs, labels, nested forks and compaction without modifying SDK behavior", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-fork-sdk-test-"));
    try {
      const parent = SessionManager.create(root, root);
      const inherited = parent.appendMessage({ role: "user", content: "context", timestamp: 0 });
      parent.appendMessage({ role: "assistant", content: [{ type: "text", text: "reply" }], api: "openai-responses", provider: "test", model: "test", stopReason: "stop", timestamp: 1,
        usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } });
      parent.appendLabelChange(inherited, "checkpoint");
      const shared = parent.getLeafId()!;
      const child = SessionManager.open(parent.getSessionFile()!, root);
      child.createBranchedSession(shared);
      const task = child.appendMessage({ role: "user", content: "child task", timestamp: 2 });
      const entries = (manager: SessionManager): FileEntry[] => [manager.getHeader()!, ...manager.getEntries()];
      const beforeNextPrompt = page(entries(child), entries(parent)).forkBoundary;
      child.appendMessage({ role: "user", content: "next child prompt", timestamp: 3 });
      expect(page(entries(child), entries(parent)).forkBoundary).toEqual(beforeNextPrompt);
      child.appendCompaction("summary", task, 100);
      const childEntries = entries(child);
      const parentIDs = new Set(entries(parent).map(entry => entry.id));
      const inheritedAnchor = childEntries.slice(1)
        .filter(entry => entry.type !== "label" && parentIDs.has(entry.id)).at(-1)!.id;
      expect(page(childEntries, entries(parent)).forkBoundary).toEqual({
        kind: "subagentFork", inheritedAnchorId: inheritedAnchor, gapOrdinal: 2,
      });
      const nested = SessionManager.open(child.getSessionFile()!, root);
      nested.createBranchedSession(task);
      const nestedTask = nested.appendMessage({ role: "user", content: "nested task", timestamp: 3 });
      expect(page(entries(nested), entries(child)).forkBoundary).toEqual({
        kind: "subagentFork", inheritedAnchorId: task, gapOrdinal: 3,
      });
    } finally { await rm(root, { recursive: true, force: true }); }
  });
});
