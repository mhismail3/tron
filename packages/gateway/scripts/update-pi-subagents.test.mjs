import assert from "node:assert/strict";
import test from "node:test";
import { copyFileSync, cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const gateway = dirname(dirname(fileURLToPath(import.meta.url)));
const updater = join(gateway, "scripts/update-pi-subagents.mjs");
function command(bin, args, options = {}) {
  const result = spawnSync(bin, args, { encoding: "utf8", timeout: 30_000, ...options });
  assert.equal(result.status, 0, result.error?.message || result.stderr || result.stdout);
  return result.stdout.trim();
}
function fixture(run, usable = false) {
  const root = mkdtempSync(join(tmpdir(), "tron-subagents-update-"));
  try {
    const target = join(root, "gateway");
    const fork = join(root, "fork");
    for (const path of [target, fork, join(target, "scripts"), join(root, "home"), join(root, "tmp")]) mkdirSync(path, { recursive: true });
    cpSync(join(gateway, "artifacts"), join(target, "artifacts"), { recursive: true });
    copyFileSync(join(gateway, "pi-subagents-pin.json"), join(target, "pi-subagents-pin.json"));
    for (const path of ["src", "test-support", "vitest.config.ts", "vitest.nested.config.ts"]) cpSync(join(gateway, path), join(target, path), { recursive: true });
    symlinkSync(join(gateway, "node_modules"), join(target, "node_modules"));
    for (const file of ["check-pi-subagents.mjs", "build-pi-subagents-closure.py"]) copyFileSync(join(gateway, "scripts", file), join(target, "scripts", file));
    const env = { PATH: process.env.PATH, HOME: join(root, "home"), TMPDIR: join(root, "tmp"), npm_config_registry: usable ? "https://registry.npmjs.org/" : "http://127.0.0.1:1", npm_config_fetch_retries: "0", npm_config_fetch_timeout: "1000", PYTHONDONTWRITEBYTECODE: "1" };
    const git = (cwd, ...args) => command("git", ["-C", cwd, ...args], { env });
    for (const repo of [target, fork]) {
      git(repo, "init", "-q"); git(repo, "config", "user.name", "Fixture"); git(repo, "config", "user.email", "fixture@example.invalid");
    }
    writeFileSync(join(fork, "base"), "upstream\n");
    git(fork, "add", "."); git(fork, "commit", "-qm", "upstream");
    const ancestor = git(fork, "rev-parse", "HEAD");
    const pin = JSON.parse(readFileSync(join(target, "pi-subagents-pin.json"), "utf8"));
    pin.fork = { repository: null, commit: pin.fork.commit };
    pin.upstream = { package: "pi-subagents", release: "v0.76.1", tagCommit: ancestor };
    writeFileSync(join(target, "pi-subagents-pin.json"), JSON.stringify(pin, null, 2) + "\n");
    writeFileSync(join(target, "package.json"), JSON.stringify({ type: "module", scripts: { "check:pi-subagents": "node scripts/check-pi-subagents.mjs" } }));
    git(target, "add", "."); git(target, "commit", "-qm", "initial pin");
    const version = "0.76.1-tron.99";
    const manifest = { name: "pi-subagents", version, dependencies: {}, scripts: { prepack: "node build.mjs" } };
    writeFileSync(join(fork, "package.json"), JSON.stringify(manifest));
    writeFileSync(join(fork, "build.mjs"), 'import { writeFileSync } from "node:fs"; writeFileSync("index.js", "export default () => {};\\n");\n');
    writeFileSync(join(fork, "package-lock.json"), JSON.stringify({ name: manifest.name, version, lockfileVersion: 3, packages: { "": { name: manifest.name, version, dependencies: {} } } }));
    if (usable) {
      command("tar", ["-xzf", join(gateway, pin.sourceArchive.path), "--strip-components=1", "-C", fork], { env });
      const realManifest = JSON.parse(readFileSync(join(fork, "package.json"), "utf8"));
      realManifest.version = version; realManifest.scripts = {}; delete realManifest.devDependencies;
      writeFileSync(join(fork, "package.json"), JSON.stringify(realManifest));
      const lock = JSON.parse(readFileSync(join(gateway, pin.lockfile.path), "utf8"));
      lock.version = version; lock.packages[""].version = version; delete lock.packages[""].devDependencies;
      writeFileSync(join(fork, "package-lock.json"), JSON.stringify(lock));
    }
    git(fork, "add", "."); git(fork, "commit", "-qm", "candidate");
    const commit = git(fork, "rev-parse", "HEAD");
    // Network is the only fake boundary; source-object export, npm packing,
    // closure construction, offline checks and repository mutations are real.
    const spawn = (bin, args, options) => {
      if (bin === "git" && args[0] === "ls-remote") return { status: 0, stdout: `${ancestor}\trefs/tags/v0.76.1\n`, stderr: "" };
      if (bin === "npm" && args[0] === "view") return { status: 0, stdout: JSON.stringify(args[1] === "pi-subagents" ? "0.77.0" : { version: "0.76.1", gitHead: ancestor, "dist.integrity": `sha512-${Buffer.alloc(64).toString("base64")}` }), stderr: "" };
      return spawnSync(bin, args, { ...options, env: { ...env, ...options?.env }, timeout: 120_000 });
    };
    return run({ target, fork, git, commit, pin, spawn, env, root });
  } finally { rmSync(root, { recursive: true, force: true }); }
}
function snapshot(root) {
  return Object.fromEntries(readdirSync(join(root, "artifacts")).map((name) => [name, readFileSync(join(root, "artifacts", name))]));
}

test("packs committed objects, builds a closure and retains current as previous", async () => {
  // fixture must outlive this async import.
  const { runUpdate } = await import(updater);
  fixture(({ target, fork, commit, pin, spawn, env, git }) => {
    writeFileSync(join(fork, "package.json"), "dirty working tree must not be read");
    const unrelated = join(target, "unrelated.txt"); writeFileSync(unrelated, "keep");
    const original = snapshot(target);
    const originalPin = readFileSync(join(target, "pi-subagents-pin.json"));
    const executed = [];
    const beforePublication = (bin, args, options) => {
      if (args.includes("src/sessions/managed-subagents.integration.test.ts") || args.includes("src/sessions/managed-subagents.rollback.test.ts")
        || args.includes("src/sessions/managed-subagents.invalid-entry.test.ts")) {
        assert.deepEqual(readFileSync(join(target, "pi-subagents-pin.json")), originalPin);
        assert.deepEqual(snapshot(target), original);
        executed.push(args.find((arg) => arg.endsWith(".test.ts")));
      }
      return spawn(bin, args, options);
    };
    const result = runUpdate({ gatewayDir: target, forkRepo: fork, commit, spawn: beforePublication });
    assert.deepEqual(executed, ["src/sessions/managed-subagents.integration.test.ts", "src/sessions/managed-subagents.rollback.test.ts", "src/sessions/managed-subagents.invalid-entry.test.ts"]);
    const candidate = JSON.parse(readFileSync(join(target, "pi-subagents-pin.json"), "utf8"));
    assert.equal(candidate.version, "0.76.1-tron.99");
    assert.deepEqual(candidate.fork, { repository: null, commit });
    const { previous: _olderPin, ...retainedPin } = pin;
    // A rollback selection is the original build, not just a version/digest pair.
    assert.deepEqual(candidate.previous, retainedPin);
    assert.equal(result.latestUpstream, "0.77.0");
    assert.equal(readFileSync(unrelated, "utf8"), "keep");
    for (const [name, bytes] of Object.entries(original)) assert.deepEqual(readFileSync(join(target, "artifacts", name)), bytes);
    command(process.execPath, [join(target, "scripts/check-pi-subagents.mjs")], { env });
    assert.equal(result.executionGate.passed, true);
    assert.equal(result.rollbackProbe.passed, true);
    for (const name of ["previous", "candidate", "rollback"]) {
      const leg = result.rollbackProbe.legs.find((item) => item.leg === name);
      assert.ok(leg, `missing ${name} execution`);
      const selection = name === "candidate" ? candidate : retainedPin;
      assert.deepEqual(leg.receipt, { version: selection.version, sha512: selection.closure.sha512,
        forkCommit: selection.fork.commit });
    }
    assert.equal(git(fork, "rev-parse", "HEAD"), commit);
    assert.deepEqual(readdirSync(join(env.TMPDIR)), []);
    assert.equal(readdirSync(target).some((name) => name.startsWith(".pi-subagents-update-")), false);
  }, true);
});

test("one staging owner excludes overlapping updates without changing its candidate", async () => {
  const { runUpdate } = await import(updater);
  fixture(({ target, fork, commit, spawn }) => {
    let overlapped = false;
    const duringBuild = (bin, args, options) => {
      if (!overlapped && bin === "npm" && args[0] === "ci") {
        overlapped = true;
        assert.throws(() => runUpdate({ gatewayDir: target, forkRepo: fork, commit, spawn }), /already running|staging owner/);
      }
      return spawn(bin, args, options);
    };
    assert.throws(() => runUpdate({ gatewayDir: target, forkRepo: fork, commit, spawn: duringBuild }), /execution gate/);
    assert.equal(overlapped, true);
    assert.notEqual(JSON.parse(readFileSync(join(target, "pi-subagents-pin.json"), "utf8")).version, "0.76.1-tron.99");
    assert.equal(readdirSync(target).some((name) => name.startsWith(".pi-subagents-update-")), false);
  });
});

for (const failure of ["ancestor", "version", "missing-source", "dirty", "late-check", "build", "execution", "rollback", "join"]) {
  test(`refuses ${failure} and restores only invocation-owned files`, async () => {
    const { runUpdate } = await import(updater);
    fixture(({ target, fork, commit, spawn, git, env, root }) => {
      if (failure === "ancestor") {
        const files = Object.fromEntries(["package.json", "package-lock.json", "build.mjs"].map((name) => [name, readFileSync(join(fork, name))]));
        git(fork, "checkout", "--orphan", "unrelated"); git(fork, "rm", "-rf", ".");
        for (const [name, bytes] of Object.entries(files)) writeFileSync(join(fork, name), bytes);
        git(fork, "add", "."); git(fork, "commit", "-qm", "unrelated");
        commit = git(fork, "rev-parse", "HEAD");
      }
      if (failure === "version") {
        const manifest = JSON.parse(readFileSync(join(fork, "package.json"), "utf8")); manifest.version = "0.76.1";
        writeFileSync(join(fork, "package.json"), JSON.stringify(manifest));
        const lock = JSON.parse(readFileSync(join(fork, "package-lock.json"), "utf8")); lock.version = manifest.version; lock.packages[""].version = manifest.version;
        writeFileSync(join(fork, "package-lock.json"), JSON.stringify(lock));
        git(fork, "add", "."); git(fork, "commit", "-qm", "not a Tron build"); commit = git(fork, "rev-parse", "HEAD");
      }
      if (failure === "build") {
        writeFileSync(join(fork, "build.mjs"), "process.exit(1);"); git(fork, "add", "."); git(fork, "commit", "-qm", "broken build"); commit = git(fork, "rev-parse", "HEAD");
      }
      const unrelated = join(target, "unrelated.txt"); writeFileSync(unrelated, "keep");
      if (failure === "dirty") writeFileSync(join(target, "pi-subagents-pin.json"), readFileSync(join(target, "pi-subagents-pin.json"), "utf8") + " ");
      const originalPin = readFileSync(join(target, "pi-subagents-pin.json")); const originalArtifacts = snapshot(target);
      if (failure === "rollback") {
        const probe = join(target, "src/sessions/managed-subagents.rollback.test.ts");
        // A real producer refusal on return, after candidate execution. No gate
        // result or provider implementation is mocked.
        const source = readFileSync(probe, "utf8");
        const altered = source.replace('id: candidateTarget, message: "Return CHILD_ROLLBACK_RESUMED"', 'id: "missing-resume-target", message: "Return CHILD_ROLLBACK_RESUMED"');
        assert.notEqual(altered, source);
        writeFileSync(probe, altered);
      }
      let writerPid;
      let preserved;
      const injected = (bin, args, options) => {
        if (failure === "join" && args.includes("src/sessions/managed-subagents.rollback.test.ts")) {
          const pidFile = join(root, "writer.pid");
          const writer = `const fs=require('node:fs'); process.removeAllListeners('SIGTERM'); process.on('SIGTERM',()=>{});
            fs.writeFileSync(${JSON.stringify(pidFile)},String(process.pid)); setInterval(()=>fs.writeFileSync(${JSON.stringify(join(root, "live"))},'writing'),1);`;
          // Permission-denied KILL is the unjoinable OS boundary. A process
          // cannot literally refuse SIGKILL; never make this a runtime hook.
          const program = `const fs=require('node:fs'); const child=require('node:child_process').spawn(process.execPath,['-e',${JSON.stringify(writer)}],{detached:true,stdio:'ignore'});
            const kill=process.kill.bind(process); process.kill=(pid,signal)=>{ if(signal==='SIGKILL') { const error=new Error('fixture termination denied'); error.code='EPERM'; throw error; } return kill(pid,signal); };
            const timer=setInterval(()=>{if(!fs.existsSync(${JSON.stringify(pidFile)})) return; clearInterval(timer); process.exit(0);},10);`;
          const result = spawnSync(process.execPath, ["--import", join(gateway, "test-support/fixture-process-owner.mjs"), "-e", program], {
            ...options, env: { ...options.env, TRON_TEST_PROCESS_OWNER: root,
              TRON_TEST_PROCESS_OWNER_FAILURE: options.env.TRON_TEST_PROCESS_OWNER_FAILURE ?? join(target, ".pi-subagents-update-staging", "process-owner-failure.jsonl"),
              NODE_OPTIONS: `--import=${join(gateway, "test-support/fixture-process-owner.mjs")}` }, timeout: 10_000,
          });
          writerPid = Number(readFileSync(pidFile, "utf8"));
          preserved = dirname(options.env.TRON_TEST_PROCESS_OWNER_FAILURE ?? join(target, ".pi-subagents-update-staging", "process-owner-failure.jsonl"));
          return result;
        }
        if (failure === "late-check" && bin === "npm" && args.join(" ") === "run check:pi-subagents") {
          assert.equal(JSON.parse(readFileSync(join(target, "pi-subagents-pin.json"), "utf8")).version, "0.76.1-tron.99");
          return { status: 1, stderr: "injected offline check failure" };
        }
        return spawn(bin, args, options);
      };
      try {
        assert.throws(() => runUpdate({ gatewayDir: target, forkRepo: failure === "missing-source" ? undefined : fork, commit, spawn: injected }), {
          message: failure === "ancestor" ? /ancestor/ : failure === "version" ? /-tron/ : failure === "missing-source" ? /--fork-repo/ : failure === "dirty" ? /uncommitted|dirty/ : failure === "build" ? /pack/ : failure === "execution" ? /execution gate/ : failure === "rollback" ? /rollback probe/ : failure === "join" ? /staging preserved.*fixture termination denied/s : /offline check failure/,
        });
        assert.deepEqual(readFileSync(join(target, "pi-subagents-pin.json")), originalPin);
        assert.deepEqual(snapshot(target), originalArtifacts);
        assert.equal(readFileSync(unrelated, "utf8"), "keep");
        assert.deepEqual(readdirSync(env.TMPDIR), []);
        if (failure === "join") {
          assert.equal(existsSync(preserved), true);
          const records = readFileSync(join(preserved, "process-owner-failure.jsonl"), "utf8").trim().split("\n").map(line => JSON.parse(line));
          assert.ok(records.some(record => record.pids.includes(writerPid)));
          assert.ok(records.some(record => record.attemptedSignals.includes("SIGKILL")));
        } else assert.equal(readdirSync(target).some((name) => name.startsWith(".pi-subagents-update-")), false);
        assert.equal(existsSync(join(target, "pi-subagents-pin.json.tmp")), false);
      } finally {
        // The denied OS boundary is injected only in the probe. The test owner
        // still kills and joins the actual writer before fixture retirement.
        if (writerPid) {
          try { process.kill(-writerPid, "SIGKILL"); } catch (error) { if (error.code !== "ESRCH") throw error; }
          const deadline = Date.now() + 5_000;
          while (true) {
            try { process.kill(writerPid, 0); } catch (error) { if (error.code === "ESRCH") break; throw error; }
            assert.ok(Date.now() < deadline, "writer must exit before removing preserved staging");
            Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 20);
          }
        }
      }
    }, failure === "late-check" || failure === "rollback" || failure === "join");
  });
}
