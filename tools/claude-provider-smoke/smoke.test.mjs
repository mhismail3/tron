// Runs the offline probe of scripts/tron provider-smoke against the Gateway's pinned Pi.
import { spawnSync } from "node:child_process";
import { strict as assert } from "node:assert";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const SMOKE = fileURLToPath(new URL("./smoke.mjs", import.meta.url));
const run = (...args) => spawnSync(process.execPath, [SMOKE, "--probe-only", "--json", ...args], { encoding: "utf8" });

test("reports the pinned Pi's Claude Code version and Fable 5.2 status, and gates on them", () => {
  const plain = run();
  assert.equal(plain.status, 0, plain.stderr);
  const { probe } = JSON.parse(plain.stdout);
  assert.match(probe.piAi, /^\d+\.\d+\.\d+/u);
  // Read off the wire, not Pi's source.
  assert.match(probe.userAgent, /^claude-cli\/\d+\.\d+\.\d+/u);
  assert.equal(probe.userAgent.split("/")[1].split(" ")[0], probe.claudeCode);
  assert.ok(["absent", "servable"].includes(probe.fable52.status), JSON.stringify(probe.fable52));
  assert.equal(probe.fable52.listed, probe.anthropicModels.includes("claude-fable-5-2"));
  assert.ok(probe.opusLevels.includes("xhigh") && probe.opusLevels.includes("max"), probe.opusLevels.join(","));

  // Requiring Fable 5.2 passes exactly when the pinned Pi serves it.
  const required = run("--require-fable-5-2");
  assert.equal(required.status, probe.fable52.status === "servable" ? 0 : 1, required.stdout);
  if (required.status) assert.match(JSON.parse(required.stdout).failures.join("\n"), /claude-fable-5-2 is absent/u);
});
