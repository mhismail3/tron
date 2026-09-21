import { describe, expect, it } from "vitest";
import type { FileEntry } from "@earendil-works/pi-coding-agent";
import { extractSearchText, excerpt, terms, validateSearchBranch } from "./session-search-text.js";

describe("session search canonical text", () => {
  it("validates the complete graph before selecting the active leaf", () => {
    const file = [
      { type: "session", id: "s", cwd: "/tmp", timestamp: "2025-01-01T00:00:00Z" },
      { type: "message", id: "a", parentId: null, timestamp: "2025-01-01T00:00:01Z", message: { role: "user", content: "root" } },
      { type: "message", id: "b", parentId: "a", timestamp: "2025-01-01T00:00:02Z", message: { role: "assistant", content: "answer" } },
    ] as unknown as FileEntry[];
    const branch = validateSearchBranch(file);
    expect(branch.entries.map(entry => entry.id)).toEqual(["a", "b"]);
  });

  it("rejects a disconnected malformed record instead of indexing a valid-looking branch", () => {
    const file = [
      { type: "session", id: "s" },
      { type: "message", id: "a", parentId: null, timestamp: "2025-01-01T00:00:01Z", message: { role: "user", content: "root" } },
      { type: "message", id: "orphan", parentId: "missing", timestamp: "2025-01-01T00:00:02Z", message: { role: "assistant", content: "hidden" } },
    ] as unknown as FileEntry[];
    expect(() => validateSearchBranch(file)).toThrow("missing parent");
  });

  it("keeps user and assistant text while excluding tool/thinking content", () => {
    const user = { type: "message", id: "u", parentId: null, timestamp: "now", message: { role: "user", content: "needle" } } as unknown as Parameters<typeof extractSearchText>[0];
    const tool = { type: "message", id: "t", parentId: "u", timestamp: "now", message: { role: "toolResult", content: "needle" } } as unknown as Parameters<typeof extractSearchText>[0];
    expect(extractSearchText(user, 0)?.text).toBe("needle");
    expect(extractSearchText(tool, 1)).toBeUndefined();
  });

  it("uses deterministic excerpts and tokenization", () => {
    expect(excerpt("prefix needle suffix", "needle", 14)).toContain("needle");
    expect(terms("Path/to File path/to")).toEqual(["path", "to", "file"]);
  });
});
