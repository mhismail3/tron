import { createHash } from "node:crypto";
import { join } from "node:path";
import type { CatalogMetadataIndexRow } from "../src/sessions/catalog-metadata-index.js";

const WORDS = ["catalog", "gateway", "session", "shard", "manifest", "review", "worker", "settle", "verify", "report",
  "branch", "merge", "fixture", "boundary", "durable", "rename", "restart", "migrate", "bounded", "signal"];

function preview(seed: number, bytes: number): string {
  const words: string[] = [];
  let length = 0;
  for (let index = 0; length < bytes; index += 1) {
    const word = WORDS[(seed * 7 + index * 13) % WORDS.length]!;
    words.push(word);
    length += word.length + 1;
  }
  return words.join(" ").slice(0, bytes);
}

export function realisticCatalogRow(root: string, index: number, variant = 0): CatalogMetadataIndexRow {
  const workspace = "--Users-example-Workspace-project--";
  const stamp = `2026-10-${String(1 + (index % 28)).padStart(2, "0")}T${String(index % 24).padStart(2, "0")}-00-00-000Z`;
  const id = createHash("sha256").update(`session-${index}`).digest("hex").slice(0, 32)
    .replace(/^(.{8})(.{4})(.{4})(.{4})(.{12})$/u, "$1-$2-$3-$4-$5");
  const stem = join(root, workspace, `${stamp}_${id}`);
  const delegated = index % 7 !== 0;
  const path = delegated ? join(stem, "subagent", `run-${index % 5}`, "session.jsonl") : `${stem}.jsonl`;
  const size = 20_000 + index * 31 + variant;
  return {
    id,
    path,
    cwd: "/Users/example/Workspace/project",
    ...(delegated ? { parentSessionPath: `${stem}.jsonl` } : {}),
    ...(index % 3 === 0 ? { name: `Worker ${index}: ${preview(index, 40)}` } : {}),
    firstMessage: preview(index + variant, 930),
    createdAt: new Date(Date.UTC(2026, 9, 1) + index * 60_000).toISOString(),
    updatedAt: new Date(Date.UTC(2026, 9, 1) + index * 60_000 + variant * 1_000).toISOString(),
    messageCount: 10 + (index % 90) + variant,
    fileIdentity: `16777232:${100_000 + index}`,
    size,
    mtimeMs: Date.UTC(2026, 9, 1) + index * 60_000 + variant,
    eofOffset: size,
    tailBoundaryHash: createHash("sha256").update(`${index}:${variant}`).digest("base64url"),
  };
}

export function realisticCatalogRows(root: string, count: number, variant = 0): CatalogMetadataIndexRow[] {
  return Array.from({ length: count }, (_, index) => realisticCatalogRow(root, index, variant));
}

export function sortedCatalogRows(rows: readonly CatalogMetadataIndexRow[] | undefined): string[] | undefined {
  return rows?.map((row) => JSON.stringify(row)).sort();
}
