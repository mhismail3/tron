import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { mkdir, mkdtemp, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { afterEach, expect, it, vi } from "vitest";
import { createTestRegistry } from "../../../../test-support/gateway-registry.js";
import { waitFor } from "../../../../test-support/wait-for.js";
import { TrustService } from "../../../kernel/resources/trust-service.js";

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
  vi.unstubAllEnvs();
});

type Body = { system: Array<{ text: string }>; tools: Array<{ name: string }>; messages: Array<{ role: string; content: Array<{ type: string; text?: string }> | string }> };

const sse = (model: string, toolCall?: string) => [
  { type: "message_start", message: { id: "msg_frame", type: "message", role: "assistant", model, content: [], stop_reason: null,
    usage: { input_tokens: 4, output_tokens: 0, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 } } },
  ...(toolCall ? [
    { type: "content_block_start", index: 0, content_block: { type: "tool_use", id: "toolu_enable", name: toolCall, input: {} } },
    { type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: "{}" } },
    { type: "content_block_stop", index: 0 },
    { type: "message_delta", delta: { stop_reason: "tool_use" }, usage: { output_tokens: 1 } },
  ] : [
    { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
    { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "ok" } },
    { type: "content_block_stop", index: 0 },
    { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 1 } },
  ]),
  { type: "message_stop" },
].map(event => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join("");

const EXTENSION = `export default function(pi) {
  pi.registerTool({ name: "late_tool", label: "Late", description: "Enabled mid-run.", promptSnippet: "Late tool snippet",
    parameters: { type: "object", properties: {} }, execute: async () => ({ content: [{ type: "text", text: "late" }], details: {} }) });
  pi.registerTool({ name: "enable_late", label: "Enable", description: "Enables late_tool.",
    parameters: { type: "object", properties: {} },
    execute: async () => { pi.setActiveTools([...pi.getActiveTools(), "late_tool"]); return { content: [{ type: "text", text: "enabled" }], details: {} }; } });
  pi.on("session_start", () => pi.setActiveTools(pi.getActiveTools().filter(name => name !== "late_tool")));
}`;

const frameOf = (body: Body) => body.messages.flatMap(message => Array.isArray(message.content) ? message.content : [])
  .map(block => block.text).find((text): text is string => text?.startsWith("<turn-frame>") === true);

it("announces a tool enabled mid-run in the next turn frame without rewriting the system text or earlier tools", async () => {
  const root = await realpath(await mkdtemp(join(tmpdir(), "tron-turn-frame-")));
  cleanups.push(() => rm(root, { recursive: true, force: true }));
  const agentDir = join(root, "agent");
  const project = join(root, "project");
  await mkdir(join(agentDir, "extensions"), { recursive: true });
  await mkdir(project);
  await writeFile(join(agentDir, "extensions", "late.ts"), EXTENSION);
  vi.stubEnv("PI_CODING_AGENT_DIR", agentDir);
  vi.stubEnv("HOME", root);
  vi.stubEnv("PI_OFFLINE", "1");
  const bodies: Body[] = [];
  const server = createServer((request, response) => {
    let text = "";
    request.on("data", chunk => { text += String(chunk); });
    request.on("end", () => {
      const body = JSON.parse(text) as Body & { model: string };
      bodies.push(body);
      response.writeHead(200, { "content-type": "text/event-stream" }).end(sse(body.model, bodies.length === 1 ? "enable_late" : undefined));
    });
  });
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  cleanups.push(() => new Promise<void>(resolve => server.close(() => resolve())));
  const model = { provider: "turn-frame", id: "frame-model" };
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({ retry: { enabled: false }, compaction: { enabled: false } }));
  await writeFile(join(agentDir, "models.json"), JSON.stringify({ providers: { [model.provider]: {
    baseUrl: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, api: "anthropic-messages", apiKey: "fixture-only-not-a-credential",
    models: [{ id: model.id, name: "Frame fixture", reasoning: false, input: ["text"], contextWindow: 128000, maxTokens: 1024,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
  } } }));
  const registry = await createTestRegistry({
    agentDir, tronHome: join(root, "tron"), trust: new TrustService(agentDir), idleRuntimeMs: 60_000,
    modelRuntimeFactory: () => ModelRuntime.create({ modelsPath: join(agentDir, "models.json"), refreshOnCreate: false }),
    broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
  });
  cleanups.push(() => registry.dispose());
  await registry.initialize();
  const slot = await registry.create(project);
  await slot.setModel(model.provider, model.id);
  await slot.prompt("enable the late tool");
  await waitFor(() => !slot.isBusy && bodies.length === 2, "the two-request turn");

  const [first, second] = bodies as [Body, Body];
  const firstTools = first.tools.map(tool => tool.name);
  expect(firstTools).not.toContain("late_tool");
  const declaration = ({ cache_control: _mark, ...tool }: Body["tools"][number] & { cache_control?: unknown }) => tool;
  expect(second.tools.slice(0, -1).map(declaration)).toEqual(first.tools.map(declaration));
  expect(second.tools.at(-1)!.name).toBe("late_tool");
  expect(second.system).toEqual(first.system);
  const date = new Date();
  const today = `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
  const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;
  for (const body of bodies) expect(frameOf(body)).toContain(`Date: ${today} (${zone}).`);
  expect(frameOf(first)).not.toContain("Tools enabled:");
  expect(frameOf(second)).toContain("Tools enabled: late_tool.");
  expect(frameOf(second)).toContain(`Model: ${model.provider}/${model.id}.`);
}, 30_000);
