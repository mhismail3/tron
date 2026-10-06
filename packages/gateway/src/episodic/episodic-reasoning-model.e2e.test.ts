import { createServer, type Server } from "node:http";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fauxAssistantMessage, type Message } from "@earendil-works/pi-ai";
import { ModelRuntime, SessionManager } from "@earendil-works/pi-coding-agent";
import { afterEach, describe, expect, it } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { createEpisodicTokenBudget } from "./episodic-contract.js";
import { COMPACTOR_MAX_TOKENS, compactorRequest, createModelRuntimeSummarizer, EPISODIC_COMPACT_PROMPT } from "./episodic-compactor.js";
import { EpisodicMemory } from "./episodic-memory.js";
import { waitFor } from "../../test-support/wait-for.js";

// #480 B1-B4, found live: opencode-go's DeepSeek spent its whole output ceiling
// on reasoning and the memory blocked. The production summarizer talks to a
// local OpenAI-compatible endpoint through pi-ai's real request builder, and the
// endpoint records every request body.

type Reply = "line" | "reasoning-only";

async function endpoint(reply: () => Reply) {
  const bodies: Array<Record<string, unknown>> = [];
  const server: Server = createServer((request, response) => {
    let raw = "";
    request.on("data", (chunk) => { raw += chunk; });
    request.on("end", () => {
      bodies.push(JSON.parse(raw) as Record<string, unknown>);
      const chunk = (delta: Record<string, unknown>, finish: string | null, usage?: Record<string, number>) =>
        `data: ${JSON.stringify({ id: "c", object: "chat.completion.chunk", created: 0, model: "m",
          choices: [{ index: 0, delta, finish_reason: finish }], ...(usage ? { usage } : {}) })}\n\n`;
      const usage = { prompt_tokens: 40, completion_tokens: 20, total_tokens: 60 };
      response.writeHead(200, { "content-type": "text/event-stream" });
      response.end(reply() === "line"
        ? chunk({ role: "assistant", reasoning_content: "thinking briefly" }, null)
          + chunk({ content: "user: a summarized line" }, null) + chunk({}, "stop", usage) + "data: [DONE]\n\n"
        : chunk({ role: "assistant", reasoning_content: "thinking ".repeat(50) }, null) + chunk({}, "length", usage) + "data: [DONE]\n\n");
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return { server, bodies, port: (server.address() as AddressInfo).port };
}

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
    const f = await fixture(() => "line");
    const request = compactorRequest(EPISODIC_COMPACT_PROMPT, "<chat>\nuser: earlier\n</chat>", "Compress this message.",
      new AbortController().signal, "tron-episodic:test");
    const reasoned = await createModelRuntimeSummarizer(f.runtime, f.runtime.getModel("local-openai", "reasoner")!)(request);
    const always = await createModelRuntimeSummarizer(f.runtime, f.runtime.getModel("local-openai", "always-reasons")!)(request);
    const plain = await createModelRuntimeSummarizer(f.runtime, f.runtime.getModel("local-openai", "plain")!)(request);
    const [reasonerBody, alwaysBody, plainBody] = f.bodies;
    expect(reasoned.content.filter((part) => part.type === "text").map((part) => part.text).join("")).toBe("user: a summarized line");
    expect([always.stopReason, plain.stopReason]).toEqual(["stop", "stop"]);
    expect(reasonerBody!.reasoning_effort).toBe("none");
    expect(alwaysBody!.reasoning_effort).toBe("low");
    expect(plainBody!.reasoning_effort).toBeUndefined();
    for (const body of [reasonerBody!, alwaysBody!, plainBody!]) {
      expect(body.max_completion_tokens ?? body.max_tokens).toBe(COMPACTOR_MAX_TOKENS);
    }
    expect(COMPACTOR_MAX_TOKENS).toBeGreaterThanOrEqual(8_192);
  });

  // B3: a reply that spent its whole ceiling on reasoning blocks with a reason that says so.
  it("blocks with an explicit reason when the whole output went to reasoning", async () => {
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
      workspace, sessionId: manager.getSessionId(), sessionFile: manager.getSessionFile()!,
      budget: createEpisodicTokenBudget(10_000_000),
      summarizer: createModelRuntimeSummarizer(f.runtime, f.runtime.getModel("local-openai", "always-reasons")!),
      sleep: async () => {},
    });
    cleanups.push(async () => { await memory.dispose(); });
    await memory.entriesCommitted(manager.getSessionId());
    await waitFor(() => memory.status().blocked !== null, "the memory to block");
    expect(memory.status().blocked).toMatchObject({ reason: "permanent-failure" });
    expect(memory.status().blocked!.detail).toMatch(/reasoning/u);
    expect(f.bodies[0]!.reasoning_effort).toBe("low");
  });
});
