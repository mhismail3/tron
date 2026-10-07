import { mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { scanReservedHomeSession } from "./home-session-recovery.js";

const roots: string[] = [];
async function fixture() {
  const directory = await mkdtemp(join(tmpdir(), "tron-home-recovery-"));
  roots.push(directory);
  const expectedPath = join(directory, "reserved.jsonl");
  return { directory, expectedPath };
}
function valid(id: string) {
  return `${JSON.stringify({ type: "session", version: 3, id, timestamp: "2026-10-07T00:00:00.000Z", cwd: "/tmp" })}\n`;
}

afterEach(async () => {
  for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true });
});

describe("reserved Home session recovery scan", () => {
  it("proves absence only after a successful complete scan", async () => {
    const f = await fixture();
    await writeFile(join(f.directory, "other.jsonl"), valid("other"));
    await expect(scanReservedHomeSession({ directory: f.directory, expectedPath: f.expectedPath, sessionId: "reserved" }))
      .resolves.toEqual({ action: "absent" });
  });

  it.each([
    ["empty expected file", ""],
    ["partial header", '{"type":"session","version":3'],
    ["torn trailing line", `${valid("reserved")}{"type":"message"`],
    ["malformed complete line", `${valid("reserved")}not-json\n`],
  ])("blocks uncertain evidence: %s", async (_label, bytes) => {
    const f = await fixture();
    await writeFile(f.expectedPath, bytes);
    await expect(scanReservedHomeSession({ directory: f.directory, expectedPath: f.expectedPath, sessionId: "reserved" }))
      .resolves.toMatchObject({ action: "blocked" });
    await expect((await import("node:fs/promises")).readFile(f.expectedPath, "utf8")).resolves.toBe(bytes);
  });

  it("adopts only one complete matching file at the exact expected path", async () => {
    const f = await fixture();
    await writeFile(f.expectedPath, valid("reserved"));
    await expect(scanReservedHomeSession({ directory: f.directory, expectedPath: f.expectedPath, sessionId: "reserved" }))
      .resolves.toEqual({ action: "adopt", path: f.expectedPath });
  });

  it("blocks duplicate IDs, path mismatch and an uninspectable directory entry", async () => {
    const f = await fixture();
    await writeFile(f.expectedPath, valid("reserved"));
    const duplicate = join(f.directory, "duplicate.jsonl");
    await writeFile(duplicate, valid("reserved"));
    await expect(scanReservedHomeSession({ directory: f.directory, expectedPath: f.expectedPath, sessionId: "reserved" }))
      .resolves.toMatchObject({ action: "blocked" });
    await rm(duplicate);
    await rm(f.expectedPath);
    await writeFile(f.expectedPath, valid("other"));
    await expect(scanReservedHomeSession({ directory: f.directory, expectedPath: f.expectedPath, sessionId: "reserved" }))
      .resolves.toMatchObject({ action: "blocked" });
    await rm(f.expectedPath);
    const link = join(f.directory, "link.jsonl");
    await symlink(f.expectedPath, link);
    await expect(scanReservedHomeSession({ directory: f.directory, expectedPath: f.expectedPath, sessionId: "reserved" }))
      .resolves.toMatchObject({ action: "blocked" });
  });

  it("blocks enumeration errors instead of proving absence", async () => {
    const f = await fixture();
    await rm(f.directory, { recursive: true });
    await expect(scanReservedHomeSession({ directory: f.directory, expectedPath: f.expectedPath, sessionId: "reserved" }))
      .resolves.toMatchObject({ action: "blocked" });
  });

  it.each([
    ["an empty JSON object", "{}"],
    ["a message without a canonical entry type", JSON.stringify({ type: "message" })],
    ["an unsupported canonical entry type", JSON.stringify({ type: "future-entry-v99", id: "x" })],
  ])("blocks a complete file whose transcript contains %s", async (_label, entry) => {
    const f = await fixture();
    const bytes = `${valid("reserved")}${entry}\n`;
    await writeFile(f.expectedPath, bytes);
    await expect(scanReservedHomeSession({ directory: f.directory, expectedPath: f.expectedPath, sessionId: "reserved" }))
      .resolves.toMatchObject({ action: "blocked" });
    await expect((await import("node:fs/promises")).readFile(f.expectedPath, "utf8")).resolves.toBe(bytes);
  });
});
