import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, symlink, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { promisify } from "node:util";
import {
  gatewayBuildInputFingerprint,
  verifyGatewayBuildInputReceipt,
  verifyGatewayInstallInputs,
  writeGatewayBuildInputReceipt,
} from "./gateway-install-inputs.mjs";

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

async function buildInputFixture(t) {
  const root = await mkdtemp(join(tmpdir(), "gateway-build-inputs-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const files = {
    ".node-version": "22.22.0\n",
    "config/ci-toolchain.env": "pins\n",
    "config/GatewayProtocol.json": "{}\n",
    "config/PushService.xcconfig": "origin\n",
    "packages/gateway/package.json": "{}\n",
    "packages/gateway/package-lock.json": "{}\n",
    "packages/gateway/tsconfig.json": "{}\n",
    "packages/gateway/scripts/check-pi-sdk.mjs": "// check\n",
    "packages/gateway/scripts/ensure-node-pty-helper.mjs": "// helper\n",
    "packages/gateway/scripts/check-pi-subagents.mjs": "// provider pin validator\n",
    "packages/gateway/scripts/install-pi-subagents.mjs": "// provider installer\n",
    "packages/gateway/pi-subagents-pin.json": "{}\n",
    "packages/mac-app/scripts/bundle-gateway.sh": "#!/bin/sh\n",
    "scripts/gateway-payload-deploy.mjs": "// deploy\n",
    "scripts/gateway-install-inputs.mjs": "// checker\n",
    "scripts/gateway_protocol_contract.py": "# contract\n",
    "scripts/hash-npm-runtime.py": "# hash\n",
    "scripts/install-ci-tools.sh": "#!/bin/sh\n",
    "scripts/validate-push-service-config.sh": "#!/bin/sh\n",
    "scripts/verify-gateway-protocol-contract.py": "# verifier\n",
    "packages/gateway/src/index.ts": "export const value = 1;\n",
  };
  for (const [path, content] of Object.entries(files)) {
    await mkdir(join(root, path, ".."), { recursive: true });
    await writeFile(join(root, path), content);
  }
  const app = join(root, "payload", "app");
  await mkdir(app, { recursive: true });
  return { root, app, source: join(root, "packages/gateway/src/index.ts"), baseline: files["packages/gateway/src/index.ts"] };
}

test("input receipt binds dirty source bytes, accepts matching dirty builds, and rejects later clean reuse", async (t) => {
  const { root, app, source, baseline } = await buildInputFixture(t);
  const revision = "0123456789abcdef0123456789abcdef01234567";
  const cleanFingerprint = await gatewayBuildInputFingerprint(root);
  const dirtyContent = "export const value = 2;\n";
  await writeFile(source, dirtyContent);
  const dirtyFingerprint = await gatewayBuildInputFingerprint(root);
  assert.notEqual(dirtyFingerprint, cleanFingerprint);
  await writeGatewayBuildInputReceipt(root, app, revision, dirtyFingerprint);
  await verifyGatewayBuildInputReceipt(root, app, revision, dirtyFingerprint);
  await writeFile(join(root, "unrelated-notes.txt"), "not a Gateway build input\n");
  await verifyGatewayBuildInputReceipt(root, app, revision, dirtyFingerprint);
  await writeFile(source, baseline);
  await assert.rejects(verifyGatewayBuildInputReceipt(root, app, revision), /does not match current build inputs/);
  assert.equal(await gatewayBuildInputFingerprint(root), cleanFingerprint);
});

test("input receipt binds copied provider installer, pin, and verifier bytes", async (t) => {
  const { root, app } = await buildInputFixture(t);
  const revision = "0123456789abcdef0123456789abcdef01234567";
  for (const relative of [
    "packages/gateway/scripts/install-pi-subagents.mjs",
    "packages/gateway/scripts/check-pi-subagents.mjs",
    "packages/gateway/pi-subagents-pin.json",
  ]) {
    const input = join(root, relative);
    const baseline = await readFile(input, "utf8");
    const sourceFingerprint = await gatewayBuildInputFingerprint(root);
    const dirty = relative.endsWith(".json") ? '{"changed":true}\n' : `${baseline}// dirty build input\n`;
    await writeFile(input, dirty);
    const dirtyFingerprint = await gatewayBuildInputFingerprint(root);
    assert.notEqual(dirtyFingerprint, sourceFingerprint, `${relative} must affect the build receipt`);
    await writeGatewayBuildInputReceipt(root, app, revision, dirtyFingerprint);
    await verifyGatewayBuildInputReceipt(root, app, revision, dirtyFingerprint);
    await writeFile(input, baseline);
    await assert.rejects(verifyGatewayBuildInputReceipt(root, app, revision), /does not match current build inputs/);
  }
});

test("accepts canonical full and Mac production installs despite npm hidden-lock differences", async (t) => {
  const full = await fixture(t);
  const later = new Date(Date.now() + 10_000);
  await utimes(join(full, "node_modules", "required"), later, later);
  assert.deepEqual(await verifyGatewayInstallInputs(full), { valid: true, mode: "full" });
  const production = await fixture(t);
  const hiddenPath = join(production, "node_modules", ".package-lock.json");
  const hidden = JSON.parse(await (await import("node:fs/promises")).readFile(hiddenPath, "utf8"));
  delete hidden.packages["node_modules/compiler"];
  delete hidden.packages["node_modules/other-platform"];
  await writeFile(hiddenPath, JSON.stringify(hidden));
  await rm(join(production, "node_modules", "compiler"), { recursive: true });
  assert.deepEqual(await verifyGatewayInstallInputs(production, { mode: "production" }), { valid: true, mode: "production" });
});

test("rejects a package manifest whose root dependency declarations differ from the lock", async (t) => {
  const root = await fixture(t);
  await writeFile(join(root, "package.json"), JSON.stringify({
    name: lock.name, version: lock.version,
    dependencies: { required: "2.0.0" }, devDependencies: lock.packages[""].devDependencies,
  }));
  await assert.rejects(verifyGatewayInstallInputs(root), /root identity, or dependency manifest.*stale.*npm ci/);
});

test("rejects stale locked versions before a source build can compile", async (t) => {
  const root = await fixture(t, async (installed) => {
    installed.packages["node_modules/required"].version = "0.9.0";
  });
  await assert.rejects(verifyGatewayInstallInputs(root), /node_modules\/required.*does not match package-lock/);
});

test("Debug build input check command refuses stale installs before staging", async (t) => {
  const root = await fixture(t, async (installed) => {
    installed.packages["node_modules/required"].version = "0.9.0";
  });
  const cli = new URL("./gateway-install-inputs.mjs", import.meta.url);
  await assert.rejects(
    execFileAsync(process.execPath, [fileURLToPath(cli), "check", root, "full"]),
    (error) => error.code === 78 && /node_modules\/required.*does not match package-lock.*npm ci/.test(error.stderr),
  );
});

test("rejects missing, substituted, or extra actual package directories", async (t) => {
  const missing = await fixture(t);
  await rm(join(missing, "node_modules", "required"), { recursive: true });
  await assert.rejects(verifyGatewayInstallInputs(missing), /node_modules\/required.*missing/);

  const substituted = await fixture(t);
  await writeFile(join(substituted, "node_modules", "required", "package.json"), JSON.stringify({ name: "required", version: "0.9.0" }));
  await assert.rejects(verifyGatewayInstallInputs(substituted), /actual package.*required.*0.9.0/);

  const extra = await fixture(t);
  await mkdir(join(extra, "node_modules", "unlocked"), { recursive: true });
  await writeFile(join(extra, "node_modules", "unlocked", "package.json"), JSON.stringify({ name: "unlocked", version: "1.0.0" }));
  await assert.rejects(verifyGatewayInstallInputs(extra), /unlocked package.*node_modules\/unlocked/);

  const linked = await fixture(t);
  await rm(join(linked, "node_modules", "required"), { recursive: true });
  await symlink("../required-target", join(linked, "node_modules", "required"));
  await mkdir(join(linked, "required-target"), { recursive: true });
  await writeFile(join(linked, "required-target", "package.json"), JSON.stringify({ name: "required", version: "1.0.0" }));
  await assert.rejects(verifyGatewayInstallInputs(linked), /symlink|unsafe|regular package directory/);
});

test("rejects package symlinks before walking their nested dependency directories", async (t) => {
  const root = await fixture(t);
  const external = join(root, "external-package");
  await mkdir(join(external, "node_modules", "@external"), { recursive: true });
  await symlink(join(root, "external-target"), join(external, "node_modules", "@external", "target"));
  await mkdir(join(root, "external-target"), { recursive: true });
  await rm(join(root, "node_modules", "required"), { recursive: true });
  await symlink(external, join(root, "node_modules", "required"));
  await assert.rejects(verifyGatewayInstallInputs(root), /installed package node_modules\/required is a symlink/);
});

test("rejects an absent hidden lock and stale or incomplete lock metadata", async (t) => {
  const missing = await fixture(t);
  await rm(join(missing, "node_modules", ".package-lock.json"));
  await assert.rejects(verifyGatewayInstallInputs(missing), /npm ci/);

  const stale = await fixture(t);
  const hiddenPath = join(stale, "node_modules", ".package-lock.json");
  const hidden = JSON.parse(await (await import("node:fs/promises")).readFile(hiddenPath, "utf8"));
  hidden.packages["node_modules/required"].integrity = "sha512-stale";
  await writeFile(hiddenPath, JSON.stringify(hidden));
  await assert.rejects(verifyGatewayInstallInputs(stale), /hidden lock.*package-lock/);
});
