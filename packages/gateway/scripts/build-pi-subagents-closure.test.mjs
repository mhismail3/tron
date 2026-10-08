import assert from "node:assert/strict";
import test from "node:test";
import { createHash } from "node:crypto";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const scripts = dirname(fileURLToPath(import.meta.url));
const hash = (path, algorithm) => createHash(algorithm).update(readFileSync(path)).digest("hex");

function run(command, args, options = {}) {
  const result = spawnSync(command, args, { encoding: "utf8", timeout: 30_000, ...options });
  assert.equal(result.status, 0, result.error?.message || result.stderr || result.stdout);
  return result.stdout;
}

test("a runtime-only lock builds with real npm without resolving development dependencies", () => {
  const root = mkdtempSync(join(tmpdir(), "tron-closure-test-"));
  try {
    for (const path of ["scripts", "artifacts", "source/package", "dependency/package", "home", "tmp"]) {
      mkdirSync(join(root, path), { recursive: true });
    }
    copyFileSync(join(scripts, "build-pi-subagents-closure.py"), join(root, "scripts/build.py"));
    const dependency = { name: "closure-test-runtime", version: "1.0.0" };
    writeFileSync(join(root, "dependency/package/package.json"), JSON.stringify(dependency));
    const dependencyArchive = join(root, "artifacts/dependency.tgz");
    run("tar", ["-czf", dependencyArchive, "-C", join(root, "dependency"), "package"]);
    const manifest = {
      name: "pi-subagents", version: "0.59.0",
      dependencies: { "closure-test-runtime": "1.0.0" },
      devDependencies: { "closure-test-unavailable-dev": "1.0.0" },
    };
    writeFileSync(join(root, "source/package/package.json"), JSON.stringify(manifest));
    const sourceArchive = join(root, "artifacts/source.tgz");
    run("tar", ["-czf", sourceArchive, "-C", join(root, "source"), "package/package.json"]);
    const lock = {
      name: manifest.name, version: manifest.version, lockfileVersion: 3, requires: true,
      packages: {
        "": { name: manifest.name, version: manifest.version, dependencies: manifest.dependencies },
        "node_modules/closure-test-runtime": {
          version: dependency.version, resolved: `file:${dependencyArchive}`,
          integrity: `sha512-${createHash("sha512").update(readFileSync(dependencyArchive)).digest("base64")}`,
        },
      },
    };
    const lockPath = join(root, "artifacts/lock.json");
    writeFileSync(lockPath, JSON.stringify(lock));
    writeFileSync(join(root, "pi-subagents-pin.json"), JSON.stringify({
      name: manifest.name, version: manifest.version,
      sourceArchive: { path: "artifacts/source.tgz", sha256: hash(sourceArchive, "sha256") },
      lockfile: { path: "artifacts/lock.json", sha256: hash(lockPath, "sha256") },
      closure: { path: "artifacts/closure.tgz" },
    }));
    run("python3", ["-X", "faulthandler", join(root, "scripts/build.py")], {
      env: {
        PATH: process.env.PATH, HOME: join(root, "home"), TMPDIR: join(root, "tmp"),
        npm_config_registry: "http://127.0.0.1:1", npm_config_fetch_retries: "0",
        npm_config_fetch_timeout: "1000",
      },
    });
    const archive = join(root, "artifacts/closure.tgz");
    const packaged = JSON.parse(run("tar", ["-xOzf", archive, "package/package.json"]));
    assert.deepEqual(packaged, { ...manifest, bundledDependencies: [dependency.name] });
    assert.deepEqual(JSON.parse(run("tar", ["-xOzf", archive, `package/node_modules/${dependency.name}/package.json`])), dependency);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
