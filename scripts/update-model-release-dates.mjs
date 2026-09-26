#!/usr/bin/env node
// Regenerate the vendored model release dates the Gateway serves in `model.list`.
//
// Manual maintainer step, not a build or runtime dependency: models.dev publishes
// `release_date`, but the pinned Pi catalog drops it, so Tron snapshots the few
// facts it needs instead of trusting the network while serving a request.
//
//   scripts/update-model-release-dates.mjs [--check]
//
// The snapshot covers exactly the providers the pinned Pi SDK can serve, plus the
// alias targets in packages/gateway/src/providers/model-release-date-aliases.json
// that platforms such as OpenAI Codex and the Vercel AI Gateway re-export. A Pi
// catalog update therefore needs a refresh; read the pinned SDK data directory
// instead of assuming a provider list.
//
// `--check` writes nothing and fails when the checked-in snapshot is stale, for
// use before a release.

import { readdir, readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const GATEWAY = join(ROOT, "packages/gateway");
const PI_DATA = join(GATEWAY, "node_modules/@earendil-works/pi-ai/dist/providers/data");
const ALIASES = join(GATEWAY, "src/providers/model-release-date-aliases.json");
const SNAPSHOT = join(GATEWAY, "src/providers/model-release-dates.json");
const SOURCE = "https://models.dev/api.json";
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const MONTH = /^\d{4}-\d{2}$/;

/** Provider ids the pinned Pi catalog can serve. */
async function piProviders() {
  let files;
  try {
    files = await readdir(PI_DATA);
  } catch {
    throw new Error(`pinned Pi catalog data was not found at ${PI_DATA}; run npm ci in packages/gateway`);
  }
  const providers = new Set();
  for (const file of files) {
    if (!file.endsWith(".json") || file.startsWith(".")) continue;
    const catalog = JSON.parse(await readFile(join(PI_DATA, file), "utf8"));
    for (const models of Object.values(catalog)) {
      for (const model of Object.values(models)) {
        if (typeof model?.provider === "string" && model.provider) providers.add(model.provider);
      }
    }
  }
  return providers;
}

/** Month-precision releases pin to the first of the month, never dropped. */
function normalize(value) {
  if (typeof value !== "string") return undefined;
  if (DAY.test(value)) return value;
  return MONTH.test(value) ? `${value}-01` : undefined;
}

async function build() {
  const providers = await piProviders();
  const aliases = JSON.parse(await readFile(ALIASES, "utf8"));
  for (const target of Object.values(aliases)) providers.add(target);

  const response = await fetch(SOURCE, { signal: AbortSignal.timeout(60_000) });
  if (!response.ok) throw new Error(`models.dev responded ${response.status}`);
  const catalog = await response.json();

  const dates = {};
  const unknown = [];
  for (const provider of providers) {
    for (const [id, model] of Object.entries(catalog[provider]?.models ?? {})) {
      const release = model?.release_date;
      if (release === undefined || release === null) continue;
      const normalized = normalize(release);
      if (normalized === undefined) {
        if (unknown.length < 3) unknown.push(`${provider}/${id}=${release}`);
        continue;
      }
      dates[`${provider}/${id}`] = normalized;
    }
  }
  if (unknown.length > 0) console.warn(`warning: unrecognized release_date shapes: ${unknown.join(", ")}`);
  const sorted = {};
  for (const key of Object.keys(dates).sort()) sorted[key] = dates[key];
  return { providers: providers.size, sorted };
}

const check = process.argv.includes("--check");
const { providers, sorted } = await build();
const encoded = `${JSON.stringify(sorted, null, 2)}\n`;
const current = await readFile(SNAPSHOT, "utf8").catch(() => undefined);
if (check) {
  if (current !== encoded) throw new Error(`${SNAPSHOT} is stale; run scripts/update-model-release-dates.mjs`);
} else {
  await writeFile(SNAPSHOT, encoded, "utf8");
}
console.log(`${check ? "verified" : "wrote"} ${Object.keys(sorted).length} release dates across ${providers} providers from ${SOURCE}`);
