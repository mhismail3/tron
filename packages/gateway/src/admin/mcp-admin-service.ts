import { spawn, spawnSync } from "node:child_process";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { createHash } from "node:crypto";
import { rename } from "node:fs/promises";
import lockfile from "proper-lockfile";
import { GatewayError } from "../errors.js";

const MAX_CONFIG_BYTES = 256 * 1_024;
const MAX_OUTPUT_BYTES = 1_048_576;
const CLI_TIMEOUT_MS = 30_000;
const EXPOSURES = ["codemode", "codemode-deferred", "deferred", "direct", "hidden"] as const;
export type McpExposure = typeof EXPOSURES[number];
export type McpScope = { scope: "global" } | { scope: "project"; cwd: string; trusted: true };

/** Secret storage is owned by the host; tests inject a fake instead of touching Keychain. */
export interface McpCredentialOwner {
  store(scope: McpScope, server: string, token: string): Promise<string>;
  remove(scope: McpScope, server: string): Promise<void>;
}

function quoteSecurityArgument(value: string): string {
  return `"${value.replace(/["\\]/gu, "\\$&")}"`;
}

export class MacKeychainMcpCredentialOwner implements McpCredentialOwner {
  constructor(private readonly run: typeof runProcess = runProcess) {}

  private account(scope: McpScope, server: string): string {
    const identity = scope.scope === "global" ? "global" : createHash("sha256").update(scope.cwd).digest("hex").slice(0, 24);
    return `tron-mcp-${identity}-${server}`;
  }
  async store(scope: McpScope, server: string, token: string): Promise<string> {
    if (!/^[A-Za-z0-9._-]{1,128}$/.test(server) || !token || Buffer.byteLength(token) > 16_384 || /[\r\n\0]/u.test(token)) {
      throw new GatewayError("invalid_request", "MCP server or bearer token is invalid");
    }
    const account = this.account(scope, server);
    const command = ["add-generic-password", "-U", "-s", "tron.mcp", "-a", account, "-w", token]
      .map(quoteSecurityArgument).join(" ");
    const result = await this.run("/usr/bin/security", ["-i"], {
      cwd: process.cwd(), timeoutMs: CLI_TIMEOUT_MS, input: `${command}\n`,
    });
    if (result.code !== 0) throw new GatewayError("internal", "Could not store the MCP bearer token in Keychain");
    return account;
  }
  async remove(scope: McpScope, server: string): Promise<void> {
    const account = this.account(scope, server);
    await runProcess("/usr/bin/security", ["delete-generic-password", "-s", "tron.mcp", "-a", account], { cwd: process.cwd(), timeoutMs: CLI_TIMEOUT_MS, allowFailure: true });
  }
}

interface ProcessResult { code: number; stdout: string; stderr: string }
function mcpChildProcessGroups(cliPid: number): number[] {
  const listing = spawnSync("/bin/ps", ["-A", "-o", "pid=,ppid=,pgid="], { encoding: "utf8", maxBuffer: 1_048_576, timeout: 1_000 });
  if (listing.error || listing.status !== 0) return [];
  const rows = listing.stdout.split("\n", 16_384);
  const ownRow = rows.map(line => line.trim().split(/\s+/u).map(Number)).find(([pid]) => pid === process.pid);
  const gatewayGroup = ownRow?.[2];
  const groups: number[] = [];
  for (const line of rows) {
    const [pid, ppid, pgid] = line.trim().split(/\s+/u).map(Number);
    if (Number.isInteger(pid) && ppid === cliPid && pid === pgid && pgid !== undefined
      && pgid > 1 && pgid !== gatewayGroup) groups.push(pgid);
  }
  return groups.slice(0, 128);
}
async function terminateMcpChildGroups(groups: number[]): Promise<void> {
  for (const pgid of groups) signalGroup(pgid, "SIGTERM");
  await new Promise(resolve => setTimeout(resolve, 250));
  for (const pgid of groups) signalGroup(pgid, "SIGKILL");
}
function signalGroup(pgid: number, signal: NodeJS.Signals): void {
  if (pgid <= 1 || !Number.isInteger(pgid)) return;
  const ownGroup = spawnSync("/bin/ps", ["-o", "pgid=", "-p", String(process.pid)], { encoding: "utf8", timeout: 1_000 });
  if (ownGroup.status === 0 && Number(ownGroup.stdout.trim()) === pgid) return;
  try { process.kill(-pgid, signal); } catch {}
}
async function runProcess(command: string, args: string[], options: { cwd: string; timeoutMs: number; allowFailure?: boolean; input?: string }): Promise<ProcessResult> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd: options.cwd, env: process.env, detached: process.platform !== "win32", stdio: [options.input === undefined ? "ignore" : "pipe", "pipe", "pipe"] });
    const killTree = () => {
      if (child.pid && process.platform !== "win32") { try { process.kill(-child.pid, "SIGKILL"); } catch {} }
      else child.kill("SIGKILL");
    };
    if (options.input !== undefined) child.stdin?.end(options.input);
    let stdout = Buffer.alloc(0); let stderr = Buffer.alloc(0); let oversized = false;
    let timedOut = false;
    let timeoutGroups: number[] = [];
    let timeoutChildCleanup: Promise<void> | undefined;
    let timeoutEscalation: NodeJS.Timeout | undefined;
    const collect = (which: "stdout" | "stderr", chunk: Buffer) => {
      const prior = which === "stdout" ? stdout : stderr;
      if (prior.length + chunk.length > MAX_OUTPUT_BYTES) { oversized = true; killTree(); return; }
      if (which === "stdout") stdout = Buffer.concat([stdout, chunk]); else stderr = Buffer.concat([stderr, chunk]);
    };
    child.stdout?.on("data", (chunk: Buffer) => collect("stdout", chunk));
    child.stderr?.on("data", (chunk: Buffer) => collect("stderr", chunk));
    const timer = setTimeout(() => {
      timedOut = true;
      timeoutGroups = child.pid ? mcpChildProcessGroups(child.pid) : [];
      child.kill("SIGTERM");
      timeoutEscalation = setTimeout(() => {
        // Pi's detached stdio process groups are ours only if this CLI directly created their leader.
        if (child.pid) signalGroup(child.pid, "SIGKILL");
        timeoutChildCleanup = terminateMcpChildGroups(timeoutGroups);
      }, 2_000);
      timeoutEscalation.unref();
    }, options.timeoutMs); timer.unref();
    child.once("error", error => { clearTimeout(timer); if (timeoutEscalation) clearTimeout(timeoutEscalation); reject(error); });
    child.once("close", async code => {
      clearTimeout(timer);
      if (timeoutEscalation) clearTimeout(timeoutEscalation);
      if (timedOut) {
        timeoutChildCleanup ??= terminateMcpChildGroups(timeoutGroups);
        await timeoutChildCleanup;
      }
      if (oversized) { reject(new GatewayError("conflict", "MCP command output exceeded its bound")); return; }
      if (code !== 0 && !options.allowFailure) { resolve({ code: code ?? -1, stdout: stdout.toString("utf8"), stderr: stderr.toString("utf8") }); return; }
      resolve({ code: code ?? -1, stdout: stdout.toString("utf8"), stderr: stderr.toString("utf8") });
    });
  });
}

function parseConfig(text: string): Record<string, unknown> {
  let parsed: unknown;
  try { parsed = JSON.parse(text); } catch { throw new GatewayError("conflict", "MCP configuration cannot be parsed; refusing to modify it"); }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new GatewayError("conflict", "MCP configuration must be a JSON object");
  return parsed as Record<string, unknown>;
}

export type McpAdminLog = (level: "warning", message: string, event: string, fields: Record<string, string>) => void;

export class McpAdminService {
  constructor(private readonly agentDir: string, private readonly cliPath: string, private readonly credentials?: McpCredentialOwner,
    private readonly log: McpAdminLog = () => {}, private readonly cliTimeoutMs = CLI_TIMEOUT_MS) {}

  private configPath(scope: McpScope): string {
    return scope.scope === "global" ? join(this.agentDir, "mcp.json") : join(scope.cwd, ".pi", "mcp.json");
  }
  private cliArgs(scope: McpScope, args: string[]): string[] {
    const command = args[0];
    return [this.cliPath, "mcp", ...(command ? [command] : []),
      ...(scope.scope === "project" && command !== "list" ? ["-l"] : []), ...args.slice(1)];
  }
  async list(scope: McpScope): Promise<unknown> {
    const result = await runProcess(process.execPath, this.cliArgs(scope, ["list", "--json"]), { cwd: scope.scope === "project" ? scope.cwd : this.agentDir, timeoutMs: this.cliTimeoutMs });
    if (result.code !== 0 && result.code !== 1) {
      this.log("warning", "Bundled MCP status listing failed", "mcp.startup.problem", { reason: "cli-failure", scope: scope.scope });
      throw new GatewayError("conflict", "MCP listing failed; inspect the MCP log for server diagnostics");
    }
    let parsed: unknown;
    try { parsed = JSON.parse(result.stdout); } catch {
      this.log("warning", "Bundled MCP status listing returned invalid JSON", "mcp.startup.problem", { reason: "invalid-output", scope: scope.scope });
      throw new GatewayError("conflict", "Bundled MCP CLI returned invalid JSON");
    }
    if (parsed && typeof parsed === "object" && Array.isArray((parsed as { errors?: unknown }).errors)) {
      const errors = (parsed as { errors: unknown[] }).errors;
      for (const error of errors.slice(0, 64)) {
        const reason = error && typeof error === "object" && "status" in error && typeof error.status === "string"
          ? error.status.slice(0, 64) : "server-problem";
        this.log("warning", "MCP server reports a startup problem", "mcp.startup.problem", { reason, scope: scope.scope });
      }
    }
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new GatewayError("conflict", "Bundled MCP CLI returned invalid JSON");
    const raw = parsed as { servers?: unknown; errors?: unknown };
    const servers = Array.isArray(raw.servers) ? raw.servers.slice(0, 128).flatMap((item) => {
      if (!item || typeof item !== "object" || Array.isArray(item)) return [];
      const row = item as Record<string, unknown>;
      if (typeof row.name !== "string" || !/^[A-Za-z0-9._-]{1,128}$/.test(row.name)) return [];
      const strings = (value: unknown, limit: number): string[] => Array.isArray(value) ? value.filter((entry): entry is string => typeof entry === "string").slice(0, limit).map(entry => entry.slice(0, 256)) : [];
      return [{ name: row.name, state: typeof row.state === "string" ? row.state.slice(0, 64) : "unknown", scope: row.scope === "project" ? "project" : "global", enabled: row.enabled !== false, transport: typeof row.transport === "string" ? row.transport.slice(0, 256) : "unknown", tools: strings(row.tools, 128) }];
    }) : [];
    const errors = Array.isArray(raw.errors) ? raw.errors.length : 0;
    return { servers, errors };
  }
  async mutate(scope: McpScope, operation: "add" | "remove" | "logout", args: string[], server?: string): Promise<unknown> {
    const result = await runProcess(process.execPath, this.cliArgs(scope, [operation, ...args]), { cwd: scope.scope === "project" ? scope.cwd : this.agentDir, timeoutMs: this.cliTimeoutMs });
    if (result.code !== 0) throw new GatewayError("conflict", `MCP ${operation} failed: ${result.stderr.slice(0, 2_000)}`);
    if (operation === "remove" && server) await this.credentials?.remove(scope, server);
    return { reloadRequired: operation !== "logout", servers: server ? [server] : [] };
  }
  async update(scope: McpScope, server: string, patch: { enabled?: boolean; exposure?: McpExposure }): Promise<unknown> {
    const path = this.configPath(scope);
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, '{"mcpServers":{}}\n', { flag: "wx", mode: 0o600 }).catch((error: NodeJS.ErrnoException) => {
      if (error.code !== "EEXIST") throw error;
    });
    const release = await lockfile.lock(path, { realpath: false, retries: { retries: 6, minTimeout: 20, maxTimeout: 150 } }).catch(() => undefined);
    if (!release) throw new GatewayError("busy", "MCP configuration is being updated", true);
    try {
      const bytes = await readFile(path);
      if (bytes.length > MAX_CONFIG_BYTES) throw new GatewayError("conflict", "MCP configuration exceeds its size limit");
      const config = parseConfig(bytes.toString("utf8"));
      const servers = config.mcpServers;
      if (!servers || typeof servers !== "object" || Array.isArray(servers)) throw new GatewayError("conflict", "MCP configuration has no valid mcpServers object");
      const entry = (servers as Record<string, unknown>)[server];
      if (!entry || typeof entry !== "object" || Array.isArray(entry)) throw new GatewayError("not_found", `MCP server ${server} was not found`);
      if (patch.exposure !== undefined && !(EXPOSURES as readonly string[]).includes(patch.exposure)) throw new GatewayError("invalid_request", "MCP exposure is invalid");
      Object.assign(entry, patch);
      const output = Buffer.from(`${JSON.stringify(config, null, 2)}\n`);
      if (output.length > MAX_CONFIG_BYTES) throw new GatewayError("conflict", "Updated MCP configuration exceeds its size limit");
      const temporary = `${path}.${createHash("sha256").update(`${process.pid}:${Date.now()}`).digest("hex").slice(0, 12)}.tmp`;
      await writeFile(temporary, output, { mode: 0o600 });
      await rename(temporary, path);
      return { server, reloadRequired: true, changed: Object.keys(patch) };
    } finally { await release(); }
  }
  async storeBearer(scope: McpScope, server: string, token: string): Promise<unknown> {
    if (!this.credentials) throw new GatewayError("unsupported", "MCP credential storage is unavailable");
    const account = await this.credentials.store(scope, server, token);
    const path = this.configPath(scope);
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, '{"mcpServers":{}}\n', { flag: "wx", mode: 0o600 }).catch((error: NodeJS.ErrnoException) => {
      if (error.code !== "EEXIST") throw error;
    });
    const release = await lockfile.lock(path, { realpath: false, retries: { retries: 6, minTimeout: 20, maxTimeout: 150 } }).catch(() => undefined);
    if (!release) throw new GatewayError("busy", "MCP configuration is being updated", true);
    try {
      const bytes = await readFile(path);
      if (bytes.length > MAX_CONFIG_BYTES) throw new GatewayError("conflict", "MCP configuration exceeds its size limit");
      const config = parseConfig(bytes.toString("utf8"));
      const servers = config.mcpServers as Record<string, unknown> | undefined;
      const entry = servers?.[server];
      if (!entry || typeof entry !== "object" || Array.isArray(entry)) throw new GatewayError("not_found", `MCP server ${server} was not found`);
      const definition = entry as Record<string, unknown>;
      const headers = definition.headers && typeof definition.headers === "object" && !Array.isArray(definition.headers) ? definition.headers as Record<string, unknown> : {};
      headers.Authorization = `!/usr/bin/security find-generic-password -s tron.mcp -a ${account} -w | /usr/bin/sed 's/^/Bearer /'`;
      definition.headers = headers;
      const output = Buffer.from(`${JSON.stringify(config, null, 2)}\n`);
      if (output.length > MAX_CONFIG_BYTES) throw new GatewayError("conflict", "Updated MCP configuration exceeds its size limit");
      const temporary = `${path}.${createHash("sha256").update(`${process.pid}:${Date.now()}`).digest("hex").slice(0, 12)}.tmp`;
      await writeFile(temporary, output, { mode: 0o600 });
      await rename(temporary, path);
    } finally { await release(); }
    return { server, stored: true };
  }
}
