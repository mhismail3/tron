import { spawn, spawnSync } from "node:child_process";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it, vi } from "vitest";
import { resolveConfigValueUncached } from "../../node_modules/@earendil-works/pi-coding-agent/dist/core/resolve-config-value.js";
import lockfile from "proper-lockfile";
import { MacKeychainMcpCredentialOwner, McpAdminService, type McpCredentialOwner } from "./mcp-admin-service.js";

const cliPath = join(dirname(fileURLToPath(import.meta.resolve("@earendil-works/pi-coding-agent"))), "bundle/cli.js");

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
    vi.stubEnv("PI_CODING_AGENT_DIR", root);
    try {
      const program = `require('node:fs').writeFileSync(${JSON.stringify(pidFile)}, String(process.pid)); process.on('SIGTERM', () => {}); setInterval(() => {}, 1000);`;
      await writeFile(join(root, "mcp.json"), JSON.stringify({ mcpServers: { slow: { command: process.execPath, args: ["-e", program] } } }));
      const unrelated = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { detached: true, stdio: "ignore" });
      if (!unrelated.pid) throw new Error("could not start unrelated process fixture");
      unrelatedPid = unrelated.pid;
      unrelated.unref();
      const service = new McpAdminService(root, cliPath, undefined, undefined, 1_000);
      await expect(service.list({ scope: "global" })).rejects.toThrow(/listing failed/u);
      const pid = Number(await readFile(pidFile, "utf8"));
      const childStatus = spawnSync("/bin/ps", ["-o", "stat=", "-p", String(pid)], { encoding: "utf8" }).stdout.trim();
      expect(childStatus === "" || childStatus.startsWith("Z")).toBe(true);
      expect(() => process.kill(unrelatedPid!, 0)).not.toThrow();
    } finally {
      vi.unstubAllEnvs();
      if (unrelatedPid) { try { process.kill(-unrelatedPid, "SIGKILL"); } catch {} }
      await rm(root, { recursive: true, force: true });
    }
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
    const config = join(root, "mcp.json");
    await writeFile(config, JSON.stringify({ mcpServers: { fixture: { url: "https://fixture.invalid/mcp" } } }));
    const owner: McpCredentialOwner = { async store() { return "account"; }, async remove() {} };
    const release = await lockfile.lock(config, { realpath: false });
    try {
      const service = new McpAdminService(root, cliPath, owner);
      await expect(service.storeBearer({ scope: "global" }, "fixture", "token"))
        .rejects.toMatchObject({ code: "busy", retryable: true });
    } finally { await release(); await rm(root, { recursive: true, force: true }); }
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

  it("stores a token only through its credential owner and writes a !command reference", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-mcp-token-"));
    const captured: string[] = [];
    const owner: McpCredentialOwner = {
      async store(scope, _server, token) { captured.push(`${scope.scope}:${token}`); return "tron-mcp-global-fixture"; },
      async remove() {},
    };
    try {
      await writeFile(join(root, "mcp.json"), JSON.stringify({ mcpServers: { fixture: { url: "https://fixture.invalid/mcp" } } }));
      const service = new McpAdminService(root, cliPath, owner);
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
      expect(resolveConfigValueUncached(piCommand)).toBe("Bearer token with spaces");
      expect(captured).toEqual(["global:never-projected-secret"]);
      expect(response).toEqual({ server: "fixture", stored: true });
      expect(config).toContain("/usr/bin/security");
      expect(saved.mcpServers.fixture.headers.Authorization).toMatch(/^!/u);
      expect(config).not.toContain("never-projected-secret");
    } finally { await rm(root, { recursive: true, force: true }); }
  });

});
