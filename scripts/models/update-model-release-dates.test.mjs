// Proves scripts/models/update-model-release-dates.mjs end to end over a copy of the repository
// paths it reads: the providers come from the pinned Pi catalog, models.dev is answered by a
// fetch stand-in, and the snapshot it writes is what --check later accepts or calls stale.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "../..");
const SCRIPT = "scripts/models/update-model-release-dates.mjs";
const PROVIDERS = "packages/gateway/src/providers";
const CATALOG = {
  openai: { models: { "gpt-b": { release_date: "2025-03" }, "gpt-a": { release_date: "2025-01-15" }, odd: { release_date: "soon" } } },
  anthropic: { models: { claude: { release_date: "2024-06-20" } } },
  unserved: { models: { other: { release_date: "2024-01-01" } } },
};

function fixture() {
  const root = mkdtempSync(join(tmpdir(), "tron-release-dates-"));
  mkdirSync(join(root, "scripts/models"), { recursive: true });
  cpSync(join(ROOT, SCRIPT), join(root, SCRIPT));
  mkdirSync(join(root, PROVIDERS), { recursive: true });
  cpSync(join(ROOT, PROVIDERS, "release-date-normalization.mjs"), join(root, PROVIDERS, "release-date-normalization.mjs"));
  writeFileSync(join(root, PROVIDERS, "model-release-date-aliases.json"), JSON.stringify({ "openai-codex": "openai" }));
  const data = join(root, "packages/gateway/node_modules/@earendil-works/pi-ai/dist/providers/data");
  mkdirSync(data, { recursive: true });
  writeFileSync(join(data, "catalog.json"), JSON.stringify({ a: { m1: { provider: "anthropic" } }, b: { m2: { provider: "openai-codex" } } }));
  writeFileSync(join(root, "catalog.json"), JSON.stringify(CATALOG));
  // The script's only network read, answered from the fixture catalog.
  writeFileSync(join(root, "fetch.mjs"), `import { readFileSync } from "node:fs";
globalThis.fetch = async () => new Response(readFileSync(${JSON.stringify(join(root, "catalog.json"))}, "utf8"));\n`);
  const run = (...args) => spawnSync(process.execPath, ["--import", join(root, "fetch.mjs"), join(root, SCRIPT), ...args], { encoding: "utf8" });
  return { root, run, snapshot: join(root, PROVIDERS, "model-release-dates.json"), data };
}

test("the refresh writes the served providers' dates, sorted, and --check accepts only that snapshot", () => {
  const { root, run, snapshot } = fixture();
  try {
    const wrote = run();
    assert.equal(wrote.status, 0, wrote.stderr);
    assert.match(wrote.stdout, /wrote 3 release dates across 3 providers from https:\/\/models\.dev\/api\.json/u);
    assert.match(wrote.stderr, /unrecognized release_date shapes: openai\/odd/u);
    assert.equal(readFileSync(snapshot, "utf8"),
      `${JSON.stringify({ "anthropic/claude": "2024-06-20", "openai/gpt-a": "2025-01-15", "openai/gpt-b": "2025-03-01" }, null, 2)}\n`);
    const checked = run("--check");
    assert.equal(checked.status, 0, checked.stderr);
    assert.match(checked.stdout, /^verified 3 release dates/u);
    writeFileSync(snapshot, "{}\n");
    const stale = run("--check");
    assert.notEqual(stale.status, 0);
    assert.match(stale.stderr, /model-release-dates\.json is stale; run scripts\/models\/update-model-release-dates\.mjs/u);
    assert.equal(readFileSync(snapshot, "utf8"), "{}\n", "--check never writes");
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("without the pinned Pi catalog the refresh says to install the Gateway dependencies", () => {
  const { root, run, snapshot, data } = fixture();
  try {
    rmSync(data, { recursive: true });
    const result = run();
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /pinned Pi catalog data was not found at .*; run npm ci in packages\/gateway/u);
    assert.throws(() => readFileSync(snapshot), /ENOENT/u);
  } finally { rmSync(root, { recursive: true, force: true }); }
});
