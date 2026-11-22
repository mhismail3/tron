#!/usr/bin/env node
// Reproduce Tron's patched agent-browser engine tarball from its pinned upstream commit, patch, registry package and toolchain.
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { sha256File, sha512Integrity } from "./check-pi-sdk.mjs";

const PIN_FILE = "agent-browser-patch.json";
const BINARIES = { "aarch64-apple-darwin": "agent-browser-darwin-arm64", "x86_64-apple-darwin": "agent-browser-darwin-x64" };
const gatewayDir = resolve(dirname(fileURLToPath(import.meta.url)), "..");

function run(command, args, options = {}) {
  const result = spawnSync(command, args, { stdio: options.capture ? ["ignore", "pipe", "inherit"] : "inherit", encoding: "utf8", ...options });
  if (result.status !== 0) throw new Error(`${command} ${args.join(" ")} failed (exit ${result.status ?? result.signal})`);
  return (result.stdout ?? "").trim();
}

const write = process.argv.includes("--write");
const pin = JSON.parse(readFileSync(join(gatewayDir, PIN_FILE), "utf8"));
if (pin.schemaVersion !== 1 || pin.package !== "agent-browser" || !/^[a-f0-9]{40}$/.test(pin.upstream.tagCommit)
  || pin.upstream.tag !== `v${pin.version}` || !pin.artifact.path.startsWith("third_party/agent-browser/")
  || pin.patch.path !== "third_party/agent-browser/tron.patch"
  || JSON.stringify(pin.targets) !== JSON.stringify(Object.keys(BINARIES))) throw new Error(`invalid ${PIN_FILE}`);
const patchPath = join(gatewayDir, pin.patch.path);
if (!write && sha256File(patchPath) !== pin.patch.sha256) throw new Error("patch digest differs from pin");
const npm = run("npm", ["--version"], { capture: true });
const rust = run("rustup", ["run", pin.toolchain.rust, "rustc", "--version"], { capture: true }).split(" ")[1];
if (process.versions.node !== pin.toolchain.node || npm !== pin.toolchain.npm || rust !== pin.toolchain.rust) {
  throw new Error(`reproduction requires Node ${pin.toolchain.node}, npm ${pin.toolchain.npm} and Rust ${pin.toolchain.rust}`);
}

const work = mkdtempSync(join(tmpdir(), "tron-agent-browser-"));
try {
  const source = join(work, "source");
  mkdirSync(source);
  run("git", ["-C", source, "init", "-q"]);
  run("git", ["-C", source, "fetch", "-q", "--depth", "1", pin.upstream.repository, `refs/tags/${pin.upstream.tag}`]);
  if (run("git", ["-C", source, "rev-parse", "FETCH_HEAD^{commit}"], { capture: true }) !== pin.upstream.tagCommit) throw new Error(`${pin.upstream.tag} moved`);
  run("git", ["-C", source, "checkout", "-q", "--detach", pin.upstream.tagCommit]);
  const touched = run("git", ["-C", source, "apply", "--numstat", patchPath], { capture: true }).split("\n").filter(Boolean).map((line) => line.split("\t")[2]);
  run("git", ["-C", source, "apply", patchPath]);
  const env = { ...process.env, CARGO_INCREMENTAL: "0", MACOSX_DEPLOYMENT_TARGET: "11.0", SOURCE_DATE_EPOCH: "0",
    RUSTFLAGS: [`--remap-path-prefix=${source}=/agent-browser`, `--remap-path-prefix=${homedir()}/.cargo=/cargo`, `--remap-path-prefix=${homedir()}/.rustup=/rustup`].join(" ") };
  for (const target of pin.targets) {
    run("cargo", [`+${pin.toolchain.rust}`, "build", "--release", "--locked", "--manifest-path", "cli/Cargo.toml", "--target", target], { cwd: source, env });
  }

  run("npm", ["pack", `agent-browser@${pin.version}`, "--pack-destination", work, "--registry=https://registry.npmjs.org/"], { cwd: work, capture: true });
  const base = join(work, `agent-browser-${pin.version}.tgz`);
  if (sha512Integrity(base) !== pin.upstream.registryIntegrity) throw new Error(`agent-browser@${pin.version} differs from its registry integrity`);
  run("tar", ["-xzf", base, "-C", work]);
  const packageDir = join(work, "package");
  for (const name of readdirSync(join(packageDir, "bin"))) if (name.startsWith("agent-browser-")) rmSync(join(packageDir, "bin", name));
  for (const [target, name] of Object.entries(BINARIES)) {
    copyFileSync(join(source, "cli/target", target, "release/agent-browser"), join(packageDir, "bin", name));
  }
  for (const path of touched) {
    try { copyFileSync(join(source, path), join(packageDir, path)); } catch (error) { if (error.code !== "ENOENT") throw error; }
  }
  const output = join(work, "patched");
  mkdirSync(output);
  run("npm", ["pack", "--ignore-scripts", "--pack-destination", output], { cwd: packageDir, capture: true });
  const built = join(output, readdirSync(output)[0]);
  const integrity = sha512Integrity(built);
  const report = { tagCommit: pin.upstream.tagCommit, patchSha256: sha256File(patchPath), integrity, expected: pin.artifact.integrity };
  if (write) {
    copyFileSync(built, join(gatewayDir, pin.artifact.path));
    writeFileSync(join(gatewayDir, PIN_FILE), `${JSON.stringify({ ...pin, artifact: { ...pin.artifact, integrity }, patch: { ...pin.patch, sha256: report.patchSha256 } }, null, 2)}\n`);
    console.log(JSON.stringify({ ...report, wrote: pin.artifact.path }, null, 2));
  } else {
    console.log(JSON.stringify(report, null, 2));
    if (integrity !== pin.artifact.integrity || sha512Integrity(join(gatewayDir, pin.artifact.path)) !== pin.artifact.integrity) {
      throw new Error("rebuilt agent-browser does not reproduce the committed artifact");
    }
    console.log(`reproduced ${pin.artifact.path}`);
  }
} finally {
  rmSync(work, { recursive: true, force: true });
}
