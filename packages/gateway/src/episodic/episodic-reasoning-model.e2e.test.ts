import { createServer, type Server } from "node:http";
import { singleModelSummarizer } from "../../test-support/settings-dependencies.js";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fauxAssistantMessage, type Message } from "@earendil-works/pi-ai";
import { ModelRuntime, SessionManager } from "@earendil-works/pi-coding-agent";
import { afterAll, afterEach, describe, expect, it, onTestFinished } from "vitest";
import { fileURLToPath } from "node:url";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { COMPACTOR_MAX_TOKENS, compactorRequest, EPISODIC_COMPACT_PROMPT } from "./episodic-compactor.js";
import { EpisodicMemory } from "./episodic-memory.js";
import { EpisodicStore } from "./episodic-store.js";
import { waitFor } from "../../test-support/wait-for.js";

// #480 B1-B4, found live: opencode-go's DeepSeek spent its whole output ceiling
// on reasoning and the memory blocked. The production summarizer talks to a
// local OpenAI-compatible endpoint through pi-ai's real request builder, and the
// endpoint records every request body.

import { singleChapterSource } from "../../test-support/episodic-chapter-source.js";
type Reply = "line" | "reasoning-only" | "copy-example";

async function endpoint(reply: () => Reply) {
  const bodies: Array<Record<string, unknown>> = [];
  const server: Server = createServer((request, response) => {
    let raw = "";
    request.on("data", (chunk) => { raw += chunk; });
    request.on("end", () => {
      const body = JSON.parse(raw) as Record<string, unknown>;
      bodies.push(body);
      const chunk = (delta: Record<string, unknown>, finish: string | null, usage?: Record<string, number>) =>
        `data: ${JSON.stringify({ id: "c", object: "chat.completion.chunk", created: 0, model: "m",
          choices: [{ index: 0, delta, finish_reason: finish }], ...(usage ? { usage } : {}) })}\n\n`;
      const usage = { prompt_tokens: 40, completion_tokens: 20, total_tokens: 60 };
      response.writeHead(200, { "content-type": "text/event-stream" });
      if (reply() === "copy-example") {
        // A deterministic copy-prone provider, not a claim about live-model
        // fidelity: any factual size demonstration competes with real sources.
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
      response.end(reply() === "line"
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

async function fixture(reply: () => Reply) {
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
      // Can turn reasoning off, mapped to the wire value "none" (as OpenAI's models are).
      { id: "reasoner", name: "Reasoner", reasoning: true, input: ["text"], contextWindow: 1_000_000, maxTokens: 65_536,
        thinkingLevelMap: { off: "none", low: "low", high: "high" } },
      // Cannot turn reasoning off (as DeepSeek v4.1 Flash on OpenCode Go): its lowest level is low.
      { id: "always-reasons", name: "Always reasons", reasoning: true, input: ["text"], contextWindow: 1_000_000, maxTokens: 65_536,
        thinkingLevelMap: { off: null, minimal: null, low: "low", high: "high" } },
      { id: "plain", name: "Plain", reasoning: false, input: ["text"], contextWindow: 1_000_000, maxTokens: 65_536 },
    ],
  } } }));
  const runtime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath, refreshOnCreate: false });
  return { root, runtime, ...local };
}

describe("the episodic summarizer on a reasoning model", () => {
  // B1, B2 and B4, and #485: reasoning off wherever a model supports it, else its
  // least; no reasoning parameter for a plain model; a ceiling with room for any
  // reasoning plus the line.
  it("asks each model for the least reasoning it supports, and a plain model for none", async () => {
    trackCase(0);
    const f = await fixture(() => "line");
    const request = compactorRequest(EPISODIC_COMPACT_PROMPT, "<chat>\nuser: earlier\n</chat>", "Compress this message.",
      new AbortController().signal, "tron-episodic:test");
    const reasoned = await singleModelSummarizer(f.runtime, { provider: "local-openai", id: "reasoner" })(request);
    const always = await singleModelSummarizer(f.runtime, { provider: "local-openai", id: "always-reasons" })(request);
    const plain = await singleModelSummarizer(f.runtime, { provider: "local-openai", id: "plain" })(request);
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
      summarizer: singleModelSummarizer(f.runtime, { provider: "local-openai", id: "plain" }),
      limits: { nodeBytes: 256, viewBytes: 4096, jobs: 1 },
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
      expect(memory.zoomLines(index, 1)?.join("\n")).toContain(topics[index]);
    }
    expect(memory.renderView(topics.length).text).toContain("user:");
    expect(memory.status().blocked).toBeNull();
  });

  // B3: a reply that spent its whole ceiling on reasoning blocks with a reason that says so.
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
      summarizer: singleModelSummarizer(f.runtime, { provider: "local-openai", id: "always-reasons" }),
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
