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

/**
 * Run one child to completion without blocking this process: the MCP fixture is
 * served from here, so a synchronous spawn would starve it and every probe would
 * report a timed-out server instead of the state under test.
 */
async function run(command, args, options = {}) {
  const timeoutMs = options.timeoutMs ?? PROCESS_TIMEOUT_MS;
  const child = spawn(command, args, {
    cwd: options.cwd,
    env: { ...process.env, npm_config_offline: "false", PI_CODING_AGENT_DIR: options.agentDir ?? join(options.cwd ?? tmpdir(), "unused-agent") },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (chunk) => { if (Buffer.byteLength(stdout) <= MAX_OUTPUT_BYTES) stdout += chunk; });
  child.stderr.on("data", (chunk) => { if (Buffer.byteLength(stderr) <= MAX_OUTPUT_BYTES) stderr += chunk; });
  let timedOut = false;
  const timer = setTimeout(() => { timedOut = true; child.kill("SIGKILL"); }, timeoutMs);
  const status = await new Promise((resolve, reject) => {
    child.once("error", reject);
    child.on("close", resolve);
  });
  clearTimeout(timer);
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
 */
async function startMcpFixture() {
  let origin = "";
  const server = createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(Buffer.from(chunk));
    const body = Buffer.concat(chunks).toString("utf8");
    if (req.url === "/.well-known/oauth-protected-resource") {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ resource: `${origin}/mcp`, authorization_servers: [origin] }));
      return;
    }
    if (req.headers.authorization !== `Bearer ${MCP_ACCESS_TOKEN}`) {
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
  return { url: `${origin}/mcp`, close: () => new Promise((resolve) => server.close(() => resolve())) };
}

/** The MCP half of the matrix. A runtime without Pi's built-in MCP extension
 * (0.87.1 predates it) reports `supported: false`; the check then asserts only
 * what the runtimes that do own the stores report, and names the runtimes it
 * skipped so a passing run never implies coverage it did not have. */
function assertMcpSequence(states, direction, versions) {
  const supported = states.flatMap((state, index) => state.supported ? [{ state, version: versions[index] }] : []);
  const skipped = versions.filter((_version, index) => !states[index].supported);
  // Every failure names the whole sequence, so the on-disk delta it reports is
  // reviewable: which runtime resolved what, and the credential keys left behind.
  const observed = states.map((state, index) => state.supported
    ? `Pi ${versions[index]} ${state.servers.find((entry) => entry.name === MCP_SERVER)?.state ?? "lost the server"} with credential keys [${state.credentials.join(", ")}]`
    : `Pi ${versions[index]} has no built-in MCP extension`).join("; ");
  if (supported.length === 0) return { checked: [], skipped };
  for (const { state, version } of supported) {
    const server = state.servers.find((entry) => entry.name === MCP_SERVER);
    if (!server) throw new Error(`${direction} MCP config lost server "${MCP_SERVER}": ${observed}`);
    if (server.state !== "connected") {
      throw new Error(`${direction} MCP OAuth credential was not resolved by Pi ${version}: server "${MCP_SERVER}" reports "${server.state}" — ${observed}`);
    }
  }
  const checked = supported.map(({ version }) => version);
  if (supported.length !== states.length) return { checked, skipped };
  const [written, appended, final] = states;
  if (!isDeepStrictEqual(appended.config, written.config) || !isDeepStrictEqual(final.config, written.config)) {
    throw new Error(`${direction} MCP config changed across the rollback: ${JSON.stringify(written.config)} -> ${JSON.stringify(appended.config)} -> ${JSON.stringify(final.config)}`);
  }
  if (!isDeepStrictEqual(appended.servers, written.servers) || !isDeepStrictEqual(final.servers, written.servers)) {
    throw new Error(`${direction} MCP server resolution changed across the rollback: ${JSON.stringify(written.servers)} -> ${JSON.stringify(appended.servers)} -> ${JSON.stringify(final.servers)}`);
  }
  if (!isDeepStrictEqual(final.credentials, written.credentials)) {
    throw new Error(`${direction} MCP credential store keys changed across the rollback: [${written.credentials.join(", ")}] -> [${appended.credentials.join(", ")}] -> [${final.credentials.join(", ")}]`);
  }
  return { checked, skipped };
}

function assertSequence([written, appended, final], direction, versions) {
  if (appended.entries.length !== written.entries.length + 1) throw new Error(`${direction} compatibility did not preserve exactly one appended JSONL entry`);
  if (!isDeepStrictEqual(appended.entries.slice(0, -1), written.entries)) throw new Error(`${direction} compatibility changed pre-existing JSONL entries`);
  if (!isDeepStrictEqual(final.entries, appended.entries)) throw new Error(`${direction} final reader disagrees with the append reader`);
  if (!isDeepStrictEqual(final.settingsAuth, appended.settingsAuth)) throw new Error(`${direction} final reader disagrees with settings/auth state`);
  if (appended.settingsAuth.settings.theme !== "dark" || !appended.settingsAuth.auth.includes("anthropic")) throw new Error(`${direction} settings/auth append was lost`);
  return assertMcpSequence([written.mcp, appended.mcp, final.mcp], direction, versions);
}

function mcpCoverage(forward, reverse, rollbackVersion, currentVersion) {
  const checked = [...new Set([...forward.checked, ...reverse.checked])].sort();
  const skipped = [...new Set([...forward.skipped, ...reverse.skipped])].sort();
  const roundTrip = forward.skipped.length === 0 && reverse.skipped.length === 0;
  return {
    checked,
    skipped,
    roundTrip,
    description: roundTrip
      ? `MCP config+credentials round-tripped through ${currentVersion} and ${rollbackVersion}`
      : `MCP config+credentials checked by ${checked.join(", ") || "no runtime"}; ${skipped.join(", ")} predates Pi's built-in MCP extension`,
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
    // cannot mask a format or migration incompatibility.
    const forwardWrite = await probe(probePath, rollbackRoot, "write", join(temp, "forward"), mcp.url);
    const forwardAppend = await probe(probePath, packageRoot(root), "read-append", join(temp, "forward"), mcp.url);
    const forwardRead = await probe(probePath, rollbackRoot, "read", join(temp, "forward"), mcp.url);
    const reverseWrite = await probe(probePath, packageRoot(root), "write", join(temp, "reverse"), mcp.url);
    const reverseAppend = await probe(probePath, rollbackRoot, "read-append", join(temp, "reverse"), mcp.url);
    const reverseRead = await probe(probePath, packageRoot(root), "read", join(temp, "reverse"), mcp.url);
    const forward = assertSequence([forwardWrite, forwardAppend, forwardRead], "forward", [baseline.value.rollbackVersion, current.version, baseline.value.rollbackVersion]);
    const reverse = assertSequence([reverseWrite, reverseAppend, reverseRead], "reverse", [current.version, baseline.value.rollbackVersion, current.version]);
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
