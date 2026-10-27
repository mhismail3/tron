import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { copyFile, mkdir, mkdtemp, readFile, realpath, rename, rm, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const lock = {
  name: "@tron/gateway", version: "1.0.0", lockfileVersion: 3,
  packages: {
    "": { name: "@tron/gateway", version: "1.0.0", dependencies: { required: "1.0.0" }, devDependencies: { compiler: "1.0.0" } },
    "node_modules/required": { version: "1.0.0", resolved: "https://registry.npmjs.org/required/-/required-1.0.0.tgz", integrity: "sha512-required", dependencies: {} },
    "node_modules/compiler": { version: "1.0.0", resolved: "https://registry.npmjs.org/compiler/-/compiler-1.0.0.tgz", integrity: "sha512-compiler", dev: true },
    "node_modules/optional-native": { version: "1.0.0", resolved: "https://registry.npmjs.org/optional-native/-/optional-native-1.0.0.tgz", integrity: "sha512-optional", optional: true, os: ["darwin"], cpu: ["arm64"] },
    "node_modules/other-platform": { version: "1.0.0", resolved: "https://registry.npmjs.org/other-platform/-/other-platform-1.0.0.tgz", integrity: "sha512-other", optional: true, os: ["linux"] },
  },
};

async function fixture(t, mutate = () => {}) {
  const root = await mkdtemp(join(tmpdir(), "gateway-install-inputs-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  await writeFile(join(root, "package.json"), JSON.stringify({
    name: lock.name, version: lock.version,
    dependencies: lock.packages[""].dependencies,
    devDependencies: lock.packages[""].devDependencies,
  }));
  await writeFile(join(root, "package-lock.json"), JSON.stringify(lock));
  const installed = structuredClone(lock);
  await mutate(installed);
  await mkdir(join(root, "node_modules"), { recursive: true });
  for (const [location, record] of Object.entries(installed.packages)) {
    if (!location || (record.os && !record.os.includes(process.platform)) || (record.cpu && !record.cpu.includes(process.arch))) continue;
    const name = location.slice("node_modules/".length);
    const packageRoot = join(root, "node_modules", name);
    await mkdir(packageRoot, { recursive: true });
    await writeFile(join(packageRoot, "package.json"), JSON.stringify({ name: name.replace(/^@([^/]+)\/(.+)$/u, "@$1/$2"), version: record.version }));
  }
  const hidden = {
    name: lock.name, version: lock.version, lockfileVersion: 3,
    packages: Object.fromEntries(Object.entries(installed.packages).filter(([location, record]) => location
      && (!record.os || record.os.includes(process.platform))
      && (!record.cpu || record.cpu.includes(process.arch)))),
  };
  await writeFile(join(root, "node_modules", ".package-lock.json"), JSON.stringify(hidden));
  const future = new Date(Date.now() + 2_000);
  await utimes(join(root, "node_modules", ".package-lock.json"), future, future);
  for (const location of Object.keys(hidden.packages)) {
    const name = location.slice("node_modules/".length);
    await utimes(join(root, "node_modules", name), new Date(Date.now()), new Date(Date.now()));
  }
  return root;
}

test("Quick replacement refuses missing or partial installs at Preflight before worker drain", async (t) => {
  const root = await realpath(await fixture(t));
  const repo = join(root, "repo");
  const gateway = join(repo, "packages/gateway");
  await mkdir(gateway, { recursive: true });
  await mkdir(join(repo, "scripts"));
  for (const name of ["package.json", "package-lock.json", "node_modules"]) {
    await rename(join(root, name), join(gateway, name));
  }
  await copyFile(cli, join(repo, "scripts/gateway-install-inputs.mjs"));
  await writeFile(join(repo, ".gitignore"), "node_modules/\n");
  const env = { ...process.env, TRON_DATA_DIR: "", TRON_HOME_NAME: "", PI_CODING_AGENT_DIR: "" };
  for (const args of [["init", "--quiet"], ["add", "."],
    ["-c", "user.name=Fixture", "-c", "user.email=fixture@invalid", "commit", "--quiet", "-m", "fixture"]]) {
    await execFileAsync("git", args, { cwd: repo, env });
  }
  const scripts = dirname(cli);
  const child = `
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from tron_mac_replace import Runner, Failure, git
from tron_mac_replace_journal import Journal
from tron_mac_replace_platform import MacPlatform
class Platform(MacPlatform):
    gateway_label = 'com.tron.fixture.missing-deps'
    helper_label = gateway_label + '.helper'
    def node(self):
        return Path(sys.argv[3]), Path(sys.argv[2]) / 'unused'
root = Path(sys.argv[2])
platform = Platform(root / 'home')
platform.home.mkdir(exist_ok=True)
revision = git(root, 'rev-parse', 'HEAD')
journal = Journal.create(root / 'journal', 'fixture', 'quick', 'fixture', {'root': str(root), 'revision': revision})
try:
    Runner(platform, journal).step_preflight()
except Failure as error:
    sys.exit(str(error))
`;
  async function preflight() {
    try {
      await execFileAsync("/usr/bin/python3", ["-c", child, scripts, repo, process.execPath], { env });
      assert.fail("fixture Gateway is deliberately absent");
    } catch (error) {
      assert.equal(error.code, 1);
      return error.stderr;
    }
  }
  // A valid install passes the real verifier and reaches the unrelated fixture registration check.
  assert.match(await preflight(), /com\.tron\.fixture\.missing-deps is absent/);
  for (const missing of ["node_modules/required", "node_modules"]) {
    await rm(join(gateway, missing), { recursive: true, force: true });
    const message = await preflight();
    assert.match(message, /Quick rebuild dependencies do not match package-lock/);
    assert.match(message, /npm ci --include=dev/);
    assert.doesNotMatch(message, /is absent/);
  }
});

test("Debug build input check command refuses stale installs before staging", async (t) => {
  const root = await fixture(t, async (installed) => {
    installed.packages["node_modules/required"].version = "0.9.0";
  });
  await assert.rejects(
    execFileAsync(process.execPath, [cli, "check", root, "full"]),
    (error) => error.code === 78 && /node_modules\/required.*does not match package-lock.*npm ci/.test(error.stderr),
  );
});

// #1010: a checkout whose lock moved without a reinstall (installed 0.9.0, locked
// 1.0.0) is repaired by a real `npm ci` from local tarballs, the same command
// Rebuild from Source runs with the payload's pinned runtime. Tracked inputs and
// an untracked file such as build.pid must survive byte for byte.
async function driftedInstall(t) {
  const root = await mkdtemp(join(tmpdir(), "gateway-install-repair-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const env = { ...process.env, HOME: join(root, "home"), npm_config_cache: join(root, "npm-cache"),
    npm_config_audit: "false", npm_config_fund: "false", npm_config_update_notifier: "false" };
  const npm = (args, cwd) => execFileAsync(process.execPath, [join(dirname(process.execPath), "npm"), ...args], { cwd, env });
  const tarballs = join(root, "tarballs");
  await mkdir(tarballs, { recursive: true });
  for (const version of ["0.9.0", "1.0.0"]) {
    const source = join(root, `dep-${version}`);
    await mkdir(source, { recursive: true });
    await writeFile(join(source, "package.json"), JSON.stringify({ name: "tron-drift-dep", version }));
    await writeFile(join(source, "index.js"), `module.exports = ${JSON.stringify(version)};\n`);
    await npm(["pack", "--pack-destination", tarballs], source);
  }
  const gateway = join(root, "gateway");
  await mkdir(gateway, { recursive: true });
  const install = async (version) => {
    await writeFile(join(gateway, "package.json"), JSON.stringify({ name: "@tron/gateway", version: "1.0.0",
      dependencies: { "tron-drift-dep": `file:../tarballs/tron-drift-dep-${version}.tgz` } }));
    await rm(join(gateway, "package-lock.json"), { force: true });
    await npm(["install", "--offline"], gateway);
  };
  // Install the old lock, keep its node_modules, then move the tracked files to
  // the new lock exactly as a fast-forward of main does.
  await install("1.0.0");
  const tracked = { manifest: await readFile(join(gateway, "package.json")), lock: await readFile(join(gateway, "package-lock.json")) };
  await install("0.9.0");
  await writeFile(join(gateway, "package.json"), tracked.manifest);
  await writeFile(join(gateway, "package-lock.json"), tracked.lock);
  await writeFile(join(gateway, "build.pid"), "4242\n");
  return { root, gateway, env, tracked, tarballs };
}

const cli = fileURLToPath(new URL("./gateway-install-inputs.mjs", import.meta.url));

test("Rebuild from Source repairs node_modules drift from package-lock with npm ci", async (t) => {
  const { gateway, env, tracked } = await driftedInstall(t);
  await assert.rejects(execFileAsync(process.execPath, [cli, "check", gateway, "full"], { env }),
    (error) => error.code === 78 && /tron-drift-dep.*does not match package-lock/.test(error.stderr));

  const { stdout } = await execFileAsync(process.execPath, [cli, "ensure", gateway, dirname(process.execPath)], { env });
  assert.match(stdout, /Gateway install drifted \(npm hidden lock package node_modules\/tron-drift-dep does not match package-lock\); running npm ci/);
  assert.match(stdout, /match package-lock.json after npm ci/);
  await execFileAsync(process.execPath, [cli, "check", gateway, "full"], { env });
  assert.equal(JSON.parse(await readFile(join(gateway, "node_modules", "tron-drift-dep", "package.json"), "utf8")).version, "1.0.0");
  assert.deepEqual(await readFile(join(gateway, "package.json")), tracked.manifest);
  assert.deepEqual(await readFile(join(gateway, "package-lock.json")), tracked.lock);
  assert.equal(await readFile(join(gateway, "build.pid"), "utf8"), "4242\n");

  // A matching install is left alone.
  const second = await execFileAsync(process.execPath, [cli, "ensure", gateway, dirname(process.execPath)], { env });
  assert.equal(second.stdout.trim(), "Gateway full installed inputs match package-lock.json");
});

test("Rebuild from Source fails loudly with the exact command when npm ci cannot repair drift", async (t) => {
  const { gateway, env, tarballs } = await driftedInstall(t);
  // Offline with the locked tarball gone and a cold cache: npm ci cannot succeed.
  await rm(join(tarballs, "tron-drift-dep-1.0.0.tgz"));
  await rm(env.npm_config_cache, { recursive: true, force: true });
  const runtimeBin = dirname(process.execPath);
  await assert.rejects(execFileAsync(process.execPath, [cli, "ensure", gateway, runtimeBin], { env: { ...env, npm_config_offline: "true" } }),
    (error) => error.code === 78
      && error.stderr.includes("automatic npm ci failed")
      && error.stderr.includes(`Run: cd '${gateway}' && PATH='${runtimeBin}':"$PATH" npm ci`));
  assert.equal(await readFile(join(gateway, "build.pid"), "utf8"), "4242\n");
});
