// Hash proof block inputs and the mutation checker's parsed JavaScript programs.

import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { join } from "node:path";

const { parseSync } = await import(createRequire(new URL("../../../packages/gateway/package.json", import.meta.url)).resolve("rolldown/utils"));

export function blockFiles(root, cfg) {
  const { interface: laws } = JSON.parse(readFileSync(join(root, "blocks", cfg.block, "block.json"), "utf8"));
  return [...new Set([...laws, cfg.impl, ...cfg.verify, ...(cfg.lawContext ?? [])])].sort();
}

export function blockHash(root, cfg) {
  const h = createHash("sha256");
  h.update(JSON.stringify(cfg));
  for (const f of blockFiles(root, cfg)) h.update(`\0${f}\0`).update(readFileSync(join(root, f)));
  return h.digest("hex").slice(0, 16);
}

export function toolHash() {
  const h = createHash("sha256");
  for (const f of ["../mutate/mutate.mjs", "./hash.mjs"]) {
    const { program, errors } = parseSync(f, readFileSync(new URL(f, import.meta.url), "utf8"));
    if (errors.length) throw new Error(`invalid mutation checker ${f}: ${JSON.stringify(errors)}`);
    h.update(JSON.stringify(program, (key, value) => key === "start" || key === "end" ? undefined : value));
  }
  return h.digest("hex").slice(0, 16);
}
