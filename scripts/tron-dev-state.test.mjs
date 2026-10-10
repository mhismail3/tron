import assert from "node:assert/strict";
import { execFile, execFileSync, spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from "node:fs";
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
// Records a build of the worktree's current HEAD with the given pre-build
// dirty flag, as `scripts/tron dev start` does after `build_candidate`.
const recordSource = (state, epoch, worktree, dirtyBeforeBuild) => run(
  state, "record-source", epoch, worktree, git(worktree, "rev-parse", "HEAD").trim(), dirtyBeforeBuild,
);
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
    recordSource(state, epochFor(1), first, "false");
    recordSource(state, epochFor(2), second, "false");
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
    recordSource(state, epochFor(1), worktree, "false");
    assert.deepEqual(runningSource(state, epochFor(1)), { worktree, branch: null });
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("Debug source records stay bounded and keep the newest record per epoch", () => {
  const root = mkdtempSync(join(tmpdir(), "tron-dev-source-"));
  try {
    const state = join(root, "lifecycle.json");
    const first = sourceFixture(root, "first", "feat/first");
    const second = sourceFixture(root, "second", "feat/second");
    for (let index = 1; index <= 12; index += 1) recordSource(state, epochFor(index), first, "false");
    recordSource(state, epochFor(12), second, "false");
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
    recordSource(state, epochFor(1), first, "false");
    markRunning(state, epochFor(1));
    for (let index = 2; index <= 13; index += 1) recordSource(state, epochFor(index), second, "false");
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
    recordSource(state, epochFor(1), worktree, "true");
    recordSource(state, epochFor(2), worktree, "false");
    // Failure mode 10: each epoch keeps its own flag; unknown is null, not clean.
    assert.equal(runningDirty(epochFor(1)), true);
    assert.equal(runningDirty(epochFor(2)), false);
    assert.equal(runningDirty(epochFor(3)), null);
    const value = JSON.parse(run(state, "read"));
    writeFileSync(state, `${JSON.stringify({ ...value, candidateSources: [{ runtimeEpoch: epochFor(4), worktree, branch: "feat/source" }] })}\n`);
    assert.equal(runningDirty(epochFor(4)), null);
    // Failure modes 11 and 21: only the full built revision and an explicit
    // true/false pre-build flag are recorded.
    const head = git(worktree, "rev-parse", "HEAD").trim();
    for (const malformed of [[head], [head, "yes"], [head, ""], ["false"], [head.slice(0, 12), "false"], ["", "false"]]) {
      assert.throws(() => execFileSync(process.execPath, [helper, "record-source", state, epochFor(5), worktree, ...malformed], { stdio: "ignore" }));
    }
    assert.equal(JSON.parse(run(state, "read")).candidateSources.some((entry) => entry.runtimeEpoch === epochFor(5)), false);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

// Post-build dirtiness failure modes (#140): `start`/`restart` measure the
// source before `build_candidate` and record it after, so the record must also
// reflect what changed while the build ran.
// 18. A tracked or untracked edit made during the build is recorded clean.
// 19. A commit made during the build (clean before and after, HEAD moved) is
//     recorded clean against the pre-build revision the payload carries.
// 20. A tree dirty before the build and cleaned during it is recorded clean.
// (21, a malformed pre-build measurement, is covered above.)
test("Debug source record is dirty when the tree changed while the candidate built", () => {
  const root = mkdtempSync(join(tmpdir(), "tron-dev-source-"));
  try {
    const state = join(root, "lifecycle.json");
    const worktree = sourceFixture(root, "source", "feat/source");
    writeFileSync(join(worktree, "tracked.ts"), "export {};\n");
    git(worktree, "add", ".");
    git(worktree, "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "commit", "-q", "-m", "tracked");
    const recordedDirty = (epoch) => JSON.parse(run(state, "read")).candidateSources.find((entry) => entry.runtimeEpoch === epoch)?.dirty;
    // Each build: measure before (candidate-source), mutate the tree as an
    // edit during the build would, then record as `scripts/tron dev` does.
    const build = (epoch, duringBuild) => {
      const before = candidateSource(worktree);
      duringBuild();
      run(state, "record-source", epoch, worktree, before.revision, before.dirty);
      return recordedDirty(epoch);
    };
    assert.equal(build(epochFor(1), () => {}), false);
    // Failure mode 18: a tracked edit, then an untracked file.
    assert.equal(build(epochFor(2), () => writeFileSync(join(worktree, "tracked.ts"), "export const edited = true;\n")), true);
    git(worktree, "checkout", "-q", "--", "tracked.ts");
    assert.equal(build(epochFor(3), () => writeFileSync(join(worktree, "new-module.ts"), "export {};\n")), true);
    // Failure mode 19: the edit is committed before the build finishes.
    assert.equal(build(epochFor(4), () => {
      git(worktree, "add", "new-module.ts");
      git(worktree, "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "commit", "-q", "-m", "during build");
    }), true);
    // Failure mode 20: dirty when measured, reverted before the record.
    writeFileSync(join(worktree, "tracked.ts"), "export const edited = true;\n");
    assert.equal(build(epochFor(5), () => git(worktree, "checkout", "-q", "--", "tracked.ts")), true);
    assert.equal(build(epochFor(6), () => {}), false);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

// Handoff source admission failure modes (#124: Stable is always a known commit):
// 13. A candidate recorded as built from a dirty tree is copied into Stable.
// 14. A candidate whose dirtiness is unknown - no record for its epoch
//     (evicted or never recorded) or a record written before dirtiness was
//     recorded - is treated as clean instead of refused.
// 15. The decision reads another candidate's record than the payload handoff
//     copies (the latest build, or a clean build sharing its fingerprint), so
//     a dirty selected candidate passes or a clean one is refused.
// 16. A refusal does not tell the maintainer how to produce an admissible
//     candidate (commit, then restart).
// 17. Admission does not hand `handoff-debug` the exact identity it admitted,
//     so the copy cannot pin that candidate against a later selection change
//     (the handoff test below covers the pinned copy).
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
    recordSource(state, epochFor(1), worktree, "false");
    recordSource(state, epochFor(2), worktree, "true");
    recordSource(state, epochFor(3), worktree, "false");

    const cleanVersion = selectDevPayload(home, epochFor(1));
    // Failure mode 17: stdout is exactly the admitted version and fingerprint.
    assert.deepEqual(handoffAdmission(state, home), { admitted: true, stdout: `${cleanVersion} ${sharedFingerprint}\n`, stderr: "" });

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
    recordSource(state, epochFor(2), worktree, "false");
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

// `scripts/tron-dev handoff` wiring failure modes (#140). The real script runs
// with a Node stand-in that passes every state-helper command to real Node
// (host resolution, supervisor liveness against a real process, admission),
// answers only `status` (it would probe port 9848) and records what the deploy
// helper is asked to do. No signed launcher is involved: handoff never runs it.
// 22. The admission output is not captured or `read` splits it wrongly, so
//     handoff-debug gets an empty, swapped or different --version/--fingerprint.
// 23. A refused admission (dirty candidate) still reaches handoff-debug.
// 24. Handoff without a live, ready supervisor (none recorded, the recorded PID
//     now has another start identity, or not ready) reaches admission or
//     handoff-debug instead of refusing.
// 25. handoff-debug gets the wrong Debug or Stable home, or a host other than
//     the live supervisor's recorded one.
const handoffWiring = ({ supervisorPid, supervisorIdentity, dirty = false, ready = true }) => {
  const root = mkdtempSync(join(tmpdir(), "tron-dev-handoff-wiring-"));
  const home = join(root, "home");
  const fakeBin = join(root, "bin");
  const fakeNode = join(fakeBin, "node");
  const calls = join(root, "calls.log");
  const deployArgv = join(root, "deploy.argv");
  try {
    mkdirSync(fakeBin, { recursive: true });
    writeFileSync(fakeNode, `#!/bin/sh
case "${"$"}{1:-}" in
  */gateway-payload-deploy.mjs) printf '%s\\n' "${"$"}@" > "${deployArgv}"; echo '{}'; exit 0 ;;
  */tron-dev-state.mjs)
    echo "${"$"}{2:-}" >> "${calls}"
    if [ "${"$"}{2:-}" = status ]; then echo '{"lifecycle":"ready","health":{"readiness":"${ready ? "ready" : "starting"}"}}'; exit 0; fi ;;
esac
exec "${process.execPath}" "${"$"}@"
`);
    execFileSync("/bin/chmod", ["+x", fakeNode]);
    writeFileSync(join(fakeBin, "npm"), "#!/bin/sh\nexit 0\n");
    execFileSync("/bin/chmod", ["+x", join(fakeBin, "npm")]);
    const devHome = join(home, ".tron-dev");
    const version = selectDevPayload(devHome, epochFor(1));
    mkdirSync(join(devHome, "gateway"), { recursive: true });
    writeFileSync(join(devHome, "gateway", "lifecycle.json"), `${JSON.stringify({
      lifecycle: "ready", expectedHost: "tailscale", epoch: epochFor(1),
      ...(supervisorPid ? { supervisorPid, supervisorStartIdentity: supervisorIdentity } : {}),
      candidateSources: [{ runtimeEpoch: epochFor(1), worktree: root, branch: "feat/source", dirty }],
    })}\n`);
    const result = spawnSync("bash", [new URL("./tron-dev", import.meta.url).pathname, "handoff"], {
      env: { PATH: process.env.PATH, HOME: home, TRON_NODE_BIN: fakeNode }, encoding: "utf8",
    });
    const readLines = (path) => (existsSync(path) ? readFileSync(path, "utf8").trim().split("\n") : null);
    return { home, version, status: result.status, stderr: result.stderr, calls: readLines(calls) ?? [], deploy: readLines(deployArgv) };
  } finally { rmSync(root, { recursive: true, force: true }); }
};

test("Debug handoff passes exactly the admitted candidate to handoff-debug without the signed launcher", async () => {
  const supervisor = spawn("/bin/sleep", ["30"], { detached: true, stdio: "ignore" });
  const exited = once(supervisor, "exit");
  try {
    const supervisorPid = String(supervisor.pid);
    const supervisorIdentity = execFileSync(process.execPath, [helper, "pid-start", supervisorPid], { encoding: "utf8" }).trim();
    // Failure modes 22 and 25.
    const admitted = handoffWiring({ supervisorPid, supervisorIdentity });
    assert.equal(admitted.status, 0, admitted.stderr);
    assert.deepEqual(admitted.deploy, [
      new URL("./gateway-payload-deploy.mjs", import.meta.url).pathname, "handoff-debug",
      "--host", "tailscale", "--dev-home", join(admitted.home, ".tron-dev"), "--stable-home", join(admitted.home, ".tron"),
      "--stable-bundled-root", "/Applications/Tron.app/Contents/Resources/Gateway",
      "--version", admitted.version, "--fingerprint", sharedFingerprint,
    ]);
    // Failure mode 23.
    const dirty = handoffWiring({ supervisorPid, supervisorIdentity, dirty: true });
    assert.notEqual(dirty.status, 0);
    assert.match(dirty.stderr, /Debug handoff refused/u);
    assert.equal(dirty.deploy, null);
    // Failure mode 24: no recorded supervisor, a reused PID, and not ready.
    for (const unsupervised of [{}, { supervisorPid, supervisorIdentity: "replaced" }]) {
      const refused = handoffWiring(unsupervised);
      assert.notEqual(refused.status, 0);
      assert.match(refused.stderr, /not supervised/u);
      assert.equal(refused.calls.includes("handoff-admission"), false);
      assert.equal(refused.deploy, null);
    }
    const notReady = handoffWiring({ supervisorPid, supervisorIdentity, ready: false });
    assert.notEqual(notReady.status, 0);
    assert.match(notReady.stderr, /not ready/u);
    assert.equal(notReady.calls.includes("handoff-admission"), false);
    assert.equal(notReady.deploy, null);
  } finally {
    supervisor.kill("SIGTERM");
    await exited;
  }
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

// Issue #144. Failure modes:
// 1. An agent shell inherits the Stable Gateway's environment, and a Stable
//    value (PI_SUBAGENTS_TEMP_ROOT pointing at Stable's subagent store,
//    TRON_GATEWAY_CHANNEL=stable, another TRON_GATEWAY_* or PI_* value)
//    reaches a process the Debug lifecycle starts.
// 2. The scrub drops what the lifecycle needs: HOME, the pinned Node selection
//    (TRON_NODE_BIN, NVM_DIR) or the CI tools cache (TRON_CI_TOOLS_DIR).
test("Debug lifecycle commands never see the caller's Stable Gateway environment", () => {
  const root = mkdtempSync(join(tmpdir(), "tron-dev-env-"));
  const home = join(root, "home");
  const fakeBin = join(root, "bin");
  const fakeNode = join(fakeBin, "node");
  const seen = join(root, "seen.env");
  try {
    mkdirSync(join(home, ".tron-dev", "gateway"), { recursive: true });
    mkdirSync(fakeBin, { recursive: true });
    writeFileSync(fakeNode, `#!/bin/sh
if [ "${"$"}{1:-}" = "--version" ]; then echo v22.22.0; exit 0; fi
/usr/bin/env > "${seen}"
echo '{"lifecycle":"stopped"}'
`);
    execFileSync("/bin/chmod", ["+x", fakeNode]);
    writeFileSync(join(fakeBin, "npm"), "#!/bin/sh\nexit 0\n");
    execFileSync("/bin/chmod", ["+x", join(fakeBin, "npm")]);
    execFileSync("bash", [new URL("./tron-dev", import.meta.url).pathname, "status"], {
      env: {
        PATH: process.env.PATH, HOME: home, TRON_NODE_BIN: fakeNode, TRON_CI_TOOLS_DIR: join(root, "tools"),
        PI_SUBAGENTS_TEMP_ROOT: join(root, "stable", "internal", "subagents"), PI_SESSION_ID: "stable-session",
        PI_CODING_AGENT_DIR: join(root, "stable", "agent"), TRON_GATEWAY_CHANNEL: "stable", TRON_GATEWAY_SUPERVISED: "1",
        TRON_GATEWAY_PAYLOAD_ROOT: join(root, "stable", "payload"), TRON_DATA_DIR: join(root, "stable"),
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    const environment = Object.fromEntries(readFileSync(seen, "utf8").trim().split("\n").map(line => {
      const index = line.indexOf("=");
      return [line.slice(0, index), line.slice(index + 1)];
    }));
    const leaked = Object.keys(environment).filter(name => /^(PI_|TRON_GATEWAY_|TRON_DATA_DIR$|TRON_AGENT_DIR_NAME$)/u.test(name));
    assert.deepEqual(leaked, []);
    assert.equal(environment.HOME, home);
    assert.equal(environment.TRON_NODE_BIN, fakeNode);
    assert.equal(environment.TRON_CI_TOOLS_DIR, join(root, "tools"));
  } finally { rmSync(root, { recursive: true, force: true }); }
});
