// The block hash: one digest over everything a gate result depends on, so any edit to a law, its
// English, a definition, the implementation, the tier or the mutation config makes every recorded gate
// result (review, mutation report, shadow) STALE. Used by packet.mjs, mutate.mjs and shadow.mjs.
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";
export function blockHash(dir, cfg) {
  const files = [...new Set([cfg.impl, ...cfg.verify, ...(cfg.lawContext ?? [])])].sort();
  const h = createHash("sha256");
  // The whole mutate.json (oracles, shadow command, report path, helpers... everything a gate reads).
  h.update(JSON.stringify(cfg));
  for (const f of files) h.update(`\0${f}\0`).update(readFileSync(join(dir, f)));
  return h.digest("hex").slice(0, 16);
}

// The mutation checker's identity: its own source plus this hashing module (a change to either can change
// what a report means, so older reports show STALE).
export function toolHash() {
  const h = createHash("sha256");
  for (const f of ["../mutate/mutate.mjs", "./hash.mjs"]) h.update(readFileSync(new URL(f, import.meta.url)));
  return h.digest("hex").slice(0, 16);
}
