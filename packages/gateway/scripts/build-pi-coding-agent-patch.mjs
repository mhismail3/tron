#!/usr/bin/env node
/**
 * Rebuild Tron's patched pi-coding-agent tarball from its declared inputs and
 * compare it with the committed artifact. pi-coding-agent-patch.json owns the
 * inputs: the upstream release tag, the checked-in patch, the published pi-ai
 * model data the release bundled, and the pinned Node/npm toolchain.
 *
 * The unpatched tag is built and packed first and must reproduce the published
 * registry tarball byte for byte, which proves the toolchain and inputs; only
 * then is the patch applied and pi-coding-agent rebuilt. The default run only
 * verifies; `--write` replaces the artifact and records the artifact and patch
 * digests after a deliberate patch change. It never installs into the Gateway.
 *
 * usage: node scripts/build-pi-coding-agent-patch.mjs [--upstream GIT-URL-OR-PATH] [--write] [--keep]
 */
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
// A deliberate patch change is recorded by --write, so its old digest is not checked then.
const { value: pin, issues } = readPiCodingAgentPatch(gatewayDir, { requireSources: !write });
if (!pin) throw new Error(`${PATCH_PIN_FILE} is not valid:\n- ${issues.join("\n- ")}`);
const node = process.versions.node;
const npm = run("npm", ["--version"], { capture: true });
if (node !== pin.toolchain.node || npm !== pin.toolchain.npm) {
  throw new Error(`reproduction requires Node ${pin.toolchain.node} and npm ${pin.toolchain.npm} (found ${node} and ${npm})`);
}

const upstream = argument("--upstream") ?? pin.upstream.repository;
const work = mkdtempSync(join(tmpdir(), "tron-pi-coding-agent-"));
const env = { ...process.env, HUSKY: "0", npm_config_audit: "false", npm_config_fund: "false", npm_config_update_notifier: "false" };
try {
  const source = join(work, "pi");
  mkdirSync(source);
  run("git", ["-C", source, "init", "-q"]);
  run("git", ["-C", source, "fetch", "-q", "--depth", "1", upstream, `refs/tags/${pin.upstream.tag}`]);
  const commit = run("git", ["-C", source, "rev-parse", "FETCH_HEAD^{commit}"], { capture: true });
  if (commit !== pin.upstream.tagCommit) throw new Error(`${pin.upstream.tag} is ${commit}, expected ${pin.upstream.tagCommit}`);
  run("git", ["-C", source, "checkout", "-q", "--detach", commit]);

  // pi-ai generates its model catalog from the network at release time. The
  // published pi-ai tarball is the exact catalog that the release bundled.
  run("npm", ["pack", `${pin.modelData.package}@${pin.modelData.version}`, "--pack-destination", work, REGISTRY], { cwd: work, env, capture: true });
  const modelTarball = join(work, readdirSync(work).find((name) => name.endsWith(".tgz")));
  if (sha512Integrity(modelTarball) !== pin.modelData.integrity) throw new Error(`${pin.modelData.package}@${pin.modelData.version} integrity differs from ${PATCH_PIN_FILE}`);
  const extracted = join(work, "model-data");
  mkdirSync(extracted);
  run("tar", ["-xzf", modelTarball, "-C", extracted, "package/dist/providers/data"]);
  run("cp", ["-R", join(extracted, "package/dist/providers/data"), join(source, "packages/ai/src/providers/data")]);

  run("npm", ["ci", REGISTRY], { cwd: source, env });
  run("npm", ["run", "build:offline"], { cwd: source, env });
  const codingAgent = join(source, "packages/coding-agent");
  const pack = (name) => {
    const output = join(work, name);
    mkdirSync(output);
    run("npm", ["pack", "--pack-destination", output], { cwd: codingAgent, env, capture: true });
    return join(output, readdirSync(output).find((file) => file.endsWith(".tgz")));
  };
  const base = sha512Integrity(pack("base"));
  if (base !== pin.upstream.registryIntegrity) {
    throw new Error(`unpatched ${pin.upstream.tag} packs ${base}, not the published ${pin.upstream.registryIntegrity}; the toolchain or inputs differ from the release`);
  }

  const patchPath = join(gatewayDir, pin.patch.path);
  const touched = run("git", ["-C", source, "apply", "--numstat", patchPath], { capture: true })
    .split("\n").filter(Boolean).map((line) => line.split("\t")[2]);
  const outside = touched.filter((path) => !path.startsWith("packages/coding-agent/") && !path.startsWith("packages/evals/"));
  if (outside.length > 0) throw new Error(`the patch changes packages this script does not rebuild: ${outside.join(", ")}`);
  run("git", ["-C", source, "apply", "--whitespace=nowarn", patchPath]);
  run("npm", ["run", "clean"], { cwd: codingAgent, env });
  run("npm", ["run", "build"], { cwd: codingAgent, env });
  const built = pack("patched");
  const integrity = sha512Integrity(built);
  const committed = join(gatewayDir, pin.artifact.path);
  const report = { upstream, tagCommit: commit, baseIntegrity: base, patchSha256: sha256File(patchPath), integrity, expected: pin.artifact.integrity };
  if (write) {
    copyFileSync(built, committed);
    const document = JSON.parse(readFileSync(join(gatewayDir, PATCH_PIN_FILE), "utf8"));
    document.artifact.integrity = integrity;
    document.patch.sha256 = report.patchSha256;
    writeFileSync(join(gatewayDir, PATCH_PIN_FILE), `${JSON.stringify(document, null, 2)}\n`);
    console.log(JSON.stringify({ ...report, wrote: pin.artifact.path }, null, 2));
    console.log("Update package-lock.json with npm install, then run npm run check:pi-sdk.");
  } else {
    console.log(JSON.stringify(report, null, 2));
    if (integrity !== pin.artifact.integrity || sha512Integrity(committed) !== pin.artifact.integrity) {
      throw new Error("rebuilt pi-coding-agent does not reproduce the committed artifact");
    }
    console.log(`reproduced ${pin.artifact.path}`);
  }
} finally {
  if (process.argv.includes("--keep")) console.log(`kept ${work}`);
  else rmSync(work, { recursive: true, force: true });
}
