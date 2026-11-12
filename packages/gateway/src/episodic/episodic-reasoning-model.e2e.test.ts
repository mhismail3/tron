import { createServer, type Server } from "node:http";
import { singleModelSummarizer } from "../../test-support/settings-dependencies.js";
import { chmod, lstat, mkdir, mkdtemp, readFile, rm, stat, symlink, writeFile } from "node:fs/promises";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fauxAssistantMessage, type Message } from "@earendil-works/pi-ai";
import { ModelRuntime, SessionManager } from "@earendil-works/pi-coding-agent";
import { afterAll, afterEach, describe, expect, it, onTestFinished } from "vitest";
import { fileURLToPath } from "node:url";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { COMPACTOR_MAX_TOKENS, compactorRequest, createQueueSummarizer, EPISODIC_COMPACT_PROMPT } from "./episodic-compactor.js";
import { ModelQueueOwner } from "../providers/model-queue.js";
import { EpisodicMemory } from "./episodic-memory.js";
import { EpisodicStore } from "./episodic-store.js";
import { waitFor } from "../../test-support/wait-for.js";

import { singleChapterSource } from "../../test-support/episodic-chapter-source.js";
type Reply = "line" | "reasoning-only" | "copy-example" | "limit" | "cache-line" | "cache-error" | "cache-unknown";

async function endpoint(reply: (body: Record<string, unknown>) => Reply) {
  const bodies: Array<Record<string, unknown>> = [];
  const server: Server = createServer((request, response) => {
    let raw = "";
    request.setEncoding("utf8");
    request.on("data", (chunk) => { raw += chunk; });
    request.on("end", () => {
      const body = JSON.parse(raw) as Record<string, unknown>;
      bodies.push(body);
      const selected = reply(body);
      if (selected === "cache-line" || selected === "cache-error" || selected === "cache-unknown") {
        const events = [
          { type: "message_start", message: { id: "summary-usage", type: "message", role: "assistant", model: body.model, content: [],
            stop_reason: null, usage: selected === "cache-unknown" ? {} : { input_tokens: 7, output_tokens: 0, cache_read_input_tokens: 90, cache_creation_input_tokens: 30,
              cache_creation: { ephemeral_1h_input_tokens: 20, ephemeral_5m_input_tokens: 10 } } } },
          ...(selected === "cache-error" ? [{ type: "error", error: { type: "invalid_request_error", message: "private provider failure text" } }]
            : [{ type: "content_block_start", index: 0, content_block: { type: "text", text: "summary content must not persist" } },
              { type: "content_block_stop", index: 0 },
              { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: selected === "cache-unknown" ? {} : { output_tokens: 11 } }, { type: "message_stop" }]),
        ];
        response.writeHead(200, { "content-type": "text/event-stream" });
        response.end(events.map(event => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join(""));
        return;
      }
      if (selected === "limit") {
        response.writeHead(429, { "content-type": "application/json" });
        response.end(JSON.stringify({ error: { message: "subscription_sharing_usage_limit_exceeded: plan usage limit reached" } }));
        return;
      }
      const chunk = (delta: Record<string, unknown>, finish: string | null, usage?: Record<string, number>) =>
        `data: ${JSON.stringify({ id: "c", object: "chat.completion.chunk", created: 0, model: "m",
          choices: [{ index: 0, delta, finish_reason: finish }], ...(usage ? { usage } : {}) })}\n\n`;
      const usage = { prompt_tokens: 40, completion_tokens: 20, total_tokens: 60 };
      response.writeHead(200, { "content-type": "text/event-stream" });
      if (selected === "copy-example") {
        const messages = body.messages as Array<{ role: string; content: unknown }>;
        const input = JSON.stringify(messages.filter(message => message.role === "user").map(message => message.content));
        const source = input.slice(Math.max(input.lastIndexOf("Compress this message"), input.lastIndexOf("Merge these two lines")));
        const topics = ["violet orchard", "amber telescope", "silver pottery", "bronze library"].filter(topic => source.includes(topic));
        const line = input.includes("For scale, this line is exactly")
          ? "Asked to keep the nightly reconcile off the request path; 12 rows rebuilt; the interval is a ceiling, not a schedule."
          : `${topics.join("; ")}: preserve the chosen appointment and its reason, with the original decision still open rather than claiming any completed work.`;
        response.end(chunk({ role: "assistant", content: line }, null) + chunk({}, "stop", usage) + "data: [DONE]\n\n");
        return;
      }
      response.end(selected === "line"
        ? chunk({ role: "assistant", reasoning_content: "thinking briefly" }, null)
          + chunk({ content: "user: a summarized line" }, null) + chunk({}, "stop", usage) + "data: [DONE]\n\n"
        : chunk({ role: "assistant", reasoning_content: "thinking ".repeat(50) }, null) + chunk({}, "length", usage) + "data: [DONE]\n\n");
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return { server, bodies, port: (server.address() as AddressInfo).port };
}

const GATEWAY_ROOT = fileURLToPath(new URL("../..", import.meta.url));
const REPORT_PATH = join(GATEWAY_ROOT, "test-results/episodic-reasoning-model/report.json");
type CaseReport = { name: string; status: "not-run" | "passed" | "failed"; observations?: Record<string, string | number | null> };
const report: { generatedAt: string; cases: CaseReport[] } = { generatedAt: new Date().toISOString(), cases: [
  { name: "reasoning effort is minimized for supported and unsupported models", status: "not-run" },
  { name: "reasoning-only output blocks with an explicit reason", status: "not-run" },
  { name: "unrelated source summaries do not store a factual size demonstration", status: "not-run" },
] };
function trackCase(index: number): void {
  onTestFinished(({ task }) => {
    const state = task.result?.state;
    report.cases[index]!.status = state === "pass" ? "passed" : state === "fail" ? "failed" : "not-run";
  });
}
afterAll(async () => {
  await mkdir(join(GATEWAY_ROOT, "test-results/episodic-reasoning-model"), { recursive: true });
  await writeFile(REPORT_PATH, `${JSON.stringify(report, null, 2)}\n`, "utf8");
});

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => { for (const cleanup of cleanups.splice(0).reverse()) await cleanup(); });

async function fixture(reply: (body: Record<string, unknown>) => Reply) {
  const root = await mkdtemp(join(tmpdir(), "tron-episodic-reasoning-"));
  const local = await endpoint(reply);
  cleanups.push(async () => {
    await new Promise<void>((resolve) => local.server.close(() => resolve()));
    await rm(root, { recursive: true, force: true });
  });
  const modelsPath = join(root, "models.json");
  await writeFile(modelsPath, JSON.stringify({ providers: { "local-openai": {
    baseUrl: `http://127.0.0.1:${local.port}/v1`, api: "openai-completions", apiKey: "local-test-key",
    compat: { supportsReasoningEffort: true },
    models: [
      { id: "reasoner", name: "Reasoner", reasoning: true, input: ["text"], contextWindow: 1_000_000, maxTokens: 65_536,
        thinkingLevelMap: { off: "none", low: "low", high: "high" } },
      { id: "always-reasons", name: "Always reasons", reasoning: true, input: ["text"], contextWindow: 1_000_000, maxTokens: 65_536,
        thinkingLevelMap: { off: null, minimal: null, low: "low", high: "high" } },
      { id: "plain", name: "Plain", reasoning: false, input: ["text"], contextWindow: 1_000_000, maxTokens: 65_536 },
    ],
  }, "local-anthropic": {
    baseUrl: `http://127.0.0.1:${local.port}`, api: "anthropic-messages", apiKey: "local-anthropic-test-key",
    models: [{ id: "cache-model", name: "Cache model", reasoning: false, input: ["text"], contextWindow: 200_000, maxTokens: 4_096 }],
  } } }));
  const runtime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath, refreshOnCreate: false });
  return { root, runtime, ...local };
}

describe("the episodic summarizer on a reasoning model", () => {
  it("finishes a real memory tree when the background model becomes plan-limited after its first leaves", async () => {
    let plainCalls = 0;
    const f = await fixture(body => body.model === "plain" && ++plainCalls > 2 ? "limit" : "line");
    const cwd = join(f.root, "project"), sessions = join(f.root, "sessions");
    await Promise.all([mkdir(cwd), mkdir(sessions)]);
    const manager = SessionManager.create(cwd, sessions);
    for (let index = 0; index < 4; index++) manager.appendMessage({ role: "user", content: `message ${index} ${"detail ".repeat(100)}`, timestamp: Date.now() });
    const workspace = new TronWorkspace(join(f.root, "home"));
    cleanups.push(async () => { await workspace.dispose(); });
    const queue = new ModelQueueOwner({ tronHome: f.root, runtime: f.runtime, usage: { read: async () => ({ providers: [] }) },
      queue: async () => ["local-openai/plain", "local-openai/reasoner"] });
    const memory = await EpisodicMemory.open({ workspace, sessionId: manager.getSessionId(),
      sessionSource: singleChapterSource(manager.getSessionId(), manager.getSessionFile()!),
      summarizer: createQueueSummarizer(queue), limits: { nodeBytes: 32, viewBytes: 40, jobs: 1 } });
    cleanups.push(async () => { await memory.dispose(); });
    await memory.entriesCommitted(manager.getSessionId());
    await memory.whenReady(4);
    const stored = await new EpisodicStore(workspace, manager.getSessionId(), 1_024 * 1_024).read();
    expect(plainCalls).toBe(3);
    expect(f.bodies.some(body => body.model === "reasoner")).toBe(true);
    expect([...stored.nodes.values()].filter(node => node.level === 0)).toHaveLength(4);
    expect([...stored.nodes.values()].some(node => node.level === 2 && node.kind === "summary")).toBe(true);
    expect(memory.status().blocked).toBeNull();
    await memory.dispose();
    const usagePath = join(f.root, "state/model-usage.json");
    const ledger = JSON.parse(await readFile(usagePath, "utf8"));
    expect(ledger.version).toBe(1);
    expect(ledger.records).toHaveLength(f.bodies.length);
    expect(ledger.records.map((record: { model: string }) => record.model)).toEqual(f.bodies.map(body => body.model));
    for (const record of ledger.records) {
      expect(Object.keys(record).sort()).toEqual(["timestamp", "provider", "model", "role", "kind", "caller", "status",
        "input", "output", "cacheRead", "cacheWrite", "cacheWrite1h", "cacheWrite5m"].sort());
      expect(record).toMatchObject({ provider: "local-openai", role: "background", kind: "summarizer",
        caller: { sessionId: manager.getSessionId() }, cacheWrite1h: null, cacheWrite5m: null });
      expect(record.timestamp).toBeGreaterThan(0);
      expect(record).toMatchObject(record.status === "error"
        ? { input: null, output: null, cacheRead: null, cacheWrite: null }
        : { status: "stop", input: 40, output: 20, cacheRead: 0, cacheWrite: 0 });
    }
    expect(ledger.records.filter((record: { status: string }) => record.status === "error")).toHaveLength(1);
    expect((await stat(usagePath)).mode & 0o777).toBe(0o600);
    expect(await readFile(usagePath, "utf8")).not.toMatch(/message 0|detail |subscription_sharing_usage_limit_exceeded|summarized line|local-test-key/);
    await mkdir(join(GATEWAY_ROOT, "test-results/episodic-reasoning-model"), { recursive: true });
    await writeFile(join(GATEWAY_ROOT, "test-results/episodic-reasoning-model/fallback.json"), JSON.stringify({ models: f.bodies.map(body => body.model), status: memory.status() }, null, 2) + "\n");
  });

  it("retains real cache buckets, partial errors, aborted and thrown calls without content", async () => {
    let reply: Reply = "cache-line";
    const f = await fixture(() => reply);
    const queue = new ModelQueueOwner({ tronHome: f.root, runtime: f.runtime, usage: { read: async () => ({ providers: [] }) },
      queue: async () => ["local-anthropic/cache-model"] });
    await queue.initialize();
    const path = join(f.root, "state/model-usage.json");
    expect(JSON.parse(await readFile(path, "utf8"))).toEqual({ version: 1, records: [] });
    const summarize = createQueueSummarizer(queue);
    const request = compactorRequest("private system prompt", "private source message", new AbortController().signal, "private-cache-key", "source-session");
    expect((await summarize(request)).stopReason).toBe("stop");
    reply = "cache-error";
    expect((await summarize(request)).stopReason).toBe("error");
    reply = "cache-unknown";
    expect((await summarize(request)).stopReason).toBe("stop");
    const aborted = new AbortController();
    aborted.abort();
    expect((await summarize({ ...request, signal: aborted.signal })).stopReason).toBe("aborted");
    await expect(queue.complete("background", () => ({ context: null as never }),
      { kind: "background", caller: { taskId: "owning-task" } })).rejects.toBeInstanceOf(Error);
    const ledger = JSON.parse(await readFile(path, "utf8"));
    expect(ledger.records.map((record: { status: string }) => record.status)).toEqual(["stop", "error", "stop", "aborted", "threw"]);
    expect(ledger.records[0]).toMatchObject({ provider: "local-anthropic", model: "cache-model", kind: "summarizer",
      caller: { sessionId: "source-session" }, input: 7, output: 11, cacheRead: 90, cacheWrite: 30, cacheWrite1h: 20, cacheWrite5m: 10 });
    expect(ledger.records[1]).toMatchObject({ input: 7, output: 0, cacheRead: 90, cacheWrite: 30, cacheWrite1h: 20, cacheWrite5m: 10 });
    for (const record of ledger.records.slice(2)) {
      expect(record).toMatchObject({ input: null, output: null, cacheRead: null, cacheWrite: null, cacheWrite1h: null, cacheWrite5m: null });
    }
    expect(ledger.records[4]).toMatchObject({ kind: "background", caller: { taskId: "owning-task" } });
    expect(f.bodies).toHaveLength(3);
    expect(await readFile(path, "utf8")).not.toMatch(/private|summary content|local-anthropic-test-key/);
  });

  it("restores and prunes the durable ledger by age, record count and encoded bytes", async () => {
    const f = await fixture(() => "line");
    let now = Date.parse("2026-11-11T00:00:00Z");
    const queue = () => new ModelQueueOwner({ tronHome: f.root, runtime: f.runtime, usage: { read: async () => ({ providers: [] }) },
      now: () => now, queue: async () => ["local-openai/plain"] });
    const request = compactorRequest("private", "private", new AbortController().signal, "cache-key", "source-session");
    await createQueueSummarizer(queue())(request);
    const path = join(f.root, "state/model-usage.json");
    const original = JSON.parse(await readFile(path, "utf8")).records[0];
    const records = Array.from({ length: 10_000 }, (_, index) => ({ ...original, timestamp: now - 10_000 + index }));
    await writeFile(path, JSON.stringify({ version: 1, records }));
    await createQueueSummarizer(queue())(request);
    let restored = JSON.parse(await readFile(path, "utf8")).records;
    expect(restored).toHaveLength(10_000);
    expect(restored[0].timestamp).toBe(now - 9_999);
    expect(restored.at(-1).timestamp).toBe(now);
    now += 30 * 24 * 60 * 60_000;
    await queue().initialize();
    restored = JSON.parse(await readFile(path, "utf8")).records;
    expect(restored).toHaveLength(1);
    expect(restored[0]).toEqual(original);
    now++;
    await queue().initialize();
    expect(JSON.parse(await readFile(path, "utf8")).records).toEqual([]);
    const longModel = "m".repeat(1_024);
    f.runtime.registerProvider("local-openai", { models: [{ id: longModel, name: "Large model ID", reasoning: false,
      input: ["text"], contextWindow: 200_000, maxTokens: 4_096 }] });
    const large = { ...original, model: longModel, caller: { sessionId: "s".repeat(256) }, timestamp: now - 1 };
    const capacity = Math.floor((8 * 1024 * 1024 - Buffer.byteLength('{"version":1,"records":[]}\n')) / (Buffer.byteLength(JSON.stringify(large)) + 1));
    await writeFile(path, JSON.stringify({ version: 1, records: Array.from({ length: capacity }, () => large) }));
    const largeQueue = new ModelQueueOwner({ tronHome: f.root, runtime: f.runtime, usage: { read: async () => ({ providers: [] }) },
      now: () => now, queue: async () => [`local-openai/${longModel}`] });
    await Promise.all([1, 2].map(() => createQueueSummarizer(largeQueue)({ ...request, sessionId: large.caller.sessionId })));
    restored = JSON.parse(await readFile(path, "utf8")).records;
    expect((await stat(path)).size).toBeLessThanOrEqual(8 * 1024 * 1024);
    expect(restored).toHaveLength(capacity);
    expect(restored.filter((record: { timestamp: number }) => record.timestamp === now)).toHaveLength(2);
    expect((await stat(path)).mode & 0o777).toBe(0o600);
    expect(f.bodies).toHaveLength(4);
  });

  it("refuses corrupt data before dispatch and exposes write failure without resetting or replaying", async () => {
    const f = await fixture(() => "line");
    const diagnostics: unknown[] = [];
    const queue = new ModelQueueOwner({ tronHome: f.root, runtime: f.runtime, usage: { read: async () => ({ providers: [] }) },
      queue: async () => ["local-openai/plain"], log: record => diagnostics.push(record) });
    await queue.initialize();
    const path = join(f.root, "state/model-usage.json");
    const request = compactorRequest("private", "private", new AbortController().signal, "cache-key", "source-session");
    const summarize = createQueueSummarizer(queue);
    const malformed = ["{broken private bytes", JSON.stringify({ version: 1, records: [], prompt: "must not persist" }),
      " ".repeat(8 * 1024 * 1024 + 1)];
    for (const document of malformed) {
      await writeFile(path, document);
      await expect(queue.initialize()).rejects.toMatchObject({ message: "Model usage ledger invalid-store" });
      await expect(summarize(request)).rejects.toMatchObject({ message: "Model usage ledger invalid-store" });
      expect(await readFile(path, "utf8")).toBe(document);
    }
    expect(f.bodies).toHaveLength(0);
    expect(diagnostics).toHaveLength(6);
    expect(diagnostics).toEqual(Array.from({ length: 6 }, () => ({ event: "model-queue.usage-failed", code: "invalid-store" })));
    await rm(path);
    const protectedPath = join(f.root, "protected.json");
    const empty = JSON.stringify({ version: 1, records: [] });
    await writeFile(protectedPath, empty);
    await symlink(protectedPath, path);
    await expect(queue.initialize()).rejects.toMatchObject({ message: "Model usage ledger read-failed" });
    expect((await lstat(path)).isSymbolicLink()).toBe(true);
    expect(await readFile(protectedPath, "utf8")).toBe(empty);
    await rm(path);
    await mkdir(path);
    await expect(queue.initialize()).rejects.toMatchObject({ message: "Model usage ledger invalid-store" });
    expect((await stat(path)).isDirectory()).toBe(true);
    expect(f.bodies).toHaveLength(0);
    await rm(path, { recursive: true });
    await writeFile(path, empty);
    const before = await readFile(path, "utf8");
    await chmod(join(f.root, "state"), 0o500);
    try {
      const completed = await summarize(request);
      expect(completed.stopReason).toBe("stop");
      expect(completed.content).toContainEqual({ type: "text", text: "user: a summarized line" });
      expect(await readFile(path, "utf8")).toBe(before);
      expect(f.bodies).toHaveLength(1);
      expect(diagnostics.at(-1)).toEqual({ event: "model-queue.usage-failed", code: "write-failed" });
    } finally { await chmod(join(f.root, "state"), 0o700); }
    await summarize(request);
    expect(f.bodies).toHaveLength(2);
    expect(JSON.parse(await readFile(path, "utf8")).records).toHaveLength(1);
  });

  it("asks each model for the least reasoning it supports, and a plain model for none", async () => {
    trackCase(0);
    const f = await fixture(() => "line");
    const request = compactorRequest(EPISODIC_COMPACT_PROMPT, "Compress this message.", new AbortController().signal, "tron-episodic:test", "test-session");
    const reasoned = await singleModelSummarizer(f.runtime, { provider: "local-openai", id: "reasoner" }, f.root)(request);
    const always = await singleModelSummarizer(f.runtime, { provider: "local-openai", id: "always-reasons" }, f.root)(request);
    const plain = await singleModelSummarizer(f.runtime, { provider: "local-openai", id: "plain" }, f.root)(request);
    const [reasonerBody, alwaysBody, plainBody] = f.bodies;
    expect(reasoned.content.filter((part) => part.type === "text").map((part) => part.text).join("")).toBe("user: a summarized line");
    expect([always.stopReason, plain.stopReason]).toEqual(["stop", "stop"]);
    expect(reasonerBody!.reasoning_effort).toBe("none");
    expect(alwaysBody!.reasoning_effort).toBe("low");
    expect(plainBody!.reasoning_effort).toBeUndefined();
    const tokenLimits = [reasonerBody!, alwaysBody!, plainBody!].map(body => Number(body.max_completion_tokens ?? body.max_tokens));
    report.cases[0]!.observations = {
      reasoningEffort: String(reasonerBody!.reasoning_effort),
      alwaysReasoningEffort: String(alwaysBody!.reasoning_effort),
      plainReasoningEffort: plainBody!.reasoning_effort == null ? null : String(plainBody!.reasoning_effort),
      tokenLimit: tokenLimits[0]!,
    };
    for (const tokenLimit of tokenLimits) expect(tokenLimit).toBe(COMPACTOR_MAX_TOKENS);
    expect(COMPACTOR_MAX_TOKENS).toBeGreaterThanOrEqual(8_192);
  });

  it("summarizes unrelated sources through the real summarizer without storing exemplar facts", async () => {
    trackCase(2);
    const f = await fixture(() => "copy-example");
    const cwd = join(f.root, "project");
    const sessionDir = join(f.root, "sessions");
    await Promise.all([mkdir(cwd, { recursive: true }), mkdir(sessionDir, { recursive: true })]);
    const manager = SessionManager.create(cwd, sessionDir);
    const topics = ["violet orchard", "amber telescope", "silver pottery", "bronze library"];
    for (const topic of topics) manager.appendMessage({ role: "user", content: `${topic}: preserve the chosen appointment and its reason; decision remains open. ${"source detail ".repeat(90)}`, timestamp: Date.now() } satisfies Message);
    const workspace = new TronWorkspace(join(f.root, "home"));
    cleanups.push(async () => { await workspace.dispose(); });
    const memory = await EpisodicMemory.open({
      workspace, sessionId: manager.getSessionId(), sessionSource: singleChapterSource(manager.getSessionId(), manager.getSessionFile()!),
      summarizer: singleModelSummarizer(f.runtime, { provider: "local-openai", id: "plain" }, f.root),
      limits: { nodeBytes: 256, viewBytes: 128, jobs: 1 },
    });
    cleanups.push(async () => { await memory.dispose(); });
    await memory.entriesCommitted(manager.getSessionId());
    await memory.whenReady(topics.length);
    await waitFor(async () => {
      const stored = await new EpisodicStore(workspace, manager.getSessionId(), 1024 * 1024).read();
      return [...stored.nodes.values()].some(node => node.level === 2);
    }, "merged unrelated source summaries");
    const stored = await new EpisodicStore(workspace, manager.getSessionId(), 1024 * 1024).read();
    const nodes = [...stored.nodes.values()];
    await mkdir(join(GATEWAY_ROOT, "test-results/episodic-reasoning-model"), { recursive: true });
    await writeFile(join(GATEWAY_ROOT, "test-results/episodic-reasoning-model/source-bound.json"), JSON.stringify({ bodies: f.bodies, nodes }, null, 2) + "\n");
    report.cases[2]!.observations = { providerCalls: f.bodies.length, nodes: nodes.length };
    expect(nodes.filter(node => node.kind === "summary" && node.level > 0).length).toBeGreaterThan(0);
    for (const node of nodes) expect(node.text).not.toMatch(/nightly reconcile|request path|12 rows rebuilt|interval is a ceiling/iu);
    for (let index = 0; index < topics.length; index++) {
      const leaf = nodes.find(node => node.level === 0 && node.index === index)!;
      expect(leaf.text).toContain(topics[index]);
      const sourceLine = memory.zoomLines(index, 1)?.join("\n");
      expect(sourceLine).toContain(topics[index]);
      expect(sourceLine).toContain("user:");
    }
    expect(memory.status().blocked).toBeNull();
  });

  it("blocks with an explicit reason when the whole output went to reasoning", async () => {
    trackCase(1);
    const f = await fixture(() => "reasoning-only");
    const cwd = join(f.root, "project");
    const sessionDir = join(f.root, "sessions");
    await Promise.all([mkdir(cwd, { recursive: true }), mkdir(sessionDir, { recursive: true })]);
    const manager = SessionManager.create(cwd, sessionDir);
    manager.appendMessage({ role: "user", content: `a long first message ${"x".repeat(900)}`, timestamp: Date.now() } satisfies Message);
    manager.appendMessage(fauxAssistantMessage([{ type: "text", text: `a long reply ${"y".repeat(900)}` }]));
    const workspace = new TronWorkspace(join(f.root, "home"));
    cleanups.push(async () => { await workspace.dispose(); });
    const memory = await EpisodicMemory.open({
      workspace, sessionId: manager.getSessionId(), sessionSource: singleChapterSource(manager.getSessionId(), manager.getSessionFile()!),
      summarizer: singleModelSummarizer(f.runtime, { provider: "local-openai", id: "always-reasons" }, f.root),
    });
    cleanups.push(async () => { await memory.dispose(); });
    await memory.entriesCommitted(manager.getSessionId());
    await waitFor(() => memory.status().blocked !== null, "the memory to block");
    report.cases[1]!.observations = { blockedReason: memory.status().blocked?.reason ?? null };
    expect(memory.status().blocked).toMatchObject({ reason: "permanent-failure" });
    expect(memory.status().blocked!.detail).toMatch(/reasoning/u);
    expect(f.bodies[0]!.reasoning_effort).toBe("low");
  });
});
