import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { DIRECT_PI_PACKAGES, PI_PACKAGES, validSha512Integrity, validatePiSdk } from "./check-pi-sdk.mjs";

const version = "1.2.3";
const integrity = `sha512-${Buffer.alloc(64).toString("base64")}`;
const short = (name) => name.slice(name.indexOf("/") + 1);
const tarball = (name) => `https://registry.npmjs.org/${name}/-/${short(name)}-${version}.tgz`;
const lockPath = (name, nested = false) => nested
  ? `node_modules/@earendil-works/pi-coding-agent/node_modules/${name}`
  : `node_modules/${name}`;

async function fixture({ installed = false } = {}) {
  const root = await mkdtemp(join(tmpdir(), "tron-pi-sdk-check-"));
  const packages = { "": { dependencies: Object.fromEntries(DIRECT_PI_PACKAGES.map((name) => [name, version])) } };
  for (const name of PI_PACKAGES) {
    const nested = !DIRECT_PI_PACKAGES.includes(name);
    packages[lockPath(name, nested)] = {
      version, resolved: tarball(name), ...(nested ? {} : { integrity }),
    };
  }
  await writeFile(join(root, "package.json"), JSON.stringify({ dependencies: Object.fromEntries(DIRECT_PI_PACKAGES.map((name) => [name, version])) }));
  await writeFile(join(root, "pi-sdk-baseline.json"), JSON.stringify({ schema: 1, rollbackVersion: version }));
  await writeFile(join(root, "package-lock.json"), JSON.stringify({ lockfileVersion: 3, packages }));
  if (installed) {
    for (const name of PI_PACKAGES) {
      const nested = !DIRECT_PI_PACKAGES.includes(name);
      const packageRoot = join(root, lockPath(name, nested));
      await mkdir(packageRoot, { recursive: true });
      const packageJson = { name, version };
      if (name === "@earendil-works/pi-coding-agent") packageJson.bin = { pi: "dist/cli.js" };
      await writeFile(join(packageRoot, "package.json"), JSON.stringify(packageJson));
      if (name === "@earendil-works/pi-coding-agent") {
        await mkdir(join(packageRoot, "dist"));
        await writeFile(join(packageRoot, "dist/cli.js"), "#!/usr/bin/env node\n");
        await (await import("node:fs/promises")).chmod(join(packageRoot, "dist/cli.js"), 0o755);
      }
    }
    await mkdir(join(root, "node_modules", ".bin"), { recursive: true });
    await (await import("node:fs/promises")).symlink("../@earendil-works/pi-coding-agent/dist/cli.js", join(root, "node_modules", ".bin", "pi"));
  }
  return root;
}

async function withFixture(options, callback) {
  const root = await fixture(options);
  try { await callback(root); } finally { await rm(root, { recursive: true, force: true }); }
}

async function editJson(root, file, mutate) {
  const path = join(root, file);
  const value = JSON.parse(await (await import("node:fs/promises")).readFile(path, "utf8"));
  mutate(value);
  await writeFile(path, JSON.stringify(value));
}

test("accepts npm's current nested pi-coding-agent shrinkwrap shape", async () => {
  await withFixture({}, (root) => assert.deepEqual(validatePiSdk({ gatewayDir: root }), {
    ok: true, version, rollbackVersion: version, packages: [...PI_PACKAGES].sort(), installedChecked: false, issues: [],
  }));
});

test("validates actual 64-byte sha512 integrity values", () => {
  assert.equal(validSha512Integrity(integrity), true);
  assert.equal(validSha512Integrity("sha512-AAAAAAAA"), false);
  assert.equal(validSha512Integrity(`sha512-${"A".repeat(88)}`), false);
});

test("accepts every resolved Pi package and installed metadata when present", async () => {
  await withFixture({ installed: true }, (root) => {
    const report = validatePiSdk({ gatewayDir: root });
    assert.equal(report.ok, true, report.issues.join("\n"));
    assert.equal(report.installedChecked, true);
  });
});

test("rejects malformed package JSON with an actionable diagnostic", async () => {
  await withFixture({}, async (root) => {
    await writeFile(join(root, "package-lock.json"), "{not-json");
    const report = validatePiSdk({ gatewayDir: root });
    assert.equal(report.ok, false);
    assert.match(report.issues.join("\\n"), /package-lock\.json is not valid JSON/);
  });
});

test("allows staged runtime-tree checks to omit development rollback metadata", async () => {
  await withFixture({}, async (root) => {
    await (await import("node:fs/promises")).unlink(join(root, "pi-sdk-baseline.json"));
    const report = validatePiSdk({ gatewayDir: root, checkInstalled: false, requireBaseline: false });
    assert.equal(report.ok, true, report.issues.join("\n"));
  });
});

test("rejects missing or malformed rollback metadata", async () => {
  await withFixture({}, async (root) => {
    await writeFile(join(root, "pi-sdk-baseline.json"), JSON.stringify({ schema: 2, rollbackVersion: version }));
    const report = validatePiSdk({ gatewayDir: root, checkInstalled: false });
    assert.equal(report.ok, false);
    assert.match(report.issues.join("\n"), /pi-sdk-baseline\.json/);
  });
});

test("rejects ranged or missing direct declarations", async () => {
  await withFixture({}, async (root) => {
    await editJson(root, "package.json", (value) => { delete value.dependencies[DIRECT_PI_PACKAGES[0]]; value.dependencies[DIRECT_PI_PACKAGES[1]] = `^${version}`; });
    const report = validatePiSdk({ gatewayDir: root });
    assert.equal(report.ok, false);
    assert.match(report.issues.join("\n"), /exact semver/);
  });
});

test("rejects an unexpected new Pi package until its release is researched", async () => {
  await withFixture({}, async (root) => {
    await editJson(root, "package-lock.json", (value) => {
      value.packages["node_modules/@earendil-works/pi-new"] = {
        version, resolved: tarball("@earendil-works/pi-new"), integrity,
      };
    });
    const report = validatePiSdk({ gatewayDir: root });
    assert.equal(report.ok, false);
    assert.match(report.issues.join("\\n"), /unexpected .*pi-new.*research the release/);
  });
});

test("requires every direct Pi dependency to have a top-level lock entry", async () => {
  await withFixture({}, async (root) => {
    await editJson(root, "package-lock.json", (value) => {
      delete value.packages[lockPath(DIRECT_PI_PACKAGES[0])];
      delete value.packages[lockPath(DIRECT_PI_PACKAGES[0], true)];
      value.packages[lockPath(DIRECT_PI_PACKAGES[0], true)] = {
        version, resolved: tarball(DIRECT_PI_PACKAGES[0]), integrity,
      };
    });
    const report = validatePiSdk({ gatewayDir: root, checkInstalled: false });
    assert.equal(report.ok, false);
    assert.match(report.issues.join("\\n"), /missing top-level direct Pi package/);
  });
});

test("rejects mixed, missing, and non-canonical lock entries", async () => {
  await withFixture({}, async (root) => {
    await editJson(root, "package-lock.json", (value) => {
      value.packages[lockPath(PI_PACKAGES[0])].version = "0.84.0";
      delete value.packages[lockPath(PI_PACKAGES[1])].resolved;
      delete value.packages[lockPath(PI_PACKAGES[2])].integrity;
      delete value.packages[lockPath(PI_PACKAGES[5], true)];
    });
    const report = validatePiSdk({ gatewayDir: root });
    assert.equal(report.ok, false);
    assert.match(report.issues.join("\n"), /resolves 0\.84\.0/);
    assert.match(report.issues.join("\n"), /canonical registry tarball/);
    assert.match(report.issues.join("\n"), /missing npm integrity/);
    assert.match(report.issues.join("\n"), /missing resolved Pi package/);
  });
});

test("rejects an npm projection that disagrees with the declared bin", async () => {
  await withFixture({ installed: true }, async (root) => {
    const projection = join(root, "node_modules", ".bin", "pi");
    await (await import("node:fs/promises")).unlink(projection);
    await (await import("node:fs/promises")).symlink("../pi-agent-core/package.json", projection);
    const report = validatePiSdk({ gatewayDir: root });
    assert.equal(report.ok, false);
    assert.match(report.issues.join("\n"), /node_modules\/\.bin\/pi/);
  });
});

test("rejects installed version drift and unsafe pi-coding-agent bins", async () => {
  await withFixture({ installed: true }, async (root) => {
    await editJson(root, "node_modules/@earendil-works/pi-coding-agent/package.json", (value) => { value.bin.pi = "../escape.js"; });
    const report = validatePiSdk({ gatewayDir: root });
    assert.equal(report.ok, false);
    assert.match(report.issues.join("\n"), /safe relative bin\.pi/);
  });
  await withFixture({ installed: true }, async (root) => {
    await editJson(root, "node_modules/@earendil-works/pi-agent-core/package.json", (value) => { value.version = "0.84.0"; });
    const report = validatePiSdk({ gatewayDir: root });
    assert.equal(report.ok, false);
    assert.match(report.issues.join("\n"), /installed .* is 0\.84\.0/);
  });
});
