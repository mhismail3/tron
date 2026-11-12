import { createServer, type IncomingHttpHeaders, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { getSupportedThinkingLevels, type Context, type Message, type Model } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { VIEW_BLOCK_LINES } from "../../../episodic/cache-layout.js";
import { applyHomeCacheRetention, HOME_NONCE_MARKER } from "../../../modules/home/home-request-policy.js";
import { CLAUDE_CODE_VERSION } from "../../../providers/claude-code-identity.js";
import { createTronHomeExtension } from "../../../modules/home/tron-home-extension.js";
import { sessionRuntimeView } from "../../../providers/openai-model-eligibility.js";
import { createProviderModelRuntime } from "../../../providers/provider-runtime.js";
import { ProviderUsageOwner } from "../../../providers/provider-usage.js";

type Captured = { headers: IncomingHttpHeaders; body: Record<string, unknown> };
type Block = { type: string; text?: string; name?: string; cache_control?: { type: string; ttl?: string } };
type WireMessage = { role: string; content: Block[] | string };

const ACCESS = "sk-ant-oat01-tron-wire-test";
const FABLE_5_2_MIN_CLAUDE_CODE = [2, 1, 290];
const atLeast = (version: string, minimum: number[]) => {
  const parts = version.split(".").map(Number);
  const differs = minimum.findIndex((part, index) => parts[index] !== part);
  return differs < 0 || parts[differs]! > minimum[differs]!;
};
const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => { for (const cleanup of cleanups.splice(0).reverse()) await cleanup(); });

function sse(events: Array<Record<string, unknown>>): string {
  return events.map((event) => `event: ${String(event.type)}\ndata: ${JSON.stringify(event)}\n\n`).join("");
}
const start = (model: string) => ({ type: "message_start", message: { id: "msg_wire", type: "message", role: "assistant", model, content: [],
  stop_reason: null, usage: { input_tokens: 4, output_tokens: 0, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 } } });
function reply(index: number, model: string): string {
  if (index === 0) return sse([start(model),
    { type: "content_block_start", index: 0, content_block: { type: "tool_use", id: "toolu_wire", name: "Bash", input: {} } },
    { type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: "{\"command\":\"echo ok\"}" } },
    { type: "content_block_stop", index: 0 },
    { type: "message_delta", delta: { stop_reason: "tool_use" }, usage: { output_tokens: 5 } }, { type: "message_stop" }]);
  return sse([start(model),
    { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
    { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "ok" } },
    { type: "content_block_stop", index: 0 },
    { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 1 } }, { type: "message_stop" }]);
}

async function anthropicEndpoint(): Promise<{ port: number; requests: Captured[] }> {
  const requests: Captured[] = [];
  const server: Server = createServer((request, response) => {
    let text = "";
    request.on("data", (chunk) => { text += String(chunk); });
    request.on("end", () => {
      const body = JSON.parse(text) as Record<string, unknown>;
      response.writeHead(200, { "content-type": "text/event-stream" }).end(reply(requests.length, String(body.model)));
      requests.push({ headers: request.headers, body });
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  cleanups.push(() => new Promise<void>((resolve) => server.close(() => resolve())));
  return { port: (server.address() as AddressInfo).port, requests };
}

function homeBeforeProviderRequest(): (payload: unknown, model: Model) => unknown {
  const handlers = new Map<string, (event: { payload: unknown }, ctx: { model: Model }) => unknown>();
  const unused = async () => { throw new Error("not used on the wire"); };
  createTronHomeExtension(() => undefined, unused, unused, () => undefined, () => undefined, unused as never, () => "user", unused)(
    { on: (name: string, handler: never) => handlers.set(name, handler), registerTool: () => {} } as never);
  const hook = handlers.get("before_provider_request")!;
  return (payload, model) => hook({ payload }, { model });
}

const TURN_STATE = "<turn-state>\nCurrent Home chat model: anthropic/claude-opus-5-5\n</turn-state>";

function memoryMessage(): Message {
  const group = (first: number) => Array.from({ length: VIEW_BLOCK_LINES }, (_, line) => `${first + line}+0|fact ${first + line}\n`).join("");
  const blocks = ["<memory>", group(1), group(1 + VIEW_BLOCK_LINES), "</memory>", TURN_STATE, `${HOME_NONCE_MARKER}wire`];
  return { role: "user", content: blocks.map((text) => ({ type: "text", text })), timestamp: 1 };
}

function viewMessage(spans: readonly number[]): Message {
  let id = 0;
  const lines = spans.map((span) => { const line = `${id}+${span}|fact ${id}\n`; id += span; return line; });
  const groups: string[] = [];
  for (let at = 0; at < lines.length; at += VIEW_BLOCK_LINES) groups.push(lines.slice(at, at + VIEW_BLOCK_LINES).join(""));
  return { role: "user", content: ["<memory>", ...groups, "</memory>", TURN_STATE, `${HOME_NONCE_MARKER}wire`].map((text) => ({ type: "text", text })), timestamp: 1 };
}

async function oauthHome(prefix: string) {
  const root = await mkdtemp(join(tmpdir(), prefix));
  cleanups.push(() => rm(root, { recursive: true, force: true }));
  const agentDir = join(root, "agent");
  const endpoint = await anthropicEndpoint();
  await mkdir(agentDir, { recursive: true });
  await writeFile(join(agentDir, "auth.json"), JSON.stringify({ anthropic: { type: "oauth", access: ACCESS, refresh: "sk-ant-ort01-tron-wire-test", expires: Date.now() + 3_600_000 } }), { mode: 0o600 });
  await writeFile(join(agentDir, "models.json"), JSON.stringify({ providers: { anthropic: { baseUrl: `http://127.0.0.1:${endpoint.port}` } } }));
  const shared = await createProviderModelRuntime(agentDir);
  const home = applyHomeCacheRetention(sessionRuntimeView(shared));
  const model = home.getModels("anthropic").find((candidate) => candidate.id === "claude-opus-5-5")!;
  return { root, endpoint, shared, home, model };
}

const HOME_TOOLS = [
  { name: "bash", description: "Run a shell command.", parameters: { type: "object", properties: { command: { type: "string" } }, required: ["command"] } },
  { name: "read", description: "Read a file.", parameters: { type: "object", properties: { path: { type: "string" } }, required: ["path"] } },
];

function wireMarks(body: Record<string, unknown>): Array<{ path: string; ttl?: string }> {
  const order = (path: string) => [".tools", ".system", ".messages"].findIndex((key) => path.startsWith(key));
  return cacheMarks(body).toSorted((left, right) => order(left.path) - order(right.path) || left.path.localeCompare(right.path, undefined, { numeric: true }));
}

function cacheMarks(body: Record<string, unknown>): Array<{ path: string; ttl?: string }> {
  const marks: Array<{ path: string; ttl?: string }> = [];
  const visit = (value: unknown, path: string) => {
    if (Array.isArray(value)) value.forEach((item, index) => visit(item, `${path}[${index}]`));
    else if (value && typeof value === "object") for (const [key, field] of Object.entries(value)) {
      if (key === "cache_control") marks.push({ path, ttl: (field as { ttl?: string }).ttl });
      else visit(field, `${path}.${key}`);
    }
  };
  visit(body, "");
  return marks;
}

describe("Claude subscription on Pi's built-in Anthropic OAuth", () => {
  it("sends Home's one-hour prefix marks and five-minute last-message mark, Claude Code identity and tool casing, and maps the reply back", async () => {
    const { root, endpoint, shared, home, model } = await oauthHome("tron-anthropic-oauth-wire-");
    expect(model).toMatchObject({ provider: "anthropic", api: "anthropic-messages" });
    expect(shared.isUsingOAuth("anthropic")).toBe(true);
    expect(getSupportedThinkingLevels(model)).toEqual(expect.arrayContaining(["xhigh", "max"]));

    const onPayload = homeBeforeProviderRequest();
    const tools = HOME_TOOLS;
    const messages: Message[] = [memoryMessage(), { role: "user", content: [{ type: "text", text: "Run echo ok." }], timestamp: 2 }];
    const context: Context = { systemPrompt: "You are Tron Home.", tools: tools as never, messages };
    const first = await home.streamSimple(model, context, { sessionId: "home-wire", reasoning: "xhigh", onPayload }).result();
    expect(first.stopReason).toBe("toolUse");
    expect(first.content.filter((block) => block.type === "toolCall")).toEqual([expect.objectContaining({ name: "bash", arguments: { command: "echo ok" } })]);
    expect(first.providerThinkingLevel).toBe("xhigh");

    const second = await home.streamSimple(model, { ...context, messages: [...messages, first,
      { role: "toolResult", toolCallId: "toolu_wire", toolName: "bash", content: [{ type: "text", text: "ok" }], isError: false, timestamp: 3 }] },
    { sessionId: "home-wire", reasoning: "max", onPayload }).result();
    expect(second).toMatchObject({ stopReason: "stop", providerThinkingLevel: "max" });

    expect(endpoint.requests).toHaveLength(2);
    for (const { headers, body } of endpoint.requests) {
      expect(headers.authorization).toBe(`Bearer ${ACCESS}`);
      expect(headers["x-api-key"]).toBeUndefined();
      expect(headers["user-agent"]).toBe(`claude-cli/${CLAUDE_CODE_VERSION}`);
      expect(atLeast(CLAUDE_CODE_VERSION, FABLE_5_2_MIN_CLAUDE_CODE)).toBe(true);
      expect(headers["x-app"]).toBe("cli");
      expect(String(headers["anthropic-beta"]).split(",")).toEqual(expect.arrayContaining(["claude-code-20250219", "oauth-2025-04-20"]));
      expect((body.system as Block[])[0]!.text).toBe("You are Claude Code, Anthropic's official CLI for Claude.");
      expect((body.tools as Block[] | undefined)?.map((tool) => tool.name)).toEqual(expect.arrayContaining(["Bash", "Read"]));
      const memory = (body.messages as WireMessage[]).findIndex((message) => Array.isArray(message.content)
        && message.content.some((block) => block.text?.startsWith(HOME_NONCE_MARKER)));
      const marks = cacheMarks(body);
      expect(marks.map((mark) => mark.path)).toContain(`.messages[${memory}].content[2]`);
      expect(marks.length).toBeLessThanOrEqual(4);
      const ordered = wireMarks(body);
      expect(ordered.map((mark) => mark.ttl)).toEqual(["1h", "1h", "1h", undefined]);
      const wire = body.messages as Array<WireMessage & { output_config?: unknown }>;
      expect(wire.at(-1)).toMatchObject({ role: "system", content: [], output_config: { effort: expect.any(String) } });
      expect(ordered.at(-1)!.path.startsWith(`.messages[${wire.length - 2}].`)).toBe(true);
    }
    const toolUse = (endpoint.requests[1]!.body.messages as WireMessage[]).flatMap((message) => Array.isArray(message.content) ? message.content : [])
      .find((block) => block.type === "tool_use");
    expect(toolUse?.name).toBe("Bash");

    let usageAgent: string | null = null;
    const usage = new ProviderUsageOwner({ fetch: async (_input, init) => {
      usageAgent = new Headers(init?.headers).get("user-agent");
      return new Response(JSON.stringify({ five_hour: null, seven_day: { utilization: 10 } }), { headers: { "content-type": "application/json" } });
    } });
    const direct = join(root, "direct");
    await mkdir(direct);
    await writeFile(join(direct, "auth.json"), JSON.stringify({ anthropic: { type: "oauth", access: ACCESS, refresh: "sk-ant-ort01-tron-wire-test", expires: Date.now() + 3_600_000 } }), { mode: 0o600 });
    expect((await usage.read(await createProviderModelRuntime(direct), "anthropic")).providers[0]).toMatchObject({ status: "available" });
    expect(usageAgent).toBe(`claude-code/${CLAUDE_CODE_VERSION}`);
  });

  it("marks the end of the settled view lines and keeps that prefix when only recent lines merge", async () => {
    const { endpoint, home, model } = await oauthHome("tron-anthropic-settled-mark-");
    const onPayload = homeBeforeProviderRequest();
    const settled = [2048, 1024, 128, 128, 128, 128, 64, 64, 64, 64];
    const send = async (spans: readonly number[], text: string) => {
      const context: Context = { systemPrompt: "You are Tron Home.", tools: HOME_TOOLS as never,
        messages: [viewMessage(spans), { role: "user", content: [{ type: "text", text }], timestamp: 2 }] };
      await home.streamSimple(model, context, { sessionId: "home-settled", reasoning: "xhigh", onPayload }).result();
      return endpoint.requests.at(-1)!.body;
    };
    const settledEnd = 1 + Math.floor(settled.length / VIEW_BLOCK_LINES) - 1;
    const prefixTo = (body: Record<string, unknown>, block: number) => JSON.stringify([body.tools, (body.system as Block[]).map(({ cache_control: _mark, ...rest }) => rest),
      (body.messages as WireMessage[])[0]!.content.slice(0, block + 1).map((part) => typeof part === "string" ? part : { type: part.type, text: part.text })]);

    const before = await send([...settled, 32, 32, 16, 16, 8, 4, 2, 1, 1, 1, 1, 1], "first");
    expect(wireMarks(before)).toEqual([
      { path: ".system[1]", ttl: "1h" },
      { path: `.messages[0].content[${settledEnd}]`, ttl: "1h" },
      { path: ".messages[0].content[5]", ttl: "1h" },
      { path: ".messages[1].content[0]", ttl: undefined },
    ]);

    const after = await send([...settled, 64, 16, 16, 8, 4, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1], "second");
    expect(wireMarks(after)).toEqual([
      { path: ".system[1]", ttl: "1h" },
      { path: `.messages[0].content[${settledEnd}]`, ttl: "1h" },
      { path: ".messages[0].content[6]", ttl: "1h" },
      { path: ".messages[1].content[0]", ttl: undefined },
    ]);
    expect(prefixTo(after, settledEnd)).toBe(prefixTo(before, settledEnd));
    expect(prefixTo(after, settledEnd + 1)).not.toBe(prefixTo(before, settledEnd + 1));

    const unsettled = await send([32, 32, 16, 16, 8, 4, 2, 1, 1], "third");
    expect(wireMarks(unsettled).map((mark) => mark.path)).toEqual([".system[0]", ".system[1]", ".messages[0].content[2]", ".messages[1].content[0]"]);
  });

  it("sends every request with its full context, never an Anthropic message thread, on Anthropic's own endpoint", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-anthropic-full-context-"));
    cleanups.push(() => rm(root, { recursive: true, force: true }));
    await writeFile(join(root, "auth.json"), JSON.stringify({ anthropic: { type: "oauth", access: ACCESS, refresh: "sk-ant-ort01-tron-wire-test", expires: Date.now() + 3_600_000 } }), { mode: 0o600 });
    const shared = await createProviderModelRuntime(root);
    const runtimes = { chat: shared, home: applyHomeCacheRetention(sessionRuntimeView(shared)) };
    const model = shared.getModels("anthropic").find((candidate) => candidate.id === "claude-opus-5-5")!;
    expect(model.baseUrl).toContain("api.anthropic.com");
    const requests: Array<{ name: string; headers: Headers; body: Record<string, unknown> }> = [];
    for (const [name, runtime] of Object.entries(runtimes)) {
      const fetch = async (_input: unknown, init?: RequestInit) => {
        const body = JSON.parse(String(init?.body)) as Record<string, unknown>;
        const index = requests.filter((request) => request.name === name).length;
        requests.push({ name, headers: new Headers(init?.headers), body });
        return new Response(reply(index, String(body.model)), { headers: { "content-type": "text/event-stream" } });
      };
      const tools = [{ name: "bash", description: "Run a shell command.", parameters: { type: "object", properties: { command: { type: "string" } }, required: ["command"] } }];
      const messages: Message[] = [{ role: "user", content: [{ type: "text", text: "Run echo ok." }], timestamp: 1 }];
      const context: Context = { systemPrompt: "You are Tron.", tools: tools as never, messages };
      const options = { sessionId: `${name}-full-context`, fetch: fetch as typeof globalThis.fetch };
      const first = await runtime.streamSimple(model, context, options).result();
      expect(first.stopReason).toBe("toolUse");
      const second = await runtime.streamSimple(model, { ...context, messages: [...messages, first,
        { role: "toolResult", toolCallId: "toolu_wire", toolName: "bash", content: [{ type: "text", text: "ok" }], isError: false, timestamp: 2 }] }, options).result();
      expect(second.stopReason).toBe("stop");
    }

    expect(requests.map((request) => request.name)).toEqual(["chat", "chat", "home", "home"]);
    for (const { name, headers, body } of requests) {
      expect(body.thread, name).toBeUndefined();
      expect(String(headers.get("anthropic-beta")).split(","), name).not.toContain("message-threads-2026-08-12");
      expect((body.system as Block[] | undefined)?.length, name).toBeGreaterThan(0);
      expect((body.tools as Block[] | undefined)?.map((tool) => tool.name), name).toContain("Bash");
    }
    for (const request of requests.filter((_, index) => index % 2 === 1)) {
      const blocks = (request.body.messages as WireMessage[]).flatMap((message) => Array.isArray(message.content) ? message.content : []);
      expect(blocks.some((block) => block.type === "text" && block.text === "Run echo ok."), request.name).toBe(true);
      expect(blocks.map((block) => block.type), request.name).toEqual(expect.arrayContaining(["tool_use", "tool_result"]));
    }
  });

  it("leaves an Anthropic API-key login's identity to Pi", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-anthropic-api-key-wire-"));
    cleanups.push(() => rm(root, { recursive: true, force: true }));
    const endpoint = await anthropicEndpoint();
    await writeFile(join(root, "auth.json"), JSON.stringify({ anthropic: { type: "api_key", key: "sk-ant-api03-tron-wire-test" } }), { mode: 0o600 });
    await writeFile(join(root, "models.json"), JSON.stringify({ providers: { anthropic: { baseUrl: `http://127.0.0.1:${endpoint.port}` } } }));
    const runtime = await createProviderModelRuntime(root);
    const model = runtime.getModels("anthropic").find((candidate) => candidate.id === "claude-opus-5-5")!;
    await runtime.streamSimple(model, { messages: [{ role: "user", content: [{ type: "text", text: "Run echo ok." }], timestamp: 1 }] }).result();
    expect(endpoint.requests).toHaveLength(1);
    expect(endpoint.requests[0]!.headers["x-api-key"]).toBe("sk-ant-api03-tron-wire-test");
    expect(endpoint.requests[0]!.headers["user-agent"]).not.toMatch(/^claude-cli\//u);
  });
});
