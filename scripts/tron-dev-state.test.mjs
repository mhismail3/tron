import assert from "node:assert/strict";
import { execFile, execFileSync, spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { once } from "node:events";
import { test } from "node:test";

const run = (state, command, ...argumentsList) => execFileSync(process.execPath, [helper, command, state, ...argumentsList], { encoding: "utf8" });
const runAsync = (state, command, ...argumentsList) => new Promise((resolve, reject) => {
  execFile(process.execPath, [helper, command, state, ...argumentsList], (error, stdout, stderr) => {
    if (error) reject(Object.assign(error, { stdout, stderr }));
    else resolve(stdout);
  });
});

const helper = new URL("./tron-dev-state.mjs", import.meta.url).pathname;

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

test("Debug start admission recovers only an exact owned orphan", () => {
  const admission = (lifecycle, supervisorLive, childLive, listenerPresent) => execFileSync(process.execPath, [
    helper, "start-admission", lifecycle, supervisorLive ? "yes" : "no", childLive ? "yes" : "no", listenerPresent ? "yes" : "no",
  ], { encoding: "utf8" }).trim();
  assert.equal(admission("ready", false, true, true), "recover-orphan");
  assert.equal(admission("ready", false, false, true), "foreign-listener");
  assert.equal(admission("ready", true, true, true), "supervised");
  assert.equal(admission("failed", false, false, false), "start");
});

// Running-candidate source (worktree + branch) failure modes:
// 1. A restart staged from another worktree fails before readiness, and status
//    names that worktree although the previous candidate is still running -
//    including when both checkouts build the same payload fingerprint (the
//    fingerprint covers only app/runtime files, so a docs- or iOS-only branch
//    matches main); records are keyed by the per-stage runtime epoch.
// 2. Status reads the worktree's branch live, so a later checkout there
//    rewrites which branch the running Gateway claims to come from.
// 3. A running epoch with no recorded source (pre-existing state or evicted
//    record) is reported as the latest build instead of unknown.
// 4. Source records grow with every restart until the bounded lifecycle state
//    becomes unwritable, or a re-recorded epoch leaves a stale duplicate.
// 5. A detached checkout is reported with an invented branch such as `HEAD`.
// 6. Consecutive builds that never reach readiness evict the running
//    candidate's record, so status loses the source of the live Gateway.
const git = (cwd, ...argumentsList) => execFileSync("git", ["-C", cwd, ...argumentsList], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
const sourceFixture = (root, name, branch) => {
  const worktree = join(root, name);
  mkdirSync(worktree, { recursive: true });
  git(worktree, "init", "-q", "-b", branch);
  git(worktree, "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "commit", "-q", "--allow-empty", "-m", "fixture");
  return worktree;
};
const epochFor = (index) => `00000000-0000-4000-8000-${index.toString(16).padStart(12, "0")}`;
// Every candidate in these fixtures shares one payload fingerprint.
const sharedFingerprint = "f".repeat(64);
const markRunning = (state, epoch) => {
  const value = JSON.parse(run(state, "read"));
  writeFileSync(state, `${JSON.stringify({ ...value, lifecycle: "ready", epoch, buildFingerprint: sharedFingerprint })}\n`);
};
const runningSource = (state, epoch) => {
  markRunning(state, epoch);
  const output = JSON.parse(execFileSync(process.execPath, [helper, "status", state, "127.0.0.1", "1"], { encoding: "utf8" }));
  return { worktree: output.sourceWorktree, branch: output.sourceBranch };
};

test("Debug status names the worktree and branch of the running candidate, not the latest build", () => {
  const root = mkdtempSync(join(tmpdir(), "tron-dev-source-"));
  try {
    const state = join(root, "lifecycle.json");
    const first = sourceFixture(root, "first", "feat/first");
    const second = sourceFixture(root, "second", "feat/second");
    run(state, "record-source", epochFor(1), first, "false");
    run(state, "record-source", epochFor(2), second, "false");
    // Failure mode 1: the second build (same fingerprint) was recorded but never became ready.
    assert.deepEqual(runningSource(state, epochFor(1)), { worktree: first, branch: "feat/first" });
    assert.deepEqual(runningSource(state, epochFor(2)), { worktree: second, branch: "feat/second" });
    // Failure mode 2: a later checkout in the source worktree does not rewrite history.
    git(second, "checkout", "-q", "-b", "feat/later");
    assert.deepEqual(runningSource(state, epochFor(2)), { worktree: second, branch: "feat/second" });
    // Failure mode 3: an unrecorded running epoch is unknown, not the latest build.
    assert.deepEqual(runningSource(state, epochFor(3)), { worktree: null, branch: null });
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("Debug status reports a detached source worktree without inventing a branch", () => {
  const root = mkdtempSync(join(tmpdir(), "tron-dev-source-"));
  try {
    const state = join(root, "lifecycle.json");
    const worktree = sourceFixture(root, "detached", "main");
    git(worktree, "checkout", "-q", "--detach");
    run(state, "record-source", epochFor(1), worktree, "false");
    assert.deepEqual(runningSource(state, epochFor(1)), { worktree, branch: null });
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("Debug source records stay bounded and keep the newest record per epoch", () => {
  const root = mkdtempSync(join(tmpdir(), "tron-dev-source-"));
  try {
    const state = join(root, "lifecycle.json");
    const first = sourceFixture(root, "first", "feat/first");
    const second = sourceFixture(root, "second", "feat/second");
    for (let index = 1; index <= 12; index += 1) run(state, "record-source", epochFor(index), first, "false");
    run(state, "record-source", epochFor(12), second, "false");
    const recorded = JSON.parse(run(state, "read")).candidateSources;
    assert.ok(recorded.length <= 8, `retained ${recorded.length} source records`);
    assert.equal(recorded.filter((entry) => entry.runtimeEpoch === epochFor(12)).length, 1);
    assert.deepEqual(runningSource(state, epochFor(12)), { worktree: second, branch: "feat/second" });
    assert.deepEqual(runningSource(state, epochFor(1)), { worktree: null, branch: null });
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("Debug source records keep the running candidate while later builds never reach readiness", () => {
  const root = mkdtempSync(join(tmpdir(), "tron-dev-source-"));
  try {
    const state = join(root, "lifecycle.json");
    const first = sourceFixture(root, "first", "feat/first");
    const second = sourceFixture(root, "second", "feat/second");
    run(state, "record-source", epochFor(1), first, "false");
    markRunning(state, epochFor(1));
    for (let index = 2; index <= 13; index += 1) run(state, "record-source", epochFor(index), second, "false");
    const recorded = JSON.parse(run(state, "read")).candidateSources;
    assert.ok(recorded.length <= 8, `retained ${recorded.length} source records`);
    assert.deepEqual(runningSource(state, epochFor(1)), { worktree: first, branch: "feat/first" });
    assert.deepEqual(runningSource(state, epochFor(13)), { worktree: second, branch: "feat/second" });
  } finally { rmSync(root, { recursive: true, force: true }); }
});

// Dirty-tree candidate failure modes (#107; the stage-validator tie lives in
// gateway-payload-deploy.test.mjs):
// 7. A tree with uncommitted changes is refused, or its revision carries a
//    suffix, instead of staging the full HEAD with dirtiness recorded apart.
// 8. Uncommitted work is reported clean: a tracked edit, or an untracked new
//    file the build compiles in (also when the repository hides untracked
//    files from `git status` by configuration).
// 9. Ignored build outputs mark every candidate dirty.
// 10. Status reports the dirtiness of the latest build rather than of the
//     running candidate, or reports an unrecorded one as clean.
// 11. A malformed dirty value is recorded instead of failing closed.
// 12. Measuring dirtiness rewrites the source checkout's index (taking its
//     index.lock), so a concurrent git command there fails.
const candidateSource = (worktree) => {
  const [revision, dirty, version, ...rest] = execFileSync(process.execPath, [helper, "candidate-source", worktree], { encoding: "utf8" }).trim().split(" ");
  assert.deepEqual(rest, []);
  return { revision, dirty, version };
};

test("Debug candidate source is the full HEAD with dirtiness measured apart", () => {
  const root = mkdtempSync(join(tmpdir(), "tron-dev-source-"));
  try {
    const worktree = sourceFixture(root, "source", "feat/source");
    writeFileSync(join(worktree, ".gitignore"), "dist/\n");
    writeFileSync(join(worktree, "tracked.ts"), "export {};\n");
    git(worktree, "add", ".");
    git(worktree, "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "commit", "-q", "-m", "tracked");
    const head = git(worktree, "rev-parse", "HEAD").trim();
    // Failure mode 9: ignored build outputs are not uncommitted work.
    mkdirSync(join(worktree, "dist"));
    writeFileSync(join(worktree, "dist", "index.js"), "built\n");
    const clean = candidateSource(worktree);
    assert.equal(clean.revision, head);
    assert.equal(clean.dirty, "false");
    assert.match(clean.version, new RegExp(`^debug-${head.slice(0, 12)}-\\d{14}$`, "u"));
    // Failure modes 7 and 8: a tracked edit keeps the full HEAD and is dirty.
    writeFileSync(join(worktree, "tracked.ts"), "export const edited = true;\n");
    const edited = candidateSource(worktree);
    assert.equal(edited.revision, head);
    assert.equal(edited.dirty, "true");
    assert.match(edited.version, new RegExp(`^debug-${head.slice(0, 12)}-dirty-\\d{14}$`, "u"));
    git(worktree, "checkout", "-q", "--", "tracked.ts");
    // Failure mode 8: an untracked source file is uncommitted work, even when
    // configuration hides untracked files from plain `git status`.
    writeFileSync(join(worktree, "new-module.ts"), "export {};\n");
    git(worktree, "config", "status.showUntrackedFiles", "no");
    assert.deepEqual(candidateSource(worktree).dirty, "true");
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("Debug candidate source leaves the source checkout's index untouched", () => {
  const root = mkdtempSync(join(tmpdir(), "tron-dev-source-"));
  try {
    const worktree = sourceFixture(root, "source", "feat/source");
    writeFileSync(join(worktree, "tracked.ts"), "export {};\n");
    git(worktree, "add", ".");
    git(worktree, "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "commit", "-q", "-m", "tracked");
    // Failure mode 12: stale cached stat data is what a refreshing `git status`
    // would write back; the measurement must not.
    const later = new Date(Date.now() + 60_000);
    utimesSync(join(worktree, "tracked.ts"), later, later);
    const index = join(worktree, ".git", "index");
    const before = readFileSync(index);
    assert.equal(candidateSource(worktree).dirty, "false");
    assert.ok(readFileSync(index).equals(before), "candidate-source rewrote the source index");
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("Debug status reports the dirtiness recorded for the running candidate", () => {
  const root = mkdtempSync(join(tmpdir(), "tron-dev-source-"));
  try {
    const state = join(root, "lifecycle.json");
    const worktree = sourceFixture(root, "source", "feat/source");
    const runningDirty = (epoch) => {
      markRunning(state, epoch);
      return JSON.parse(execFileSync(process.execPath, [helper, "status", state, "127.0.0.1", "1"], { encoding: "utf8" })).sourceDirty;
    };
    run(state, "record-source", epochFor(1), worktree, "true");
    run(state, "record-source", epochFor(2), worktree, "false");
    // Failure mode 10: each epoch keeps its own flag; unknown is null, not clean.
    assert.equal(runningDirty(epochFor(1)), true);
    assert.equal(runningDirty(epochFor(2)), false);
    assert.equal(runningDirty(epochFor(3)), null);
    const value = JSON.parse(run(state, "read"));
    writeFileSync(state, `${JSON.stringify({ ...value, candidateSources: [{ runtimeEpoch: epochFor(4), worktree, branch: "feat/source" }] })}\n`);
    assert.equal(runningDirty(epochFor(4)), null);
    // Failure mode 11: only an explicit true/false is recorded.
    for (const malformed of [[], ["yes"], [""]]) {
      assert.throws(() => execFileSync(process.execPath, [helper, "record-source", state, epochFor(5), worktree, ...malformed], { stdio: "ignore" }));
    }
    assert.equal(JSON.parse(run(state, "read")).candidateSources.some((entry) => entry.runtimeEpoch === epochFor(5)), false);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

// Handoff source admission failure modes (#124: Stable is always a known commit):
// 13. A candidate recorded as built from a dirty tree is copied into Stable.
// 14. A candidate whose dirtiness is unknown - no record for its epoch
//     (evicted or never recorded) or a record written before dirtiness was -
//     is treated as clean instead of refused.
// 15. The decision reads another candidate's record than the payload handoff
//     copies (the latest build, or a clean build sharing its fingerprint), so
//     a dirty selected candidate passes or a clean one is refused.
// 16. A refusal does not tell the maintainer how to produce an admissible
//     candidate (commit, then restart).
const selectDevPayload = (home, epoch) => {
  const version = `debug-${epoch.slice(-12)}`;
  const root = join(home, "gateway", "payloads", "dev");
  mkdirSync(join(root, "versions", version), { recursive: true });
  writeFileSync(join(root, "current.json"), `${JSON.stringify({ schema: 1, kind: "tron-gateway-selection", channel: "dev", version, payloadFingerprint: sharedFingerprint })}\n`);
  writeFileSync(join(root, "versions", version, "manifest.json"), `${JSON.stringify({
    schema: 1, kind: "tron-gateway-payload", channel: "dev", version, payloadFingerprint: sharedFingerprint,
    runtimeEpoch: epoch, sourceRevision: "a".repeat(40),
  })}\n`);
  return version;
};
const handoffAdmission = (state, home) => {
  try {
    const stdout = execFileSync(process.execPath, [helper, "handoff-admission", state, home], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    return { admitted: true, stdout, stderr: "" };
  } catch (error) {
    return { admitted: false, stdout: String(error.stdout ?? ""), stderr: String(error.stderr ?? "") };
  }
};

test("Debug handoff admits only a selected candidate recorded as built from a clean tree", () => {
  const root = mkdtempSync(join(tmpdir(), "tron-dev-handoff-"));
  try {
    const state = join(root, "lifecycle.json");
    const home = join(root, "home");
    const worktree = sourceFixture(root, "source", "feat/source");
    run(state, "record-source", epochFor(1), worktree, "false");
    run(state, "record-source", epochFor(2), worktree, "true");
    run(state, "record-source", epochFor(3), worktree, "false");

    selectDevPayload(home, epochFor(1));
    assert.equal(handoffAdmission(state, home).admitted, true);

    // Failure modes 13 and 15: the selected candidate is dirty although the
    // latest record (epoch 3) and the running epoch are clean builds with the
    // same payload fingerprint.
    const dirtyVersion = selectDevPayload(home, epochFor(2));
    markRunning(state, epochFor(3));
    const dirty = handoffAdmission(state, home);
    assert.equal(dirty.admitted, false);
    assert.equal(dirty.stdout, "");
    assert.match(dirty.stderr, new RegExp(dirtyVersion, "u"));
    // Failure mode 16: the refusal names the way to an admissible candidate.
    assert.match(dirty.stderr, /commit/u);
    assert.match(dirty.stderr, /scripts\/tron dev restart/u);

    // Failure mode 15: a clean selected candidate is not refused because a
    // later build (epoch 2 re-selected away from) was dirty.
    selectDevPayload(home, epochFor(1));
    markRunning(state, epochFor(2));
    assert.equal(handoffAdmission(state, home).admitted, true);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("Debug handoff refuses a candidate whose source dirtiness is unknown", () => {
  const root = mkdtempSync(join(tmpdir(), "tron-dev-handoff-"));
  try {
    const state = join(root, "lifecycle.json");
    const home = join(root, "home");
    const worktree = sourceFixture(root, "source", "feat/source");
    // Failure mode 14: no lifecycle state at all.
    selectDevPayload(home, epochFor(1));
    const missingState = handoffAdmission(state, home);
    assert.equal(missingState.admitted, false);
    assert.match(missingState.stderr, /scripts\/tron dev restart/u);
    // Failure mode 14: other epochs are recorded clean, the selected one is not.
    run(state, "record-source", epochFor(2), worktree, "false");
    markRunning(state, epochFor(1));
    assert.equal(handoffAdmission(state, home).admitted, false);
    // Failure mode 14: a record written before dirtiness was recorded.
    const value = JSON.parse(run(state, "read"));
    writeFileSync(state, `${JSON.stringify({ ...value, candidateSources: [{ runtimeEpoch: epochFor(1), worktree, branch: "feat/source" }] })}\n`);
    const unrecorded = handoffAdmission(state, home);
    assert.equal(unrecorded.admitted, false);
    assert.match(unrecorded.stderr, /commit/u);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

const stopFixture = ({ child, identity, childIsOwned }) => {
  const root = mkdtempSync(join(tmpdir(), "tron-dev-stop-"));
  const home = join(root, "home");
  const fakeBin = join(root, "bin");
  const fakeNode = join(fakeBin, "node");
  const fakeNpm = join(fakeBin, "npm");
  try {
    mkdirSync(home, { recursive: true });
    mkdirSync(fakeBin, { recursive: true });
    writeFileSync(fakeNode, `#!/bin/sh
if [ "${"$"}{1:-}" = "--version" ]; then echo v22.22.0; exit 0; fi
command="${"$"}{2:-}";
count_file="${root}/pid-current.count";
case "${"$"}command" in
  get)
    case "${"$"}{4:-}" in childPid) echo ${child} ;; childStartIdentity) echo ${identity} ;; *) echo ;; esac ;;
  pid-current)
    if [ "${"$"}{4:-}" = "${identity}" ]; then
      count=0; [ -f "${"$"}count_file" ] && count=$(cat "${"$"}count_file"); count=$((count + 1)); echo "${"$"}count" > "${"$"}count_file";
      if [ "${childIsOwned ? "yes" : "no"}" = yes ] && [ "${"$"}count" -eq 1 ]; then echo yes; else echo no; fi
    else echo no; fi ;;
  transition|resolve-command-host) exit 0 ;;
  status) echo '{"lifecycle":"stopped"}' ;;
  *) exit 0 ;;
esac
`);
    execFileSync("/bin/chmod", ["+x", fakeNode]);
    writeFileSync(fakeNpm, "#!/bin/sh\nexit 0\n");
    execFileSync("/bin/chmod", ["+x", fakeNpm]);
    const stateDir = join(home, ".tron-dev", "gateway");
    mkdirSync(stateDir, { recursive: true });
    writeFileSync(join(stateDir, "lifecycle.json"), JSON.stringify({ lifecycle: "ready", childPid: child, childStartIdentity: identity }));
    execFileSync("bash", [new URL("./tron-dev", import.meta.url).pathname, "stop"], {
      env: { ...process.env, HOME: home, TRON_NODE_BIN: fakeNode },
      stdio: ["ignore", "pipe", "pipe"],
    });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
};

test("Debug stop refuses to signal a child after its recorded identity changes", async () => {
  const childProcess = spawn("/bin/sleep", ["30"], { detached: true, stdio: "ignore" });
  const child = String(childProcess.pid);
  const exited = once(childProcess, "exit");
  try {
    stopFixture({ child, identity: "replaced", childIsOwned: false });
    assert.doesNotThrow(() => process.kill(Number(child), 0));
  } finally {
    try { childProcess.kill("SIGTERM"); } catch {}
    await exited;
  }
});

test("Debug stop terminates and reaps an exactly owned child", async () => {
  const childProcess = spawn("/bin/sleep", ["30"], { detached: true, stdio: "ignore" });
  const child = String(childProcess.pid);
  const exited = once(childProcess, "exit");
  try {
    stopFixture({ child, identity: "owned", childIsOwned: true });
    await exited;
    assert.notEqual(childProcess.signalCode, null);
    assert.equal(childProcess.exitCode, null);
  } finally {
    if (childProcess.exitCode === null && childProcess.signalCode === null) {
      try { childProcess.kill("SIGTERM"); } catch {}
      await exited.catch(() => {});
    }
  }
});
