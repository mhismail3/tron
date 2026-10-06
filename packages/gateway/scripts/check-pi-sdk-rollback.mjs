#!/usr/bin/env node
/**
 * Sequential old/candidate persistence compatibility check. All files and
 * credentials are created beneath a disposable temp directory.
 *
 * The MCP case exists because Pi owns two more persisted stores than the JSONL,
 * settings and auth files this matrix started with:
 * - `mcp.json` is the MCP configuration authority. A runtime that renames,
 *   drops or refuses a configured server (here a hyphenated name) leaves the
 *   previous runtime without the tools the user configured.
 * - `mcp-auth.json` holds MCP OAuth credentials. A candidate that keys them by
 *   server name and URL, and moves the URL-keyed entries it finds, strands every
 *   sign-in the moment the Gateway is rolled back to the runtime that keys them
 *   by URL alone. `pi mcp list --json` reports `needs-auth` for such a server,
 *   which is the signal this check turns into a failure.
 * Each direction seeds the pre-upgrade on-disk state, lets the candidate run,
 * and then asks the rollback runtime to resolve it again.
 *
 * A store whose re-keying the maintainer has accepted as a one-way rollback
 * delta is listed in `pi-sdk-baseline.json` under `knownOneWayDeltas`. The entry
 * names the store, the version range, the credential-key transform and the
 * rollback state that transform may leave behind; the check then asserts every
 * other runtime, step, state and key, and fails when the entry is stale. The
 * list is absent on the pinned 0.99.1 layer.
 *
 * `TRON_PI_ROLLBACK_MCP_FAULT=candidate-needs-auth` (or `candidate-failed`) is a
 * negative-control injection that makes the fixture refuse the candidate
 * runtime's requests, proving the matrix still fails when the candidate, rather
 * than the rollback, is the runtime that cannot resolve the credential. It is
 * never set in a normal run.
 */
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { isDeepStrictEqual } from "node:util";
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { PI_PACKAGES, readPiSdkBaseline, validSha512Integrity, validatePiSdk } from "./check-pi-sdk.mjs";

const MAX_OUTPUT_BYTES = 256 * 1024;
const PROCESS_TIMEOUT_MS = 120_000;
const PACKAGE_NAME = "@earendil-works/pi-coding-agent";
const MCP_SERVER = "probe-mcp-server";
const MCP_ACCESS_TOKEN = "probe-mcp-access-token";
const MCP_FAULT = process.env.TRON_PI_ROLLBACK_MCP_FAULT ?? "";

/**
 * Run one child to completion without blocking this process: the MCP fixture is
 * served from here, so a synchronous spawn would starve it and every probe would
 * report a timed-out server instead of the state under test. Each child leads
 * its own process group, so a timeout kills its descendants too — a probe that
 * is killed must not leave a `pi mcp` grandchild behind.
 */
async function run(command, args, options = {}) {
  const timeoutMs = options.timeoutMs ?? PROCESS_TIMEOUT_MS;
  const child = spawn(command, args, {
    cwd: options.cwd, detached: true,
    env: { ...process.env, npm_config_offline: "false", PI_CODING_AGENT_DIR: options.agentDir ?? join(options.cwd ?? tmpdir(), "unused-agent") },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (chunk) => { if (Buffer.byteLength(stdout) <= MAX_OUTPUT_BYTES) stdout += chunk; });
  child.stderr.on("data", (chunk) => { if (Buffer.byteLength(stderr) <= MAX_OUTPUT_BYTES) stderr += chunk; });
  let timedOut = false;
  const killGroup = () => {
    try { process.kill(-child.pid, "SIGKILL"); }
    catch { try { child.kill("SIGKILL"); } catch { /* already gone */ } }
  };
  const timer = setTimeout(() => { timedOut = true; killGroup(); }, timeoutMs);
  let status;
  try {
    status = await new Promise((resolve, reject) => {
      child.once("error", reject);
      child.on("close", resolve);
    });
  } finally {
    clearTimeout(timer);
  }
  if (timedOut) throw new Error(`${command} ${args.join(" ")} did not finish within ${timeoutMs}ms`);
  if (status !== 0) throw new Error(`${command} ${args.join(" ")} failed: ${stderr.trim() || `exit ${status}`}`);
  if (Buffer.byteLength(stdout) > MAX_OUTPUT_BYTES) throw new Error("rollback probe output exceeded bound");
  return stdout;
}

function packageRoot(gatewayDir) {
  const root = resolve(gatewayDir, "node_modules/@earendil-works/pi-coding-agent");
  if (!existsSync(join(root, "package.json"))) throw new Error(`candidate Pi package is missing: ${root}`);
  return root;
}

export function rollbackInstallCommand(version) {
  if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/u.test(version)) throw new Error("rollback version must be exact semver");
  return ["install", "--save-exact", "--ignore-scripts", "--engine-strict", "--omit=optional", "--no-audit", "--no-fund", "--registry=https://registry.npmjs.org/", "--offline=false", `${PACKAGE_NAME}@${version}`];
}
export function rollbackAuditCommand() { return ["audit", "signatures", "--registry=https://registry.npmjs.org/", "--offline=false", "--prefer-online"]; }

function validateRollbackInstalled(project, version) {
  const root = resolve(project);
  const packageJson = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
  if (packageJson.dependencies?.[PACKAGE_NAME] !== version) throw new Error("rollback project does not pin exact pi-coding-agent");
  const lock = JSON.parse(readFileSync(join(root, "package-lock.json"), "utf8"));
  const rootReal = realpathSync(root);
  const found = new Set();
  for (const [relativePath, entry] of Object.entries(lock.packages ?? {})) {
    const match = relativePath.match(/(?:^|\/)node_modules\/@earendil-works\/(pi-[^/]+|chord)$/u);
    if (!match || !entry || typeof entry !== "object") continue;
    const name = `@earendil-works/${match[1]}`;
    if (!PI_PACKAGES.includes(name)) throw new Error(`rollback install contains unexpected Pi package: ${name}`);
    found.add(name);
    const absolute = resolve(root, relativePath);
    if (absolute !== root && !absolute.startsWith(`${root}/`)) throw new Error(`rollback lock path escapes project: ${relativePath}`);
    const info = lstatSync(absolute);
    if (!info.isDirectory() || info.isSymbolicLink()) throw new Error(`rollback Pi package root is substituted: ${relativePath}`);
    const real = realpathSync(absolute);
    if (!real.startsWith(`${rootReal}/`)) throw new Error(`rollback Pi package root escapes project: ${relativePath}`);
    const nestedShrinkwrap = relativePath.startsWith("node_modules/@earendil-works/pi-coding-agent/node_modules/");
    if (entry.version !== version || entry.resolved !== `https://registry.npmjs.org/${name}/-/${name.slice(name.indexOf("/") + 1)}-${version}.tgz`
      || (entry.integrity !== undefined && !validSha512Integrity(entry.integrity))
      || (entry.integrity === undefined && !nestedShrinkwrap)) throw new Error(`rollback Pi package metadata is incoherent: ${relativePath}`);
  }
  if (!found.has(PACKAGE_NAME)) throw new Error(`rollback install omitted ${PACKAGE_NAME}`);
}

async function installRollback(gatewayDir, version, temp) {
  const project = join(temp, "rollback-project");
  mkdirSync(project, { recursive: true });
  const packageManifest = { name: "tron-pi-rollback-fixture", private: true, version: "1.0.0" };
  writeFileSync(join(project, "package.json"), `${JSON.stringify(packageManifest, null, 2)}\n`);
  const args = rollbackInstallCommand(version);
  const cache = process.env.npm_config_cache;
  if (cache) args.push("--cache", cache);
  await run("npm", args, { cwd: project, agentDir: join(temp, "rollback-agent"), timeoutMs: 300_000 });
  validateRollbackInstalled(project, version);
  await run("npm", rollbackAuditCommand(), { cwd: project, agentDir: join(temp, "rollback-agent"), timeoutMs: 300_000 });
  return packageRoot(project);
}

async function probe(probePath, root, action, temp, mcpUrl) {
  mkdirSync(temp, { recursive: true });
  return JSON.parse((await run(process.execPath, [probePath, root, action, temp, mcpUrl], { cwd: temp, agentDir: join(temp, "agent") })).trim());
}

/**
 * One loopback MCP server that only answers with the seeded OAuth access token.
 * It lives in this check rather than in each probe process so every probe of a
 * direction writes and reads the same server URL: a per-process port would make
 * `mcp.json` differ between the runtimes and hide exactly what is being compared.
 * `setFault` is the negative-control injection described in the file header.
 */
async function startMcpFixture() {
  let origin = "";
  let fault = "";
  const server = createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(Buffer.from(chunk));
    const body = Buffer.concat(chunks).toString("utf8");
    if (req.url === "/.well-known/oauth-protected-resource") {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ resource: `${origin}/mcp`, authorization_servers: [origin] }));
      return;
    }
    if (fault === "failed") { res.writeHead(503, { "content-type": "application/json" }); res.end(JSON.stringify({ error: "injected failure" })); return; }
    if (fault === "needs-auth" || req.headers.authorization !== `Bearer ${MCP_ACCESS_TOKEN}`) {
      res.writeHead(401, { "www-authenticate": `Bearer resource_metadata="${origin}/.well-known/oauth-protected-resource"` });
      res.end();
      return;
    }
    const headers = { "content-type": "application/json", "mcp-session-id": "probe-session", "mcp-protocol-version": "2025-03-26" };
    const request = body ? JSON.parse(body) : undefined;
    if (request?.method === "initialize") {
      res.writeHead(200, headers);
      res.end(JSON.stringify({ jsonrpc: "2.0", id: request.id, result: { protocolVersion: "2025-03-26", capabilities: { tools: {} }, serverInfo: { name: "probe", version: "1" } } }));
      return;
    }
    if (request?.method === "notifications/initialized") { res.writeHead(202); res.end(); return; }
    if (request?.method === "tools/list") {
      res.writeHead(200, headers);
      res.end(JSON.stringify({ jsonrpc: "2.0", id: request.id, result: { tools: [{ name: "probe-tool", description: "probe", inputSchema: { type: "object", properties: {} } }] } }));
      return;
    }
    res.writeHead(200, headers);
    res.end();
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("MCP fixture failed to bind loopback");
  origin = `http://127.0.0.1:${address.port}`;
  return {
    url: `${origin}/mcp`,
    setFault: (next) => { fault = next; },
    close: () => new Promise((resolve) => server.close(() => resolve())),
  };
}

/** Pi's tool and credential namespace for a server name: `-` becomes `_`. */
function mcpNamespace(server) {
  return `mcp__${server.replace(/-/gu, "_")}`;
}

/** Render one accepted-delta key template; `check-pi-sdk.mjs` allows no other placeholder. */
function renderCredentialKey(template, server, url) {
  return template.split("{namespace}").join(mcpNamespace(server)).split("{url}").join(url);
}

/**
 * The MCP half of the matrix. A runtime without Pi's built-in MCP extension
 * (0.87.1 predates it) reports `supported: false`; the check then asserts only
 * what the runtimes that do own the stores report, and names the runtimes it
 * skipped so a passing run never implies coverage it did not have. Only the
 * rollback runtime may be unsupported, so a candidate that drops or moves the
 * MCP surface cannot pass as "unsupported".
 *
 * A matching `knownOneWayDeltas` entry does not bypass the MCP checks. It names
 * exactly one observation it accepts: the rollback runtime, in the step after
 * the candidate wrote the store, reports the entry's `rollbackState` for the
 * server whose credential key moved from the entry's `from` template to its `to`
 * template. Every candidate step must still be connected, the server must still
 * resolve, `mcp.json` must still round-trip, the pre-candidate rollback step
 * must still be connected, no other state is accepted, and an entry whose delta
 * is not observed fails as stale.
 */
function assertMcpSequence(states, direction, versions, rollbackVersion, mcpUrl, knownOneWayDeltas) {
  const supported = states.flatMap((state, index) => state.supported ? [{ state, version: versions[index], index }] : []);
  const skipped = versions.filter((_version, index) => !states[index].supported);
  const server = (state) => state.servers.find((entry) => entry.name === MCP_SERVER);
  const observed = states.map((state, index) => {
    if (!state.supported) return `Pi ${versions[index]} has no usable built-in MCP surface (${state.reason})`;
    const resolved = server(state);
    const keys = state.credentialsBefore.join(", ") === state.credentialsAfter.join(", ")
      ? `[${state.credentialsBefore.join(", ")}]`
      : `[${state.credentialsBefore.join(", ")}] re-keyed to [${state.credentialsAfter.join(", ")}]`;
    return `Pi ${versions[index]} ${resolved ? `${resolved.state}${resolved.error ? ` (${resolved.error})` : ""}` : "lost the server"} with credential keys ${keys}`;
  }).join("; ");
  for (const [index, state] of states.entries()) {
    if (!state.supported && versions[index] !== rollbackVersion) {
      throw new Error(`${direction} Pi ${versions[index]} has no usable built-in MCP surface (${state.reason}): ${observed}`);
    }
  }
  if (supported.length === 0) return { checked: [], skipped, accepted: [] };
  const candidateIndex = versions.findIndex((version) => version !== rollbackVersion);
  const candidateVersion = candidateIndex < 0 ? undefined : versions[candidateIndex];
  const entry = candidateVersion === undefined ? undefined
    : knownOneWayDeltas.find((delta) => delta.store === "mcp-auth" && delta.from === rollbackVersion && delta.to === candidateVersion);
  if (entry !== undefined && supported.length !== states.length) {
    throw new Error(`${direction} the accepted ${entry.store} delta ${entry.from} -> ${entry.to} cannot be observed because Pi ${rollbackVersion} has no usable built-in MCP surface: ${observed}`);
  }
  // 1. Every runtime that owns the stores must still resolve the configured server.
  for (const { state, version } of supported) {
    if (!server(state)) throw new Error(`${direction} MCP config lost server "${MCP_SERVER}" for Pi ${version}: ${observed}`);
  }
  // 2. Every candidate step must be connected: an upgrade that signs users out is
  //    a forward regression, never an accepted rollback delta.
  for (const { state, version } of supported) {
    if (version !== rollbackVersion && server(state).state !== "connected") {
      throw new Error(`${direction} MCP OAuth credential was not resolved by candidate Pi ${version}: server "${MCP_SERVER}" reports "${server(state).state}" — ${observed}`);
    }
  }
  // 3. The rollback step before the candidate ran must be connected. Only the
  //    rollback step after it may report the entry's expected rollback state.
  let deltaObserved = 0;
  for (const { state, version, index } of supported) {
    if (version !== rollbackVersion) continue;
    const state_ = server(state).state;
    if (state_ === "connected") continue;
    if (entry !== undefined && index > candidateIndex && state_ === entry.rollbackState) { deltaObserved += 1; continue; }
    throw new Error(`${direction} MCP OAuth credential was not resolved by rollback Pi ${version}: server "${MCP_SERVER}" reports "${state_}" — ${observed}`);
  }
  const checked = supported.map(({ version }) => version);
  const report = { checked, skipped, accepted: entry === undefined ? [] : [{ ...entry, direction, observed }] };
  if (supported.length !== states.length) return report;
  const [written, appended, final] = states;
  if (!isDeepStrictEqual(appended.config, written.config) || !isDeepStrictEqual(final.config, written.config)) {
    throw new Error(`${direction} MCP config changed across the rollback: ${JSON.stringify(written.config)} -> ${JSON.stringify(appended.config)} -> ${JSON.stringify(final.config)}`);
  }
  // `mcp.json` is not the accepted store, so its resolution must round-trip
  // whichever state the credential is in.
  const resolution = (state) => {
    const { name, enabled, exposure, transport } = server(state);
    return { name, enabled, exposure, transport };
  };
  if (!isDeepStrictEqual(resolution(appended), resolution(written)) || !isDeepStrictEqual(resolution(final), resolution(written))) {
    throw new Error(`${direction} MCP server resolution changed across the rollback: ${JSON.stringify(written.servers)} -> ${JSON.stringify(appended.servers)} -> ${JSON.stringify(final.servers)}`);
  }
  if (entry === undefined) {
    if (!isDeepStrictEqual(appended.servers, written.servers) || !isDeepStrictEqual(final.servers, written.servers)) {
      throw new Error(`${direction} MCP server resolution changed across the rollback: ${JSON.stringify(written.servers)} -> ${JSON.stringify(appended.servers)} -> ${JSON.stringify(final.servers)}`);
    }
    if (!isDeepStrictEqual(final.credentialsBefore, written.credentialsBefore)) {
      throw new Error(`${direction} MCP credential store keys changed across the rollback: [${written.credentialsBefore.join(", ")}] -> [${appended.credentialsBefore.join(", ")}] -> [${final.credentialsBefore.join(", ")}]`);
    }
    return report;
  }
  if (deltaObserved === 0) {
    throw new Error(`${direction} the accepted ${entry.store} delta ${entry.from} -> ${entry.to} was not observed, so its entry is stale and must be removed: ${observed}`);
  }
  const fromKey = renderCredentialKey(entry.credentialKey.from, MCP_SERVER, mcpUrl);
  const toKey = renderCredentialKey(entry.credentialKey.to, MCP_SERVER, mcpUrl);
  if (!isDeepStrictEqual(written.credentialsBefore, [fromKey])) {
    throw new Error(`${direction} MCP credential store did not start from the accepted key "${fromKey}": [${written.credentialsBefore.join(", ")}] — ${observed}`);
  }
  if (!isDeepStrictEqual(appended.credentialsAfter, [toKey]) || !isDeepStrictEqual(final.credentialsBefore, [toKey])) {
    throw new Error(`${direction} MCP credential store did not move to the accepted key "${toKey}": [${appended.credentialsAfter.join(", ")}] -> [${final.credentialsBefore.join(", ")}] — ${observed}`);
  }
  return report;
}

function assertSequence([written, appended, final], direction, versions, rollbackVersion, mcpUrl, knownOneWayDeltas) {
  if (appended.entries.length !== written.entries.length + 1) throw new Error(`${direction} compatibility did not preserve exactly one appended JSONL entry`);
  if (!isDeepStrictEqual(appended.entries.slice(0, -1), written.entries)) throw new Error(`${direction} compatibility changed pre-existing JSONL entries`);
  if (!isDeepStrictEqual(final.entries, appended.entries)) throw new Error(`${direction} final reader disagrees with the append reader`);
  if (!isDeepStrictEqual(final.settingsAuth, appended.settingsAuth)) throw new Error(`${direction} final reader disagrees with settings/auth state`);
  if (appended.settingsAuth.settings.theme !== "dark" || !appended.settingsAuth.auth.includes("anthropic")) throw new Error(`${direction} settings/auth append was lost`);
  return assertMcpSequence([written.mcp, appended.mcp, final.mcp], direction, versions, rollbackVersion, mcpUrl, knownOneWayDeltas);
}

function mcpCoverage(forward, reverse, rollbackVersion, currentVersion) {
  const checked = [...new Set([...forward.checked, ...reverse.checked])].sort();
  const skipped = [...new Set([...forward.skipped, ...reverse.skipped])].sort();
  // Both directions verify the same accepted range; report it once, with the
  // exact sequence each direction observed it in.
  const reported = [...forward.accepted, ...reverse.accepted];
  const knownDeltas = [...new Set(reported.map((entry) => `${entry.store}|${entry.from}|${entry.to}`))].map((key) => {
    const group = reported.filter((entry) => `${entry.store}|${entry.from}|${entry.to}` === key);
    return { ...group[0], observed: group.map((entry) => `${entry.direction}: ${entry.observed}`).join(" | ") };
  });
  const roundTrip = forward.skipped.length === 0 && reverse.skipped.length === 0 && knownDeltas.length === 0;
  const coverage = checked.length > 0
    ? `MCP config+credentials checked by ${checked.join(", ")}`
    : "MCP config+credentials checked by no runtime";
  return {
    checked,
    skipped,
    roundTrip,
    knownDeltas,
    description: roundTrip
      ? `${coverage}, round-tripped through ${currentVersion} and ${rollbackVersion}`
      : `${coverage}${skipped.length > 0 ? `; ${skipped.join(", ")} predates Pi's built-in MCP extension` : ""}${knownDeltas.map((entry) => `; known one-way delta accepted: ${entry.store} ${entry.from} -> ${entry.to} (${entry.rollbackState}, ${entry.observed})`).join("")}`,
  };
}

export async function runRollbackCheck({ gatewayDir = resolve(dirname(fileURLToPath(import.meta.url)), "..") } = {}) {
  const root = resolve(gatewayDir);
  const current = validatePiSdk({ gatewayDir: root, checkInstalled: true });
  if (!current.ok || !current.version) throw new Error(`current Pi SDK is not coherent: ${current.issues.join("; ")}`);
  const baseline = readPiSdkBaseline(root);
  if (baseline.issues.length > 0 || !baseline.value) throw new Error(`rollback metadata is invalid: ${baseline.issues.join("; ")}`);
  const temp = mkdtempSync(join(tmpdir(), "tron-pi-rollback-"));
  let mcp;
  try {
    mcp = await startMcpFixture();
    const rollbackRoot = current.version === baseline.value.rollbackVersion
      ? packageRoot(root)
      : await installRollback(root, baseline.value.rollbackVersion, temp);
    const probePath = join(root, "scripts/pi-session-compatibility-probe.mjs");
    // Each action is a separate Node process, so module caches and open files
    // cannot mask a format or migration incompatibility. The candidate's steps
    // are the ones the fault injection refuses.
    const candidateFault = MCP_FAULT === "candidate-needs-auth" ? "needs-auth" : MCP_FAULT === "candidate-failed" ? "failed" : "";
    const asCandidate = async (work) => {
      mcp.setFault(candidateFault);
      try { return await work(); } finally { mcp.setFault(""); }
    };
    const forwardWrite = await probe(probePath, rollbackRoot, "write", join(temp, "forward"), mcp.url);
    const forwardAppend = await asCandidate(() => probe(probePath, packageRoot(root), "read-append", join(temp, "forward"), mcp.url));
    const forwardRead = await probe(probePath, rollbackRoot, "read", join(temp, "forward"), mcp.url);
    const reverseWrite = await asCandidate(() => probe(probePath, packageRoot(root), "write", join(temp, "reverse"), mcp.url));
    const reverseAppend = await probe(probePath, rollbackRoot, "read-append", join(temp, "reverse"), mcp.url);
    const reverseRead = await asCandidate(() => probe(probePath, packageRoot(root), "read", join(temp, "reverse"), mcp.url));
    const knownOneWayDeltas = baseline.value.knownOneWayDeltas ?? [];
    const forward = assertSequence([forwardWrite, forwardAppend, forwardRead], "forward", [baseline.value.rollbackVersion, current.version, baseline.value.rollbackVersion], baseline.value.rollbackVersion, mcp.url, knownOneWayDeltas);
    const reverse = assertSequence([reverseWrite, reverseAppend, reverseRead], "reverse", [current.version, baseline.value.rollbackVersion, current.version], baseline.value.rollbackVersion, mcp.url, knownOneWayDeltas);
    const coverage = mcpCoverage(forward, reverse, baseline.value.rollbackVersion, current.version);
    return { currentVersion: current.version, rollbackVersion: baseline.value.rollbackVersion, mcp: coverage, forward: [forwardWrite, forwardAppend, forwardRead], reverse: [reverseWrite, reverseAppend, reverseRead] };
  } finally {
    if (mcp) await mcp.close();
    rmSync(temp, { recursive: true, force: true });
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const gatewayDir = process.argv[2] ? resolve(process.argv[2]) : resolve(dirname(fileURLToPath(import.meta.url)), "..");
    const result = await runRollbackCheck({ gatewayDir });
    console.log(`Pi SDK rollback compatibility passed (${result.rollbackVersion} -> ${result.currentVersion}; isolated JSONL/settings/auth subprocesses; ${result.mcp.description})`);
  } catch (error) {
    console.error(`Pi SDK rollback compatibility failed: ${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 1;
  }
}
