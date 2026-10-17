import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir, userInfo } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { fileURLToPath } from "node:url";

// Real Node process: the child imports the actual test-support preflight before any
// code runs. Paths are inert strings; the child only reads environment names, and
// nothing is opened at the account home. The HOME override reproduces an isolated
// test shell that inherited a live-home path from the original user's account.
const preflight = new URL("../test-support/tron-home-environment-preflight.mjs", import.meta.url).href;
const accountHome = userInfo().homedir;
const root = await mkdtemp(join(tmpdir(), "tron-home-preflight-"));
after(() => rm(root, { recursive: true, force: true }));

const isolatedHome = join(root, "home");
const probedNames = ["PATH", "PI_CODING_AGENT_DIR", "PI_SESSION_FILE", "JITI_ALIAS", "PI_SUBAGENTS_TEMP_ROOT", "TRON_GATEWAY_PAYLOAD_ROOT", "TRON_DATA_DIR", "TRON_HOME_NAME"];

function runChild(inherited) {
  const env = { PATH: process.env.PATH ?? "", HOME: isolatedHome, TMPDIR: join(root, "tmp"), ...inherited };
  return spawnSync(process.execPath, [
    "--import", preflight, "--input-type=module", "-e",
    `process.stdout.write(JSON.stringify(${JSON.stringify(probedNames)}.filter(name => name in process.env)));`,
  ], { env, encoding: "utf8", timeout: 20_000 });
}

test("removes inherited live-home variables recognized from the account home when HOME is isolated", () => {
  const result = runChild({
    PI_CODING_AGENT_DIR: join(accountHome, ".tron", "__inert_marker"),
    PI_SESSION_FILE: join(accountHome, ".tron-dev", "sessions", "inert.jsonl"),
    JITI_ALIAS: JSON.stringify({ "@tron-inert": `${accountHome}/.tron/extensions/inert` }),
    // Whole-path boundary: a sibling of the live home is a fixture, not a live home.
    TRON_GATEWAY_PAYLOAD_ROOT: join(accountHome, ".tron-fixture-sibling", "payload"),
    PI_SUBAGENTS_TEMP_ROOT: join(isolatedHome, "fixtures", "subagents"),
  });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), ["PATH", "PI_SUBAGENTS_TEMP_ROOT", "TRON_GATEWAY_PAYLOAD_ROOT"]);

  // Literal shorthand still belongs to the supplied HOME; recognizing the
  // account's absolute paths must not change the existing shorthand rule.
  const shorthand = runChild({ PI_SESSION_FILE: "~/.tron-dev/sessions/inert.jsonl" });
  assert.equal(shorthand.status, 0, shorthand.stderr);
  assert.deepEqual(JSON.parse(shorthand.stdout), ["PATH"]);
});

test("diagnoses an inherited live-home path using only the variable name", () => {
  const result = spawnSync(process.execPath, [fileURLToPath(new URL("../src/tron-home-environment-policy.mjs", import.meta.url))], {
    env: { PATH: process.env.PATH ?? "", HOME: isolatedHome, PI_CODING_AGENT_DIR: join(accountHome, ".tron", "__inert_marker") },
    encoding: "utf8", timeout: 20_000,
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, "PI_CODING_AGENT_DIR\n");
});

test("still refuses home selectors that resolve into a live home", () => {
  const dataDir = runChild({ TRON_DATA_DIR: join(accountHome, ".tron") });
  assert.notEqual(dataDir.status, 0);
  assert.match(dataDir.stderr, /refuse inherited Tron-home selectors: TRON_DATA_DIR=/u);

  const homeName = runChild({ TRON_HOME_NAME: ".tron-dev" });
  assert.notEqual(homeName.status, 0);
  assert.match(homeName.stderr, /refuse inherited Tron-home selectors: TRON_HOME_NAME=/u);
});
