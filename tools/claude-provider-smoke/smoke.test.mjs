// Runs the offline probe of scripts/tron provider-smoke against the Gateway's pinned Pi.
import { spawnSync } from "node:child_process";
import { strict as assert } from "node:assert";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { newerOrEqual } from "./smoke.mjs";

const SMOKE = fileURLToPath(new URL("./smoke.mjs", import.meta.url));
const run = (...args) => spawnSync(process.execPath, [SMOKE, "--probe-only", "--json", ...args], { encoding: "utf8" });

test("reports the Claude Code version Pi sends and Fable 5.2's status, and gates on them", () => {
  const plain = run();
  const { probe } = JSON.parse(plain.stdout);
  assert.match(probe.piAi, /^\d+\.\d+\.\d+/u);
  // Read off the wire, not Pi's source.
  assert.match(probe.userAgent, /^claude-cli\/\d+\.\d+\.\d+/u);
  assert.equal(probe.userAgent.split("/")[1].split(" ")[0], probe.claudeCode);
  assert.equal(probe.fable52.listed, probe.anthropicModels.includes("claude-fable-5-2"));
  const expected = !probe.fable52.listed ? "absent" : newerOrEqual(probe.claudeCode, probe.fable52.minimumClaudeCode) ? "servable" : "listed-but-refused";
  assert.equal(probe.fable52.status, expected);
  assert.ok(probe.opusLevels.includes("xhigh") && probe.opusLevels.includes("max"), probe.opusLevels.join(","));
  // A listed model Anthropic refuses fails the plain run; requiring Fable 5.2 passes exactly when Pi serves it.
  assert.equal(plain.status, expected === "listed-but-refused" ? 1 : 0, plain.stdout + plain.stderr);
  const required = run("--require-fable-5-2");
  assert.equal(required.status, expected === "servable" ? 0 : 1, required.stdout);
  if (expected === "absent") assert.match(JSON.parse(required.stdout).failures.join("\n"), /claude-fable-5-2 is absent/u);
});

test("refuses --live without an explicit agent directory", () => {
  const live = spawnSync(process.execPath, [SMOKE, "--probe-only", "--live"], { encoding: "utf8" });
  assert.equal(live.status, 2);
  assert.match(live.stderr, /--agent-dir <dir>/u);
});
