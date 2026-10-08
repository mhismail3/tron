import assert from "node:assert/strict";
import test from "node:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const gateway = dirname(dirname(fileURLToPath(import.meta.url)));
const checker = join(gateway, "scripts/check-pi-subagents.mjs");
const pinPath = join(gateway, "pi-subagents-pin.json");

function check(pin = pinPath) {
  return spawnSync(process.execPath, [checker, "--pin", pin], { cwd: gateway, encoding: "utf8" });
}

test("the vendored source and closure match their pinned provenance", () => {
  const result = check();
  assert.equal(result.status, 0, result.stderr || result.stdout);
});

test("a previous pin must bind a source archive and lockfile", () => {
  const root = mkdtempSync(join(gateway, "artifacts", ".previous-pin-"));
  try {
    const pin = JSON.parse(readFileSync(pinPath, "utf8"));
    pin.previous = { version: "0.59.0", path: "artifacts/missing.tgz", sha512: "a".repeat(128) };
    const candidate = join(root, "pin.json");
    writeFileSync(candidate, JSON.stringify(pin));
    const result = check(candidate);
    assert.notEqual(result.status, 0, "incomplete previous pin unexpectedly passed");
    assert.match(result.stderr, /previous|predecessor/iu);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("a modified closure is refused", () => {
  const root = mkdtempSync(join(gateway, "artifacts", ".tamper-"));
  try {
    const pin = JSON.parse(readFileSync(pinPath, "utf8"));
    const artifact = join(gateway, pin.closure.path);
    const tampered = join(root, "tampered.tgz");
    const bytes = readFileSync(artifact);
    bytes[bytes.length - 1] ^= 1;
    writeFileSync(tampered, bytes);
    const alteredPin = join(root, "pin.json");
    pin.closure.path = relative(gateway, tampered);
    writeFileSync(alteredPin, JSON.stringify(pin));
    const result = check(alteredPin);
    assert.notEqual(result.status, 0, "tampered closure unexpectedly passed integrity validation");
    assert.match(result.stderr, /SHA-512|digest|integrity|escapes/iu);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
