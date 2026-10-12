// The patched pi-coding-agent declaration is accepted only as declared: the
// checker runs as a process against a copy of the Gateway's real manifests,
// lock, declaration and tarball, then against single-fault variants.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { appendFileSync, cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { PATCH_PIN_FILE } from "./check-pi-sdk.mjs";
import { runUpdate } from "./update-pi-sdk.mjs";

const gatewayDir = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const checker = join(gatewayDir, "scripts", "check-pi-sdk.mjs");

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), "tron-check-pi-sdk-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  for (const name of ["package.json", "package-lock.json", "pi-sdk-baseline.json", PATCH_PIN_FILE, "third_party"]) {
    cpSync(join(gatewayDir, name), join(root, name), { recursive: true });
  }
  return root;
}

function check(root) {
  const result = spawnSync(process.execPath, [checker, root], { encoding: "utf8" });
  return { status: result.status, output: `${result.stdout}${result.stderr}` };
}

const json = (path) => JSON.parse(readFileSync(path, "utf8"));
const writeJson = (path, value) => writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`);

test("accepts the declared tarball and refuses every single fault", (t) => {
  const accepted = check(fixture(t));
  assert.equal(accepted.status, 0, accepted.output);
  assert.match(accepted.output, /pi-coding-agent from third_party\/pi-coding-agent\//u);

  const tampered = fixture(t);
  appendFileSync(join(tampered, json(join(tampered, PATCH_PIN_FILE)).artifact.path), "x");
  assert.match(check(tampered).output, /does not match its declared integrity/u);

  const undeclared = fixture(t);
  rmSync(join(undeclared, PATCH_PIN_FILE));
  assert.match(check(undeclared).output, /no pi-coding-agent-patch\.json declares a patched tarball/u);

  const relocked = fixture(t);
  const lock = json(join(relocked, "package-lock.json"));
  lock.packages["node_modules/@earendil-works/pi-coding-agent"].integrity = lock.packages["node_modules/@earendil-works/pi-ai"].integrity;
  writeJson(join(relocked, "package-lock.json"), lock);
  assert.match(check(relocked).output, /must resolve file:third_party\/pi-coding-agent\/.* with integrity/u);

  const escaping = fixture(t);
  const pin = json(join(escaping, PATCH_PIN_FILE));
  pin.artifact.path = "third_party/pi-coding-agent/../../package.json";
  writeJson(join(escaping, PATCH_PIN_FILE), pin);
  assert.match(check(escaping).output, /must be schemaVersion 1/u);

  const patched = fixture(t);
  appendFileSync(join(patched, json(join(patched, PATCH_PIN_FILE)).patch.path), "\n");
  assert.match(check(patched).output, /does not match its declared sha256/u);
});

test("the SDK updater refuses while the patch is declared", (t) => {
  const root = fixture(t);
  const before = readFileSync(join(root, "package.json"));
  assert.throws(() => runUpdate({ gatewayDir: root, version: "1.1.0", spawn: () => assert.fail("no command may run") }),
    /declares a Tron-patched pi-coding-agent/u);
  assert.deepEqual(readFileSync(join(root, "package.json")), before);
});
