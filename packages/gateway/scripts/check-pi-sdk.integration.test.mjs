// The patched pi-coding-agent declaration is accepted only as declared: the
// checker runs as a process against a copy of the Gateway's real manifests,
// lock, declaration and tarball, then against single-fault variants.
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { appendFileSync, chmodSync, cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
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

test("the SDK updater installs only the cohort its patch declaration was rebuilt for", (t) => {
  const root = fixture(t);
  const pin = json(join(root, PATCH_PIN_FILE));
  const before = readFileSync(join(root, "package.json"));
  assert.throws(() => runUpdate({ gatewayDir: root, version: "9.9.9", spawn: () => assert.fail("no command may run") }),
    new RegExp(`declares a Tron-patched pi-coding-agent ${pin.version.replaceAll(".", "\\.")}; rebuild it for 9\\.9\\.9`, "u"));
  assert.deepEqual(readFileSync(join(root, "package.json")), before);
});

// A real npm stand-in process: it answers the registry preflight with the
// declaration's own integrities and no gitHead (as Pi publishes since 1.1.0),
// records every invocation, and fails the install, so the updater must restore
// the manifests and run npm ci.
test("a failed patched-cohort install restores the manifests and runs npm ci", (t) => {
  const root = fixture(t);
  execFileSync("git", ["init", "-q"], { cwd: root });
  execFileSync("git", ["add", "-A"], { cwd: root });
  execFileSync("git", ["-c", "user.email=t@example.invalid", "-c", "user.name=t", "commit", "-qm", "fixture"], { cwd: root });
  const pin = json(join(root, PATCH_PIN_FILE));
  const integrities = {
    "@earendil-works/pi-coding-agent": pin.upstream.registryIntegrity,
    "@earendil-works/pi-ai": pin.modelData.integrity,
  };
  const log = join(root, "npm-calls.jsonl");
  const npm = join(root, "npm-stand-in.mjs");
  writeFileSync(npm, `#!${process.execPath}
import { appendFileSync } from "node:fs";
const args = process.argv.slice(2);
appendFileSync(${JSON.stringify(log)}, JSON.stringify(args) + "\\n");
if (args[0] === "view") {
  const [name, version] = args[1].split(/@(?=[^@]*$)/u);
  const integrities = ${JSON.stringify(integrities)};
  console.log(JSON.stringify({ version, "dist.integrity": integrities[name] ?? "sha512-${"A".repeat(86)}==", engines: { node: ">=22.19.0" } }));
} else if (args[0] === "install") {
  process.exit(7);
}
`);
  chmodSync(npm, 0o755);
  const before = { package: readFileSync(join(root, "package.json")), baseline: readFileSync(join(root, "pi-sdk-baseline.json")) };
  assert.throws(() => runUpdate({ gatewayDir: root, version: pin.version, npmBin: npm }), /npm install \(exit 7\).*restored package\.json\/package-lock\.json and ran npm ci/su);
  const calls = readFileSync(log, "utf8").trim().split("\n").map((line) => JSON.parse(line));
  const install = calls.find((args) => args[0] === "install");
  assert.ok(install.includes(`./${pin.artifact.path}`), `install names the declared tarball: ${install.join(" ")}`);
  assert.ok(install.includes(`@earendil-works/pi-ai@${pin.version}`));
  assert.equal(calls.at(-1)[0], "ci");
  assert.deepEqual(readFileSync(join(root, "package.json")), before.package);
  assert.deepEqual(readFileSync(join(root, "pi-sdk-baseline.json")), before.baseline);
});
