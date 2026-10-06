import { createServer } from "node:http";
import { readFileSync, watch } from "node:fs";
import readline from "node:readline";

const [transport, statePath, pidPath, childPidPath] = process.argv.slice(2);
const state = () => JSON.parse(readFileSync(statePath, "utf8"));
if (pidPath && transport === "stdio") await import("node:fs/promises").then(({ writeFile }) => writeFile(pidPath, String(process.pid)));
if (childPidPath) {
  const { spawn } = await import("node:child_process");
  const child = spawn(process.execPath, ["-e", "setInterval(() => {}, 60_000);"], { stdio: "ignore" });
  await import("node:fs/promises").then(({ writeFile }) => writeFile(childPidPath, String(child.pid)));
}

function dispatch(message) {
  const params = message.params ?? {};
  switch (message.method) {
    case "initialize": return { protocolVersion: params.protocolVersion ?? "2025-03-26", capabilities: { tools: { listChanged: true }, resources: { listChanged: true } }, serverInfo: { name: "tron-fixture", version: "1" } };
    case "tools/list": return { tools: state().tools ?? [] };
    case "resources/list": return { resources: [{ uri: "fixture://one", name: "Fixture resource", mimeType: "text/plain" }] };
    case "resources/read": return { contents: [{ uri: params.uri, mimeType: "text/plain", text: "fixture resource body" }] };
    case "tools/call": return { content: [{ type: "text", text: `fixture:${params.name}:${JSON.stringify(params.arguments ?? {})}` }] };
    case "ping": return {};
    default: return null;
  }
}
function response(message) {
  const result = dispatch(message);
  return { jsonrpc: "2.0", id: message.id, ...(result === null
    ? { error: { code: -32601, message: `Method not found: ${message.method}` } }
    : { result }) };
}

if (transport === "stdio") {
  const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
  const send = (message) => process.stdout.write(`${JSON.stringify(message)}\n`);
  input.on("line", (line) => {
    try {
      const message = JSON.parse(line);
      if (message.method === "notifications/initialized") return;
      if (message.method && !("id" in message)) return;
      send(response(message));
    } catch (error) {
      process.stderr.write(`${String(error)}\n`);
    }
  });
  watch(statePath, () => send({ jsonrpc: "2.0", method: "notifications/tools/list_changed" }));
} else if (transport === "http") {
  const server = createServer(async (request, reply) => {
    if (request.method !== "POST") { reply.writeHead(405).end(); return; }
    let body = "";
    for await (const part of request) body += part;
    let message;
    try { message = JSON.parse(body); } catch { reply.writeHead(400).end(); return; }
    if (message.method === "notifications/initialized" || !("id" in message)) { reply.writeHead(202).end(); return; }
    const result = response(message);
    reply.writeHead(200, { "content-type": "application/json", "mcp-session-id": "fixture-session", "mcp-protocol-version": "2025-03-26" });
    reply.end(JSON.stringify(result));
  });
  server.listen(Number(process.env.MCP_FIXTURE_PORT ?? 0), "127.0.0.1", async () => {
    const address = server.address();
    // Published by rename: the port file exists only once it holds the port.
    // A plain write is visible empty first, and a reader polling for the file
    // then read port 0 under load (#406).
    const { rename, writeFile } = await import("node:fs/promises");
    await writeFile(`${pidPath}.tmp`, String(address.port));
    await rename(`${pidPath}.tmp`, pidPath);
  });
  process.on("SIGTERM", () => server.close(() => process.exit(0)));
} else {
  throw new Error(`Unknown fixture transport: ${transport}`);
}
