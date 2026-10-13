import { spawn, spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it, onTestFinished, vi } from "vitest";
import lockfile from "proper-lockfile";
import { MacKeychainMcpCredentialOwner, McpAdminService, type McpCredentialOwner } from "./mcp-admin-service.js";

/** The Pi CLI the package declares in its own manifest, not a guessed layout. */
function piCliPath(): string {
  let directory = dirname(fileURLToPath(import.meta.resolve("@earendil-works/pi-coding-agent")));
  while (directory !== dirname(directory)) {
    const manifest = join(directory, "package.json");
    if (existsSync(manifest)) {
      const parsed = JSON.parse(readFileSync(manifest, "utf8")) as { name?: string; bin?: { pi?: string } };
      if (parsed.name === "@earendil-works/pi-coding-agent" && parsed.bin?.pi) return join(directory, parsed.bin.pi);
    }
    directory = dirname(directory);
  }
  throw new Error("could not locate the pi-coding-agent package manifest");
}
const cliPath = piCliPath();

/** `ps` state of a process: empty once it is reaped, `Z` while an exited child awaits reaping. */
function processState(pid: number): string {
  return spawnSync("/bin/ps", ["-o", "stat=", "-p", String(pid)], { encoding: "utf8" }).stdout.trim();
}
function isExited(pid: number): boolean {
  const state = processState(pid);
  return state === "" || state.startsWith("Z");
}

/** Kills every process whose command line names this test's private root (the stdio fixture and
 * the CLI stand-ins it starts), then removes the root. It runs from `onTestFinished`, after the
 * assertions and on every outcome, so a failing or hung test cannot leave a server running. It is
 * a test-side net: the production cleanup under test must have already killed these processes. */
async function cleanupFixtures(root: string, unrelatedPid?: number): Promise<void> {
  vi.unstubAllEnvs();
  if (unrelatedPid) { try { process.kill(-unrelatedPid, "SIGKILL"); } catch {} }
  killProcessesNaming(root);
  await rm(root, { recursive: true, force: true });
}
function killProcessesNaming(root: string): void {
  const listing = spawnSync("/bin/ps", ["-A", "-o", "pid=,command="], { encoding: "utf8", maxBuffer: 16 * 1_048_576 }).stdout;
  for (const line of listing.split("\n")) {
    const pid = Number(line.trim().split(/\s+/u, 1)[0]);
    if (Number.isInteger(pid) && pid > 1 && pid !== process.pid && line.includes(root)) {
      try { process.kill(pid, "SIGKILL"); } catch {}
    }
  }
}

describe("McpAdminService", () => {
  it("quotes interactive Keychain commands and rejects line-breaking secrets without exposing argv", async () => {
    let invocation: { command: string; args: string[]; input?: string } | undefined;
    const owner = new MacKeychainMcpCredentialOwner(async (command, args, options) => {
      invocation = { command, args, input: options.input };
      return { code: 0, stdout: "", stderr: "" };
    });
    const token = 'space "quote" \\ slash';
    await owner.store({ scope: "global" }, "fixture", token);
    expect(invocation).toEqual({
      command: "/usr/bin/security",
      args: ["-i"],
      input: '"add-generic-password" "-U" "-s" "tron.mcp" "-a" "tron-mcp-global-fixture" "-w" "space \\"quote\\" \\\\ slash"\n',
    });
    expect(JSON.stringify(invocation)).not.toContain(token);
    const globalAccount = invocation?.input;
    const projectScope = { scope: "project" as const, cwd: "/tmp/workspace-a", trusted: true as const };
    await owner.store(projectScope, "fixture", token);
    const projectAccount = invocation?.input;
    expect(projectAccount).not.toBe(globalAccount);
    await owner.store(projectScope, "fixture", token);
    expect(invocation?.input).toBe(projectAccount);
    await expect(owner.store({ scope: "global" }, "fixture", "line\nbreak")).rejects.toThrow(/invalid/u);
    await expect(owner.store({ scope: "global" }, "fixture", "nul\0byte")).rejects.toThrow(/invalid/u);
  });
  it("uses the bundled CLI for explicit status reads and bounds the result to valid JSON", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-mcp-admin-"));
    try {
      const service = new McpAdminService(root, cliPath);
      const result = await service.list({ scope: "global" }) as { servers: unknown[]; errors: unknown[] };
      expect(result.servers).toEqual([]);
      expect(result.errors).toBe(0);
    } finally { await rm(root, { recursive: true, force: true }); }
  });

  // Captured from the bundled Pi 0.99.1 CLI; the machine-specific source path is redacted.
  it("projects the pinned Pi failed-list payload even when the CLI exits 1", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-mcp-list-payload-"));
    const fixture = fileURLToPath(new URL("./fixtures/mcp-list-failed-cli.json", import.meta.url));
    const script = join(root, "cli.mjs");
    try {
      await writeFile(script, `process.stdout.write(await (await import('node:fs/promises')).readFile(${JSON.stringify(fixture)}, 'utf8')); process.exit(1);`);
      const service = new McpAdminService(root, script);
      expect(await service.list({ scope: "global" })).toEqual({
        servers: [
          { name: "unreachable", state: "failed", scope: "global", enabled: true, exposure: "codemode", transport: "http://127.0.0.1:1/mcp", tools: [], error: "fetch failed" },
          { name: "disabled", state: "disabled", scope: "global", enabled: false, exposure: "codemode", transport: "http://127.0.0.1:1/mcp", tools: [] },
        ], errors: 0,
      });
    } finally { await rm(root, { recursive: true, force: true }); }
  });

  it("kills a stdio MCP child when the bounded CLI list times out", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-mcp-timeout-"));
    const pidFile = join(root, "stdio.pid");
    let unrelatedPid: number | undefined;
    // Registered before the fixtures start: vitest runs it on timeouts too, where a hung
    // CLI would otherwise leave a `finally`-less body (and its stdio server) pending.
    onTestFinished(() => cleanupFixtures(root, unrelatedPid));
    vi.stubEnv("PI_CODING_AGENT_DIR", root);
    const program = `require('node:fs').writeFileSync(${JSON.stringify(pidFile)}, String(process.pid)); process.on('SIGTERM', () => {}); setInterval(() => {}, 1000);`;
    await writeFile(join(root, "mcp.json"), JSON.stringify({ mcpServers: { slow: { command: process.execPath, args: ["-e", program] } } }));
    const unrelated = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { detached: true, stdio: "ignore" });
    if (!unrelated.pid) throw new Error("could not start unrelated process fixture");
    unrelatedPid = unrelated.pid;
    unrelated.unref();
    const service = new McpAdminService(root, cliPath, undefined, undefined, 1_000);
    await expect(service.list({ scope: "global" })).rejects.toThrow(/listing failed/u);
    const pid = Number(await readFile(pidFile, "utf8"));
    expect(isExited(pid)).toBe(true);
    expect(() => process.kill(unrelatedPid!, 0)).not.toThrow();
  });

  it("kills a stdio MCP child that the CLI starts after the bounded timeout's SIGTERM", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-mcp-late-timeout-"));
    const serverPidFile = join(root, "server.pid");
    onTestFinished(() => cleanupFixtures(root));
    vi.stubEnv("PI_CODING_AGENT_DIR", root);
    // A CLI stand-in that survives SIGTERM and starts its stdio server only when the bounded
    // timeout delivers that SIGTERM, i.e. after the timeout's process snapshot was taken.
    const server = "process.on('SIGTERM', () => {}); setInterval(() => {}, 1000);";
    const cli = [
      "const { spawn } = require('node:child_process');",
      "const { writeFileSync } = require('node:fs');",
      "process.on('SIGTERM', () => {",
      `  const child = spawn(process.execPath, ['-e', ${JSON.stringify(server)}, ${JSON.stringify(root)}], { detached: true, stdio: 'ignore' });`,
      "  child.unref();",
      `  writeFileSync(${JSON.stringify(serverPidFile)}, String(child.pid));`,
      "});",
      "setInterval(() => {}, 1000);",
    ].join("\n");
    const script = join(root, "cli.cjs");
    await writeFile(script, cli);
    const service = new McpAdminService(root, script, undefined, undefined, 1_000);
    await expect(service.list({ scope: "global" })).rejects.toThrow(/listing failed/u);
    const serverPid = Number(await readFile(serverPidFile, "utf8"));
    expect(isExited(serverPid)).toBe(true);
  });

  it("records bounded MCP startup problems without returning command stderr", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-mcp-startup-"));
    const script = join(root, "bad-cli.mjs");
    const events: string[] = [];
    try {
      await writeFile(script, "process.stdout.write('{broken');");
      const service = new McpAdminService(root, script, undefined, (_level, _message, event) => events.push(event));
      await expect(service.list({ scope: "global" })).rejects.toThrow(/invalid JSON/u);
      expect(events).toEqual(["mcp.startup.problem"]);
    } finally { await rm(root, { recursive: true, force: true }); }
  });

  it("updates only requested fields, preserves neighboring config and fails closed on malformed files", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-mcp-patch-"));
    try {
      const config = join(root, "mcp.json");
      const original = { extensionData: { retained: true }, mcpServers: {
        wanted: { command: "fixture", enabled: true, exposure: "direct", args: ["a"] },
        other: { url: "https://fixture.invalid/mcp", headers: { retained: "value" } },
      } };
      await writeFile(config, JSON.stringify(original));
      const service = new McpAdminService(root, cliPath);
      await service.update({ scope: "global" }, "wanted", { enabled: false, exposure: "hidden" });
      const saved = JSON.parse(await readFile(config, "utf8"));
      expect(saved.mcpServers.wanted).toEqual({ ...original.mcpServers.wanted, enabled: false, exposure: "hidden" });
      expect(saved.mcpServers.other).toEqual(original.mcpServers.other);
      expect(saved.extensionData).toEqual(original.extensionData);
      await expect(service.update({ scope: "global" }, "missing", { enabled: true })).rejects.toThrow(/not found/u);
      await writeFile(config, "{broken");
      await expect(service.update({ scope: "global" }, "wanted", { enabled: true })).rejects.toThrow(/cannot be parsed/u);
    } finally { await rm(root, { recursive: true, force: true }); }
  });

  it("maps a contended token configuration lock to a retryable busy error", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-mcp-token-lock-"));
    // Registered before the lock is taken, so a failed setup still removes the root.
    onTestFinished(() => rm(root, { recursive: true, force: true }));
    const config = join(root, "mcp.json");
    await writeFile(config, JSON.stringify({ mcpServers: { fixture: { url: "https://fixture.invalid/mcp" } } }));
    const owner: McpCredentialOwner = { async store() { return "account"; }, async remove() {} };
    const release = await lockfile.lock(config, { realpath: false });
    try {
      // 10s: under vitest's 15s test timeout, so a hanging Pi fails here and the
      // finally block still runs instead of the worker being abandoned.
      const service = new McpAdminService(root, cliPath, owner, undefined, 10_000);
      await expect(service.storeBearer({ scope: "global" }, "fixture", "token"))
        .rejects.toMatchObject({ code: "busy", retryable: true });
    } finally { await release(); }
  });

  it("scopes credential removal to the same config scope", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-mcp-remove-scope-"));
    const script = join(root, "cli.mjs");
    const removed: Array<{ scope: string; server: string }> = [];
    const owner: McpCredentialOwner = {
      async store() { return "account"; },
      async remove(scope, server) { removed.push({ scope: scope.scope, server }); },
    };
    try {
      await writeFile(script, "process.exit(0);");
      const service = new McpAdminService(root, script, owner);
      await service.mutate({ scope: "global" }, "remove", ["fixture"], "fixture");
      await service.mutate({ scope: "project", cwd: root, trusted: true }, "remove", ["fixture"], "fixture");
      expect(removed).toEqual([{ scope: "global", server: "fixture" }, { scope: "project", server: "fixture" }]);
    } finally { await rm(root, { recursive: true, force: true }); }
  });

  it("stores a token only through its credential owner and writes a !command reference Pi resolves", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-mcp-token-"));
    const captured: string[] = [];
    const owner: McpCredentialOwner = {
      async store(scope, _server, token) { captured.push(`${scope.scope}:${token}`); return "tron-mcp-global-fixture"; },
      async remove() {},
    };
    // The header Pi actually sends is observed at a loopback MCP server, so the
    // `!command` resolution is proved through Pi's own public CLI rather than by
    // calling an unexported helper.
    const received: Array<string | undefined> = [];
    const fixture = createServer(async (req, res) => {
      const chunks: Buffer[] = [];
      for await (const chunk of req) chunks.push(Buffer.from(chunk));
      received.push(req.headers.authorization);
      const rpc = JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}") as { id?: number; method?: string };
      const answer = (body: unknown, status = 200) => {
        res.writeHead(status, { "content-type": "application/json", "mcp-session-id": "fixture-session", "mcp-protocol-version": "2025-03-26" });
        res.end(JSON.stringify(body));
      };
      if (rpc.method === "initialize") return answer({ jsonrpc: "2.0", id: rpc.id, result: { protocolVersion: "2025-03-26", capabilities: { tools: {} }, serverInfo: { name: "fixture", version: "1" } } });
      if (rpc.method === "notifications/initialized") { res.writeHead(202); res.end(); return; }
      if (rpc.method === "tools/list") return answer({ jsonrpc: "2.0", id: rpc.id, result: { tools: [] } });
      answer({});
    });
    try {
      await new Promise<void>((resolve) => fixture.listen(0, "127.0.0.1", resolve));
      const address = fixture.address();
      if (!address || typeof address === "string") throw new Error("MCP fixture failed to bind loopback");
      const origin = `http://127.0.0.1:${address.port}`;
      await writeFile(join(root, "mcp.json"), JSON.stringify({ mcpServers: { fixture: { url: `${origin}/mcp` } } }));
      const service = new McpAdminService(root, cliPath, owner, undefined, 10_000);
      const response = await service.storeBearer({ scope: "global" }, "fixture", "never-projected-secret");
      const config = await readFile(join(root, "mcp.json"), "utf8");
      const saved = JSON.parse(config) as { mcpServers: Record<string, { headers: { Authorization: string } }> };
      expect(saved.mcpServers.fixture.headers.Authorization).toContain("Bearer ");
      const tokenCommand = join(root, "token-command");
      await writeFile(tokenCommand, "#!/bin/sh\nprintf 'token with spaces'\n");
      await chmod(tokenCommand, 0o700);
      const piCommand = saved.mcpServers.fixture.headers.Authorization.replace(
        /\/usr\/bin\/security find-generic-password -s tron\.mcp -a [A-Za-z0-9._-]+ -w/u, tokenCommand,
      );
      await writeFile(join(root, "mcp.json"), JSON.stringify({ mcpServers: { fixture: { url: `${origin}/mcp`, headers: { Authorization: piCommand } } } }));
      // The bounded production path: it owns the CLI's timeout and kills the
      // process group, so a hanging Pi is cut off inside this test's own budget.
      vi.stubEnv("PI_CODING_AGENT_DIR", root);
      const listed = await service.list({ scope: "global" }) as { servers: Array<{ name: string; state: string }> };
      expect(listed.servers).toEqual([expect.objectContaining({ name: "fixture", state: "connected" })]);
      expect(received).toContain("Bearer token with spaces");
      expect(captured).toEqual(["global:never-projected-secret"]);
      expect(response).toEqual({ server: "fixture", stored: true });
      expect(config).toContain("/usr/bin/security");
      expect(saved.mcpServers.fixture.headers.Authorization).toMatch(/^!/u);
      expect(config).not.toContain("never-projected-secret");
    } finally {
      vi.unstubAllEnvs();
      await new Promise<void>((resolve) => fixture.close(() => resolve()));
      await rm(root, { recursive: true, force: true });
    }
  });

});
