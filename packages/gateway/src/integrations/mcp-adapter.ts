import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { StdioClientTransport, getDefaultEnvironment } from "@modelcontextprotocol/sdk/client/stdio.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import type { Tool as McpTool } from "@modelcontextprotocol/sdk/types.js";
import type { ExtensionFactory, ToolDefinition } from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import type { GatewayWorkRegistry } from "../sessions/gateway-work-registry.js";
import type { ConnectionInstance, McpConnectionConfiguration } from "./connection-contract.js";
import type { ConnectionOwner } from "./connection-owner.js";
import type { ConnectorCredentialStore } from "../knowledge/connector-credentials.js";

/** MCP is intentionally a tools-only adapter. This is the stable protocol
 * cohort accepted by this pinned SDK; resources/prompts/tasks/apps and server
 * sampling/elicitation are not advertised or delegated. */
/** The revision negotiated by the pinned SDK cohort. Older server revisions
 * are rejected rather than silently changing the feature contract. */
export const MCP_SUPPORTED_PROTOCOL_VERSION = "2025-11-25" as const;
const MAX_TOOLS = 128;
const MAX_SCHEMA_BYTES = 64 * 1024;
const MAX_SCHEMA_DEPTH = 8;
const MAX_SCHEMA_NODES = 2_048;
const MAX_RESULT_BYTES = 512 * 1024;
const MAX_TEXT_BYTES = 256 * 1024;
const MAX_STDERR_BYTES = 64 * 1024;
const CALL_TIMEOUT_MS = 120_000;
const HTTP_MAX_RESPONSE_BYTES = 2 * 1024 * 1024;

type ToolSchema = Record<string, unknown>;
type ToolOutcome = { outcome: "success" | "remote-error" | "unknown"; connectionId: string; tool: string };

interface ActiveConnection {
  readonly client: Client;
  readonly close: () => Promise<void>;
  closed?: boolean;
}

function invalid(message: string): GatewayError { return new GatewayError("invalid_request", message); }
function unavailable(message: string): GatewayError { return new GatewayError("conflict", message, true, { integration: "mcp", availability: "unavailable" }); }
function byteLength(value: string): number { return Buffer.byteLength(value, "utf8"); }
function boundedText(value: unknown, maximum: number, label: string): string {
  if (typeof value !== "string") return "";
  if (byteLength(value) > maximum) throw invalid(`${label} exceeds its bounded size`);
  return value.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, "");
}

function validateSchema(value: unknown, depth = 0, state = { nodes: 0 }): asserts value is ToolSchema {
  if (depth > MAX_SCHEMA_DEPTH) throw invalid("MCP tool schema is too deeply nested");
  if (!value || typeof value !== "object") throw invalid("MCP tool schema must be an object or array");
  state.nodes += 1;
  if (state.nodes > MAX_SCHEMA_NODES) throw invalid("MCP tool schema is too large");
  if (Array.isArray(value)) {
    for (const child of value) if (child && typeof child === "object") validateSchema(child, depth + 1, state);
  } else {
    for (const [key, child] of Object.entries(value)) {
      if (key.length > 256 || /[\u0000-\u001f\u007f]/.test(key)) throw invalid("MCP tool schema contains an invalid key");
      if (child && typeof child === "object") validateSchema(child, depth + 1, state);
    }
  }
  if (byteLength(JSON.stringify(value)) > MAX_SCHEMA_BYTES) throw invalid("MCP tool schema exceeds its bounded size");
}

function safeToolName(connectionId: string, name: string): string {
  const normalized = `${connectionId}_${name}`.replace(/[^A-Za-z0-9_-]+/g, "_").replace(/^[-_]+|[-_]+$/g, "");
  const result = `mcp_${normalized}`;
  if (!result || result.length > 128) throw invalid("MCP tool name is too long after attribution");
  return result;
}

function resultBytes(value: unknown): number {
  try { return byteLength(JSON.stringify(value)); } catch { return MAX_RESULT_BYTES + 1; }
}

function textContent(value: unknown): { type: "text"; text: string } {
  return { type: "text", text: boundedText(value, MAX_TEXT_BYTES, "MCP tool text") };
}

function toAgentContent(result: any): Array<{ type: "text"; text: string } | { type: "image"; data: string; mimeType: string }> {
  if (!result || typeof result !== "object" || !Array.isArray(result.content)) throw unavailable("MCP tool returned an invalid result");
  if (resultBytes(result) > MAX_RESULT_BYTES) throw unavailable("MCP tool result exceeds its bounded size");
  return result.content.map((part: any) => {
    if (part?.type === "text") return textContent(part.text);
    if (part?.type === "image" && typeof part.data === "string" && typeof part.mimeType === "string") {
      if (byteLength(part.data) > MAX_RESULT_BYTES) throw unavailable("MCP image result exceeds its bounded size");
      return { type: "image", data: part.data, mimeType: boundedText(part.mimeType, 256, "MCP image MIME type") };
    }
    if (part?.type === "resource" && part.resource && typeof part.resource.uri === "string") {
      // Resource contents are not exposed as a separate MCP capability. A
      // bounded URI notice keeps a tool result truthful without granting the
      // model a second read authority.
      return textContent(`[MCP resource returned: ${part.resource.uri}]`);
    }
    throw unavailable("MCP returned an unsupported tool content type");
  });
}

function validateEndpoint(endpoint: string): URL {
  let url: URL;
  try { url = new URL(endpoint); } catch { throw invalid("MCP endpoint is not a valid URL"); }
  if (!["http:", "https:"].includes(url.protocol) || url.username || url.password || url.hash) throw invalid("MCP endpoint must be HTTP(S) without embedded credentials or fragments");
  return url;
}

function endpointFetch(endpoint: URL, token: string | undefined): typeof fetch {
  const origin = endpoint.origin;
  return async (input, init) => {
    const url = new URL(input.toString());
    if (url.origin !== origin || url.pathname !== endpoint.pathname || url.search !== endpoint.search) throw new Error("MCP transport attempted to leave the configured endpoint");
    const headers = new Headers(init?.headers);
    if (token) headers.set("authorization", `Bearer ${token}`);
    const response = await fetch(url, { ...init, headers, redirect: "error" });
    const contentLength = response.headers.get("content-length");
    if (contentLength && (!/^\d+$/.test(contentLength) || Number(contentLength) > HTTP_MAX_RESPONSE_BYTES)) throw new Error("MCP HTTP response exceeds its bounded size");
    if (!response.body) return response;
    const reader = response.body.getReader();
    const chunks: Uint8Array[] = [];
    let total = 0;
    try {
      while (true) {
        const next = await reader.read();
        if (next.done) break;
        total += next.value.byteLength;
        if (total > HTTP_MAX_RESPONSE_BYTES) throw new Error("MCP HTTP response exceeds its bounded size");
        chunks.push(next.value);
      }
    } finally { reader.releaseLock(); }
    const body = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) { body.set(chunk, offset); offset += chunk.byteLength; }
    return new Response(body, { status: response.status, statusText: response.statusText, headers: response.headers });
  };
}

function stdioEnvironment(configuration: McpConnectionConfiguration, token: string | undefined): Record<string, string> {
  // The SDK's allowlist deliberately excludes arbitrary parent secrets. Only
  // explicitly configured values and the owned credential handoff are added.
  return { ...getDefaultEnvironment(), ...(configuration.env ?? {}), ...(token ? { TRON_MCP_TOKEN: token } : {}) };
}

export interface McpAdapterOptions {
  connections: ConnectionOwner;
  credentials: ConnectorCredentialStore;
  workRegistry?: GatewayWorkRegistry;
}

export class McpAdapter {
  private readonly lanes = new Map<string, AsyncMutex>();

  constructor(private readonly options: McpAdapterOptions) {}

  private lane(connectionId: string): AsyncMutex {
    let lane = this.lanes.get(connectionId);
    if (!lane) { lane = new AsyncMutex(); this.lanes.set(connectionId, lane); }
    return lane;
  }

  /** Returns factories for ready instances only. A configured instance that
   * cannot authenticate fails runtime admission rather than silently granting
   * a partially discovered tool set. */
  async extensionFactories(sessionId: string, hostEpoch: string): Promise<ExtensionFactory[]> {
    const snapshot = await this.options.connections.snapshot();
    const instances = snapshot.instances.filter(instance => instance.definitionId === "mcp.remote-http" && (instance.health === "ready" || instance.health === "setup-required") && instance.policy.enabled);
    const factories: ExtensionFactory[] = [];
    const names = new Set<string>();
    const opened: ActiveConnection[] = [];
    try {
      for (const projection of instances) {
        const instance = await this.options.connections.resolveInstance(projection.id);
        factories.push(await this.factoryFor(instance, sessionId, hostEpoch, names, opened));
      }
      return factories;
    } catch (error) {
      // No factory reaches the runtime on partial admission. Retire every
      // transport acquired by this attempt, including earlier valid servers.
      await Promise.allSettled(opened.map(active => active.close()));
      throw error;
    }
  }

  private async factoryFor(instance: ConnectionInstance, sessionId: string, hostEpoch: string, names: Set<string>, opened: ActiveConnection[]): Promise<ExtensionFactory> {
    // MCP annotations are untrusted. A server cannot turn a write-capable
    // connection into a read-only one by labelling a tool read-only.
    if (!instance.policy.allowWrites) throw unavailable("MCP tools require an enabled write policy");
    const active = await this.connect(instance);
    opened.push(active);
    const discovered: McpTool[] = [];
    let cursor: string | undefined;
    let pages = 0;
    do {
      if (++pages > MAX_TOOLS) { await active.close(); throw unavailable("MCP tool pagination exceeded its bounded capacity"); }
      const listed = await active.client.listTools(cursor ? { cursor } : {});
      if (!Array.isArray(listed.tools) || discovered.length + listed.tools.length > MAX_TOOLS) {
        await active.close();
        throw unavailable("MCP tool discovery exceeded its bounded capacity");
      }
      discovered.push(...listed.tools);
      cursor = listed.nextCursor;
    } while (cursor);
    const tools = discovered.map(tool => this.admitTool(instance, tool, names, active, sessionId, hostEpoch));
    await this.options.connections.markRuntimeReady(instance.id, instance.setupRevision);
    await this.options.connections.admitRuntimeBinding({ schemaVersion: 1, integrationId: instance.definitionId, connectionId: instance.id, capabilityId: "tools", sessionId, runtimeGeneration: Number.isFinite(Number(hostEpoch)) ? Number(hostEpoch) : 0, provider: { owner: "connection", definitionId: instance.definitionId, connectionId: instance.id } });
    return async (pi) => {
      for (const tool of tools) pi.registerTool(tool as ToolDefinition<any>);
      pi.on("session_shutdown", async () => { await active.close(); });
    };
  }

  private admitTool(instance: ConnectionInstance, tool: McpTool, names: Set<string>, active: ActiveConnection, sessionId: string, hostEpoch: string): ToolDefinition<any> {
    if (!tool || typeof tool.name !== "string" || tool.name.length < 1 || tool.name.length > 256) throw invalid("MCP tool name is invalid");
    if (!tool.inputSchema || typeof tool.inputSchema !== "object" || Array.isArray(tool.inputSchema)) throw invalid("MCP tool input schema must be an object");
    validateSchema(tool.inputSchema);
    const name = safeToolName(instance.id, tool.name);
    if (names.has(name)) throw new GatewayError("conflict", `MCP tool collision for ${name}`);
    names.add(name);
    const sourceName = boundedText(tool.name, 256, "MCP tool name");
    const description = boundedText(tool.description ?? "MCP server tool", 4_096, "MCP tool description");
    const readOnly = tool.annotations?.readOnlyHint === true;
    return {
      name,
      label: boundedText(tool.title ?? sourceName, 160, "MCP tool title") || sourceName,
      description: `${description} (MCP server ${instance.id}; source tool ${sourceName})`,
      parameters: tool.inputSchema as any,
      executionMode: "sequential",
      execute: async (toolCallId, params, signal, onUpdate) => {
        const controller = new AbortController();
        const abort = () => controller.abort(signal?.reason);
        if (signal?.aborted) abort(); else signal?.addEventListener("abort", abort, { once: true });
        const work = this.options.workRegistry?.begin({ kind: "mcp-tool-call", sessionId, hostEpoch, cancellation: () => controller.abort() });
        try {
          const result = await this.lane(instance.id).run(async () => {
            const current = await this.options.connections.resolveInstance(instance.id);
            if (active.closed || current.setupRevision !== instance.setupRevision || current.health !== "ready" || !current.policy.enabled || !current.policy.allowWrites) {
              active.closed = true;
              await active.close();
              throw unavailable("MCP connection is no longer admitted");
            }
            return active.client.callTool({ name: sourceName, arguments: params as Record<string, unknown> }, undefined, {
            signal: controller.signal,
            timeout: CALL_TIMEOUT_MS,
            onprogress: (progress: { progress: number; total?: number | undefined }) => {
              work?.progress();
              onUpdate?.({ content: [textContent(`MCP progress: ${String(progress.progress)}${progress.total === undefined ? "" : `/${progress.total}`}`)], details: { outcome: "success", connectionId: instance.id, tool: sourceName } satisfies ToolOutcome });
            },
            });
          });
          const content = toAgentContent(result);
          return { content, details: { outcome: result.isError ? "remote-error" : "success", connectionId: instance.id, tool: sourceName } satisfies ToolOutcome };
        } catch (error) {
          const detail = error instanceof Error ? error.message : "MCP tool call failed";
          if (!readOnly) {
            return { content: [textContent(`MCP call outcome is unknown; do not retry automatically: ${detail}`)], details: { outcome: "unknown", connectionId: instance.id, tool: sourceName } satisfies ToolOutcome };
          }
          throw unavailable(`MCP tool call failed: ${detail}`);
        } finally {
          signal?.removeEventListener("abort", abort);
          work?.settle();
        }
      },
    };
  }

  private async connect(instance: ConnectionInstance): Promise<ActiveConnection> {
    const configuration = instance.configuration;
    if (!configuration) throw unavailable("MCP connection has no transport configuration");
    const token = await this.options.credentials.read(instance.credentialRef);
    if (!token && instance.credentialRef) throw unavailable("MCP credential is unavailable");
    const client = new Client({ name: "tron-mcp-adapter", version: "0.1.0" }, { capabilities: {}, enforceStrictCapabilities: true });
    let transport: StreamableHTTPClientTransport | StdioClientTransport;
    if (configuration.transport === "http") {
      const endpoint = validateEndpoint(configuration.endpoint!);
      transport = new StreamableHTTPClientTransport(endpoint, {
        fetch: endpointFetch(endpoint, token),
        reconnectionOptions: { maxRetries: 0, initialReconnectionDelay: 100, reconnectionDelayGrowFactor: 1, maxReconnectionDelay: 100 },
      });
    } else {
      if (!configuration.command) throw invalid("MCP stdio executable is missing");
      transport = new StdioClientTransport({ command: configuration.command, ...(configuration.args ? { args: configuration.args } : {}), ...(configuration.cwd ? { cwd: configuration.cwd } : {}), env: stdioEnvironment(configuration, token), stderr: "pipe" });
      const stderr = transport.stderr;
      let stderrBytes = 0;
      stderr?.on("data", (chunk: Buffer | string) => {
        stderrBytes += Buffer.byteLength(chunk.toString(), "utf8");
        if (stderrBytes > MAX_STDERR_BYTES) void transport.close();
      });
    }
    try {
      await client.connect(transport as any, { timeout: CALL_TIMEOUT_MS });
      const version = transport instanceof StreamableHTTPClientTransport ? transport.protocolVersion : undefined;
      if (version && version !== MCP_SUPPORTED_PROTOCOL_VERSION) throw unavailable(`MCP protocol version ${version} is unsupported; expected ${MCP_SUPPORTED_PROTOCOL_VERSION}`);
      const capabilities = client.getServerCapabilities() ?? {};
      if (capabilities.resources || capabilities.prompts || capabilities.completions || capabilities.logging || capabilities.tasks) {
        // These are tolerated server declarations, but intentionally not
        // advertised by this client. Tool discovery remains the only route.
      }
      return { client, close: async () => { await client.close().catch(() => undefined); await transport.close().catch(() => undefined); } };
    } catch (error) {
      await transport.close().catch(() => undefined);
      throw unavailable(`MCP connection failed: ${error instanceof Error ? error.message : "unknown error"}`);
    }
  }
}

export function createMcpAdapter(options: McpAdapterOptions): McpAdapter { return new McpAdapter(options); }
