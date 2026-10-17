import { appendFile, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it } from "vitest";
import { buildCatalogSessionInfo } from "./catalog-discovery.js";
import { CatalogMetadataIndex } from "./catalog-metadata-index.js";

it("refuses oversized catalog rows on cold scans and cached appends, then recovers from repaired JSONL", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-catalog-jsonl-"));
  const path = join(root, "session.jsonl");
  const time = "2026-01-01T00:00:00.000Z";
  const header = JSON.stringify({ type: "session", version: 3, id: "catalog-line-bound", cwd: root, timestamp: time }) + "\n";
  const failures: string[] = [];
  const reportFailure = (stage: string) => { failures.push(stage); };
  const index = new CatalogMetadataIndex(join(root, "gateway"), reportFailure);
  try {
    await writeFile(path, header);
    const row = await index.entryFromSummary({ id: "catalog-line-bound", cwd: root, path,
      firstMessage: "(no messages)", createdAt: time, updatedAt: time, messageCount: 0 });
    expect(row).toBeDefined();
    // A valid JSON row above the catalog's 64 MiB line budget. Write bounded
    // pieces so this regression never needs a V8-sized string or host pressure.
    await appendFile(path, '{"type":"message","message":{"role":"user","content":"');
    const chunk = Buffer.alloc(1_048_576, "x");
    for (let part = 0; part < 65; part += 1) await appendFile(path, chunk);
    await appendFile(path, '"}}\n');
    expect.soft(await buildCatalogSessionInfo(path, undefined, reportFailure)).toBeNull();
    expect.soft(await index.append(row!)).toBeUndefined();
    expect(failures).toEqual(["line-limit", "line-limit"]);

    await writeFile(path, header + JSON.stringify({ type: "message", message: { role: "user", content: "repaired 😀", timestamp: Date.parse(time) } }) + "\n");
    expect(await buildCatalogSessionInfo(path)).toMatchObject({ messageCount: 1, firstMessage: "repaired 😀" });
  } finally {
    await index.dispose();
    await rm(root, { recursive: true, force: true });
  }
});

it("preserves UTF-8, CRLF, chunk-spanning lines and final unterminated catalog rows", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-catalog-jsonl-"));
  const path = join(root, "session.jsonl");
  try {
    const header = JSON.stringify({ type: "session", version: 3, id: "catalog-text", cwd: root, timestamp: "2026-01-01T00:00:00.000Z" });
    const first = JSON.stringify({ type: "message", message: { role: "user", content: "😀漢字".repeat(20_000) } });
    await writeFile(path, header + "\r\n" + first + "\r\n" + JSON.stringify({ type: "session_info", name: "final 😀 title" }));
    const info = await buildCatalogSessionInfo(path);
    expect(info).toMatchObject({ id: "catalog-text", messageCount: 1, name: "final 😀 title" });
    expect(info?.firstMessage).not.toContain("\uFFFD");
    expect(info?.firstMessage.startsWith("😀漢字")).toBe(true);
  } finally { await rm(root, { recursive: true, force: true }); }
});
