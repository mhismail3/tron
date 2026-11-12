import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { execFileSync } from "node:child_process";
import { fixture, disposeFixtures } from "../../test-support/home-task-fixture.js";
import { waitFor } from "../../test-support/wait-for.js";
import { GatewayService, type GatewayServiceDependencies } from "../transport/gateway-service.js";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it, vi } from "vitest";
import { TEST_SETTINGS_SCHEMA } from "../../test-support/settings-schema.js";
import { SettingsChangeRecord } from "../kernel/settings/settings-record.js";
import { OutsideChanges, projectStores } from "./settings-outside.js";

const roots: string[] = [];
afterEach(async () => { await disposeFixtures(); for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true }); });

it("persists observed state only when a comparison changed it", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-settings-outside-"));
  roots.push(root);
  const tronHome = join(root, "tron"), agentDir = join(root, "agent");
  await mkdir(agentDir, { recursive: true });
  await mkdir(join(tronHome, "gateway", "settings"), { recursive: true });
  const settingsPath = join(agentDir, "settings.json");
  await writeFile(settingsPath, `${JSON.stringify({ defaultThinkingLevel: "low" })}\n`);
  const outside = new OutsideChanges(TEST_SETTINGS_SCHEMA, tronHome, agentDir, new SettingsChangeRecord(tronHome), {
    global: async () => JSON.parse(await readFile(settingsPath, "utf8")) as Record<string, unknown>,
    project: async () => undefined,
  });
  try {
    const stores = [{ kind: "global" as const }, { kind: "trust" as const }];
    await outside.reconcile(stores);
    const baseline = await stat(outside.path);
    for (let read = 0; read < 5; read += 1) await outside.reconcile(stores);
    const unchanged = await stat(outside.path);
    expect([unchanged.ino, unchanged.mtimeMs]).toEqual([baseline.ino, baseline.mtimeMs]);

    await writeFile(settingsPath, `${JSON.stringify({ defaultThinkingLevel: "high" })}\n`);
    await outside.reconcile(stores);
    expect((await stat(outside.path)).ino).not.toBe(baseline.ino);
    expect(Object.keys(await outside.marks({ kind: "global" })).length).toBeGreaterThan(0);
  } finally {
    await outside.dispose();
  }
});

it("applies outside MCP and trust edits to live sessions and refreshes provider inputs without reading auth", async () => {
  const isolatedHome = await mkdtemp(join(tmpdir(), "tron-outside-home-"));
  roots.push(isolatedHome);
  vi.stubEnv("HOME", isolatedHome);
  const f = await fixture();
  execFileSync("git", ["init", "--quiet", f.cwd]);
  vi.stubEnv("PI_CODING_AGENT_DIR", f.agentDir);
  const requests: string[] = [];
  const server = createServer(async (request, response) => {
    if (request.method !== "POST") { response.writeHead(405).end(); return; }
    const chunks: Buffer[] = [];
    for await (const chunk of request) chunks.push(Buffer.from(chunk));
    const rpc = JSON.parse(Buffer.concat(chunks).toString()) as { id?: number; method: string };
    requests.push(rpc.method);
    if (rpc.id === undefined) { response.writeHead(202).end(); return; }
    const result = rpc.method === "initialize" ? { protocolVersion: "2025-03-26", capabilities: { tools: {} }, serverInfo: { name: "outside-fixture", version: "1" } }
      : rpc.method === "tools/list" ? { tools: [{ name: "outside_tool", description: "outside tool", inputSchema: { type: "object", properties: {} } }] }
        : { content: [{ type: "text", text: "outside-adopted" }] };
    response.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ jsonrpc: "2.0", id: rpc.id, result }));
  });
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  const address = server.address() as { port: number };
  const outside = new OutsideChanges(TEST_SETTINGS_SCHEMA, f.tronHome, f.agentDir, new SettingsChangeRecord(f.tronHome), f.settings.settingsModel.owner.observedReaders);
  f.settings.settingsModel.owner.observeOutside(outside);
  let refreshes = 0;
  const service = new GatewayService({ config: { tronHome: f.tronHome, agentDir: f.agentDir }, sessions: f.registry,
    modelRuntime: f.gateway, trust: f.trust, settingsModel: f.settings.settingsModel, settingsChanges: f.settings.settingsChanges,
    broadcast: () => {}, globalProviderResources: { requestReload: () => { refreshes += 1; } },
  } as unknown as GatewayServiceDependencies);
  let settingsReads: NodeJS.Timeout | undefined;
  try {
    await f.trust.set(f.cwd, true);
    const slot = await f.registry.create(f.cwd);
    await outside.reconcile([{ kind: "mcp" }, { kind: "trust" }, { kind: "models" }]);
    outside.startWatching(error => { throw error; });
    settingsReads = setInterval(() => { void f.settings.settingsModel.owner.observedReaders.global(); }, 25);
    await writeFile(join(f.agentDir, "mcp.json"), JSON.stringify({ mcpServers: { outside: { url: `http://127.0.0.1:${address.port}/mcp`, exposure: "direct" } } }));
    await waitFor(() => slot.runtime.session.getAllTools().some(tool => tool.name === "mcp__outside__outside_tool"), "outside MCP edit reaches the same idle session").catch(error => {
      throw new Error(JSON.stringify({ requests, signals: f.signals, tools: slot.runtime.session.getAllTools().map(tool => tool.name), observed: outside.path }), { cause: error });
    });
    expect(requests).toContain("tools/list");
    const otherProject = join(f.root, "other-project");
    await mkdir(otherProject);
    await f.trust.set(otherProject, true);
    const other = await f.registry.create(otherProject);
    await mkdir(join(f.cwd, ".pi"), { recursive: true });
    await outside.reconcile(projectStores(await f.trust.canonicalDirectory(f.cwd)));
    const beforeProject = f.signals.length;
    await writeFile(join(f.cwd, ".pi", "mcp.json"), JSON.stringify({ mcpServers: { local: { url: `http://127.0.0.1:${address.port}/mcp`, exposure: "direct" } } }));
    await waitFor(() => slot.runtime.session.getAllTools().some(tool => tool.name === "mcp__local__outside_tool"), "project MCP reaches its live session");
    expect(other.runtime.session.getAllTools().some(tool => tool.name === "mcp__local__outside_tool")).toBe(false);
    expect(f.signals.slice(beforeProject).filter(event => event.outcome === "resources-reload" && event.reason === "completed").map(event => event.sessionId)).not.toContain(other.id);
    const nestedCwd = join(f.cwd, "nested");
    await mkdir(nestedCwd);
    const nested = await f.registry.create(nestedCwd);
    expect(nested.projectDir).toBe(slot.projectDir);
    expect(nested.cwd).not.toBe(nested.projectDir);
    await writeFile(join(f.agentDir, "trust.json"), JSON.stringify({ [slot.projectDir]: true, [nested.cwd]: false, [other.projectDir]: true }));
    await waitFor(() => !nested.runtime.session.settingsManager.isProjectTrusted(), "outside cwd-keyed trust revocation reaches its nested idle runtime", { boundMs: 4_000 });
    expect(slot.runtime.session.settingsManager.isProjectTrusted()).toBe(true);
    await writeFile(join(f.agentDir, "models.json"), JSON.stringify({ providers: { outside: { baseUrl: "https://fixture.invalid", api: "openai-completions", models: [] } } }));
    await waitFor(() => refreshes > 0, "outside models refreshes the provider owner");
    const beforeAuth = refreshes;
    await writeFile(join(f.agentDir, "auth.json"), "not a JSON document: change-only synthetic auth input");
    await waitFor(() => refreshes > beforeAuth, "auth change refreshes without parsing credentials");
    expect(await readFile(outside.path, "utf8")).not.toContain("synthetic auth input");
    const beforeRules = f.signals.length;
    await writeFile(join(f.agentDir, "AGENTS.md"), "# Global fixture rules\nApply this explicit global input.\n");
    await waitFor(() => f.signals.slice(beforeRules).some(event => event.outcome === "resources-reload" && event.reason === "completed" && event.sessionId === f.home.sessionId), "global AGENTS invalidates the live Home slot");
  } finally {
    clearInterval(settingsReads);
    await outside.dispose();
    service.dispose();
    try { await disposeFixtures(); }
    finally {
      server.closeAllConnections();
      await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
    }
  }
});
