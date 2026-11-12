import { displayOwnerOf, createTestRegistry, homeOwnerOf } from "../../../test-support/gateway-registry.js";
import { createServer, type IncomingHttpHeaders, type Server, type ServerResponse } from "node:http";
import { settingsDependencies } from "../../../test-support/settings-dependencies.js";
import { homeMemoryChange } from "../../../test-support/session-settings-change.js";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { afterAll, afterEach, describe, expect, it, vi } from "vitest";
import { TrustService } from "../../kernel/resources/trust-service.js";
import type { GatewayConfig } from "../../config.js";
import { ANTHROPIC_MAX_CACHE_BREAKPOINTS, VIEW_BLOCK_LINES } from "../../episodic/cache-layout.js";
import { EPISODIC_COMPACT_PROMPT } from "../../episodic/episodic-compactor.js";
import { EPISODIC_DEFAULTS } from "../../episodic/episodic-contract.js";
import { HOME_MEMORY_VIEW_MARKER } from "../../modules/home/home-memory.js";
import { HOME_NONCE_MARKER, markHomeMemoryCache, type HomeRequestRecord } from "../../modules/home/home-request-policy.js";
import type { HomeStatus } from "../../protocol/types.js";
import type { RequestRecord } from "../../kernel/run/request-record.js";
import { CommandReceiptStore } from "../../transport/command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../../transport/gateway-service.js";
import { awaitsWithin, waitFor } from "../../../test-support/wait-for.js";

const PROVIDER = "local-anthropic";
const MODEL_ID = "opus-local";
const MODEL = { provider: PROVIDER, id: MODEL_ID };
const SMALL_MODEL_ID = "small-local";
const SUMMARY = (n: number) => `summary ${n} ${"s".repeat(470)}`.slice(0, 490);
const REPORT_PATH = "test-results/home-cache-layout/report.json";
const CACHE_READ = 7;
const CACHE_WRITE = 11;
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

const HELD_REQUEST = "hold this request open";
const METERED_WINDOW = 120_000;

function providerCount(body: Record<string, unknown>): number {
  const messages = body.messages as WireMessage[];
  const view = blocks(messages[0]!).map((block) => block.text ?? "").join("");
  const memory = view.startsWith(HOME_MEMORY_VIEW_MARKER);
  const rest = JSON.stringify([body.tools, body.system, memory ? messages.slice(1) : messages]);
  return Math.ceil((memory ? Buffer.byteLength(view) : 0) / 2 + Buffer.byteLength(rest) / 2.8);
}

async function endpoint(responses = false, metered = false): Promise<{ server: Server; port: number; requests: Captured[]; toolCalls: Array<{ name: string; input: unknown }>; held: ServerResponse[] }> {
  const requests: Captured[] = [];
  const toolCalls: Array<{ name: string; input: unknown }> = [];
  const held: ServerResponse[] = [];
  let summaries = 0;
  const server = createServer((request, response) => {
    let raw = "";
    request.setEncoding("utf8");
    request.on("data", (chunk) => { raw += chunk; });
    request.on("end", () => {
      const body = JSON.parse(raw) as Record<string, unknown>;
      const system = JSON.stringify(body.system ?? body.input ?? "");
      const kind: Captured["kind"] = system.includes(EPISODIC_COMPACT_PROMPT.slice(0, 40)) ? "summarizer"
        : system.includes("## Tron Home") ? "home" : "ordinary";
      requests.push({ kind, body, headers: request.headers });
      if (raw.includes(HELD_REQUEST)) return void held.push(response);
      const tool = kind === "home" ? toolCalls.shift() : undefined;
      const text = kind === "summarizer" ? SUMMARY(++summaries) : `reply ${requests.length} ${"r".repeat(900)}`;
      const event = (type: string, data: Record<string, unknown>) => `event: ${type}\ndata: ${JSON.stringify({ type, ...data })}\n\n`;
      const usage = { input_tokens: metered && kind === "home" ? providerCount(body) : 10, output_tokens: 5, cache_read_input_tokens: kind === "summarizer" ? CACHE_READ : 0,
        cache_creation_input_tokens: kind === "home" && !metered ? CACHE_WRITE : 0 };
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
  return { server, port: (server.address() as AddressInfo).port, requests, toolCalls, held };
}

async function fixture(responses = false, metered = false) {
  const root = await mkdtemp(join(tmpdir(), "tron-home-cache-"));
  const local = await endpoint(responses, metered);
  disposals.push(async () => {
    for (const response of local.held) response.destroy();
    await new Promise<void>((resolve) => local.server.close(() => resolve()));
    await rm(root, { recursive: true, force: true });
  });
  const agentDir = join(root, "agent");
  const tronHome = join(root, "tron");
  await mkdir(agentDir, { recursive: true });
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({ defaultProvider: PROVIDER, defaultModel: MODEL_ID }));
  await writeFile(join(agentDir, "models.json"), JSON.stringify({ providers: { [PROVIDER]: {
    baseUrl: `http://127.0.0.1:${local.port}`, api: responses ? "openai-responses" : "anthropic-messages", apiKey: "local-test-key",
    compat: { sendSessionAffinityHeaders: true },
    models: [
      { id: MODEL_ID, name: "Opus (local)", reasoning: false, input: ["text"], contextWindow: metered ? METERED_WINDOW : 1_000_000, maxTokens: 4_096 },
      { id: SMALL_MODEL_ID, name: "Small (local)", reasoning: false, input: ["text"], contextWindow: 4_096, maxTokens: 1_024 },
    ],
  } } }));
  const runtime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath: join(agentDir, "models.json"), refreshOnCreate: false });
  const records: HomeRequestRecord[] = [];
  const requestRecords: RequestRecord[] = [];
  const configurations: Array<{ sessionId: string; blocker: unknown }> = [];
  let settings: ReturnType<typeof settingsDependencies> | undefined;
  const registry = await createTestRegistry({ agentDir, tronHome, idleRuntimeMs: 60_000,
    settings: () => settings ? { model: settings.settingsModel, changes: settings.settingsChanges } : undefined,
    modelRuntimeFactory: async () => runtime,
    trust: new TrustService(agentDir),
    broadcast: (sessionId: string, topic: string, payload: unknown) => {
      if (topic === "session.configuration") configurations.push({ sessionId, blocker: (payload as { data: { configurationBlocker: unknown } }).data.configurationBlocker });
    },
    sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    gatewayModelRuntime: runtime,
    homeRequestDiagnostic: (record) => records.push(record),
    requestRecord: (record) => requestRecords.push(record),
  });
  disposals.push(async () => { await registry.dispose(); });
  const service = new GatewayService({ display: displayOwnerOf(registry),
    config: { tronHome } as unknown as GatewayConfig, modelRuntime: runtime, sessions: registry, home: homeOwnerOf(registry),
    receipts: new CommandReceiptStore(join(tronHome, "receipts")),
    broadcast: () => {},
    ...(settings = settingsDependencies({ agentDir, tronHome, trust: new TrustService(agentDir), modelRuntime: runtime, sessions: registry, home: () => homeOwnerOf(registry), registry })),
    trust: new TrustService(agentDir), sessionDeleted: () => {}, uploads: { removeSession: async () => {} },
  } as unknown as GatewayServiceDependencies);
  await settings.settingsChanges.start();
  await registry.initialize();
  return { ...local, registry, service, records, requestRecords, root, configurations };
}

async function settledTurn(f: { configurations: Array<{ sessionId: string; blocker: unknown }> },
  slot: { id: string; prompt(text: string): Promise<unknown> }, text: string, label: string): Promise<void> {
  const cut = f.configurations.length;
  await slot.prompt(text);
  await waitFor(() => {
    const published = f.configurations.slice(cut).filter((entry) => entry.sessionId === slot.id);
    return published.some((entry) => entry.blocker !== null) && published.at(-1)?.blocker === null;
  }, label);
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

const viewBlocksOf = (request: Captured) => memoryOf(request).slice(0, -2).map((block) => block.text ?? "");

function lifetimes(captured: Captured): string[] {
  return wireBlocks(captured).flatMap((block) => block.ttl === undefined ? [] : [block.ttl]);
}

function expectViewLayout(pieces: string[]): void {
  expect(pieces[0]!.startsWith(HOME_MEMORY_VIEW_MARKER)).toBe(true);
  expect(pieces[0]!.endsWith("<chat>\n")).toBe(true);
  expect(pieces.at(-1)).toBe("</chat>");
  const groups = pieces.slice(1, -1);
  groups.forEach((piece, index) => {
    expect(piece).toMatch(/^(?:\d+\+\d+\|[^\n]*\n)+$/u);
    const lines = piece.split("\n").length - 1;
    if (index < groups.length - 1) expect(lines).toBe(VIEW_BLOCK_LINES);
    else expect(lines).toBeLessThanOrEqual(VIEW_BLOCK_LINES);
  });
}

function wireBlocks(captured: Captured): Array<{ path: string; json: string; marked: boolean; ttl?: string }> {
  const out: Array<{ path: string; json: string; marked: boolean; ttl?: string }> = [];
  const add = (path: string, block: unknown) => {
    const { cache_control: control, ...rest } = block as Record<string, unknown>;
    out.push({ path, json: JSON.stringify(rest), marked: control !== undefined,
      ...(control === undefined ? {} : { ttl: String((control as { ttl?: unknown }).ttl ?? "5m") }) });
  };
  for (const key of ["tools", "system"] as const) {
    const list = captured.body[key];
    if (Array.isArray(list)) list.forEach((block, index) => add(`.${key}[${index}]`, block));
  }
  messagesOf(captured).forEach((message, index) => blocks(message).forEach((block, at) => add(`.messages[${index}].content[${at}]`, block)));
  return out;
}

function prefixHashes(list: ReadonlyArray<{ json: string }>): string[] {
  const hash = createHash("sha256");
  return list.map(({ json }) => { hash.update(json); return hash.copy().digest("hex"); });
}

function reread(previous: Captured, next: Captured): string | undefined {
  const before = wireBlocks(previous), after = wireBlocks(next);
  const written = new Set(prefixHashes(before).filter((_hash, index) => before[index]!.marked));
  const hashes = prefixHashes(after);
  let deepest = -1;
  after.forEach((block, index) => {
    if (!block.marked) return;
    for (let at = index; at >= 0 && at > index - 20; at -= 1) {
      if (written.has(hashes[at]!)) { deepest = Math.max(deepest, at); return; }
    }
  });
  return deepest < 0 ? undefined : after[deepest]!.path;
}

const recordedIdentity = new Map<string, string>();
const wireIdentity = new Map<string, string>();

function expectRecordOfWire(record: RequestRecord, captured: Captured): void {
  const units: Array<{ path: string; json: string; ttl?: string }> = [];
  const add = (path: string, unit: unknown) => {
    const { cache_control: control, ...rest } = unit as Record<string, unknown>;
    units.push({ path, json: JSON.stringify(rest), ...(control === undefined ? {} : { ttl: String((control as { ttl?: unknown }).ttl ?? "5m") }) });
  };
  for (const key of ["tools", "system"] as const) (captured.body[key] as unknown[]).forEach((unit, index) => add(`.${key}[${index}]`, unit));
  (captured.body.messages as Array<Record<string, unknown>>).forEach((message, index) => {
    if (!Array.isArray(message.content)) return add(`.messages[${index}]`, message);
    const { content, ...envelope } = message;
    add(`.messages[${index}]`, envelope);
    (content as unknown[]).forEach((block, at) => add(`.messages[${index}].content[${at}]`, block));
  });
  const hashes = prefixHashes(units);
  const sizes = units.map((_unit, index) => units.slice(0, index + 1).reduce((bytes, unit) => bytes + Buffer.byteLength(unit.json), 0));
  const same = (recorded: { bytes: number; hash: string } | undefined, at: number) => {
    expect(recorded?.bytes).toBe(sizes[at]);
    expect(recorded!.hash).toMatch(/^[0-9a-f]{16}$/u);
    expect(recordedIdentity.get(hashes[at]!) ?? recorded!.hash, "one sent prefix has one recorded hash").toBe(recorded!.hash);
    expect(wireIdentity.get(recorded!.hash) ?? hashes[at], "one recorded hash names one sent prefix").toBe(hashes[at]);
    recordedIdentity.set(hashes[at]!, recorded!.hash);
    wireIdentity.set(recorded!.hash, hashes[at]!);
  };
  const end = (prefix: string) => units.reduce((last, unit, index) => unit.path.startsWith(prefix) ? index : last, -1);
  const marked = units.flatMap((unit, index) => unit.ttl === undefined ? [] : [{ at: unit.path, ttl: unit.ttl, index }]);
  expect(marked.length).toBeGreaterThan(0);
  expect(record.marks.map(({ at, ttl }) => ({ at, ttl }))).toEqual(marked.map(({ at, ttl }) => ({ at, ttl })));
  marked.forEach((mark, index) => same(record.marks[index], mark.index));
  same(record.tools, end(".tools"));
  expect(record.system).toHaveLength((captured.body.system as unknown[]).length);
  same(record.system.at(-1), end(".system"));
  same(record.request, units.length - 1);
  const { tools: _tools, system: _system, messages: _messages, ...params } = captured.body;
  expect(record.params.bytes).toBe(Buffer.byteLength(JSON.stringify(Object.fromEntries(Object.entries(params).sort(([left], [right]) => left < right ? -1 : 1)))));
}

function viewMarks(captured: Captured): string[] {
  return wireBlocks(captured).filter((block) => block.marked && block.path.startsWith(".messages[0].")).map((block) => block.path);
}

function transition(previous: Captured, next: Captured): "extend" | "partial" | "rewrite" {
  const mark = viewMarks(previous).at(-1);
  const read = reread(previous, next);
  if (mark !== undefined && read === mark) return "extend";
  return read?.startsWith(".messages[0].") ? "partial" : "rewrite";
}

function sharedViewBlocks(previous: Captured, next: Captured): number {
  const a = viewBlocksOf(previous), b = viewBlocksOf(next);
  let index = 0;
  while (index < a.length && index < b.length && a[index] === b[index]) index += 1;
  return index;
}

function sharedViewBytes(previous: Captured, next: Captured): { shared: number; previous: number } {
  const a = viewBlocksOf(previous).join(""), b = viewBlocksOf(next).join("");
  let index = 0;
  while (index < a.length && index < b.length && a.charCodeAt(index) === b.charCodeAt(index)) index += 1;
  return { shared: Buffer.byteLength(a.slice(0, index)), previous: Buffer.byteLength(a) };
}

describe("Tron Home prompt caching on the wire", { concurrent: false }, () => {
  it("OpenAI Responses preserves Home's stable prefix, tool loop and cache affinity", async () => {
    const f = await fixture(true);
    await f.service.invoke(client, "home.designate", { commandId: "responses-designate", model: MODEL });
    await f.service.invoke(client, "settings.change", homeMemoryChange({ commandId: "responses-memory", model: MODEL }));
    const status = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
    const home = await f.registry.acquire(status.sessionId!);
    for (let turn = 0; turn < 3; turn += 1) {
      if (turn === 2) f.toolCalls.push({ name: "memory_search", input: { query: "reply" } });
      await settledTurn(f, home, `responses input ${turn} ${"i".repeat(900)}`, `Responses turn ${turn}`);
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

  it("lays out Home turns as the recipe's cached prefix and sends summarizer steps alone", async () => {
    const f = await fixture();
    await f.service.invoke(client, "home.designate", { commandId: "cache-designate", model: MODEL });
    await f.service.invoke(client, "settings.change", homeMemoryChange({ commandId: "cache-memory", model: MODEL }));
    const status = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
    const home = await f.registry.acquire(status.sessionId!);

    const TURNS = 62;
    for (let turn = 0; turn < TURNS; turn += 1) {
      await settledTurn(f, home, `input ${turn} ${"i".repeat(900)}`, `Home turn ${turn}`);
    }
    f.toolCalls.push({ name: "memory_search", input: { query: "reply" } });
    await settledTurn(f, home, `input ${TURNS} ${"i".repeat(900)}`, "the tool turn");

    const homeRequests = f.requests.filter((request) => request.kind === "home");
    const summarizer = f.requests.filter((request) => request.kind === "summarizer");
    const [previous, last, toolStep] = homeRequests.slice(-3);
    const lastMemory = memoryOf(last!);
    const viewPieces = lastMemory.slice(0, -1).map((block) => block.text ?? "");
    const view = viewPieces.join("");
    const lastMarks = cacheMarks(last!);

    expect(lastMemory.length).toBeGreaterThanOrEqual(2);
    expect(lastMemory.at(-1)!.text).toMatch(new RegExp(`^${HOME_NONCE_MARKER.replace(".", "\\.")}[0-9a-f-]{36}$`, "u"));
    expect(JSON.stringify(last!.body).split(HOME_NONCE_MARKER).length - 1).toBe(1);
    const previousBlocks = wireBlocks(previous!), lastBlocks = wireBlocks(last!);
    const previousMark = previousBlocks.findIndex((block) => block.path === viewMarks(previous!).at(-1));
    expect(previousMark).toBeGreaterThanOrEqual(0);
    expect(lastBlocks.slice(0, previousMark + 1).map((block) => block.json)).toEqual(previousBlocks.slice(0, previousMark + 1).map((block) => block.json));
    expect(transition(previous!, last!)).toBe("extend");
    expect(view.length).toBeGreaterThan(50_000);
    expectViewLayout(viewPieces);
    const lastGroup = lastMemory.length - 3;
    const viewMarkAt = (lastMemory[lastGroup]!.text ?? "").split("\n").length - 1 === VIEW_BLOCK_LINES ? lastGroup : lastGroup - 1;
    expect(viewMarks(last!)).toEqual([`.messages[0].content[${viewMarkAt}]`]);
    expect(homeRequests.slice(0, 3).map(viewMarks)).toEqual([[".messages[0].content[0]"], [".messages[0].content[0]"], [".messages[0].content[1]"]]);
    const prepended = structuredClone(last!.body) as { messages: Array<{ content: Block[] }> };
    for (const block of prepended.messages[0]!.content) delete block.cache_control;
    prepended.messages[0]!.content.unshift({ type: "text", text: "provider prompt block", cache_control: { type: "ephemeral", ttl: "1h" } });
    const remarked = markHomeMemoryCache(prepended) as { messages: Array<{ content: Block[] }> };
    expect(remarked.messages[0]!.content.flatMap((block, index) => block.cache_control ? [index] : [])).toEqual([0, viewMarkAt + 1]);
    const lastMessage = messagesOf(last!).length - 1;
    expect(lastMarks).toContain(`.messages[${lastMessage}].content[${blocks(messagesOf(last!)[lastMessage]!).length - 1}]`);
    expect(lastMarks.length).toBeLessThanOrEqual(ANTHROPIC_MAX_CACHE_BREAKPOINTS);
    expect(lifetimes(last!)).toEqual(["1h", "1h", "1h", "5m"]);
    expect(wireBlocks(last!).findLast((block) => block.marked)!.path).toBe(`.messages[${lastMessage}].content[${blocks(messagesOf(last!)[lastMessage]!).length - 1}]`);
    expect(JSON.stringify(previous!.body.system)).toBe(JSON.stringify(last!.body.system));
    expect(JSON.stringify(previous!.body.tools)).toBe(JSON.stringify(last!.body.tools));
    expect(memoryOf(toolStep!).map((block) => block.text)).toEqual(lastMemory.map((block) => block.text));
    expect(messagesOf(toolStep!).length).toBeGreaterThan(messagesOf(last!).length);
    const stepLast = messagesOf(toolStep!).length - 1;
    expect(cacheMarks(toolStep!).length).toBeLessThanOrEqual(ANTHROPIC_MAX_CACHE_BREAKPOINTS);
    expect(viewMarks(toolStep!)).toEqual(viewMarks(last!));
    expect(cacheMarks(toolStep!)).toContain(`.messages[${stepLast}].content[${blocks(messagesOf(toolStep!)[stepLast]!).length - 1}]`);
    expect(lifetimes(toolStep!)).toEqual(["1h", "1h", "1h", "5m"]);
    expect(wireBlocks(toolStep!).findLast((block) => block.marked)!.path).toBe(`.messages[${stepLast}].content[${blocks(messagesOf(toolStep!)[stepLast]!).length - 1}]`);

    expect(summarizer.length).toBeGreaterThan(0);
    for (const request of summarizer) {
      const first = blocks(messagesOf(request)[0]!);
      expect(first).toHaveLength(1);
      expect(first[0]!.text).toMatch(/^(?:Compress this message|Merge these two lines) into one/u);
      expect(JSON.stringify(request.body)).not.toContain(HOME_MEMORY_VIEW_MARKER);
    }
    const sample = summarizer.at(-1)!;
    const sampleMarks = cacheMarks(sample);
    expect(sampleMarks.length).toBeLessThanOrEqual(ANTHROPIC_MAX_CACHE_BREAKPOINTS);
    expect(new Set(lifetimes(sample))).toEqual(new Set(["1h"]));
    expect(new Set(summarizer.map((request) => request.headers["x-session-affinity"]))).toEqual(new Set([`tron-episodic:${status.homeId}`]));
    expect(f.records.filter((record) => record.event === "refused")).toEqual([]);
    expect(f.records.filter((record) => record.event === "usage"), "a usage of 21 tokens is not a plausible count of these requests").toEqual([]);
    const statusOf = async () => (await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus).memory.episodic!;
    await waitFor(async () => (await statusOf()).view.unbuilt === 0, "the memory view to complete");
    await f.service.invoke(client, "home.pauseMemory", { commandId: "cache-freeze-usage" });
    await waitFor(async () => (await statusOf()).pump.busy === 0, "accepted compactor calls to settle");
    const settled = await statusOf();
    expect(settled.blocked).toBeNull();
    expect(settled.view.unbuilt).toBe(0);
    const settledCalls = f.requests.filter((request) => request.kind === "summarizer").length;
    expect(settled.tokens.sinceOpen.cacheRead).toBe(CACHE_READ * settledCalls);

    const ordinary = await f.registry.create(f.root);
    await ordinary.setModel(PROVIDER, MODEL_ID);
    await ordinary.prompt("an ordinary message");
    await waitFor(() => ordinary.snapshot().configurationBlocker === null, "the ordinary turn");
    const plain = f.requests.filter((request) => request.kind === "ordinary").at(-1)!;
    const plainMarks = cacheMarks(plain);
    expect(plainMarks.every((path) => path.startsWith(".system") || path.startsWith(".tools")
      || path.startsWith(`.messages[${messagesOf(plain).length - 1}]`))).toBe(true);
    expect(JSON.stringify(plain.body)).not.toContain(HOME_MEMORY_VIEW_MARKER);
    expect(new Set(lifetimes(plain))).toEqual(new Set(["5m"]));

    const homeRecords = f.requestRecords.filter((record) => record.sessionId === home.id);
    expect(homeRecords).toHaveLength(homeRequests.length);
    const [previousRecord, lastRecord, stepRecord] = homeRecords.slice(-3);
    expectRecordOfWire(previousRecord!, previous!);
    expectRecordOfWire(lastRecord!, last!);
    expectRecordOfWire(stepRecord!, toolStep!);
    expect(lastRecord).toMatchObject({ kind: "home", provider: PROVIDER, model: MODEL_ID, api: "anthropic-messages", stop: "toolUse",
      usage: { input: 10, cacheRead: 0, cacheWrite: CACHE_WRITE, output: 5 } });
    expect(stepRecord!.stop).toBe("stop");
    expect([lastRecord!.tools, lastRecord!.system, lastRecord!.params, lastRecord!.hashKey]).toEqual([previousRecord!.tools, previousRecord!.system, previousRecord!.params, previousRecord!.hashKey]);
    expect(JSON.stringify(f.requestRecords)).not.toMatch(/input \d|reply \d|summary \d|Tron Home/u);
    expect(lastRecord!.request.hash).not.toBe(previousRecord!.request.hash);
    const viewMark = (record: RequestRecord) => record.marks.find((mark) => mark.at.startsWith(".messages[0]."));
    expect(viewMark(stepRecord!)).toEqual(viewMark(lastRecord!));
    expect(stepRecord!.request.bytes).toBeGreaterThan(lastRecord!.request.bytes);
    const plainRecords = f.requestRecords.filter((record) => record.sessionId === ordinary.id);
    expect(plainRecords).toHaveLength(1);
    expectRecordOfWire(plainRecords[0]!, plain);
    expect(plainRecords[0]).toMatchObject({ kind: "ordinary", usage: { input: 10, cacheRead: 0, cacheWrite: 0, output: 5 } });
    expect(plainRecords[0]!.tools.hash).not.toBe(lastRecord!.tools.hash);
    void ordinary.prompt(HELD_REQUEST).catch(() => {});
    await waitFor(() => f.held.length === 1, "the provider to hold the request");
    await ordinary.abort("agent");
    await waitFor(() => f.requestRecords.filter((record) => record.sessionId === ordinary.id).length === 2, "the aborted request's record");
    const abortedRecord = f.requestRecords.filter((record) => record.sessionId === ordinary.id)[1]!;
    expect(abortedRecord.stop).toBe("aborted");
    expectRecordOfWire(abortedRecord, f.requests.at(-1)!);

    report.cases.push({
      case: "wire-layout", homeTurns: homeRequests.length, summarizerCalls: summarizer.length,
      viewChars: view.length, viewPieces: viewPieces.map((piece) => piece.length), lastTurnMarks: lastMarks,
      summarizerMarks: sampleMarks,
      ordinaryMarks: plainMarks,
    });
  }, 300_000);

  it("keeps Home's cached view across turns past the view budget", async () => {
    const f = await fixture();
    await f.service.invoke(client, "home.designate", { commandId: "budget-designate", model: MODEL });
    await f.service.invoke(client, "settings.change", homeMemoryChange({ commandId: "budget-memory", model: MODEL }));
    const status = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
    const home = await f.registry.acquire(status.sessionId!);
    const TURNS = 210;
    for (let turn = 0; turn < TURNS; turn += 1) {
      await settledTurn(f, home, `input ${turn} ${"i".repeat(900)}`, `Home turn ${turn}`);
    }
    const turns = f.requests.filter((request) => request.kind === "home");
    expect(turns.length).toBe(TURNS);
    const steps = turns.slice(1).map((next, index) => {
      const previous = turns[index]!;
      const { shared, previous: size } = sharedViewBytes(previous, next);
      const linesOf = (request: Captured) => viewBlocksOf(request).slice(1).join("").split("\n").slice(0, -1);
      const before = linesOf(previous), after = linesOf(next);
      let sharedLines = 0;
      while (sharedLines < before.length && before[sharedLines] === after[sharedLines]) sharedLines += 1;
      return { turn: index + 1, kind: transition(previous, next), shared, size, rewrite: shared < size,
        sharedBlocks: sharedViewBlocks(previous, next), sharedLines };
    });
    const firstRewrite = steps.find((step) => step.rewrite && step.size >= EPISODIC_DEFAULTS.viewBytes / 2);
    expect(firstRewrite, "the view never reached its budget").toBeDefined();
    const past = steps.filter((step) => step.turn >= firstRewrite!.turn);
    const rewrites = past.filter((step) => step.rewrite);
    expect(past.length).toBeGreaterThanOrEqual(60);
    expect(rewrites.length, JSON.stringify(rewrites.map((step) => ({ turn: step.turn, shared: step.shared, size: step.size }))))
      .toBeLessThanOrEqual(Math.ceil(past.length / 8));
    for (const step of past) if (!step.rewrite) expect(step.kind, `turn ${step.turn}`).toBe("extend");
    for (const step of rewrites) {
      expect(step.sharedBlocks, `rebalance at turn ${step.turn}`).toBeGreaterThanOrEqual(1 + Math.floor(step.sharedLines / VIEW_BLOCK_LINES));
    }
    for (const request of turns.slice(-3)) expectViewLayout(memoryOf(request).slice(0, -1).map((block) => block.text ?? ""));
    report.cases.push({
      case: "past-budget", turns: turns.length, firstRewrite: firstRewrite!.turn, turnsPast: past.length,
      rewrites: rewrites.map((step) => ({ turn: step.turn, sharedBytes: step.shared, previousBytes: step.size, sharedBlocks: step.sharedBlocks, kind: step.kind })),
      transitions: past.reduce<Record<string, number>>((counts, step) => ({ ...counts, [step.kind]: (counts[step.kind] ?? 0) + 1 }), {}),
      lastViewBytes: Buffer.byteLength(viewBlocksOf(turns.at(-1)!).join("")),
    });
  }, 900_000);

  it("counts Home requests by the provider's usage: calibrated before sending, exact after, and refuses a real overflow", async () => {
    const f = await fixture(false, true);
    await f.service.invoke(client, "home.designate", { commandId: "count-designate", model: MODEL });
    await f.service.invoke(client, "settings.change", homeMemoryChange({ commandId: "count-memory", model: MODEL }));
    const status = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
    const home = await f.registry.acquire(status.sessionId!);
    const TURNS = 130;
    for (let turn = 0; turn < TURNS; turn += 1) {
      if (turn % 40 === 1) f.toolCalls.push({ name: "memory_search", input: { query: "reply" } });
      await settledTurn(f, home, `input ${turn} ${"i".repeat(900)}`, `Home turn ${turn}`);
    }
    const requests = f.requests.filter((request) => request.kind === "home");
    const activations = f.records.flatMap((record) => record.event === "activation" ? [record] : []);
    const usages = f.records.flatMap((record) => record.event === "usage" ? [record] : []);
    expect(activations).toHaveLength(TURNS);
    expect(usages).toHaveLength(TURNS);
    const firstOf = (turn: number) => requests.find((request) => JSON.stringify(messagesOf(request).at(-1)).includes(`input ${turn} `))!;
    const error = (turn: number) => activations[turn]!.effectiveTokens / providerCount(firstOf(turn).body) - 1;

    expect(error(0)).toBeLessThan(-0.25);
    for (const turn of [TURNS - 3, TURNS - 2, TURNS - 1]) {
      expect(Math.abs(error(turn)), `turn ${turn}`).toBeLessThan(0.02);
      expect(usages[turn]).toEqual({ event: "usage", estimatedTokens: activations[turn]!.effectiveTokens, providerTokens: providerCount(firstOf(turn).body) });
    }
    const last = requests.at(-1)!;
    expect(Buffer.byteLength(viewBlocksOf(last).join(""))).toBeGreaterThan(100_000);
    const counted = providerCount(last.body);
    const context = await f.service.invoke(client, "home.context", {}) as unknown as { effectiveTokens: number; breakdown: { effectiveTokens: number; sections: Array<{ id: string; tokens: number }> } };
    expect(context.effectiveTokens).toBe(counted);
    expect(context.breakdown.effectiveTokens).toBe(counted);
    expect(context.breakdown.sections.reduce((total, section) => total + section.tokens, 0)).toBe(counted);
    const memoryCounted = Math.ceil(Buffer.byteLength(blocks(messagesOf(last)[0]!).map((block) => block.text ?? "").join("")) / 2);
    expect(Math.abs(context.breakdown.sections.find((section) => section.id === "memory")!.tokens / memoryCounted - 1)).toBeLessThan(0.05);

    const sized = (share: number, from: number) => "i".repeat(Math.ceil((share * (METERED_WINDOW - 1_024) - from) * 2.8));
    const under = sized(0.92, counted);
    expect(under.length).toBeGreaterThan(0);
    await settledTurn(f, home, `input under ${under}`, "the under-window turn");
    const admitted = f.requests.filter((request) => request.kind === "home").at(-1)!;
    expect(JSON.stringify(messagesOf(admitted).at(-1))).toContain("input under ");
    expect(providerCount(admitted.body)).toBeGreaterThan(0.91 * (METERED_WINDOW - 1_024));
    expect(providerCount(admitted.body)).toBeLessThan(METERED_WINDOW - 1_024);
    expect(f.records.filter((record) => record.event === "refused")).toEqual([]);

    const over = sized(1.1, providerCount(admitted.body) - under.length / 2.8);
    expect(over.length).toBeGreaterThan(under.length);
    const sent = f.requests.length;
    await home.prompt(`input over ${over}`);
    await waitFor(() => home.snapshot().configurationBlocker === null, "Home configuration after the over-window turn");
    expect(f.records.flatMap((record) => record.event === "refused" ? [record] : []).map((record) => ({ reason: record.reason, contextWindow: record.contextWindow })))
      .toEqual([{ reason: "context-overflow", contextWindow: METERED_WINDOW }]);
    expect(f.requests.slice(sent).filter((request) => request.kind === "home")).toEqual([]);
    report.cases.push({ case: "provider-count", turns: TURNS, firstError: error(0), lastErrors: [TURNS - 3, TURNS - 2, TURNS - 1].map(error), counted, underChars: under.length, overChars: over.length });
  }, 600_000);

  it("keeps the cached view's end across an activation refused before dispatch", async () => {
    const f = await fixture();
    await f.service.invoke(client, "home.designate", { commandId: "refused-designate", model: MODEL });
    await f.service.invoke(client, "settings.change", homeMemoryChange({ commandId: "refused-memory", model: MODEL }));
    const status = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
    const home = await f.registry.acquire(status.sessionId!);
    const owner = homeOwnerOf(f.registry);
    const quiescent = owner.chapterQuiescent.bind(owner);
    let release!: () => void;
    let held = false;
    const gate = new Promise<void>(resolve => { release = resolve; });
    const hook = vi.spyOn(owner, "chapterQuiescent").mockImplementation(async id => {
      held = true;
      await gate;
      await quiescent(id);
    });
    let ready = false;
    let readiness: Promise<unknown> | undefined;
    try {
      await home.prompt(`input 0 ${"i".repeat(900)}`);
      await waitFor(() => held && !home.isBusy, "post-terminal Home quiescence");
      expect(home.snapshot().configurationBlocker).toBe("running");
      readiness = waitFor(() => home.snapshot().configurationBlocker === null, "Home configuration readiness").then(() => { ready = true; });
      await awaitsWithin(new Promise<void>(resolve => setImmediate(resolve)), "readiness observation turn");
      expect(ready, "actionable work retirement is not configuration readiness").toBe(false);
    } finally {
      release();
      hook.mockRestore();
      await readiness;
    }
    for (let turn = 1; turn < 3; turn += 1) {
      await settledTurn(f, home, `input ${turn} ${"i".repeat(900)}`, `Home configuration after turn ${turn}`);
    }
    const sent = f.requests.filter((request) => request.kind === "home").at(-1)!;
    await home.setModel(PROVIDER, SMALL_MODEL_ID);
    await home.prompt(`refused input ${"i".repeat(900)}`);
    await waitFor(() => home.snapshot().configurationBlocker === null, "Home configuration after the refused turn");
    expect(f.records.filter((record) => record.event === "refused").map((record) => record.reason)).toContain("context-overflow");
    expect(f.requests.filter((request) => request.kind === "home").at(-1)).toBe(sent);
    await home.setModel(PROVIDER, MODEL_ID);
    await settledTurn(f, home, `input after ${"i".repeat(900)}`, "Home configuration after the refusal");
    const next = f.requests.filter((request) => request.kind === "home").at(-1)!;
    expect(next).not.toBe(sent);
    expect(transition(sent, next)).toBe("extend");
    report.cases.push({ case: "refused-activation-configuration-cut", heldQuiescence: held, refusedReason: "context-overflow",
      sentHomeRequests: f.requests.filter(request => request.kind === "home").length, transition: transition(sent, next) });
  }, 300_000);
});
