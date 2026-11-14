import { appendFileSync } from "node:fs";
import { createInterface } from "node:readline";

const [launchLog] = process.argv.slice(2);
const record = line => { if (launchLog) appendFileSync(launchLog, `${line}\n`); };
record(`launched ${process.pid}`);

const TOOL = { name: "fixture_tool", description: "fixture", inputSchema: { type: "object", properties: { value: { type: "string" } }, required: ["value"] } };

const send = message => process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", ...message })}\n`);

createInterface({ input: process.stdin }).on("line", line => {
  const request = JSON.parse(line);
  if (request.id === undefined) return;
  if (request.method === "initialize") {
    return send({ id: request.id, result: { protocolVersion: request.params.protocolVersion, capabilities: { tools: {} }, serverInfo: { name: "fixture-docs", version: "1" } } });
  }
  if (request.method === "tools/list") {
    record("tools/list");
    return send({ id: request.id, result: { tools: [TOOL] } });
  }
  if (request.method === "tools/call") {
    record("tools/call");
    return send({ id: request.id, result: { content: [{ type: "text", text: `worked:${request.params.arguments.value}` }] } });
  }
  send({ id: request.id, error: { code: -32601, message: "method not found" } });
});
