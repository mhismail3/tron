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
import { EPISODIC_DEFAULTS } from "../episodic/episodic-contract.js";
import { HOME_MEMORY_VIEW_MARKER } from "../home/home-memory.js";
import { HOME_NONCE_MARKER, type HomeRequestRecord } from "../home/home-request-policy.js";
import type { HomeStatus } from "../protocol/types.js";
import { CommandReceiptStore } from "../transport/command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../transport/gateway-service.js";
import { waitFor } from "../../test-support/wait-for.js";
import { RuntimeRegistry } from "./runtime-registry.js";

// Recipe §8 caching, proved on the wire (progress.md C1-C11; #491 R1-R8): Home
// turns and the episodic summarizer's calls go through pi-ai's real Anthropic
// request builder to a local Anthropic-compatible endpoint that records every
// request body and header. Nothing here calls a real provider.

const PROVIDER = "local-anthropic";
const MODEL_ID = "opus-local";
const MODEL = { provider: PROVIDER, id: MODEL_ID };
const SMALL_MODEL_ID = "small-local";
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
async function endpoint(responses = false): Promise<{ server: Server; port: number; requests: Captured[]; toolCalls: Array<{ name: string; input: unknown }> }> {
  const requests: Captured[] = [];
  const toolCalls: Array<{ name: string; input: unknown }> = [];
  let summaries = 0;
  const server = createServer((request, response) => {
    let raw = "";
    request.on("data", (chunk) => { raw += chunk; });
    request.on("end", () => {
      const body = JSON.parse(raw) as Record<string, unknown>;
      const system = JSON.stringify(body.system ?? body.input ?? "");
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
      if (responses) {
        const output = tool
          ? { type: "function_call", id: `fc_${requests.length}`, call_id: `call_${requests.length}`, name: tool.name, arguments: JSON.stringify(tool.input), status: "completed" }
          : { type: "message", id: `msg_${requests.length}`, role: "assistant", status: "completed", content: [{ type: "output_text", text, annotations: [] }] };
        response.writeHead(200, { "content-type": "text/event-stream" });
        response.end(
          event("response.output_item.added", { output_index: 0, item: output })
          + event("response.output_item.done", { output_index: 0, item: output })
          + event("response.completed", { response: { id: `resp_${requests.length}`, status: "completed", output: [output], usage: { input_tokens: 10, output_tokens: 5, total_tokens: 15, input_tokens_details: { cached_tokens: kind === "summarizer" ? CACHE_READ : 0 } } } }),
        );
        return;
      }
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

async function fixture(responses = false) {
  const root = await mkdtemp(join(tmpdir(), "tron-home-cache-"));
  const local = await endpoint(responses);
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
    baseUrl: `http://127.0.0.1:${local.port}`, api: responses ? "openai-responses" : "anthropic-messages", apiKey: "local-test-key",
    compat: { sendSessionAffinityHeaders: true },
    models: [
      { id: MODEL_ID, name: "Opus (local)", reasoning: false, input: ["text"], contextWindow: 1_000_000, maxTokens: 4_096 },
      // Too small for Home's request: an activation on it is refused before dispatch.
      { id: SMALL_MODEL_ID, name: "Small (local)", reasoning: false, input: ["text"], contextWindow: 4_096, maxTokens: 1_024 },
    ],
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

const memoryOf = (request: Captured) => blocks(messagesOf(request)[0]!);

/** The view blocks of one Home request: every memory block but the footer and the nonce. */
const viewBlocksOf = (request: Captured) => memoryOf(request).slice(0, -2).map((block) => block.text ?? "");

/** Every `cache_control.ttl` in one request; pi-ai writes "1h" only for long retention. */
function markTtls(captured: Captured): Set<string> {
  const ttls = new Set<string>();
  const visit = (value: unknown) => {
    if (Array.isArray(value)) value.forEach(visit);
    else if (value && typeof value === "object") {
      for (const [key, field] of Object.entries(value)) {
        if (key === "cache_control") ttls.add(String((field as { ttl?: unknown }).ttl ?? "5m"));
        else visit(field);
      }
    }
  };
  visit(captured.body);
  return ttls;
}

/** #491 R4, R7: the base block (header plus base lines), one block per later line, the footer. */
function expectViewLayout(pieces: string[]): void {
  expect(pieces[0]!.startsWith(HOME_MEMORY_VIEW_MARKER)).toBe(true);
  expect(pieces.at(-1)).toBe("</chat>");
  for (const piece of pieces.slice(1, -1)) expect(piece).toMatch(/^\d+\+\d+\|[^\n]*\n$/u);
  for (const piece of pieces.slice(0, -1)) expect(piece.endsWith("\n")).toBe(true);
}

/**
 * Anthropic's cache rule for the memory message (#491 R4): a request re-reads an
 * entry the previous request wrote at one of its marks when that mark's offset is
 * a block end of this request with the same text before it, within 20 blocks
 * before one of this request's marks. Home marks the first block and the last
 * line (`markHomeMemoryCache`). Returns the longest re-read offset, in characters.
 */
function anthropicReuse(previous: Captured, next: Captured): number {
  const ends = (texts: string[]) => texts.reduce<number[]>((acc, text) => [...acc, (acc.at(-1) ?? 0) + text.length], []);
  const marked = (texts: string[]) => [...new Set([0, texts.length - 1])];
  const before = viewBlocksOf(previous), after = viewBlocksOf(next);
  const beforeText = before.join(""), afterText = after.join("");
  const beforeEnds = ends(before), afterEnds = ends(after);
  let reused = 0;
  for (const mark of marked(before)) {
    const offset = beforeEnds[mark]!;
    const block = afterEnds.indexOf(offset);
    if (block < 0 || afterText.slice(0, offset) !== beforeText.slice(0, offset)) continue;
    if (marked(after).some((nextMark) => nextMark >= block && nextMark - block <= 20)) reused = Math.max(reused, offset);
  }
  return reused;
}

/** "extend" when the next request re-reads the previous request's whole view. */
function transition(previous: Captured, next: Captured): "extend" | "partial" | "rewrite" {
  const reused = anthropicReuse(previous, next);
  const whole = viewBlocksOf(previous).join("").length;
  return reused === whole ? "extend" : reused > 0 ? "partial" : "rewrite";
}

/** Bytes of the view text the next request shares with the previous one, from its start. */
function sharedViewBytes(previous: Captured, next: Captured): { shared: number; previous: number } {
  const a = viewBlocksOf(previous).join(""), b = viewBlocksOf(next).join("");
  let index = 0;
  while (index < a.length && index < b.length && a.charCodeAt(index) === b.charCodeAt(index)) index += 1;
  return { shared: Buffer.byteLength(a.slice(0, index)), previous: Buffer.byteLength(a) };
}

describe.sequential("Tron Home prompt caching on the wire", () => {
  it("OpenAI Responses preserves Home's stable prefix, tool loop and cache affinity", async () => {
    const f = await fixture(true);
    await f.service.invoke(client, "home.designate", { commandId: "responses-designate", model: MODEL });
    await f.service.invoke(client, "home.configureMemory", { commandId: "responses-memory", model: MODEL });
    const status = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
    const home = await f.registry.acquire(status.sessionId!);
    for (let turn = 0; turn < 3; turn += 1) {
      if (turn === 2) f.toolCalls.push({ name: "memory_search", input: { query: "reply" } });
      await home.prompt(`responses input ${turn} ${"i".repeat(900)}`);
      await waitFor(() => !home.isBusy, `Responses turn ${turn}`);
    }
    const requests = f.requests.filter((request) => request.kind === "home");
    expect(requests).toHaveLength(4);
    const [prior, activation, step] = requests.slice(-3).map((request) => request!.body);
    type Input = { role?: string; type?: string; content?: Array<{ text?: string }> };
    const input = (body: Record<string, unknown>) => body.input as Input[];
    const memory = (body: Record<string, unknown>) => input(body).find((message) => JSON.stringify(message).includes(HOME_MEMORY_VIEW_MARKER))!;
    const text = (message: Input) => message.content!.map((block) => block.text ?? "").join("");
    const view = (body: Record<string, unknown>) => text(memory(body)).split("</chat>")[0]!;
    expect(input(activation!)[0]!.role).toBe("system");
    expect(input(activation!)[1]).toEqual(memory(activation!));
    expect(input(activation!)[2]!.role).toBe("user");
    expect(JSON.stringify(input(activation!)[2])).toContain("responses input 2");
    expect(JSON.stringify(activation)).not.toContain("responses input 1");
    expect(view(activation!).startsWith(view(prior!))).toBe(true);
    expect(view(activation!).length).toBeGreaterThan(view(prior!).length);
    expect(text(memory(activation!))).toMatch(new RegExp(`</chat>${HOME_NONCE_MARKER.replace(".", "\\.")}[0-9a-f-]{36}$`, "u"));
    expect(memory(step!)).toEqual(memory(activation!));
    expect(input(step!).some((message) => message.type === "function_call_output")).toBe(true);
    expect(step!.tools).toEqual(activation!.tools);
    expect(input(step!)[0]).toEqual(input(activation!)[0]);
    expect(input(prior!)[0]).toEqual(input(activation!)[0]);
    expect(prior!.tools).toEqual(activation!.tools);
    const keys = requests.map((request) => request.body.prompt_cache_key);
    expect(typeof keys[0]).toBe("string");
    expect(String(keys[0]).length).toBeGreaterThan(0);
    expect(new Set(keys).size).toBe(1);
    expect(requests.every((request) => request.body.prompt_cache_retention === "24h")).toBe(true);
    const summaries = f.requests.filter((request) => request.kind === "summarizer");
    expect(summaries.length).toBeGreaterThan(0);
    expect(new Set(summaries.map((request) => request.body.prompt_cache_key))).toEqual(new Set([`tron-episodic:${status.homeId}`]));
    expect(summaries.every((request) => request.body.prompt_cache_retention === "24h")).toBe(true);
    expect(f.records.filter((record) => record.event === "refused")).toEqual([]);
    report.cases.push({ case: "openai-responses", requests: requests.map((request) => request.body), summarizerCalls: summaries.length });
  }, 60_000);

  it("lays out Home turns and summarizer calls as the recipe's cached prefix", async () => {
    const f = await fixture();
    await f.service.invoke(client, "home.designate", { commandId: "cache-designate", model: MODEL });
    await f.service.invoke(client, "home.configureMemory", { commandId: "cache-memory", model: MODEL });
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
    const lastMemory = memoryOf(last!);
    const viewPieces = lastMemory.slice(0, -1).map((block) => block.text ?? "");
    const view = viewPieces.join("");
    const lastMarks = cacheMarks(last!);

    // C1: the nonce is the memory message's last block, and appears nowhere else.
    expect(lastMemory.length).toBeGreaterThanOrEqual(2);
    expect(lastMemory.at(-1)!.text).toMatch(new RegExp(`^${HOME_NONCE_MARKER.replace(".", "\\.")}[0-9a-f-]{36}$`, "u"));
    expect(JSON.stringify(last!.body).split(HOME_NONCE_MARKER).length - 1).toBe(1);
    // C3 (#491 R4, R7): the base block, then one block per line since it, then the
    // footer: they rejoin to the view text exactly as the model reads it.
    expect(view.length).toBeGreaterThan(50_000);
    expectViewLayout(viewPieces);
    // C4 and C7 (#491 R4-R6): marks on the base and on the last line, none on the
    // footer or the nonce, the request end marked, the limit kept, every mark long-lived.
    const lastLine = lastMemory.length - 3;
    expect(lastMarks).toContain(".messages[0].content[0]");
    expect(lastMarks).toContain(`.messages[0].content[${lastLine}]`);
    expect(lastMarks).not.toContain(`.messages[0].content[${lastMemory.length - 2}]`);
    expect(lastMarks).not.toContain(`.messages[0].content[${lastMemory.length - 1}]`);
    const lastMessage = messagesOf(last!).length - 1;
    expect(lastMarks).toContain(`.messages[${lastMessage}].content[${blocks(messagesOf(last!)[lastMessage]!).length - 1}]`);
    expect(lastMarks.length).toBeLessThanOrEqual(ANTHROPIC_MAX_CACHE_BREAKPOINTS);
    expect(markTtls(last!)).toEqual(new Set(["1h"]));
    // C2 (#491 R4): the previous turn's view is a block prefix of this one, with
    // its end within Anthropic's 20-block lookback of this request's end mark.
    expect(transition(previous!, last!)).toBe("extend");
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
    // #491 R6: the summarizer's calls ask for long retention too.
    expect(markTtls(sample)).toEqual(new Set(["1h"]));
    expect(new Set(summarizer.map((request) => request.headers["x-session-affinity"]))).toEqual(new Set([`tron-episodic:${status.homeId}`]));
    expect(f.records.filter((record) => record.event === "refused")).toEqual([]);
    // The memory keeps building merges after the last turn. A tree over N
    // messages is complete at exactly sum(floor(N / 2^l)) nodes, and nothing can
    // start after that, so the count and the usage are read at that end state.
    const statusOf = async () => (await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus).memory.episodic!;
    const complete = (messages: number) => { let total = 0; for (let span = 1; span <= messages; span *= 2) total += Math.floor(messages / span); return total; };
    await waitFor(async () => {
      const episodic = await statusOf();
      return episodic.pump.busy === 0 && episodic.nodes.total === complete(episodic.messages);
    }, "the memory's tree to complete");
    const settled = await statusOf();
    const settledCalls = f.requests.filter((request) => request.kind === "summarizer").length;
    expect(settled.tokens.sinceOpen.cacheRead).toBe(CACHE_READ * settledCalls);

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
    // #491 R6: only Home asks for long retention; an ordinary session keeps pi-ai's default.
    expect(markTtls(plain)).toEqual(new Set(["5m"]));

    report.cases.push({
      case: "wire-layout", homeTurns: homeRequests.length, summarizerCalls: summarizer.length,
      viewChars: view.length, viewPieces: viewPieces.map((piece) => piece.length), lastTurnMarks: lastMarks,
      summarizerContextPieces: contextBlocks.slice(0, -1).map((block) => (block.text ?? "").length), summarizerMarks: sampleMarks,
      ordinaryMarks: plainMarks,
    });
  }, 300_000);

  // #491 R1-R7 at scale: past the view budget, the view's head changes only once
  // per batch, and every other turn extends the previous turn's cached view.
  it("keeps Home's cached view across turns past the view budget", async () => {
    const f = await fixture();
    await f.service.invoke(client, "home.designate", { commandId: "budget-designate", model: MODEL });
    await f.service.invoke(client, "home.configureMemory", { commandId: "budget-memory", model: MODEL });
    const status = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
    const home = await f.registry.acquire(status.sessionId!);
    // About 1 KB of summaries per turn: the 128,000-byte view fills near turn 125.
    const TURNS = 210;
    for (let turn = 0; turn < TURNS; turn += 1) {
      await home.prompt(`input ${turn} ${"i".repeat(900)}`);
      await waitFor(() => !home.isBusy, `Home turn ${turn}`);
    }
    const turns = f.requests.filter((request) => request.kind === "home");
    expect(turns.length).toBe(TURNS);
    const steps = turns.slice(1).map((next, index) => {
      const previous = turns[index]!;
      const { shared, previous: size } = sharedViewBytes(previous, next);
      // A rewrite is any change before the previous view's end: a rebalance,
      // wherever its merges landed. Everything else only appended.
      return { turn: index + 1, kind: transition(previous, next), shared, size, rewrite: shared < size };
    });
    // The budget was passed: a view at least half the budget was rebalanced.
    const firstRewrite = steps.find((step) => step.rewrite && step.size >= EPISODIC_DEFAULTS.viewBytes / 2);
    expect(firstRewrite, "the view never reached its budget").toBeDefined();
    const past = steps.filter((step) => step.turn >= firstRewrite!.turn);
    const rewrites = past.filter((step) => step.rewrite);
    // R1, R2: one rewrite per rebalance, and a rebalance leaves room for many turns.
    expect(past.length).toBeGreaterThanOrEqual(60);
    expect(rewrites.length, JSON.stringify(rewrites.map((step) => ({ turn: step.turn, shared: step.shared, size: step.size }))))
      .toBeLessThanOrEqual(Math.ceil(past.length / 8));
    // R4: every turn that is not a rebalance extends the previous turn's blocks
    // within Anthropic's lookback, so its marked end is found again.
    for (const step of past) if (!step.rewrite) expect(step.kind, `turn ${step.turn}`).toBe("extend");
    // R7: the layout holds at every size.
    for (const request of turns.slice(-3)) expectViewLayout(memoryOf(request).slice(0, -1).map((block) => block.text ?? ""));
    report.cases.push({
      case: "past-budget", turns: turns.length, firstRewrite: firstRewrite!.turn, turnsPast: past.length,
      rewrites: rewrites.map((step) => ({ turn: step.turn, sharedBytes: step.shared, previousBytes: step.size })),
      transitions: past.reduce<Record<string, number>>((counts, step) => ({ ...counts, [step.kind]: (counts[step.kind] ?? 0) + 1 }), {}),
      lastViewBytes: Buffer.byteLength(viewBlocksOf(turns.at(-1)!).join("")),
    });
  }, 900_000);

  // #491 R9 (review): a refused activation sends nothing, so it must not move the
  // view the next request continues from.
  it("keeps the cached view's end across an activation refused before dispatch", async () => {
    const f = await fixture();
    await f.service.invoke(client, "home.designate", { commandId: "refused-designate", model: MODEL });
    await f.service.invoke(client, "home.configureMemory", { commandId: "refused-memory", model: MODEL });
    const status = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
    const home = await f.registry.acquire(status.sessionId!);
    for (let turn = 0; turn < 3; turn += 1) {
      await home.prompt(`input ${turn} ${"i".repeat(900)}`);
      await waitFor(() => !home.isBusy, `Home turn ${turn}`);
    }
    const sent = f.requests.filter((request) => request.kind === "home").at(-1)!;
    await home.setModel(PROVIDER, SMALL_MODEL_ID);
    await home.prompt(`refused input ${"i".repeat(900)}`);
    await waitFor(() => !home.isBusy, "the refused turn");
    expect(f.records.filter((record) => record.event === "refused").map((record) => record.reason)).toContain("context-overflow");
    expect(f.requests.filter((request) => request.kind === "home").at(-1)).toBe(sent);
    await home.setModel(PROVIDER, MODEL_ID);
    await home.prompt(`input after ${"i".repeat(900)}`);
    await waitFor(() => !home.isBusy, "the turn after the refusal");
    const next = f.requests.filter((request) => request.kind === "home").at(-1)!;
    expect(next).not.toBe(sent);
    expect(transition(sent, next)).toBe("extend");
  }, 300_000);
});
