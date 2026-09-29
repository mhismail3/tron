#!/usr/bin/env node
// Regenerate the vendored model release dates the Gateway serves in `model.list`.
// This is a maintainer baseline refresh, not a runtime or build dependency.
// `scripts/update-model-release-dates.mjs [--check]`

import { readdir, readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { RELEASE_DATE_SOURCE, releaseDatesFromCatalog } from "../packages/gateway/src/providers/release-date-normalization.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const GATEWAY = join(ROOT, "packages/gateway");
const PI_DATA = join(GATEWAY, "node_modules/@earendil-works/pi-ai/dist/providers/data");
const ALIASES = join(GATEWAY, "src/providers/model-release-date-aliases.json");
const SNAPSHOT = join(GATEWAY, "src/providers/model-release-dates.json");

/** Provider ids the pinned catalog can serve. */
async function piProviders() {
  let files;
  try { files = await readdir(PI_DATA); }
  catch { throw new Error(`pinned Pi catalog data was not found at ${PI_DATA}; run npm ci in packages/gateway`); }
  const providers = new Set();
  for (const file of files) {
    if (!file.endsWith(".json") || file.startsWith(".")) continue;
    const source = JSON.parse(await readFile(join(PI_DATA, file), "utf8"));
    for (const models of Object.values(source)) for (const model of Object.values(models)) {
      if (typeof model?.provider === "string" && model.provider) providers.add(model.provider);
    }
  }
  return providers;
}

async function build() {
  const providers = await piProviders();
  const aliases = JSON.parse(await readFile(ALIASES, "utf8"));
  const response = await fetch(RELEASE_DATE_SOURCE, { signal: AbortSignal.timeout(60_000) });
  if (!response.ok) throw new Error(`models.dev responded ${response.status}`);
  const parsed = releaseDatesFromCatalog(await response.json(), providers, aliases);
  if (parsed.unknown.length) console.warn(`warning: unrecognized release_date shapes: ${parsed.unknown.join(", ")}`);
  const sorted = {};
  for (const key of Object.keys(parsed.dates).sort()) sorted[key] = parsed.dates[key];
  return { providers: parsed.providers, sorted };
}

const check = process.argv.includes("--check");
const { providers, sorted } = await build();
const encoded = `${JSON.stringify(sorted, null, 2)}\n`;
const current = await readFile(SNAPSHOT, "utf8").catch(() => undefined);
if (check) {
  if (current !== encoded) throw new Error(`${SNAPSHOT} is stale; run scripts/update-model-release-dates.mjs`);
} else await writeFile(SNAPSHOT, encoded, "utf8");
console.log(`${check ? "verified" : "wrote"} ${Object.keys(sorted).length} release dates across ${providers} providers from ${RELEASE_DATE_SOURCE}`);
