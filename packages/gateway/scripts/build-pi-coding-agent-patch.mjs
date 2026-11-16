#!/usr/bin/env node
// Reproduce Tron's patched package tarballs from their declared source, patch and toolchain.
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { PATCH_PIN_FILE, readPiCodingAgentPatch, sha256File, sha512Integrity } from "./check-pi-sdk.mjs";

const REGISTRY = "--registry=https://registry.npmjs.org/";
const gatewayDir = resolve(dirname(fileURLToPath(import.meta.url)), "..");

function run(command, args, options = {}) {
  const result = spawnSync(command, args, { stdio: options.capture ? ["ignore", "pipe", "inherit"] : "inherit", encoding: "utf8", ...options });
  if (result.status !== 0) throw new Error(`${command} ${args.join(" ")} failed (exit ${result.status ?? result.signal})`);
  return (result.stdout ?? "").trim();
}

function argument(name) {
  const index = process.argv.indexOf(name);
  return index < 0 ? undefined : process.argv[index + 1];
}

const write = process.argv.includes("--write");
const pinFile = argument("--pin") ?? PATCH_PIN_FILE;
const sdk = pinFile === PATCH_PIN_FILE;
if (!sdk && pinFile !== "pi-agent-browser-native-patch.json") throw new Error("unknown patched package pin");
const { value: pin, issues } = sdk
  ? readPiCodingAgentPatch(gatewayDir, { requireSources: !write, requireArtifact: !write })
  : { value: JSON.parse(readFileSync(join(gatewayDir, pinFile), "utf8")), issues: [] };
if (!pin) throw new Error(`${pinFile} is not valid:\n- ${issues.join("\n- ")}`);
if (!sdk && (pin.schemaVersion !== 1 || pin.package !== "pi-agent-browser-native"
  || !/^[a-f0-9]{40}$/.test(pin.upstream.commit)
  || !pin.artifact.path.startsWith("third_party/pi-agent-browser-native/")
  || pin.patch.path !== "third_party/pi-agent-browser-native/tron.patch")) throw new Error("invalid native browser patch pin");
if (!write && sha256File(join(gatewayDir, pin.patch.path)) !== pin.patch.sha256) throw new Error("patch digest differs from pin");
const node = process.versions.node;
const npm = run("npm", ["--version"], { capture: true });
if (node !== pin.toolchain.node || npm !== pin.toolchain.npm) {
  throw new Error(`reproduction requires Node ${pin.toolchain.node} and npm ${pin.toolchain.npm} (found ${node} and ${npm})`);
}

const upstream = argument("--upstream") ?? pin.upstream.repository;
const work = mkdtempSync(join(tmpdir(), "tron-patched-package-"));
const env = { ...process.env, HUSKY: "0", npm_config_audit: "false", npm_config_fund: "false", npm_config_update_notifier: "false" };
try {
  const source = join(work, "pi");
  mkdirSync(source);
  run("git", ["-C", source, "init", "-q"]);
  const revision = sdk ? `refs/tags/${pin.upstream.tag}` : pin.upstream.commit;
  run("git", ["-C", source, "fetch", "-q", "--depth", "1", upstream, revision]);
  const commit = run("git", ["-C", source, "rev-parse", "FETCH_HEAD^{commit}"], { capture: true });
  const expectedCommit = sdk ? pin.upstream.tagCommit : pin.upstream.commit;
  if (commit !== expectedCommit) throw new Error(`${revision} is ${commit}, expected ${expectedCommit}`);
  run("git", ["-C", source, "checkout", "-q", "--detach", commit]);

  if (sdk) {
  run("npm", ["pack", `${pin.modelData.package}@${pin.modelData.version}`, "--pack-destination", work, REGISTRY], { cwd: work, env, capture: true });
  const modelTarball = join(work, readdirSync(work).find((name) => name.endsWith(".tgz")));
  if (sha512Integrity(modelTarball) !== pin.modelData.integrity) throw new Error(`${pin.modelData.package}@${pin.modelData.version} integrity differs from ${PATCH_PIN_FILE}`);
  const extracted = join(work, "model-data");
  mkdirSync(extracted);
  run("tar", ["-xzf", modelTarball, "-C", extracted, "package/dist/providers/data"]);
  run("cp", ["-R", join(extracted, "package/dist/providers/data"), join(source, "packages/ai/src/providers/data")]);
  }

  run("npm", ["ci", ...(sdk ? [] : ["--ignore-scripts"]), REGISTRY], { cwd: source, env });
  if (sdk) run("npm", ["run", "build:offline"], { cwd: source, env });
  const packageDir = sdk ? join(source, "packages/coding-agent") : source;
  const pack = (name) => {
    const output = join(work, name);
    mkdirSync(output);
    run("npm", ["pack", ...(sdk ? [] : ["--ignore-scripts"]), "--pack-destination", output], { cwd: packageDir, env, capture: true });
    return join(output, readdirSync(output).find((file) => file.endsWith(".tgz")));
  };
  const base = sdk ? sha512Integrity(pack("base")) : undefined;
  if (sdk && base !== pin.upstream.registryIntegrity) {
    throw new Error(`unpatched ${pin.upstream.tag} packs ${base}, not the published ${pin.upstream.registryIntegrity}; the toolchain or inputs differ from the release`);
  }

  const patchPath = join(gatewayDir, pin.patch.path);
  const touched = run("git", ["-C", source, "apply", "--numstat", patchPath], { capture: true })
    .split("\n").filter(Boolean).map((line) => line.split("\t")[2]);
  const outside = sdk ? touched.filter((path) => path !== "package-lock.json" && !path.startsWith("packages/coding-agent/") && !path.startsWith("packages/evals/"))
    : touched.filter((path) => !path.startsWith("extensions/agent-browser/") && !path.startsWith("docs/") && !path.startsWith("test/") && !["package.json", "package-lock.json", "README.md"].includes(path));
  if (outside.length > 0) throw new Error(`the patch changes packages this script does not rebuild: ${outside.join(", ")}`);
  run("git", ["-C", source, "apply", "--unidiff-zero", "--whitespace=nowarn", patchPath]);
  if (touched.includes("package-lock.json")) run("npm", ["ci", ...(sdk ? [] : ["--ignore-scripts"]), REGISTRY], { cwd: source, env });
  if (sdk) run("npm", ["run", "clean"], { cwd: packageDir, env });
  run("npm", ["run", "build"], { cwd: packageDir, env });
  const built = pack("patched");
  const integrity = sha512Integrity(built);
  const committed = join(gatewayDir, pin.artifact.path);
  const report = { upstream, tagCommit: commit, baseIntegrity: base, patchSha256: sha256File(patchPath), integrity, expected: pin.artifact.integrity };
  if (write) {
    copyFileSync(built, committed);
    const document = JSON.parse(readFileSync(join(gatewayDir, pinFile), "utf8"));
    document.artifact.integrity = integrity;
    document.patch.sha256 = report.patchSha256;
    writeFileSync(join(gatewayDir, pinFile), `${JSON.stringify(document, null, 2)}\n`);
    console.log(JSON.stringify({ ...report, wrote: pin.artifact.path }, null, 2));
    console.log("Update package-lock.json with npm install, then run npm run check:pi-sdk.");
  } else {
    console.log(JSON.stringify(report, null, 2));
    if (integrity !== pin.artifact.integrity || sha512Integrity(committed) !== pin.artifact.integrity) {
      throw new Error(`rebuilt ${pin.package} does not reproduce the committed artifact`);
    }
    console.log(`reproduced ${pin.artifact.path}`);
  }
} finally {
  if (process.argv.includes("--keep")) console.log(`kept ${work}`);
  else rmSync(work, { recursive: true, force: true });
}
