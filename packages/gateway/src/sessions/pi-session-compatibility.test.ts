/**
 * Pi's migration of pre-v3 session formats.
 *
 * The persisted-state upgrade corpus (`test-fixtures/pi-sdk/corpus/`) owns
 * canonical state: what the Gateway writes today, reopened by the installed SDK.
 * It cannot own this: the Gateway only ever writes the current format, so an SDK
 * that stopped reading v1/v2 would leave an existing user's old session
 * unreadable with no corpus case to catch it. `v1.jsonl` and `v2.jsonl` are the
 * two legacy shapes — the implicit parent chain with `firstKeptEntryIndex`, and
 * explicit tree ids with the legacy `hookMessage` role — and both must migrate to
 * the current format and still produce the same model context.
 *
 * The v3 fixture is gone: the corpus's own sessions are v3, and its reopen test
 * asserts they are read byte-identically.
 */
import { copyFile, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { afterEach, describe, expect, it } from "vitest";

const roots: string[] = [];
const fixtureRoot = join(dirname(fileURLToPath(import.meta.url)), "../../test-fixtures/pi-sdk");

afterEach(async () => { await Promise.all(roots.splice(0).map((path) => rm(path, { recursive: true, force: true }))); });

/** The model context one legacy fixture produces, with volatile fields removed. */
function context(messages: Array<{ role: string; content?: unknown }>): string[] {
  return messages.map((message) => JSON.stringify({
    role: message.role,
    content: message.content,
    summary: "summary" in message ? (message as { summary?: unknown }).summary : undefined,
    tokensBefore: "tokensBefore" in message ? (message as { tokensBefore?: unknown }).tokensBefore : undefined,
  }));
}

describe("legacy Pi session formats", () => {
  it("migrates v1 and v2 copies to the current format with the same model context", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-pi-session-fixtures-"));
    roots.push(root);
    const contexts: string[][] = [];
    for (const version of ["v1", "v2"]) {
      const target = join(root, `${version}.jsonl`);
      await copyFile(join(fixtureRoot, `${version}.jsonl`), target);
      const before = await readFile(target, "utf8");
      const manager = SessionManager.open(target, root);
      const after = await readFile(target, "utf8");
      const entries = manager.getEntries();
      expect(entries.length, `${version}: entries must survive the migration`).toBeGreaterThan(1);
      expect(manager.getHeader()?.version, `${version}: the file must migrate to the current format`).toBe(3);
      expect(manager.buildSessionContext().messages.map((message) => message.role), `${version}: the user turn must stay in context`)
        .toContain("user");
      contexts.push(context(manager.buildSessionContext().messages));
      expect(after, `${version}: a legacy file is migrated on open`).not.toBe(before);
      // The legacy `hookMessage` role becomes a canonical custom message, and the
      // implicit parent chain becomes explicit ids on the current branch.
      expect(entries.find((entry) => entry.type === "message" && entry.message.role === "custom"),
        `${version}: the legacy hook message must become a canonical custom message`).toBeTruthy();
      expect(entries.filter((entry) => entry.type !== "session")
        .every((entry) => typeof entry.id === "string" && entry.parentId !== undefined),
      `${version}: every migrated entry must carry tree identity`).toBe(true);
      expect(entries.find((entry) => entry.type === "compaction"))
        .toMatchObject({ firstKeptEntryId: expect.any(String) });
    }
    expect(contexts[0], "both legacy formats must produce the same model context").toEqual(contexts[1]);
  });
});
