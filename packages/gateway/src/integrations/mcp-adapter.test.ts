import { createServer, type Server } from "node:http";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { ConnectionOwner } from "./connection-owner.js";
import { McpAdapter } from "./mcp-adapter.js";
import { InMemoryConnectorCredentialStore } from "../knowledge/connector-credentials.js";
import { GatewayWorkRegistry } from "../sessions/gateway-work-registry.js";

const cleanup: Array<() => Promise<void>> = [];
const policy = { enabled: true, allowWrites: true, paidAccessApproved: false, paidBudgetCents: 0, recurringApproved: false };

async function setupConnection(root: string, config: Record<string, unknown>, id: string): Promise<{ owner: ConnectionOwner; adapter: McpAdapter }> {
  const owner = new ConnectionOwner(root);
  const credentials = new InMemoryConnectorCredentialStore(new Map([[`connector:mcp:${id}`, "fixture-token"]]));
  const begin = await owner.execute({ kind: "setup.begin", commandId: `${id}-begin`, instanceId: id, definitionId: "mcp.remote-http", method: config.transport === "http" ? "endpoint" : "local-command" });
  await owner.execute({ kind: "setup.complete", commandId: `${id}-complete`, operationId: (begin as { operationId: string }).operationId, instanceId: id, providerAccountId: "fixture", credentialRef: `connector:mcp:${id}`, policy, configuration: config as never });
  const workRegistry = new GatewayWorkRegistry();
  return { owner, adapter: new McpAdapter({ connections: owner, credentials, workRegistry }), workRegistry };
}

async function registerFactory(adapter: McpAdapter, session = "session", host = "host"): Promise<Record<string, any>> {
  const tools: Record<string, any> = {};
  for (const factory of await adapter.extensionFactories(session, host)) {
    await factory({ registerTool(tool: any) { tools[tool.name] = tool; }, on() {} } as any);
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
        const result = message ? handler(message) : undefined;
        response.setHeader("mcp-session-id", "fixture-session");
        if (!result) { response.statusCode = 202; response.end(); return; }
        response.setHeader("content-type", "application/json");
        response.end(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
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
    const { adapter } = await setupConnection(root, { transport: "http", endpoint: fixture.endpoint }, "remote");
    const tools = await registerFactory(adapter);
    expect(Object.keys(tools)).toEqual(["mcp_remote_echo", "mcp_remote_mutate"]);
    const result = await tools.mcp_remote_echo.execute("call", { text: "ok" }, undefined, undefined, {});
    expect(result.content[0]).toMatchObject({ type: "text", text: '{"text":"ok"}' });
    const unknown = await tools.mcp_remote_mutate.execute("mutation", {}, undefined, undefined, {});
    expect(unknown.details).toMatchObject({ outcome: "unknown" });
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
