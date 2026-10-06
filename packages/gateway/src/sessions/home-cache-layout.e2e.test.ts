import { createServer, type IncomingHttpHeaders, type Server } from "node:http";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { afterAll, afterEach, describe, expect, it } from "vitest";
import { SettingsService } from "../admin/settings-service.js";
import { TrustService } from "../admin/trust-service.js";
import type { GatewayConfig } from "../config.js";
import { ANTHROPIC_MAX_CACHE_BREAKPOINTS, cachePieces } from "../episodic/cache-layout.js";
import { createModelRuntimeSummarizer, EPISODIC_COMPACT_PROMPT } from "../episodic/episodic-compactor.js";
import { HOME_MEMORY_VIEW_MARKER } from "../home/home-memory.js";
import { HOME_NONCE_MARKER, type HomeRequestRecord } from "../home/home-request-policy.js";
import type { HomeStatus } from "../protocol/types.js";
import { CommandReceiptStore } from "../transport/command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../transport/gateway-service.js";
import { waitFor } from "../../test-support/wait-for.js";
import { RuntimeRegistry } from "./runtime-registry.js";

// Recipe §8 caching, proved on the wire (progress.md C1-C11): Home turns and the
// episodic summarizer's calls go through pi-ai's real Anthropic request builder
// to a local Anthropic-compatible endpoint that records every request body and
// header. Nothing here calls a real provider.

const PROVIDER = "local-anthropic";
const MODEL_ID = "opus-local";
const MODEL = { provider: PROVIDER, id: MODEL_ID };
const SUMMARY = (n: number) => `summary ${n} ${"s".repeat(470)}`.slice(0, 490);
const REPORT_PATH = "test-results/home-cache-layout/report.json";
const CACHE_READ = 7;
const client = { id: "terminal", identity: "device:home-cache", isLocal: false, unsubscribe: () => {} } as unknown as ClientContext;

interface Captured {
  kind: "home" | "summarizer" | "ordinary";
  body: Record<string, unknown>;
  headers: IncomingHttpHeaders;
}

type Block = { type: string; text?: string; cache_control?: unknown; content?: unknown };
type WireMessage = { role: string; content: Block[] | string };

const report: { generatedAt: string; cases: Array<Record<string, unknown>> } = { generatedAt: new Date().toISOString(), cases: [] };
const disposals: Array<() => Promise<void>> = [];
afterEach(async () => { for (const dispose of disposals.splice(0).reverse()) await dispose(); });
afterAll(async () => {
  await mkdir(join(process.cwd(), "test-results", "home-cache-layout"), { recursive: true });
  await writeFile(join(process.cwd(), REPORT_PATH), `${JSON.stringify(report, null, 2)}\n`);
  process.stdout.write(`home-cache-layout e2e: ${report.cases.length} cases -> ${REPORT_PATH}\n`);
});

/** A minimal Anthropic Messages endpoint: records each request, then streams one
 * text block, or the next scripted tool call for a Home turn. */
async function endpoint(): Promise<{ server: Server; port: number; requests: Captured[]; toolCalls: Array<{ name: string; input: unknown }> }> {
  const requests: Captured[] = [];
  const toolCalls: Array<{ name: string; input: unknown }> = [];
  let summaries = 0;
  const server = createServer((request, response) => {
    let raw = "";
    request.on("data", (chunk) => { raw += chunk; });
    request.on("end", () => {
      const body = JSON.parse(raw) as Record<string, unknown>;
      const system = JSON.stringify(body.system ?? "");
      const kind: Captured["kind"] = system.includes(EPISODIC_COMPACT_PROMPT.slice(0, 40)) ? "summarizer"
        : system.includes("## Tron Home") ? "home" : "ordinary";
      requests.push({ kind, body, headers: request.headers });
      const tool = kind === "home" ? toolCalls.shift() : undefined;
      const text = kind === "summarizer" ? SUMMARY(++summaries) : `reply ${requests.length} ${"r".repeat(900)}`;
      const event = (type: string, data: Record<string, unknown>) => `event: ${type}\ndata: ${JSON.stringify({ type, ...data })}\n\n`;
      // Summarizer calls report a fixed cache read, so the test can follow the
      // provider's own usage field through to Home's memory status.
      const usage = { input_tokens: 10, output_tokens: 5, cache_read_input_tokens: kind === "summarizer" ? CACHE_READ : 0,
        cache_creation_input_tokens: 0 };
      const block = tool
        ? event("content_block_start", { index: 0, content_block: { type: "tool_use", id: `toolu_${requests.length}`, name: tool.name, input: {} } })
          + event("content_block_delta", { index: 0, delta: { type: "input_json_delta", partial_json: JSON.stringify(tool.input) } })
        : event("content_block_start", { index: 0, content_block: { type: "text", text: "" } })
          + event("content_block_delta", { index: 0, delta: { type: "text_delta", text } });
      response.writeHead(200, { "content-type": "text/event-stream" });
      response.end(
        event("message_start", { message: { id: `msg_${requests.length}`, type: "message", role: "assistant", model: MODEL_ID,
          content: [], stop_reason: null, stop_sequence: null, usage } })
        + block
        + event("content_block_stop", { index: 0 })
        + event("message_delta", { delta: { stop_reason: tool ? "tool_use" : "end_turn", stop_sequence: null }, usage: { output_tokens: 5 } })
        + event("message_stop", {}),
      );
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return { server, port: (server.address() as AddressInfo).port, requests, toolCalls };
}

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "tron-home-cache-"));
  const local = await endpoint();
  disposals.push(async () => {
    await new Promise<void>((resolve) => local.server.close(() => resolve()));
    await rm(root, { recursive: true, force: true });
  });
  const agentDir = join(root, "agent");
  const tronHome = join(root, "tron");
  await mkdir(agentDir, { recursive: true });
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({ defaultProvider: PROVIDER, defaultModel: MODEL_ID }));
  // A models.json provider, as a maintainer configures a compatible endpoint;
  // session affinity puts each request's cache key on the wire.
  await writeFile(join(agentDir, "models.json"), JSON.stringify({ providers: { [PROVIDER]: {
    baseUrl: `http://127.0.0.1:${local.port}`, api: "anthropic-messages", apiKey: "local-test-key",
    compat: { sendSessionAffinityHeaders: true },
    models: [{ id: MODEL_ID, name: "Opus (local)", reasoning: false, input: ["text"], contextWindow: 1_000_000, maxTokens: 4_096 }],
  } } }));
  const runtime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath: join(agentDir, "models.json"), refreshOnCreate: false });
  const records: HomeRequestRecord[] = [];
  const registry = new RuntimeRegistry({
    agentDir, tronHome, idleRuntimeMs: 60_000,
    modelRuntimeFactory: async () => runtime,
    trust: new TrustService(agentDir),
    broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    // The production summarizer on the Gateway's runtime, as gateway-main wires it.
    homeMemorySummarizer: (model) => ({ summarizer: createModelRuntimeSummarizer(runtime, runtime.getModel(model.provider, model.id)!) }),
    homeRequestDiagnostic: (record) => records.push(record),
  });
  disposals.push(async () => { await registry.dispose(); });
  const service = new GatewayService({
    config: { tronHome } as unknown as GatewayConfig, modelRuntime: runtime, sessions: registry, home: registry.homeOwner(),
    receipts: new CommandReceiptStore(join(tronHome, "receipts")), settings: new SettingsService(agentDir, runtime),
    trust: new TrustService(agentDir), sessionDeleted: () => {}, uploads: { removeSession: async () => {} },
  } as unknown as GatewayServiceDependencies);
  await registry.initialize();
  return { ...local, registry, service, records, root };
}

function messagesOf(captured: Captured): WireMessage[] {
  return captured.body.messages as WireMessage[];
}

function cacheMarks(captured: Captured): string[] {
  const found: string[] = [];
  const visit = (value: unknown, path: string) => {
    if (Array.isArray(value)) value.forEach((item, index) => visit(item, `${path}[${index}]`));
    else if (value && typeof value === "object") {
      for (const [key, field] of Object.entries(value)) key === "cache_control" ? found.push(path) : visit(field, `${path}.${key}`);
    }
  };
  visit(captured.body, "");
  return found;
}

function blocks(message: WireMessage): Block[] {
  return typeof message.content === "string" ? [{ type: "text", text: message.content }] : message.content;
}

describe.sequential("Tron Home prompt caching on the wire", () => {
  it("lays out Home turns and summarizer calls as the recipe's cached prefix", async () => {
    const f = await fixture();
    await f.service.invoke(client, "home.designate", { commandId: "cache-designate", model: MODEL });
    await f.service.invoke(client, "home.configureMemory", { commandId: "cache-memory", model: MODEL, tokenBudget: 100_000_000 });
    const status = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
    const home = await f.registry.acquire(status.sessionId!);

    // Each turn adds two summarized messages (~490 bytes each), so the view passes
    // the recipe's first 50,000-character mark after about 55 turns.
    const TURNS = 62;
    for (let turn = 0; turn < TURNS; turn += 1) {
      await home.prompt(`input ${turn} ${"i".repeat(900)}`);
      await waitFor(() => !home.isBusy, `Home turn ${turn}`);
    }
    // A last turn with a tool step: the step must reuse the frozen view and keep the end mark.
    f.toolCalls.push({ name: "memory_search", input: { query: "reply" } });
    await home.prompt(`input ${TURNS} ${"i".repeat(900)}`);
    await waitFor(() => !home.isBusy, "the tool turn");

    const homeRequests = f.requests.filter((request) => request.kind === "home");
    const summarizer = f.requests.filter((request) => request.kind === "summarizer");
    // The turn before the tool turn, then the tool turn's two steps.
    const [previous, last, toolStep] = homeRequests.slice(-3);
    const memoryOf = (request: Captured) => blocks(messagesOf(request)[0]!);
    const lastMemory = memoryOf(last!);
    const viewPieces = lastMemory.slice(0, -1).map((block) => block.text ?? "");
    const view = viewPieces.join("");
    const lastMarks = cacheMarks(last!);

    // C1: the nonce is the memory message's last block, and appears nowhere else.
    expect(lastMemory.length).toBeGreaterThanOrEqual(2);
    expect(lastMemory.at(-1)!.text).toMatch(new RegExp(`^${HOME_NONCE_MARKER.replace(".", "\\.")}[0-9a-f-]{36}$`, "u"));
    expect(JSON.stringify(last!.body).split(HOME_NONCE_MARKER).length - 1).toBe(1);
    // C3: the view's pieces are exactly the recipe's cuts of the view.
    expect(viewPieces[0]!.startsWith(HOME_MEMORY_VIEW_MARKER)).toBe(true);
    expect(view.length).toBeGreaterThan(50_000);
    expect(viewPieces).toEqual(cachePieces(view));
    // C4 and C7: a mark on every cut, the request end marked, the budget kept.
    const cuts = viewPieces.length - 1;
    expect(cuts).toBeGreaterThanOrEqual(1);
    for (let index = 0; index < cuts; index += 1) expect(lastMarks).toContain(`.messages[0].content[${index}]`);
    expect(lastMarks).not.toContain(`.messages[0].content[${cuts}]`);
    const lastMessage = messagesOf(last!).length - 1;
    expect(lastMarks).toContain(`.messages[${lastMessage}].content[${blocks(messagesOf(last!)[lastMessage]!).length - 1}]`);
    expect(lastMarks.length).toBeLessThanOrEqual(ANTHROPIC_MAX_CACHE_BREAKPOINTS);
    // C2: consecutive turns send the same bytes up to the first cut.
    expect(memoryOf(previous!)[0]!.text).toBe(viewPieces[0]);
    expect(JSON.stringify(previous!.body.system)).toBe(JSON.stringify(last!.body.system));
    expect(JSON.stringify(previous!.body.tools)).toBe(JSON.stringify(last!.body.tools));
    // C11: the tool step reuses the frozen view and marks its own end.
    expect(memoryOf(toolStep!).map((block) => block.text)).toEqual(lastMemory.map((block) => block.text));
    expect(messagesOf(toolStep!).length).toBeGreaterThan(messagesOf(last!).length);
    const stepLast = messagesOf(toolStep!).length - 1;
    expect(cacheMarks(toolStep!)).toContain(`.messages[${stepLast}].content[${blocks(messagesOf(toolStep!)[stepLast]!).length - 1}]`);

    // C9: the summarizer's context comes first, cut at the same marks, under the
    // budget, and every call carries the memory's stable cache key.
    const longContext = summarizer.filter((request) => blocks(messagesOf(request)[0]!).length >= 3);
    expect(longContext.length).toBeGreaterThan(0);
    const sample = longContext.at(-1)!;
    const contextBlocks = blocks(messagesOf(sample)[0]!);
    const contextText = contextBlocks.slice(0, -1).map((block) => block.text ?? "").join("");
    expect(contextText.startsWith("<chat>\n")).toBe(true);
    expect(contextBlocks.slice(0, -1).map((block) => block.text)).toEqual(cachePieces(contextText));
    const sampleMarks = cacheMarks(sample);
    for (let index = 0; index < contextBlocks.length - 2; index += 1) expect(sampleMarks).toContain(`.messages[0].content[${index}]`);
    expect(sampleMarks.length).toBeLessThanOrEqual(ANTHROPIC_MAX_CACHE_BREAKPOINTS);
    expect(new Set(summarizer.map((request) => request.headers["x-session-affinity"]))).toEqual(new Set([`tron-episodic:${status.sessionId}`]));
    expect(f.records.filter((record) => record.event === "refused")).toEqual([]);
    const memory = (await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus).memory;
    expect(memory.episodic?.tokens.sinceOpen.cacheRead).toBe(CACHE_READ * summarizer.length);

    // C10: an ordinary session on the same endpoint keeps pi-ai's own layout.
    const ordinary = await f.registry.create(f.root);
    await ordinary.setModel(PROVIDER, MODEL_ID);
    await ordinary.prompt("an ordinary message");
    await waitFor(() => !ordinary.isBusy, "the ordinary turn");
    const plain = f.requests.filter((request) => request.kind === "ordinary").at(-1)!;
    const plainMarks = cacheMarks(plain);
    expect(plainMarks.every((path) => path.startsWith(".system") || path.startsWith(".tools")
      || path.startsWith(`.messages[${messagesOf(plain).length - 1}]`))).toBe(true);
    expect(JSON.stringify(plain.body)).not.toContain(HOME_MEMORY_VIEW_MARKER);

    report.cases.push({
      case: "wire-layout", homeTurns: homeRequests.length, summarizerCalls: summarizer.length,
      viewChars: view.length, viewPieces: viewPieces.map((piece) => piece.length), lastTurnMarks: lastMarks,
      summarizerContextPieces: contextBlocks.slice(0, -1).map((block) => (block.text ?? "").length), summarizerMarks: sampleMarks,
      ordinaryMarks: plainMarks,
    });
  }, 300_000);
});
