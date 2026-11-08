// The block hash: one digest over everything a gate result depends on, so any edit to a law, its
// English, a definition, the implementation, the tier or the mutation config makes every recorded gate
// result (review, mutation report, shadow) STALE. Used by packet.mjs and mutate.mjs.
// Paths are relative to the core root (packages/core); the block's laws are its block.json interface files.
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";

// Every source file a gate reads: the block's laws (block.json interface), impl, verify targets and law context.
export function blockFiles(root, cfg) {
  const { interface: laws } = JSON.parse(readFileSync(join(root, "blocks", cfg.block, "block.json"), "utf8"));
  return [...new Set([...laws, cfg.impl, ...cfg.verify, ...(cfg.lawContext ?? [])])].sort();
}

export function blockHash(root, cfg) {
  const h = createHash("sha256");
  // The whole mutate.json (oracles, shadow command, report path, helpers... everything a gate reads).
  h.update(JSON.stringify(cfg));
  for (const f of blockFiles(root, cfg)) h.update(`\0${f}\0`).update(readFileSync(join(root, f)));
  return h.digest("hex").slice(0, 16);
}

// The mutation checker's identity: its own source plus this hashing module (a change to either can change
// what a report means, so older reports show STALE).
export function toolHash() {
  const h = createHash("sha256");
  for (const f of ["../mutate/mutate.mjs", "./hash.mjs"]) h.update(readFileSync(new URL(f, import.meta.url)));
  return h.digest("hex").slice(0, 16);
}
