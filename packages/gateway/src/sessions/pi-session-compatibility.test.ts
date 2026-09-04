import { copyFile, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { afterEach, describe, expect, it } from "vitest";

const roots: string[] = [];
const fixtureRoot = join(dirname(fileURLToPath(import.meta.url)), "../../test-fixtures/pi-sdk");

afterEach(async () => { await Promise.all(roots.splice(0).map((path) => rm(path, { recursive: true, force: true }))); });

describe("Pi session compatibility fixtures", () => {
  it("lets Pi migrate v1/v2 disposable copies and leaves v3 byte-identical", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-pi-session-fixtures-")); roots.push(root);
    const contexts: string[][] = [];
    for (const version of ["v1", "v2", "v3"]) {
      const target = join(root, `${version}.jsonl`); await copyFile(join(fixtureRoot, `${version}.jsonl`), target);
      const before = await readFile(target, "utf8"); const manager = SessionManager.open(target, root); const after = await readFile(target, "utf8");
      const entries = manager.getEntries();
      expect(entries.length).toBeGreaterThan(1); expect(manager.getHeader()?.version).toBe(3);
      expect(manager.buildSessionContext().messages.map((message) => message.role)).toContain("user");
      contexts.push(manager.buildSessionContext().messages.map((message) => JSON.stringify({ role: message.role, content: message.content, summary: "summary" in message ? message.summary : undefined, tokensBefore: "tokensBefore" in message ? message.tokensBefore : undefined })));
      if (version === "v3") expect(after).toBe(before); else expect(after).not.toBe(before);
      if (version === "v1") {
        expect(entries.filter((entry) => entry.type !== "session").every((entry) => typeof entry.id === "string" && entry.parentId !== undefined)).toBe(true);
        expect(entries.find((entry) => entry.type === "compaction")).toMatchObject({ firstKeptEntryId: expect.any(String) });
      }
      if (version === "v1" || version === "v2") expect(entries.find((entry) => entry.type === "message" && entry.message.role === "custom")).toBeTruthy();
    }
    expect(contexts[0]).toEqual(contexts[2]); expect(contexts[1]).toEqual(contexts[2]);
  });
});
