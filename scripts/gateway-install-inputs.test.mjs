import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdir, mkdtemp, rm, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
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
