#!/usr/bin/env node
// Purpose: `scripts/tron proof shadow <block>`: run a block's shadow comparison (mutate.json "shadow") and write
// <block dir>/SHADOW.json for the packet. The comparison runs the core compiled from the current sources with the
// pinned toolchain against the shipped TypeScript it models; `{core}` in shadow.cmd is the compiled core.js.
// Generated-input comparisons are recorded realTraffic: false, windowDays: 0; recorded Debug-Gateway traffic is
// the replay runner's (#2349). The result is bound to the block hash and the compiled core's hash; zero
// comparisons, a crash or unparsable output is a failure, and the previous SHADOW.json is deleted first so a
// failed run never leaves an old "match" behind.
// Usage: scripts/tron proof shadow <block> [--root <dir>] [--out <file>]
// Exit 0: match. 1: mismatch or failed comparison. 2: usage or toolchain error.
import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { blockHash } from "../packet/hash.mjs";

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const DAFNY = join(process.env.XDG_CACHE_HOME || join(homedir(), "Library/Caches"), "tron-proof/bin/dafny");
const args = process.argv.slice(2);
const opt = (n) => (args.includes(n) ? args[args.indexOf(n) + 1] : undefined);
const block = args[0];
if (!block || block.startsWith("-")) { console.error("usage: scripts/tron proof shadow <block> [--root <dir>] [--out <file>]"); process.exit(2); }
const root = resolve(opt("--root") ?? join(REPO, "packages/core"));
const dir = join(root, "blocks", block);
const full = JSON.parse(readFileSync(join(dir, "mutate.json"), "utf8"));
const cfg = full.shadow;
if (!cfg) { console.error(`block ${block} has no mutate.json shadow`); process.exit(2); }
const outPath = resolve(opt("--out") ?? join(dir, "SHADOW.json"));
rmSync(outPath, { force: true });
const env = { ...process.env, PATH: `${dirname(process.execPath)}:/usr/bin:/bin`, DAFNY_CORES: "1" };
const date = new Date().toISOString().slice(0, 10);
let work;
const fail = (why) => {
  if (work) rmSync(work, { recursive: true, force: true });
  writeFileSync(outPath, `${JSON.stringify({ status: "error", error: why, inputsHash: blockHash(root, full), realTraffic: false, compared: 0, mismatches: null, date }, null, 1)}\n`);
  console.error(`shadow: FAIL: ${why}`);
  process.exit(1);
};
const doctor = spawnSync("/bin/bash", [join(REPO, "tools/proof/bootstrap.sh"), "doctor"], { encoding: "utf8" });
if (doctor.status !== 0) { console.error(`shadow: pinned toolchain unavailable: ${doctor.stderr.trim()}`); process.exit(2); }
work = mkdtempSync(join(tmpdir(), "tron-proof-shadow-"));
try {
  const core = join(work, "core.js");
  execFileSync(DAFNY, ["translate", "js", "--no-verify", "--include-runtime", full.translate, "-o", join(work, "core")], { cwd: root, env, stdio: "ignore" });
  const run = spawnSync(cfg.cmd[0], cfg.cmd.slice(1).map((c) => c.replaceAll("{core}", core)), { cwd: REPO, env, encoding: "utf8", maxBuffer: 1 << 26 });
  if (run.error) fail(`shadow command did not run: ${run.error.message}`);
  // The comparison exits 1 on a mismatch (its output still says how many agreed); anything else is a crash.
  if (run.signal || ![0, 1].includes(run.status)) fail(`shadow command ${run.signal ? `killed by ${run.signal}` : `exited ${run.status}`}: ${`${run.stdout}${run.stderr}`.slice(-200)}`);
  let j; try { j = JSON.parse(run.stdout.slice(run.stdout.indexOf("{"))); } catch { fail(`unparsable shadow output: ${`${run.stdout}${run.stderr}`.slice(0, 200)}`); }
  const compared = j.requests, mismatches = j.requests - j.agree;
  if (!(compared > 0) || !Number.isInteger(mismatches) || mismatches < 0) fail(`nothing compared (${JSON.stringify({ compared, mismatches })})`);
  if ((mismatches === 0) !== (run.status === 0)) fail(`shadow command exited ${run.status} but reported ${mismatches} mismatches`);
  const status = {
    status: mismatches === 0 ? "match" : "mismatch", compared, unit: "inputs", mismatches, firstMismatch: j.diffs?.[0] ?? null,
    source: cfg.source, realTraffic: false, windowDays: 0, inputsHash: blockHash(root, full),
    coreJsHash: createHash("sha256").update(readFileSync(core)).digest("hex").slice(0, 16), command: cfg.cmd.join(" "), date,
  };
  writeFileSync(outPath, `${JSON.stringify(status, null, 1)}\n`);
  console.log(JSON.stringify({ ...status, firstMismatch: undefined }));
  process.exitCode = mismatches === 0 ? 0 : 1;
} finally {
  rmSync(work, { recursive: true, force: true });
}
