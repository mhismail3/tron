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

  it.each([
    ["self cycle", [{ id: "a", parentId: "a" }]],
    ["two-entry cycle", [{ id: "a", parentId: "b" }, { id: "b", parentId: "a" }]],
    ["duplicate entry ID", [{ id: "a", parentId: null }, { id: "a", parentId: "a" }]],
    ["missing parent", [{ id: "a", parentId: "missing" }]],
    ["second root", [{ id: "a", parentId: null }, { id: "b", parentId: null }]],
    ["branch", [{ id: "a", parentId: null }, { id: "b", parentId: "a" }, { id: "c", parentId: "a" }]],
  ])("blocks a non-linear canonical chain: %s", async (_label, topology) => {
    const f = await fixture();
    const bytes = valid("reserved") + topology.map(entry => JSON.stringify({
      type: "thinking_level_change", timestamp: "2026-10-07T00:00:00.000Z", thinkingLevel: "off", ...entry,
    }) + "\n").join("");
    await writeFile(f.expectedPath, bytes);
    await expect(scanReservedHomeSession({ ...f, sessionId: "reserved" })).resolves.toEqual({ action: "blocked" });
    await expect((await import("node:fs/promises")).readFile(f.expectedPath, "utf8")).resolves.toBe(bytes);
  });

  it.each([
    ["missing role", {}],
    ["missing content", { role: "user", timestamp: 1 }],
    ["malformed text", { role: "user", timestamp: 1, content: [{ type: "text", text: {} }] }],
    ["unsupported role", { role: "future", timestamp: 1, content: "text" }],
    ["incomplete assistant", { role: "assistant", timestamp: 1, content: [] }],
    ["malformed tool result", { role: "toolResult", timestamp: 1, content: [], isError: "false" }],
  ])("blocks an insufficiently validated message: %s", async (_label, message) => {
    const f = await fixture();
    const bytes = valid("reserved") + JSON.stringify({ type: "message", id: "a", parentId: null,
      timestamp: "2026-10-07T00:00:00.000Z", message }) + "\n";
    await writeFile(f.expectedPath, bytes);
    await expect(scanReservedHomeSession({ ...f, sessionId: "reserved" })).resolves.toEqual({ action: "blocked" });
    await expect((await import("node:fs/promises")).readFile(f.expectedPath, "utf8")).resolves.toBe(bytes);
  });

  it.each([
    ["invalid entry timestamp", { type: "custom", customType: "data", timestamp: "invalid" }],
    ["empty ID", { type: "custom", customType: "data", id: "" }],
    ["invalid session metadata", { type: "session_info", name: {} }],
    ["invalid context edit", { type: "context_edit", targetId: "prior", replacement: {} }],
    ["unknown label target", { type: "label", targetId: "absent" }],
    ["invalid usage", { type: "usage", kind: "cache_warm", provider: "fixture", model: "chat", usage: {} }],
    ["invalid custom content", { type: "custom_message", customType: "note", content: {}, display: true }],
  ])("blocks an insufficiently validated entry: %s", async (_label, entry) => {
    const f = await fixture();
    const bytes = valid("reserved") + JSON.stringify({ type: "custom", customType: "data", id: "prior",
      parentId: null, timestamp: "2026-10-07T00:00:00.000Z" }) + "\n"
      + JSON.stringify({ id: "next", parentId: "prior", timestamp: "2026-10-07T00:00:00.000Z", ...entry }) + "\n";
    await writeFile(f.expectedPath, bytes);
    await expect(scanReservedHomeSession({ ...f, sessionId: "reserved" })).resolves.toEqual({ action: "blocked" });
  });

  it.each([
    { type: "session", version: 3, id: "reserved" },
    { type: "session", version: 3, id: "reserved", cwd: "/tmp", timestamp: "invalid" },
    { type: "session", version: 3, id: "reserved", cwd: {}, timestamp: "2026-10-07T00:00:00.000Z" },
  ])("blocks an incomplete canonical header %j", async header => {
    const f = await fixture();
    await writeFile(f.expectedPath, JSON.stringify(header) + "\n");
    await expect(scanReservedHomeSession({ ...f, sessionId: "reserved" })).resolves.toEqual({ action: "blocked" });
  });

  it("accepts a complete linear canonical chain", async () => {
    const f = await fixture();
    await writeFile(f.expectedPath, valid("reserved") + [
      { type: "thinking_level_change", id: "a", parentId: null, thinkingLevel: "off" },
      { type: "message", id: "b", parentId: "a", message: { role: "user", content: "hello", timestamp: 1 } },
      { type: "custom", id: "c", parentId: "b", customType: "receipt", data: { outcome: "settled" } },
    ].map(entry => JSON.stringify({ timestamp: "2026-10-07T00:00:00.000Z", ...entry }) + "\n").join(""));
    await expect(scanReservedHomeSession({ ...f, sessionId: "reserved" }))
      .resolves.toEqual({ action: "adopt", path: f.expectedPath });
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
