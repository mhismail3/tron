import { createServer, type Server } from "node:http";
import { mkdtemp, writeFile, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { ConnectionOwner } from "./connection-owner.js";
import { McpAdapter } from "./mcp-adapter.js";
import { InMemoryConnectorCredentialStore } from "../knowledge/connector-credentials.js";
import { GatewayWorkRegistry } from "../sessions/gateway-work-registry.js";

const cleanup: Array<() => Promise<void>> = [];
const policy = { enabled: true, allowWrites: true, paidAccessApproved: false, paidBudgetCents: 0, recurringApproved: false };

async function setupConnection(root: string, config: Record<string, unknown>, id: string, connectionPolicy = policy): Promise<{ owner: ConnectionOwner; adapter: McpAdapter }> {
  const owner = new ConnectionOwner(root);
  const credentials = new InMemoryConnectorCredentialStore(new Map([[`connector:mcp:${id}`, "fixture-token"]]));
  const begin = await owner.execute({ kind: "setup.begin", commandId: `${id}-begin`, instanceId: id, definitionId: "mcp.remote-http", method: config.transport === "http" ? "endpoint" : "local-command" });
  await owner.execute({ kind: "setup.complete", commandId: `${id}-complete`, operationId: (begin as { operationId: string }).operationId, instanceId: id, providerAccountId: "fixture", credentialRef: `connector:mcp:${id}`, policy: connectionPolicy, configuration: config as never });
  const workRegistry = new GatewayWorkRegistry();
  return { owner, adapter: new McpAdapter({ connections: owner, credentials, workRegistry }), workRegistry };
}

async function registerFactory(adapter: McpAdapter, session = "session", host = "host"): Promise<Record<string, any>> {
  const tools: Record<string, any> = {};
  for (const factory of await adapter.extensionFactories(session, host)) {
    await factory({ registerTool(tool: any) { tools[tool.name] = tool; }, on(event: string, handler: () => Promise<void>) { if (event === "session_shutdown") cleanup.push(handler); } } as any);
  }
  return tools;
}

function rpcServer(handler: (request: any) => any): Promise<{ server: Server; endpoint: string }> {
  return new Promise((resolve) => {
    const server = createServer((request, response) => {
      let body = "";
      request.setEncoding("utf8");
      request.on("data", chunk => { body += chunk; });
      request.on("end", () => {
        const message = body ? JSON.parse(body) : undefined;
        Promise.resolve(message ? handler(message) : undefined).then(result => {
          response.setHeader("mcp-session-id", "fixture-session");
          if (!result) { response.statusCode = 202; response.end(); return; }
          response.setHeader("content-type", "application/json");
          if (result && typeof result === "object" && "__raw" in result) { response.end((result as { __raw: string }).__raw); return; }
          response.end(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
        });
      });
    });
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      const port = typeof address === "object" && address ? address.port : 0;
      resolve({ server, endpoint: `http://127.0.0.1:${port}/mcp` });
    });
  });
}

afterEach(async () => { while (cleanup.length) await cleanup.pop()!(); });

describe("Mac-owned MCP adapter", () => {
  it("discovers and invokes bounded remote HTTP tools with bearer credentials", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-mcp-http-"));
    cleanup.push(() => rm(root, { recursive: true, force: true }));
    const fixture = await rpcServer(message => {
      if (message.method === "initialize") return { protocolVersion: "2025-11-25", capabilities: { tools: {} }, serverInfo: { name: "fixture", version: "1" } };
      if (message.method === "tools/list") return { tools: [{ name: "echo", description: "fixture echo", inputSchema: { type: "object", properties: { text: { type: "string" } } }, annotations: { readOnlyHint: true } }, { name: "mutate", inputSchema: { type: "object" }, annotations: { readOnlyHint: false } }] };
      if (message.method === "tools/call" && message.params.name === "mutate") return { content: [{ type: "not-supported" }] };
      if (message.method === "tools/call") return { content: [{ type: "text", text: JSON.stringify(message.params.arguments) }] };
      if (message.method === "notifications/initialized") return undefined;
      throw new Error(`unexpected ${message.method}`);
    });
    cleanup.push(() => new Promise<void>(resolve => fixture.server.close(() => resolve())));
    const { owner, adapter } = await setupConnection(root, { transport: "http", endpoint: fixture.endpoint }, "remote");
    expect((await owner.snapshot()).instances.find(instance => instance.id === "remote")?.health).toBe("setup-required");
    const tools = await registerFactory(adapter);
    expect((await owner.snapshot()).instances.find(instance => instance.id === "remote")?.health).toBe("ready");
    expect(Object.keys(tools)).toEqual(["mcp_remote_echo", "mcp_remote_mutate"]);
    const result = await tools.mcp_remote_echo.execute("call", { text: "ok" }, undefined, undefined, {});
    expect(result.content[0]).toMatchObject({ type: "text", text: '{"text":"ok"}' });
    const unknown = await tools.mcp_remote_mutate.execute("mutation", {}, undefined, undefined, {});
    expect(unknown.details).toMatchObject({ outcome: "unknown" });
  });

  it("fences a previously registered tool after its owner is disabled", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-mcp-revoke-"));
    cleanup.push(() => rm(root, { recursive: true, force: true }));
    let calls = 0;
    const fixture = await rpcServer(message => {
      if (message.method === "initialize") return { protocolVersion: "2025-11-25", capabilities: { tools: {} }, serverInfo: { name: "fixture", version: "1" } };
      if (message.method === "tools/list") return { tools: [{ name: "mutate", inputSchema: { type: "object" }, annotations: { readOnlyHint: false } }] };
      if (message.method === "tools/call") { calls += 1; return { content: [{ type: "text", text: "called" }] }; }
      return undefined;
    });
    cleanup.push(() => new Promise<void>(resolve => fixture.server.close(() => resolve())));
    const { owner, adapter } = await setupConnection(root, { transport: "http", endpoint: fixture.endpoint }, "revoke");
    const tools = await registerFactory(adapter);
    await owner.execute({ kind: "policy.update", commandId: "revoke-policy-0001", instanceId: "revoke", expectedSetupRevision: 1, policy: { ...policy, enabled: false } });
    const result = await tools.mcp_revoke_mutate.execute("mutation", {}, undefined, undefined, {});
    expect(result.details).toMatchObject({ outcome: "unknown" });
    expect(calls).toBe(0);
  });

  it("serializes calls for one account while allowing separate adapters to share its lane", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-mcp-lane-"));
    cleanup.push(() => rm(root, { recursive: true, force: true }));
    let active = 0; let maximum = 0;
    const fixture = await rpcServer(async message => {
      if (message.method === "initialize") return { protocolVersion: "2025-11-25", capabilities: { tools: {} }, serverInfo: { name: "fixture", version: "1" } };
      if (message.method === "tools/list") return { tools: [{ name: "mutate", inputSchema: { type: "object" }, annotations: { readOnlyHint: false } }] };
      if (message.method === "tools/call") { active += 1; maximum = Math.max(maximum, active); await new Promise(resolve => setTimeout(resolve, 20)); active -= 1; return { content: [{ type: "text", text: "called" }] }; }
      return undefined;
    });
    cleanup.push(() => new Promise<void>(resolve => fixture.server.close(() => resolve())));
    const { adapter } = await setupConnection(root, { transport: "http", endpoint: fixture.endpoint }, "lane");
    const first = await registerFactory(adapter, "session-a", "host-a");
    const second = await registerFactory(adapter, "session-b", "host-b");
    await Promise.all([
      first.mcp_lane_mutate.execute("one", {}, undefined, undefined, {}),
      second.mcp_lane_mutate.execute("two", {}, undefined, undefined, {}),
    ]);
    expect(maximum).toBe(1);
  });

  it("rejects an unknown-length HTTP response once its body exceeds the bound", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-mcp-body-"));
    cleanup.push(() => rm(root, { recursive: true, force: true }));
    const fixture = await rpcServer(message => message.method === "initialize"
      ? { __raw: "x".repeat(2 * 1024 * 1024 + 1) }
      : undefined);
    cleanup.push(() => new Promise<void>(resolve => fixture.server.close(() => resolve())));
    const { adapter } = await setupConnection(root, { transport: "http", endpoint: fixture.endpoint }, "body");
    await expect(adapter.extensionFactories("session", "host")).rejects.toThrow(/bounded size|connection failed/i);
  });

  it("rejects colliding attributed tool names instead of replacing one supplier", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-mcp-collision-"));
    cleanup.push(() => rm(root, { recursive: true, force: true }));
    const fixture = await rpcServer(message => {
      if (message.method === "initialize") return { protocolVersion: "2025-11-25", capabilities: { tools: {} }, serverInfo: { name: "fixture", version: "1" } };
      if (message.method === "tools/list") return { tools: [
        { name: "same", inputSchema: { type: "object" }, annotations: { readOnlyHint: true } },
        { name: "same", inputSchema: { type: "object" }, annotations: { readOnlyHint: true } },
      ] };
      return undefined;
    });
    cleanup.push(() => new Promise<void>(resolve => fixture.server.close(() => resolve())));
    const { adapter } = await setupConnection(root, { transport: "http", endpoint: fixture.endpoint }, "collision");
    await expect(adapter.extensionFactories("session", "host")).rejects.toThrow(/collision/);
  });

  it("rejects write-capable MCP admission when the owner write policy is disabled", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-mcp-policy-"));
    cleanup.push(() => rm(root, { recursive: true, force: true }));
    const fixture = await rpcServer(message => {
      if (message.method === "initialize") return { protocolVersion: "2025-11-25", capabilities: { tools: {} }, serverInfo: { name: "fixture", version: "1" } };
      if (message.method === "tools/list") return { tools: [{ name: "read", inputSchema: { type: "object" }, annotations: { readOnlyHint: true } }] };
      return undefined;
    });
    cleanup.push(() => new Promise<void>(resolve => fixture.server.close(() => resolve())));
    const { owner, adapter } = await setupConnection(root, { transport: "http", endpoint: fixture.endpoint }, "policy", { ...policy, allowWrites: false });
    await owner.markRuntimeReady("policy", 1);
    expect((await owner.snapshot()).capabilities.find(item => item.id === "tools" && item.connectionId === "policy")).toMatchObject({
      availability: "unavailable",
      detail: "Write approval is required for this capability"
    });
    await expect(adapter.extensionFactories("session", "host")).rejects.toThrow(/write policy/);
  });

  it.each(["list-error", "collision"])("retires every stdio child when a later server fails %s admission", async failure => {
    const root = await mkdtemp(join(tmpdir(), "tron-mcp-retirement-"));
    cleanup.push(() => rm(root, { recursive: true, force: true }));
    const script = join(root, "server.mjs");
    await writeFile(script, `import { writeFileSync } from 'node:fs';
      writeFileSync(process.argv[2], String(process.pid));
      let buffer = ''; process.stdin.setEncoding('utf8');
      process.stdin.on('end', () => process.exit(0));
      process.stdin.on('data', chunk => {
        buffer += chunk;
        for (const line of buffer.split('\\n').slice(0, -1)) {
          const m = JSON.parse(line); let result;
          if (m.method === 'initialize') result = {protocolVersion:'2025-11-25',capabilities:{tools:{}},serverInfo:{name:'fixture',version:'1'}};
          if (m.method === 'tools/list') {
            if (process.argv[3] === 'list-error') {
              process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:m.id,error:{code:-32603,message:'fixture discovery failed'}})+'\\n'); continue;
            }
            const tool = {name:'echo',inputSchema:{type:'object'}};
            result = {tools: process.argv[3] === 'collision' ? [tool,tool] : [tool]};
          }
          if (result) process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:m.id,result})+'\\n');
        }
        buffer = buffer.slice(buffer.lastIndexOf('\\n') + 1);
      });`);
    const firstPid = join(root, "first.pid"), secondPid = join(root, "second.pid");
    await setupConnection(root, { transport: "stdio", command: process.execPath, args: [script, firstPid, "ok"] }, "first");
    const { owner } = await setupConnection(root, { transport: "stdio", command: process.execPath, args: [script, secondPid, failure] }, "second");
    const credentials = new InMemoryConnectorCredentialStore(new Map([["connector:mcp:first", "fixture"], ["connector:mcp:second", "fixture"]]));
    // Cleanup is fixture-owned only; it cannot mask the assertions below.
    cleanup.push(async () => {
      for (const file of [firstPid, secondPid]) {
        try { process.kill(Number(await readFile(file, "utf8")), "SIGTERM"); } catch { /* already retired */ }
      }
    });
    await expect(new McpAdapter({ connections: owner, credentials }).extensionFactories("session", "1")).rejects.toThrow(failure === "collision" ? /collision/ : /discovery failed/);
    for (const file of [firstPid, secondPid]) {
      const pid = Number(await readFile(file, "utf8"));
      expect(() => process.kill(pid, 0)).toThrow();
    }
    expect((await owner.resolveInstance("second")).health).toBe("setup-required");
  });

  it("launches trusted stdio without shell interpolation or ambient secret inheritance", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-mcp-stdio-"));
    cleanup.push(() => rm(root, { recursive: true, force: true }));
    const script = join(root, "server.mjs");
    await writeFile(script, `process.stdin.setEncoding('utf8'); let b=''; process.stdin.on('data', c => { b += c; for (const line of b.split('\\n').slice(0, -1)) { const m=JSON.parse(line); let r; if (m.method==='initialize') r={protocolVersion:'2025-11-25',capabilities:{tools:{}},serverInfo:{name:'stdio',version:'1'}}; else if (m.method==='tools/list') r={tools:[{name:'secret-check',inputSchema:{type:'object'},annotations:{readOnlyHint:true}}]}; else if (m.method==='tools/call') r={content:[{type:'text',text:process.env.TRON_MCP_TOKEN+'|'+(process.env.TRON_UNRELATED_SECRET||'missing')} ]}; if (r) process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:m.id,result:r})+'\\n'); } b=b.slice(b.lastIndexOf('\\n')+1); });`);
    process.env.TRON_UNRELATED_SECRET = "ambient-secret";
    cleanup.push(async () => { delete process.env.TRON_UNRELATED_SECRET; });
    const { adapter } = await setupConnection(root, { transport: "stdio", command: process.execPath, args: [script] }, "stdio");
    const tools = await registerFactory(adapter);
    expect(Object.keys(tools)).toEqual(["mcp_stdio_secret-check"]);
    const result = await tools["mcp_stdio_secret-check"].execute("call", {}, undefined, undefined, {});
    expect(result.content[0]).toMatchObject({ type: "text", text: "fixture-token|missing" });
  });
});
