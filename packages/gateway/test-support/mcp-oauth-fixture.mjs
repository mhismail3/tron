/**
 * Streamable-HTTP MCP fixture that authenticates with OAuth 2.0 + PKCE.
 *
 * Pi's built-in MCP client connects to this server exactly as it would to a
 * real one: it discovers the protected-resource and authorization-server
 * metadata, registers a public client, completes the loopback authorization
 * code exchange, and then presents the issued bearer token on every MCP
 * request. `/mcp` answers 401 without that exact token, so a caller can prove
 * "this server is authenticated" rather than "this server is configured" — the
 * persisted credential really was used.
 *
 * Everything here is synthetic: the token, the client id and the single `echo`
 * tool contain no user or host data. The token's lifetime is deliberately far
 * in the future so a corpus recorded once stays signed in across later runs;
 * `refresh_token` is still issued so a client that refreshes does not fail.
 *
 * It is a standalone process rather than an inline server because the corpus's
 * `mcp.json` names a command Pi spawns; the inline OAuth servers in
 * `mcp-auth.integration.test.ts` and `mcp-auth-session.integration.test.ts` are
 * bound to their own tests' transports and cannot be configured as a server.
 *
 * Usage: node mcp-oauth-fixture.mjs <port-file>
 * Writes the bound port to <port-file> once listening; exits on SIGTERM.
 */
import { createHash } from "node:crypto";
import { writeFileSync } from "node:fs";
import { createServer } from "node:http";

const [portPath] = process.argv.slice(2);
const TOKEN = "corpus-mcp-access-token";
const CLIENT_ID = "corpus-mcp-fixture-client";
const TOOLS = [{
  name: "echo",
  description: "Echo synthetic fixture input through the OAuth-protected server",
  inputSchema: { type: "object", properties: { value: { type: "string" } }, required: ["value"] },
}];

let origin = "";
let authorizationQuery;

function reply(response, status, payload) {
  response.writeHead(status, {
    "content-type": "application/json",
    "mcp-session-id": "corpus-fixture-session",
    "mcp-protocol-version": "2025-03-26",
  });
  response.end(JSON.stringify(payload));
}

async function requestBody(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(Buffer.from(chunk));
  return Buffer.concat(chunks).toString("utf8");
}

const server = createServer(async (request, response) => {
  const url = new URL(request.url ?? "/", origin || "http://127.0.0.1");
  if (url.pathname === "/.well-known/oauth-protected-resource") {
    return reply(response, 200, { resource: `${origin}/mcp`, authorization_servers: [origin] });
  }
  if (url.pathname === "/.well-known/oauth-authorization-server") {
    return reply(response, 200, {
      issuer: origin,
      authorization_endpoint: `${origin}/authorize`,
      token_endpoint: `${origin}/token`,
      registration_endpoint: `${origin}/register`,
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      token_endpoint_auth_methods_supported: ["none"],
      code_challenge_methods_supported: ["S256"],
    });
  }
  if (url.pathname === "/register") return reply(response, 201, { client_id: CLIENT_ID });
  if (url.pathname === "/authorize") {
    authorizationQuery = url.searchParams;
    const callback = new URL(url.searchParams.get("redirect_uri"));
    callback.searchParams.set("code", "corpus-fixture-code");
    callback.searchParams.set("state", url.searchParams.get("state"));
    response.writeHead(302, { location: callback.href });
    response.end();
    return;
  }
  if (url.pathname === "/token") {
    const form = new URLSearchParams(await requestBody(request));
    if (form.get("grant_type") === "refresh_token") {
      return reply(response, 200, { access_token: TOKEN, token_type: "Bearer", expires_in: 315_360_000, refresh_token: "corpus-fixture-refresh-token" });
    }
    const challenge = createHash("sha256").update(form.get("code_verifier") ?? "").digest("base64url");
    if (form.get("grant_type") !== "authorization_code" || challenge !== authorizationQuery?.get("code_challenge")) {
      return reply(response, 400, { error: "invalid_grant" });
    }
    return reply(response, 200, { access_token: TOKEN, token_type: "Bearer", expires_in: 315_360_000, refresh_token: "corpus-fixture-refresh-token" });
  }
  if (url.pathname !== "/mcp") {
    response.writeHead(404);
    response.end();
    return;
  }
  if (request.headers.authorization !== `Bearer ${TOKEN}`) {
    response.writeHead(401, { "www-authenticate": `Bearer resource_metadata="${origin}/.well-known/oauth-protected-resource"` });
    response.end();
    return;
  }
  if (request.method !== "POST") {
    response.writeHead(405);
    response.end();
    return;
  }
  const message = JSON.parse(await requestBody(request));
  if (message.method === "notifications/initialized" || !("id" in message)) {
    response.writeHead(202);
    response.end();
    return;
  }
  const result = message.method === "initialize"
    ? { protocolVersion: "2025-03-26", capabilities: { tools: {} }, serverInfo: { name: "corpus-oauth-fixture", version: "1" } }
    : message.method === "tools/list"
      ? { tools: TOOLS }
      : message.method === "tools/call"
        ? { content: [{ type: "text", text: `fixture:${message.params.name}:${JSON.stringify(message.params.arguments ?? {})}` }] }
        : null;
  if (result === null) return reply(response, 200, { jsonrpc: "2.0", id: message.id, error: { code: -32601, message: `Method not found: ${message.method}` } });
  return reply(response, 200, { jsonrpc: "2.0", id: message.id, result });
});

server.listen(0, "127.0.0.1", () => {
  origin = `http://127.0.0.1:${server.address().port}`;
  if (portPath) writeFileSync(portPath, `${server.address().port}`);
});

process.on("SIGTERM", () => { server.close(() => process.exit(0)); });
process.on("SIGINT", () => { server.close(() => process.exit(0)); });
