#!/usr/bin/env node
/** Prepare a reviewed provider build from immutable git objects, never deploy it. */
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { closeSync, copyFileSync, cpSync, existsSync, lstatSync, mkdirSync, openSync, readFileSync, renameSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const GATEWAY = dirname(dirname(fileURLToPath(import.meta.url)));
const PIN = "pi-subagents-pin.json";
const UPSTREAM = "https://github.com/nicobailon/pi-subagents.git";
const hash = (bytes, algorithm) => createHash(algorithm).update(bytes).digest("hex");
const commitId = (value) => typeof value === "string" && /^[0-9a-f]{40}$/u.test(value);

export function runUpdate({ gatewayDir = GATEWAY, forkRepo, commit, spawn = spawnSync } = {}) {
  const root = resolve(gatewayDir);
  if (!commitId(commit)) throw new Error("fork commit must be one full 40-character commit hash (archives are not accepted)");
  // The staging root is also the exclusive invocation lease. Its owner alone
  // may retire it; an interrupted owner is never silently swept by another run.
  const staging = join(root, ".pi-subagents-update-staging");
  try { mkdirSync(staging, { mode: 0o700 }); }
  catch (error) {
    if (error.code === "EEXIST") throw new Error("provider update already running or interrupted: inspect the staging owner before removing .pi-subagents-update-staging");
    throw error;
  }
  // Explicit probe/fixture retirement contract: descendants record failed
  // joins here, outside their disposable roots. Only this updater owns the
  // path; a record means staging remains owned and must not be removed.
  const processOwnerFailure = join(staging, "process-owner-failure.jsonl");
  const created = [];
  let published = false;
  let originalBytes;
  const pinPath = join(root, PIN);
  try {
    const invoke = (bin, args, cwd = root, env = process.env, raw = false) => {
      const result = spawn(bin, args, { cwd, env, encoding: "utf8", maxBuffer: 8 * 1024 * 1024, timeout: 120_000 });
      if (result.status !== 0) throw new Error(`${bin} ${args.join(" ")} failed (exit ${result.status ?? "unknown"}): ${(result.stderr || result.stdout || result.error?.message || "").trim()}`);
      return raw ? (result.stdout ?? "") : (result.stdout ?? "").trim();
    };
    const dirty = invoke("git", ["status", "--porcelain", "--untracked-files=all", "--", PIN, "artifacts/pi-subagents*", "package.json", "package-lock.json"]);
    if (dirty) throw new Error("refusing update: provider pin, artifacts or package manifests have uncommitted changes");
    if (!lstatSync(pinPath).isFile() || lstatSync(pinPath).isSymbolicLink()) throw new Error("pin must be a regular file");
    originalBytes = readFileSync(pinPath);
    const current = JSON.parse(originalBytes);
    const repository = current.fork?.repository;
    if (repository === null && !forkRepo) throw new Error("--fork-repo is required while fork.repository is null");
    if (repository !== null && forkRepo !== undefined && forkRepo !== repository) throw new Error("--fork-repo must match the pinned fork.repository");
    const source = forkRepo ?? repository;
    if (typeof source !== "string" || !source) throw new Error("fork.repository must be a repository URL or null with --fork-repo");
    if (process.versions.node !== current.nodeVersion) throw new Error(`use pinned Node ${current.nodeVersion}, not ${process.versions.node}`);
    if (invoke("npm", ["--version"]) !== current.npmVersion) throw new Error(`use npm ${current.npmVersion} paired with pinned Node`);
    invoke(process.execPath, [join(root, "scripts/check-pi-subagents.mjs")]);

    // One invocation owns staging, including all package-script home/cache writes.
    // Immutable publications are exclusive creates; exception rollback cannot
    // remove an older artifact or an unrelated file.
    for (const path of ["home", "tmp", "export", "candidate/scripts", "candidate/artifacts"]) mkdirSync(join(staging, path), { recursive: true });
    const env = { PATH: process.env.PATH, HOME: join(staging, "home"), TMPDIR: join(staging, "tmp"), PYTHONDONTWRITEBYTECODE: "1", npm_config_cache: join(staging, "home/cache"), npm_config_engine_strict: "true", npm_config_fetch_retries: "0", npm_config_fetch_timeout: "30000" };
    const upstream = current.upstream;
    if (upstream?.package !== "pi-subagents" || !/^v0\.\d+\.\d+$/u.test(upstream.release) || !commitId(upstream.tagCommit)) throw new Error("upstream release/tag provenance is invalid");
    const release = upstream.release.slice(1);
    const metadata = JSON.parse(invoke("npm", ["view", `pi-subagents@${release}`, "version", "gitHead", "dist.integrity", "--json", "--prefer-online", "--offline=false", "--registry=https://registry.npmjs.org/"], root, env));
    const integrity = metadata["dist.integrity"] ?? metadata.dist?.integrity;
    if (metadata.version !== release || metadata.gitHead !== upstream.tagCommit || typeof integrity !== "string" || !/^sha512-[A-Za-z0-9+/]{86}==$/u.test(integrity)) throw new Error("upstream npm release metadata disagrees with pinned release/tag");
    const refs = invoke("git", ["ls-remote", UPSTREAM, `refs/tags/${upstream.release}`, `refs/tags/${upstream.release}^{}`], root, env).split("\n").map((line) => line.split(/\s+/u));
    const tagCommit = refs.find(([, ref]) => ref === `refs/tags/${upstream.release}^{}`)?.[0] ?? refs.find(([, ref]) => ref === `refs/tags/${upstream.release}`)?.[0];
    if (tagCommit !== upstream.tagCommit) throw new Error("upstream release tag commit disagrees with pin");
    const latestUpstream = JSON.parse(invoke("npm", ["view", "pi-subagents", "version", "--json", "--prefer-online", "--offline=false", "--registry=https://registry.npmjs.org/"], root, env));
    let fork = resolve(source);
    if (!existsSync(fork)) {
      fork = join(staging, "fork.git");
      invoke("git", ["clone", "--bare", "--", source, fork], root, env);
    }
    const git = (...args) => invoke("git", ["-C", fork, ...args], root, env);
    if (git("rev-parse", "--verify", `${commit}^{commit}`) !== commit) throw new Error("fork commit is not an exact commit object");
    try { git("merge-base", "--is-ancestor", upstream.tagCommit, commit); }
    catch { throw new Error("pinned upstream tag commit must be an ancestor of fork commit"); }
    const exportRoot = join(staging, "export");
    git("archive", "--format=tar", `--output=${join(staging, "source.tar")}`, commit);
    invoke("tar", ["-xf", join(staging, "source.tar"), "-C", exportRoot], root, env);
    const lockBytes = Buffer.from(invoke("git", ["-C", fork, "show", `${commit}:package-lock.json`], root, env, true));
    const manifest = JSON.parse(readFileSync(join(exportRoot, "package.json"), "utf8"));
    if (manifest.name !== "pi-subagents" || !/^0\.\d+\.\d+-tron\.\d+$/u.test(manifest.version) || !manifest.version.startsWith(`${release}-tron.`)) throw new Error("fork package must be the pinned upstream release with an exact -tron.N version");
    if (manifest.version === current.version) throw new Error("candidate must have a new immutable -tron.N version");
    const paths = {
      source: `artifacts/pi-subagents-${manifest.version}.tgz`,
      lock: `artifacts/pi-subagents-${manifest.version}-package-lock.json`,
      closure: `artifacts/pi-subagents-${manifest.version}-closure.tgz`,
    };
    for (const path of Object.values(paths)) if (existsSync(join(root, path))) throw new Error(`immutable artifact already exists: ${path}`);
    invoke("npm", ["ci", "--ignore-scripts", "--omit=peer", "--engine-strict", "--no-audit", "--no-fund"], exportRoot, env);
    const packed = JSON.parse(invoke("npm", ["pack", "--silent", "--json", `--pack-destination=${join(staging, "candidate/artifacts")}`], exportRoot, env));
    if (!Array.isArray(packed) || packed.length !== 1 || packed[0].filename !== `pi-subagents-${manifest.version}.tgz`) throw new Error("npm pack produced unexpected package identity");
    const candidateRoot = join(staging, "candidate");
    const sourceBytes = readFileSync(join(candidateRoot, paths.source));
    writeFileSync(join(candidateRoot, paths.lock), lockBytes);
    const { previous: _previous, ...previous } = current;
    const candidate = {
      ...previous, version: manifest.version, fork: { repository, commit },
      sourceArchive: { path: paths.source, sha256: hash(sourceBytes, "sha256") },
      lockfile: { path: paths.lock, sha256: hash(lockBytes, "sha256") },
      closure: { path: paths.closure }, previous,
    };
    writeFileSync(join(candidateRoot, PIN), JSON.stringify(candidate, null, 2) + "\n");
    copyFileSync(join(root, "scripts/build-pi-subagents-closure.py"), join(candidateRoot, "scripts/build-pi-subagents-closure.py"));
    invoke("python3", ["-X", "faulthandler", join(candidateRoot, "scripts/build-pi-subagents-closure.py")], candidateRoot, env);
    candidate.closure.sha512 = hash(readFileSync(join(candidateRoot, paths.closure)), "sha512");
    // Validate both selections before the pin can name new files.
    for (const input of [previous.sourceArchive.path, previous.lockfile.path, previous.closure.path]) copyFileSync(join(root, input), join(candidateRoot, input));
    copyFileSync(join(root, "scripts/check-pi-subagents.mjs"), join(candidateRoot, "scripts/check-pi-subagents.mjs"));
    writeFileSync(join(candidateRoot, PIN), JSON.stringify(candidate, null, 2) + "\n");
    invoke(process.execPath, [join(candidateRoot, "scripts/check-pi-subagents.mjs")], candidateRoot, env);
    // Qualify the exact unpublished bytes in their own payload lifetime. The
    // repository pin stays current until both real execution gates have settled.
    for (const path of ["src", "test-support", "vitest.config.ts", "package.json"]) cpSync(join(root, path), join(candidateRoot, path), { recursive: true });
    symlinkSync(join(root, "node_modules"), join(candidateRoot, "node_modules"));
    const gate = (label, file, reportName, reportEnv) => {
      const reportPath = join(staging, reportName);
      try {
        invoke(process.execPath, [join(root, "node_modules/vitest/vitest.mjs"), "run", file, "--maxWorkers=2"], candidateRoot, { ...env, [reportEnv]: reportPath, TRON_TEST_PROCESS_OWNER_FAILURE: processOwnerFailure });
        const report = JSON.parse(readFileSync(reportPath, "utf8"));
        if (report.passed !== true) throw new Error("execution report did not pass");
        return report;
      } catch (error) { throw new Error(`${label} failed: ${error.message}`, { cause: error }); }
    };
    const executionGate = gate("offline real-Gateway execution gate", "src/sessions/managed-subagents.integration.test.ts", "activation.json", "TRON_SUBAGENTS_REPORT");
    const rollbackProbe = gate("previous-candidate-previous rollback probe", "src/sessions/managed-subagents.rollback.test.ts", "rollback.json", "TRON_SUBAGENTS_ROLLBACK_REPORT");
    // Refusal of a verified build with an invalid extension entry: each case is its own
    // nested run and reports by exit status. A refusal regression must still block publication.
    invoke(process.execPath, [join(root, "node_modules/vitest/vitest.mjs"), "run", "src/sessions/managed-subagents.invalid-entry.test.ts", "--maxWorkers=2"], candidateRoot, { ...env, TRON_TEST_PROCESS_OWNER_FAILURE: processOwnerFailure });
    if (existsSync(processOwnerFailure)) throw new Error("probe process join failed before publication");
    for (const path of Object.values(paths)) {
      const bytes = readFileSync(join(candidateRoot, path));
      const destination = join(root, path);
      const file = openSync(destination, "wx");
      // Ownership begins at exclusive creation, before a write can fail partway.
      created.push(destination);
      try { writeFileSync(file, bytes); } finally { closeSync(file); }
    }
    renameSync(join(candidateRoot, PIN), pinPath);
    published = true;
    invoke("npm", ["run", "check:pi-subagents"], root, env);
    return { version: candidate.version, forkCommit: commit, upstream, latestUpstream, closureSha512: candidate.closure.sha512, executionGate, rollbackProbe };
  } catch (error) {
    if (published) {
      const restore = join(staging, "restore-pin.json");
      writeFileSync(restore, originalBytes);
      renameSync(restore, pinPath);
    }
    for (const path of created) rmSync(path);
    throw error;
  } finally {
    if (existsSync(processOwnerFailure)) {
      // Catch above restores publications first. Do not race unjoined writers
      // with recursive removal or let another update sweep this owner away.
      const failure = readFileSync(processOwnerFailure, "utf8").slice(0, 4_096).trim();
      throw new Error(`probe process join failed; staging preserved at ${staging}: ${failure}`);
    }
    rmSync(staging, { recursive: true, force: true });
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const args = process.argv.slice(2);
    const options = args.length === 1 ? { commit: args[0] } : args.length === 3 && args[0] === "--fork-repo" ? { forkRepo: args[1], commit: args[2] } : undefined;
    if (!options) throw new Error("usage: update:pi-subagents -- [--fork-repo <path-or-url>] <full-fork-commit>");
    console.log(JSON.stringify(runUpdate(options), null, 2));
  } catch (error) {
    console.error(`pi-subagents update failed: ${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 1;
  }
}
