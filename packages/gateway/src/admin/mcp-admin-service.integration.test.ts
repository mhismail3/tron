import { spawn, spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { chmod, mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it, onTestFinished } from "vitest";
import lockfile from "proper-lockfile";
import { waitFor } from "../../test-support/wait-for.js";
import { drainDurableWriteStats } from "../foundation/durable-json.js";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { TEST_SETTINGS_SCHEMA } from "../../test-support/settings-schema.js";
import { TrustService } from "../kernel/resources/trust-service.js";
import { SettingsModel } from "../kernel/settings/settings-model.js";
import { SettingsChangePath } from "../kernel/settings/settings-change.js";
import { SettingsChangeRecord } from "../kernel/settings/settings-record.js";
import { SettingsStoreAdapter } from "./settings-model.js";
import { OutsideChanges } from "./settings-outside.js";
import { MacKeychainMcpCredentialOwner, McpAdminService } from "./mcp-admin-service.js";

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

function processState(pid: number): string {
  return spawnSync("/bin/ps", ["-o", "stat=", "-p", String(pid)], { encoding: "utf8" }).stdout.trim();
}
function isExited(pid: number): boolean {
  const state = processState(pid);
  return state === "" || state.startsWith("Z");
}

async function cleanupFixtures(root: string, unrelatedPid?: number): Promise<void> {
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

function callWithAmbientAgentDir<T>(ambientRoot: string, call: () => Promise<T>): Promise<T> {
  const previous = process.env.PI_CODING_AGENT_DIR;
  process.env.PI_CODING_AGENT_DIR = ambientRoot;
  try { return call(); } finally {
    if (previous === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = previous;
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
    await owner.store("tron-mcp-fixture", token);
    expect(invocation).toEqual({
      command: "/usr/bin/security",
      args: ["-i"],
      input: '"add-generic-password" "-U" "-s" "tron.mcp" "-a" "tron-mcp-fixture" "-w" "space \\"quote\\" \\\\ slash"\n',
    });
    expect(JSON.stringify(invocation)).not.toContain(token);
    await expect(owner.store("tron-mcp-fixture", "line\nbreak")).rejects.toThrow(/invalid/u);
    await expect(owner.store("tron-mcp-fixture", "nul\0byte")).rejects.toThrow(/invalid/u);
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

  it("reads canonical MCP configuration without probing, resolving credentials or exposing diagnostics", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-mcp-configured-"));
    const project = join(root, "project");
    const globalPath = join(root, "mcp.json");
    const projectPath = join(project, ".pi", "mcp.json");
    const launched = join(root, "launched");
    const resolved = join(root, "resolved");
    const globalBytes = JSON.stringify({ mcpServers: {
      kept: { command: process.execPath, args: ["-e", `require('node:fs').writeFileSync(${JSON.stringify(launched)}, 'launched')`] },
      shared: { type: "http", url: "http://127.0.0.1:1/mcp", command: "unused", headers: { Authorization: `!touch ${resolved}` } },
      broken: { command: 7 },
    } });
    const projectBytes = JSON.stringify({ mcpServers: {
      kept: { enabled: false, exposure: "hidden" },
      shared: { enabled: false, headers: { Authorization: "private-project-secret" } },
      projectOnly: { url: "https://project.fixture.invalid/mcp", enabled: false },
    } });
    try {
      await mkdir(dirname(projectPath), { recursive: true });
      await mkdir(join(root, ".pi"));
      await writeFile(join(root, ".pi", "mcp.json"), JSON.stringify({ mcpServers: { kept: { enabled: false } } }));
      await writeFile(globalPath, globalBytes);
      await writeFile(projectPath, projectBytes);
      const service = new McpAdminService(root, join(root, "must-not-run.mjs"));
      const global = {
        servers: [
          { name: "kept", scope: "global", state: "configured", enabled: true, exposure: "codemode", transport: "stdio" },
          { name: "shared", scope: "global", state: "configured", enabled: true, exposure: "codemode", transport: "http" },
        ],
        errors: 1,
      };
      expect(await service.configured()).toEqual(global);
      const scoped = { scope: "project" as const, cwd: project, trusted: true as const };
      const configured = await service.configured(scoped);
      expect(configured).toEqual({
        servers: [
          { name: "kept", scope: "project", state: "disabled", enabled: false, exposure: "hidden", transport: "stdio" },
          global.servers[1],
          { name: "projectOnly", scope: "project", state: "disabled", enabled: false, exposure: "codemode", transport: "http" },
        ],
        errors: 2,
      });
      expect(await readFile(globalPath, "utf8")).toBe(globalBytes);
      expect(await readFile(projectPath, "utf8")).toBe(projectBytes);
      expect(JSON.stringify(configured)).not.toMatch(/private-project-secret|Authorization|127\.0\.0\.1|touch/);
      expect(existsSync(launched)).toBe(false);
      expect(existsSync(resolved)).toBe(false);
      await writeFile(projectPath, '{"mcpServers":private-parser-secret}');
      expect(await service.configured(scoped)).toEqual({ ...global, errors: 2 });
      expect(await service.configured()).toEqual(global);
      await writeFile(projectPath, JSON.stringify({ padding: "x".repeat(256 * 1_024), mcpServers: { kept: { enabled: false } } }));
      expect(await service.configured(scoped)).toEqual({ ...global, errors: 2 });
      await writeFile(projectPath, '{"mcpServers":{}}');
      await chmod(project, 0);
      expect(await service.configured(scoped)).toEqual({ ...global, errors: 2 });
    } finally {
      if (existsSync(project)) await chmod(project, 0o700);
      await rm(root, { recursive: true, force: true });
    }
  });

  it("lists the owner agent directory's servers when the ambient agent env names another root", async () => {
    const owner = await mkdtemp(join(tmpdir(), "tron-mcp-owner-"));
    const decoy = await mkdtemp(join(tmpdir(), "tron-mcp-decoy-"));
    try {
      await writeFile(join(owner, "mcp.json"), JSON.stringify({ mcpServers: { ownerDisabled: { url: "https://owner.fixture.invalid/mcp", enabled: false } } }));
      await writeFile(join(decoy, "mcp.json"), JSON.stringify({ mcpServers: { decoyDisabled: { url: "https://decoy.fixture.invalid/mcp", enabled: false } } }));
      const service = new McpAdminService(owner, cliPath);
      const listed = await callWithAmbientAgentDir(decoy, () => service.list({ scope: "global" })) as { servers: Array<{ name: string; state: string }> };
      expect(listed.servers).toEqual([expect.objectContaining({ name: "ownerDisabled", state: "disabled" })]);
    } finally {
      await rm(owner, { recursive: true, force: true });
      await rm(decoy, { recursive: true, force: true });
    }
  });

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
    onTestFinished(() => cleanupFixtures(root, unrelatedPid));
    const program = `require('node:fs').writeFileSync(${JSON.stringify(pidFile)}, String(process.pid)); process.on('SIGTERM', () => {}); setInterval(() => {}, 1000);`;
    await writeFile(join(root, "mcp.json"), JSON.stringify({ mcpServers: { slow: { command: process.execPath, args: ["-e", program] } } }));
    const unrelated = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { detached: true, stdio: "ignore" });
    if (!unrelated.pid) throw new Error("could not start unrelated process fixture");
    unrelatedPid = unrelated.pid;
    unrelated.unref();
    const service = new McpAdminService(root, cliPath, undefined, undefined, 1_000);
    await expect(service.list({ scope: "global" })).rejects.toThrow(/listing failed/u);
    const pid = Number(await readFile(pidFile, "utf8"));
    await waitFor(() => isExited(pid), "the timed-out list's stdio child exits");
    expect(() => process.kill(unrelatedPid!, 0)).not.toThrow();
  });

  it("kills a stdio MCP child that the CLI starts after the bounded timeout's SIGTERM", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-mcp-late-timeout-"));
    const serverPidFile = join(root, "server.pid");
    onTestFinished(() => cleanupFixtures(root));
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
    await waitFor(() => isExited(serverPid), "the late stdio server exits");
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

  it("writes one server, preserves neighboring config and fails closed on malformed files", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-mcp-patch-"));
    try {
      const config = join(root, "mcp.json");
      const original = { extensionData: { retained: true }, mcpServers: {
        wanted: { command: "fixture", enabled: true, exposure: "direct", args: ["a"] },
        other: { url: "https://fixture.invalid/mcp", headers: { retained: "value" } },
      } };
      await writeFile(config, JSON.stringify(original));
      const service = new McpAdminService(root, cliPath);
      drainDurableWriteStats();
      await service.setServer("wanted", { ...original.mcpServers.wanted, enabled: false, exposure: "hidden" });
      expect(drainDurableWriteStats().count).toBe(2);
      const text = await readFile(config, "utf8");
      const saved = JSON.parse(text);
      expect(text).toBe(`${JSON.stringify(saved, null, 2)}\n`);
      expect((await stat(config)).mode & 0o777).toBe(0o600);
      expect(saved.mcpServers.wanted).toEqual({ ...original.mcpServers.wanted, enabled: false, exposure: "hidden" });
      expect(saved.mcpServers.other).toEqual(original.mcpServers.other);
      expect(saved.extensionData).toEqual(original.extensionData);
      await writeFile(config, "{broken");
      await expect(service.setServer("wanted", original.mcpServers.wanted)).rejects.toThrow(/cannot be parsed/u);
    } finally { await rm(root, { recursive: true, force: true }); }
  });

  it("maps a contended configuration lock to a retryable busy error", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-mcp-token-lock-"));
    onTestFinished(() => rm(root, { recursive: true, force: true }));
    const config = join(root, "mcp.json");
    await writeFile(config, JSON.stringify({ mcpServers: { fixture: { url: "https://fixture.invalid/mcp" } } }));
    const release = await lockfile.lock(config, { realpath: false });
    try {
      const service = new McpAdminService(root, cliPath);
      await expect(service.setServer("fixture", { url: "https://fixture.invalid/mcp", enabled: false }))
        .rejects.toMatchObject({ code: "busy", retryable: true });
    } finally { await release(); }
  });

  it("stores a bearer only through its credential owner and writes this server's Keychain reference, which Pi's loader accepts", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-mcp-token-"));
    onTestFinished(() => rm(root, { recursive: true, force: true }));
    const captured: string[][] = [];
    const service = new McpAdminService(root, cliPath, { async store(account, token) { captured.push([account, token]); } });
    const reference = await service.storeBearer("fixture", "never-projected-secret");
    expect(captured).toEqual([["tron-mcp-fixture", "never-projected-secret"]]);
    await service.setServer("fixture", { url: "https://fixture.invalid/mcp", headers: { Authorization: reference } });
    const config = await readFile(join(root, "mcp.json"), "utf8");
    expect(JSON.parse(config).mcpServers.fixture.headers.Authorization)
      .toEqual({ source: "keychain", service: "tron.mcp", account: "tron-mcp-fixture", format: "bearer" });
    expect(config).not.toContain("never-projected-secret");
    expect(await service.configured()).toEqual({ errors: 0, servers: [expect.objectContaining({ name: "fixture", transport: "http", state: "configured" })] });
  });

});

describe("MCP servers through the settings change path", () => {
  const global = { kind: "global" as const };
  const home = { actor: { kind: "home" as const, id: "home" }, reason: "Maintainer asked for the docs server" };
  const set = (server: string, value: unknown, layer: "global" | "session" | "project" = "global") =>
    ({ key: "tools.mcp.server", qualifiers: { server }, layer, op: "set" as const, value });
  const unset = (server: string) => ({ key: "tools.mcp.server", qualifiers: { server }, layer: "global" as const, op: "unset" as const });

  async function fixture() {
    const root = await mkdtemp(join(tmpdir(), "tron-mcp-change-"));
    onTestFinished(() => rm(root, { recursive: true, force: true }));
    const tronHome = join(root, "tron");
    const agentDir = join(tronHome, "agent");
    await mkdir(agentDir, { recursive: true });
    const modelRuntime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    const settingsModel = new SettingsModel(new SettingsStoreAdapter({ schema: TEST_SETTINGS_SCHEMA, agentDir, tronHome, trust: new TrustService(agentDir), modelRuntime,
      mcpAdmin: new McpAdminService(agentDir, cliPath) }));
    const record = new SettingsChangeRecord(tronHome);
    settingsModel.owner.observeOutside(new OutsideChanges(TEST_SETTINGS_SCHEMA, tronHome, agentDir, record, settingsModel.owner.observedReaders));
    const changes = new SettingsChangePath(settingsModel, record, { setTrust: async () => { throw new Error("no trust writes in this proof"); } });
    const file = join(agentDir, "mcp.json");
    const bytes = () => readFile(file, "utf8").catch(() => undefined);
    const servers = async () => (JSON.parse(await readFile(file, "utf8")) as { mcpServers: Record<string, unknown> }).mcpServers;
    return { root, file, settingsModel, record, changes, bytes, servers };
  }

  async function approve(f: Awaited<ReturnType<typeof fixture>>, requests: Parameters<SettingsChangePath["change"]>[1], review: { digest: string }) {
    return f.changes.change(global, requests, { actor: { kind: "ui", id: "device:phone" }, reason: home.reason, confirmationDigest: review.digest });
  }

  it("shows the exact command on the card and writes only after the native tap", async () => {
    const f = await fixture();
    const requests = [set("docs", { command: "npx", args: ["-y", "@acme/docs-mcp"], exposure: "deferred" })];
    const review = await f.changes.change(global, requests, home);
    expect(review).toMatchObject({ status: "review", changes: [], review: { requiresTap: true } });
    const exact = review.review!.items[0]!.exact!;
    expect(exact).toContain("npx");
    expect(exact).toContain("@acme/docs-mcp");
    expect(await f.bytes()).toBeUndefined();
    expect(await approve(f, requests, review.review!)).toMatchObject({ status: "applied" });
    expect(await f.servers()).toEqual({ docs: { command: "npx", args: ["-y", "@acme/docs-mcp"], exposure: "deferred" } });
  });

  it("undoes an added server through the same change owner, with one applied audit entry each way", async () => {
    const f = await fixture();
    const requests = [set("docs", { command: "npx", args: ["-y", "@acme/docs-mcp"] })];
    const review = await f.changes.change(global, requests, home);
    const applied = await approve(f, requests, review.review!);
    const changeId = applied.changes[0]!.changeId;
    expect(await f.changes.undo(changeId, { actor: { kind: "home", id: "home" } })).toMatchObject({ status: "applied" });
    expect(await f.servers()).toEqual({});
    const entries = (await f.record.page({ filter: entry => entry.key === "tools.mcp.server" })).entries;
    expect(entries).toHaveLength(2);
    expect(entries.every(entry => entry.status === "applied")).toBe(true);
    expect(entries.find(entry => entry.undoOf === changeId)).toMatchObject({ op: "unset" });
    expect(entries.find(entry => entry.changeId === changeId)).toMatchObject({ op: "set", after: { command: "npx", args: ["-y", "@acme/docs-mcp"] } });
    expect(entries.find(entry => entry.changeId === changeId)!.before).toBeUndefined();
  });

  it("applies a disable without a card, and taps an enable or a command change", async () => {
    const f = await fixture();
    const first = [set("docs", { command: "npx", args: ["a"] })];
    await approve(f, first, (await f.changes.change(global, first, home)).review!);
    const disable = await f.changes.change(global, [set("docs", { command: "npx", args: ["a"], enabled: false })], home);
    expect(disable).toMatchObject({ status: "applied" });
    expect((await f.servers()).docs).toEqual({ command: "npx", args: ["a"], enabled: false });
    const enable = [set("docs", { command: "npx", args: ["a"] })];
    const enableReview = await f.changes.change(global, enable, home);
    expect(enableReview).toMatchObject({ status: "review", review: { requiresTap: true } });
    await approve(f, enable, enableReview.review!);
    const commandChange = [set("docs", { command: "node", args: ["a"] })];
    expect(await f.changes.change(global, commandChange, home)).toMatchObject({ status: "review", review: { requiresTap: true } });
    const exposureOnly = await f.changes.change(global, [set("docs", { command: "npx", args: ["a"], exposure: "hidden" })], home);
    expect(exposureOnly).toMatchObject({ status: "applied" });
    const widened = [set("docs", { command: "npx", args: ["a"], exposure: "direct" })];
    const widenedReview = await f.changes.change(global, widened, home);
    expect(widenedReview).toMatchObject({ status: "review", review: { requiresTap: true } });
    await approve(f, widened, widenedReview.review!);
    expect(await f.changes.change(global, [set("docs", { command: "npx", args: ["a"], exposure: "deferred" })], home)).toMatchObject({ status: "applied" });
  });

  it("refuses secret-bearing fields without echoing them, and writes nothing", async () => {
    const f = await fixture();
    expect(await f.changes.change(global, [set("docs", { command: "npx" })], home)).toMatchObject({ status: "review" });
    const secret = "sk-live-never-echoed";
    const attempts = [
      { command: "npx", env: { API_KEY: secret } },
      { url: "https://example.com/mcp", headers: { Authorization: `Bearer ${secret}` } },
      { url: `https://user:${secret}@example.com/mcp` },
      { url: `https://example.com/mcp?api_key=${secret}` },
      { command: "npx", args: [`--api-key=${secret}`] },
      { command: "npx", oauth: { clientSecret: secret } },
      { command: `npx ${secret}` },
      { command: `API_KEY=${secret} npx`, args: ["-y", "pkg"] },
      { command: "npx", args: [`Bearer ${secret}`] },
      { url: `https://example.com/mcp/${secret}` },
    ];
    for (const value of attempts) {
      const error = await f.changes.change(global, [set("docs", value)], home).catch((caught: unknown) => caught);
      expect(error).toMatchObject({ code: "invalid_request" });
      expect(String((error as Error).message)).not.toContain(secret);
    }
    expect(await f.bytes()).toBeUndefined();
  });

  it("refuses to change a record it cannot carry, and keeps unrelated servers and all settings working", async () => {
    const f = await fixture();
    const legacy = { url: "https://example.com/legacy", headers: { Authorization: "Bearer legacy-secret-value" } };
    await writeFile(f.file, JSON.stringify({ mcpServers: { legacy, docs: { command: "node", args: ["docs.js"] } } }));
    const before = await readFile(f.file, "utf8");
    for (const request of [set("legacy", { url: "https://example.com/new" }), unset("legacy")]) {
      const error = await f.changes.change(global, [request], home).catch((caught: unknown) => caught);
      expect(error).toMatchObject({ code: "conflict" });
      expect(String((error as Error).message)).not.toContain("legacy-secret-value");
    }
    expect(await readFile(f.file, "utf8")).toBe(before);
    expect(await f.changes.change(global, [set("docs", { command: "node", args: ["docs.js"], enabled: false })], home)).toMatchObject({ status: "applied" });
    expect((await f.servers()).legacy).toEqual(legacy);
    await expect(f.settingsModel.resolve(global)).resolves.toBeDefined();
  });

  it("writes only for Home and Global; ordinary chat, workers and Project layers are refused", async () => {
    const f = await fixture();
    expect(await f.changes.change(global, [set("docs", { command: "npx" })], home)).toMatchObject({ status: "review" });
    const request = set("docs", { command: "npx" });
    for (const actor of [{ kind: "agent", id: "chat" }, { kind: "worker", id: "task" }]) {
      await expect(f.changes.change(global, [request], { actor: actor as never, reason: "try" })).rejects.toMatchObject({ code: "invalid_request" });
    }
    await expect(f.changes.change(global, [set("docs", { command: "npx" }, "project")], home)).rejects.toMatchObject({ code: "invalid_request" });
    await expect(f.changes.change(global, [set("docs", { command: "npx" }, "session")], home)).rejects.toMatchObject({ code: "invalid_request" });
    expect(await f.bytes()).toBeUndefined();
  });

  it("records Tron's own write once, and still records a hand edit as an outside change", async () => {
    const f = await fixture();
    const requests = [set("docs", { command: "npx", args: ["a"] })];
    const review = await f.changes.change(global, requests, home);
    await approve(f, requests, review.review!);
    await f.settingsModel.resolve(global);
    const outside = async () => (await f.record.page({ filter: entry => entry.key === "tools.mcp.server" && entry.status === "outside" })).entries;
    expect(await outside()).toEqual([]);
    await writeFile(f.file, JSON.stringify({ mcpServers: { docs: { command: "npx", args: ["a"] }, hand: { url: "https://example.com/hand" } } }));
    await f.settingsModel.resolve(global);
    const hand = await outside();
    expect(hand).toEqual([expect.objectContaining({ key: "tools.mcp.server", qualifiers: { server: "hand" }, op: "set", redacted: true, status: "outside" })]);
    expect(JSON.stringify(hand)).not.toContain("https://example.com/hand");
  });
});
