import assert from "node:assert/strict";
import test, { after, before } from "node:test";
import { createHash } from "node:crypto";
import { copyFileSync, cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const gateway = dirname(dirname(fileURLToPath(import.meta.url)));
const checker = join(gateway, "scripts/check-pi-subagents.mjs");
const pinPath = join(gateway, "pi-subagents-pin.json");

function check(root) {
  return spawnSync(process.execPath, [checker, ...(root ? ["--root", root] : [])], { cwd: gateway, encoding: "utf8", timeout: 15_000 });
}
function copyInputs(root, pin) {
  mkdirSync(join(root, "artifacts"));
  const paths = new Set();
  for (const selection of [pin, pin.previous].filter(Boolean)) {
    paths.add(selection.sourceArchive?.path ?? selection.path);
    paths.add(selection.lockfile?.path);
    paths.add(selection.closure?.path);
  }
  for (const path of paths) copyFileSync(join(gateway, path), join(root, path));
}

const digest = (path, algorithm) => createHash(algorithm).update(readFileSync(path)).digest("hex");
function tar(args) {
  const result = spawnSync("tar", args, { encoding: "utf8", timeout: 10_000 });
  assert.equal(result.status, 0, result.stderr || result.error?.message);
}
function alterJson(path, alter) {
  const data = JSON.parse(readFileSync(path, "utf8"));
  alter(data);
  writeFileSync(path, JSON.stringify(data));
}
let baselineRoot;
before(() => {
  baselineRoot = mkdtempSync(join(tmpdir(), "tron-closure-baselines-"));
  try {
    for (const selectionName of ["current", "fork predecessor", "registry predecessor"]) {
      const root = join(baselineRoot, selectionName);
      mkdirSync(root);
      const pin = JSON.parse(readFileSync(pinPath, "utf8"));
      if (selectionName === "registry predecessor") {
        const source = "artifacts/pi-subagents-0.59.0.tgz";
        const lock = "artifacts/pi-subagents-0.59.0-package-lock.json";
        const closure = "artifacts/pi-subagents-0.59.0-closure.tgz";
        pin.previous = { version: "0.59.0", path: source, sha512: digest(join(gateway, source), "sha512"),
          sourceIntegrity: `sha512-${createHash("sha512").update(readFileSync(join(gateway, source))).digest("base64")}`,
          lockfile: { path: lock, sha256: digest(join(gateway, lock), "sha256") },
          closure: { path: closure, sha512: digest(join(gateway, closure), "sha512") } };
      }
      copyInputs(root, pin);
      writeFileSync(join(root, "pi-subagents-pin.json"), JSON.stringify(pin));
      const selection = selectionName === "current" ? pin : pin.previous;
      const archive = join(gateway, selection.closure.path);
      const listing = spawnSync("tar", ["-tzf", archive], { encoding: "utf8", timeout: 10_000 });
      assert.equal(listing.status, 0, listing.stderr || listing.error?.message);
      // These mutations exercise graph metadata, not execution. Preserve the
      // real closure's manifests/locks once, avoiding full runtime-byte repacks
      // in every case. The provenance test below still checks the actual archive.
      const manifests = listing.stdout.split("\n").filter((entry) => /\/(?:package\.json|package-lock\.json|\.package-lock\.json)$/u.test(entry));
      mkdirSync(join(root, "unpacked"));
      tar(["-xzf", archive, "-C", join(root, "unpacked"), ...manifests]);
    }
  } catch (error) {
    rmSync(baselineRoot, { recursive: true, force: true });
    throw error;
  }
});
after(() => { if (baselineRoot) rmSync(baselineRoot, { recursive: true, force: true }); });

function alteredClosure(selectionName, alter, run) {
  const root = mkdtempSync(join(tmpdir(), "tron-closure-graph-"));
  try {
    cpSync(join(baselineRoot, selectionName), root, { recursive: true });
    const pin = JSON.parse(readFileSync(join(root, "pi-subagents-pin.json"), "utf8"));
    const selection = selectionName === "current" ? pin : pin.previous;
    const unpacked = join(root, "unpacked");
    alter(join(unpacked, "package"));
    const archive = join(root, "closure.tgz");
    tar(["-czf", archive, "-C", unpacked, "package"]);
    selection.closure = { path: relative(root, archive), sha512: digest(archive, "sha512") };
    writeFileSync(join(root, "pi-subagents-pin.json"), JSON.stringify(pin));
    run(check(root));
  } finally { rmSync(root, { recursive: true, force: true }); }
}

for (const selection of ["current", "fork predecessor"]) {
  test(`refuses a missing transitive runtime dependency in the ${selection}`, () => {
    alteredClosure(selection, (root) => rmSync(join(root, "node_modules/jsbi"), { recursive: true }), (result) => {
      assert.notEqual(result.status, 0, "closure missing jsbi unexpectedly passed");
      assert.match(result.stderr, /missing.*jsbi/iu);
    });
  });
}

test("refuses an unpinned nested package that shadows the locked hoisted dependency", () => {
  alteredClosure("current", (root) => {
    const nested = join(root, "node_modules/@js-temporal/polyfill/node_modules/jsbi");
    cpSync(join(root, "node_modules/jsbi"), nested, { recursive: true });
    alterJson(join(nested, "package.json"), (manifest) => { manifest.version = "0.0.0"; });
  }, (result) => {
    assert.notEqual(result.status, 0, "unlocked nested dependency unexpectedly passed");
    assert.match(result.stderr, /dependency.*resolution/iu);
  });
});

for (const selection of ["current", "registry predecessor"]) {
  for (const failure of ["version", "integrity", "resolution", "runtime declarations", "source declarations"]) {
    test(`refuses ${failure} mismatch in the ${selection} closure`, () => {
      alteredClosure(selection, (root) => {
        const dependency = selection === "current" ? "jsbi" : "acorn";
        if (failure === "version") alterJson(join(root, `node_modules/${dependency}/package.json`), (manifest) => { manifest.version = "0.0.0"; });
        if (failure === "integrity" || failure === "resolution") alterJson(join(root, "node_modules/.package-lock.json"), (lock) => {
          lock.packages[`node_modules/${dependency}`][failure === "integrity" ? "integrity" : "resolved"] = failure === "integrity" ? `sha512-${Buffer.alloc(64).toString("base64")}` : "https://example.invalid/dependency.tgz";
        });
        if (failure === "runtime declarations") alterJson(join(root, `node_modules/${dependency}/package.json`), (manifest) => { manifest.dependencies = { "not-packaged": "1.0.0" }; });
        if (failure === "source declarations") alterJson(join(root, "package.json"), (manifest) => {
          delete manifest.dependencies.acorn;
          manifest.bundledDependencies = manifest.bundledDependencies.filter((name) => name !== "acorn");
        });
      }, (result) => {
        assert.notEqual(result.status, 0, `${failure} mismatch unexpectedly passed`);
        assert.match(result.stderr, /dependency|dependencies|integrity|resolution/iu);
      });
    });
  }
}

test("resolves nested versions, scoped hoisting and cycles without bundling host peers", () => {
  const root = mkdtempSync(join(tmpdir(), "tron-closure-graph-"));
  try {
    const pin = JSON.parse(readFileSync(pinPath, "utf8"));
    pin.previous = null;
    const manifest = { name: pin.name, version: pin.version, dependencies: { alpha: "^1.0.0", "@fixture/beta": "^1.0.0" },
      peerDependencies: { "@earendil-works/pi-ai": "*", typebox: "*" } };
    const nodes = {
      "node_modules/alpha": { name: "alpha", version: "1.0.0", dependencies: { shared: "^2.0.0" } },
      "node_modules/@fixture/beta": { name: "@fixture/beta", version: "1.0.0", dependencies: { shared: "^1.0.0", alpha: "^1.0.0" } },
      "node_modules/shared": { name: "shared", version: "1.0.0", dependencies: { "@fixture/beta": "^1.0.0" } },
      "node_modules/alpha/node_modules/shared": { name: "shared", version: "2.0.0" },
    };
    const records = Object.fromEntries(Object.entries(nodes).map(([path, node]) => [path, { ...node,
      resolved: `https://example.invalid/${node.name}-${node.version}.tgz`, integrity: `sha512-${Buffer.alloc(64).toString("base64")}` }]));
    const lock = { name: pin.name, version: pin.version, lockfileVersion: 3, packages: { "": manifest, ...records } };
    const source = join(root, "source");
    const closure = join(root, "closure");
    mkdirSync(join(source, "package"), { recursive: true });
    mkdirSync(join(closure, "package/node_modules"), { recursive: true });
    writeFileSync(join(source, "package/package.json"), JSON.stringify(manifest));
    writeFileSync(join(closure, "package/package.json"), JSON.stringify({ ...manifest, bundledDependencies: Object.keys(manifest.dependencies) }));
    writeFileSync(join(closure, "package/package-lock.json"), JSON.stringify(lock));
    writeFileSync(join(closure, "package/node_modules/.package-lock.json"), JSON.stringify({ packages: records }));
    for (const [path, node] of Object.entries(nodes)) {
      mkdirSync(join(closure, "package", path), { recursive: true });
      writeFileSync(join(closure, "package", path, "package.json"), JSON.stringify(node));
    }
    const lockPath = join(root, "lock.json");
    writeFileSync(lockPath, JSON.stringify(lock));
    for (const [field, directory] of [["sourceArchive", source], ["closure", closure]]) {
      const archive = join(root, `${field}.tgz`);
      tar(["-czf", archive, "-C", directory, "package"]);
      const algorithm = field === "closure" ? "sha512" : "sha256";
      pin[field] = { path: relative(root, archive), [algorithm]: digest(archive, algorithm) };
    }
    pin.lockfile = { path: relative(root, lockPath), sha256: digest(lockPath, "sha256") };
    writeFileSync(join(root, "pi-subagents-pin.json"), JSON.stringify(pin));
    const result = check(root);
    assert.equal(result.status, 0, result.stderr || result.stdout);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("the vendored source and closure match their pinned provenance", () => {
  const result = check();
  assert.equal(result.status, 0, result.stderr || result.stdout);
});

test("a previous pin must bind a source archive and lockfile", () => {
  const root = mkdtempSync(join(tmpdir(), "tron-previous-pin-"));
  try {
    const pin = JSON.parse(readFileSync(pinPath, "utf8"));
    copyInputs(root, pin);
    pin.previous = { version: "0.59.0", path: "artifacts/missing.tgz", sha512: "a".repeat(128) };
    writeFileSync(join(root, "pi-subagents-pin.json"), JSON.stringify(pin));
    const result = check(root);
    assert.notEqual(result.status, 0, "incomplete previous pin unexpectedly passed");
    assert.match(result.stderr, /previous|predecessor/iu);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("a modified closure is refused", () => {
  const root = mkdtempSync(join(tmpdir(), "tron-closure-tamper-"));
  try {
    const pin = JSON.parse(readFileSync(pinPath, "utf8"));
    copyInputs(root, pin);
    const artifact = join(gateway, pin.closure.path);
    const tampered = join(root, "tampered.tgz");
    const bytes = readFileSync(artifact);
    bytes[bytes.length - 1] ^= 1;
    writeFileSync(tampered, bytes);
    pin.closure.path = relative(root, tampered);
    writeFileSync(join(root, "pi-subagents-pin.json"), JSON.stringify(pin));
    const result = check(root);
    assert.notEqual(result.status, 0, "tampered closure unexpectedly passed integrity validation");
    assert.match(result.stderr, /SHA-512|digest|integrity|escapes/iu);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
