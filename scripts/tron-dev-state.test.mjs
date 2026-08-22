import assert from "node:assert/strict";
import { execFile, execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

const run = (state, command, ...argumentsList) => execFileSync(process.execPath, [helper, command, state, ...argumentsList], { encoding: "utf8" });
const runAsync = (state, command, ...argumentsList) => new Promise((resolve, reject) => {
  execFile(process.execPath, [helper, command, state, ...argumentsList], (error, stdout, stderr) => {
    if (error) reject(Object.assign(error, { stdout, stderr }));
    else resolve(stdout);
  });
});

const helper = new URL("./tron-dev-state.mjs", import.meta.url).pathname;
const resolveFixture = (fixture) => execFileSync(process.execPath, [helper, "resolve-host-fixture", JSON.stringify(fixture)], { encoding: "utf8" }).trim();

test("Debug health host uses Gateway deterministic Tailscale ordering", () => {
  const mixed = {
    zeta: [
      { address: "fd7a:115c:a1e0::1", family: "IPv6", internal: false },
      { address: "100.90.0.2", family: "IPv4", internal: false },
    ],
    alpha: [
      { address: "100.80.0.3", family: 4, internal: false },
      { address: "127.0.0.1", family: "IPv4", internal: true },
    ],
  };
  assert.equal(resolveFixture(mixed), "100.80.0.3");
  const reversed = Object.fromEntries(Object.entries(mixed).reverse());
  assert.equal(resolveFixture(reversed), "100.80.0.3");
});

test("Debug command host inherits a live Tailscale lifecycle and rejects conflicts", () => {
  const root = mkdtempSync(join(tmpdir(), "tron-dev-host-"));
  try {
    const state = join(root, "lifecycle.json");
    writeFileSync(state, `${JSON.stringify({ expectedHost: "tailscale" })}\n`);
    const resolveCommand = (requested, explicit, live) => execFileSync(process.execPath, [
      helper, "resolve-command-host", state, requested, explicit ? "yes" : "no", live ? "yes" : "no",
    ], { encoding: "utf8" }).trim();
    assert.equal(resolveCommand("", false, true), "tailscale");
    assert.equal(resolveCommand("tailscale", true, true), "tailscale");
    assert.throws(() => resolveCommand("127.0.0.1", true, true));
    assert.equal(resolveCommand("", false, false), "127.0.0.1");
    assert.equal(resolveCommand("tailscale", true, false), "tailscale");
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("Debug lifecycle accepts the operational start/readiness/stop flow", () => {
  const root = mkdtempSync(join(tmpdir(), "tron-dev-transition-"));
  try {
    const state = join(root, "lifecycle.json");
    run(state, "transition", "starting", "generation=1");
    run(state, "transition", "ready", "readiness=ready");
    run(state, "transition", "stopping", "intentionalExit=true");
    run(state, "transition", "stopped", "supervisorPid=");
    assert.equal(JSON.parse(run(state, "read")).lifecycle, "stopped");
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("Debug lifecycle rejects regressions and permits failed recovery", () => {
  const root = mkdtempSync(join(tmpdir(), "tron-dev-transition-"));
  try {
    const state = join(root, "lifecycle.json");
    run(state, "transition", "starting");
    run(state, "transition", "ready");
    assert.throws(() => run(state, "transition", "starting"));
    assert.throws(() => run(state, "transition", "stopped"));
    run(state, "transition", "failed");
    run(state, "transition", "starting", "restartCount=0");
    run(state, "transition", "ready", "readiness=ready");
    run(state, "transition", "stopping");
    run(state, "transition", "stopped");
    assert.throws(() => run(state, "transition", "ready", "readiness=not-ready"));
    assert.throws(() => run(state, "write", "lifecycle=ready"));
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("Debug lifecycle serializes concurrent generation writes", async () => {
  const root = mkdtempSync(join(tmpdir(), "tron-dev-transition-"));
  try {
    const state = join(root, "lifecycle.json");
    await Promise.all(Array.from({ length: 24 }, (_, generation) => runAsync(state, "transition", "starting", `generation=${generation}`)));
    const value = JSON.parse(run(state, "read"));
    assert.equal(value.lifecycle, "starting");
    assert.match(String(value.generation), /^\d+$/u);
    assert.ok(value.updatedAt);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("Debug candidate identity parser rejects noisy stdout", () => {
  const valid = `debug-build ${"a".repeat(64)}`;
  assert.equal(execFileSync(process.execPath, [helper, "validate-build-identity", valid], { encoding: "utf8" }).trim(), valid);
  assert.throws(() => execFileSync(process.execPath, [helper, "validate-build-identity", `npm chatter\n${valid}`], { stdio: "ignore" }));
  assert.throws(() => execFileSync(process.execPath, [helper, "validate-build-identity", "debug-build short"], { stdio: "ignore" }));
});

test("Debug lifecycle fails closed when a recorded supervisor is orphaned", () => {
  const root = mkdtempSync(join(tmpdir(), "tron-dev-state-"));
  try {
    const state = join(root, "lifecycle.json");
    writeFileSync(state, `${JSON.stringify({ lifecycle: "ready", supervisorPid: 99999999, supervisorStartIdentity: "Mon Jan  1 00:00:00 2001", childPid: 99999998, childStartIdentity: "Mon Jan  1 00:00:00 2001" })}\n`);
    const output = JSON.parse(execFileSync(process.execPath, [helper, "status", state, "127.0.0.1", "1"], { encoding: "utf8" }));
    assert.equal(output.lifecycle, "failed");
    assert.equal(output.supervisor.live, false);
    assert.equal(output.child.live, false);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("Debug health host orders IPv6 addresses then interface names", () => {
  assert.equal(resolveFixture({ z: [{ address: "fd7a:115c:a1e0::b", family: 6, internal: false }], a: [{ address: "fd7a:115c:a1e0::a", family: "IPv6", internal: false }] }), "fd7a:115c:a1e0::a");
  assert.equal(resolveFixture({ z: [{ address: "fd7a:115c:a1e0::a", family: 6, internal: false }], a: [{ address: "fd7a:115c:a1e0::a", family: 6, internal: false }] }), "fd7a:115c:a1e0::a");
});

test("Debug start admission recovers only an exact owned orphan", () => {
  const admission = (lifecycle, supervisorLive, childLive, listenerPresent) => execFileSync(process.execPath, [
    helper, "start-admission", lifecycle, supervisorLive ? "yes" : "no", childLive ? "yes" : "no", listenerPresent ? "yes" : "no",
  ], { encoding: "utf8" }).trim();
  assert.equal(admission("ready", false, true, true), "recover-orphan");
  assert.equal(admission("ready", false, false, true), "foreign-listener");
  assert.equal(admission("ready", true, true, true), "supervised");
  assert.equal(admission("failed", false, false, false), "start");
});

test("Debug child termination always revalidates exact PID identity", () => {
  const source = readFileSync(new URL("./tron-dev", import.meta.url), "utf8");
  assert.match(source, /kill_child\(\)/);
  assert.match(source, /pid_current "\x24pid" "\x24identity"/);
  assert.match(source, /kill_child "\x24child" "\x24child_identity"/);
  assert.match(source, /kill_child "\x24child_pid" "\x24child_identity"/);
  assert.doesNotMatch(source, /kill(?: -[A-Z0-9]+)? "\x24child(?:_pid)?"/u);
  assert.match(source, /for _ in \$\(seq 1 80\)/);
  assert.match(source, /sleep 0\.05/);
});

test("Debug mutator command lock rejects a concurrent owner", () => {
  const root = mkdtempSync(join(tmpdir(), "tron-dev-command-lock-"));
  const lock = join(root, "command.lock");
  try {
    execFileSync("/usr/bin/shlock", ["-f", lock, "-p", String(process.pid)]);
    assert.throws(() => execFileSync("/usr/bin/shlock", ["-f", lock, "-p", String(process.pid)]));
  } finally { rmSync(root, { recursive: true, force: true }); }
});
