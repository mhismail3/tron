import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import { RuntimeRegistry } from "./runtime-registry.js";

const registries: RuntimeRegistry[] = [];
const roots: string[] = [];
afterEach(async () => {
  await Promise.all(registries.splice(0).map((registry) => registry.dispose().catch(() => {})));
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

async function waitUntil(predicate: () => boolean): Promise<void> {
  const deadline = Date.now() + 5_000;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error("condition timed out");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

describe("codemode classifier usage projection", () => {
  it("counts TypeSafe classify usage once in the codemode card and session snapshot", async () => {
    // Failure modes covered: Pi can omit classifier usage from the enclosing
    // result, count it twice in session totals, or lose it in Tron projection.
    const root = await mkdtemp(join(tmpdir(), "tron-codemode-classify-cost-"));
    roots.push(root);
    const agentDir = join(root, "agent");
    const sessionDir = join(root, "sessions");
    const cwd = join(root, "workspace");
    const extensions = join(cwd, ".pi", "extensions");
    await Promise.all([
      mkdir(agentDir, { recursive: true }), mkdir(sessionDir, { recursive: true }),
      mkdir(extensions, { recursive: true }), mkdir(cwd, { recursive: true }),
    ]);
    const sdkUrl = import.meta.resolve("@earendil-works/pi-coding-agent");
    await Promise.all([
      writeFile(join(agentDir, "settings.json"), JSON.stringify({ sessionDir, defaultTools: ["+codemode"] })),
      writeFile(join(extensions, "codemode.ts"), `import { createCodemodeExtension } from ${JSON.stringify(sdkUrl)}; export default createCodemodeExtension({ mode: "on" });\n`),
    ]);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-codemode-classify-cost", tokensPerSecond: 10_000 });
    faux.setResponses([
      fauxAssistantMessage([fauxToolCall("codemode", { code: `const model = await models.getModelOfType("classifier", "typesafe", "jev-latest"); const result = await models.classify(model, { state: { text: "classifier usage fixture" }, questions: { relevant: { type: "bool", instructions: "Is this relevant?" } } }); return JSON.stringify(result);` }, { id: "classify-parent" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("classification complete"),
    ]);
    const modelRuntimeFactory = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      await runtime.setRuntimeApiKey("typesafe", "synthetic-typesafe-key");
      return runtime;
    };
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, modelRuntimeFactory, trust,
      broadcast: () => {},
      sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const chatModel = faux.getModel();
    await slot.setModel(chatModel.provider, chatModel.id);

    const originalFetch = globalThis.fetch;
    const requests: Array<{ url: string; authorization: string | null; body: Record<string, unknown> }> = [];
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      requests.push({
        url: String(input),
        authorization: new Headers(init?.headers).get("authorization"),
        body: JSON.parse(String(init?.body)) as Record<string, unknown>,
      });
      return new Response(JSON.stringify({
        model: "jev-latest",
        answers: { relevant: { type: "noul", noul: 0.91 } },
        usage: { input_tokens: 128, output_tokens: 8 },
      }), { status: 200, headers: { "content-type": "application/json" } });
    }) as typeof fetch;
    const startedAt = Date.now();
    let live: ReturnType<typeof slot.snapshot>;
    try {
      const prompting = slot.prompt("classify once");
      await waitUntil(() => slot.snapshot().toolExecutions.some((tool) => tool.toolCallId === "classify-parent"));
      live = slot.snapshot();
      await prompting;
      await waitUntil(() => !slot.isBusy);
    } finally {
      globalThis.fetch = originalFetch;
    }
    const snapshot = slot.snapshot();
    const result = snapshot.transcript.find((item) =>
      item.kind === "message" && item.role === "toolResult" && item.toolCallId === "classify-parent");
    expect(requests).toHaveLength(1);
    expect(requests[0]).toMatchObject({ url: "https://api.typesafe.ai/v1/systemone", authorization: "Bearer synthetic-typesafe-key", body: { model: "jev-latest" } });
    const estimatedClassifierCostUSD = 128 * 0.042 / 1_000_000;
    expect(result).toMatchObject({
      role: "toolResult",
      usage: { input: 128, output: 8, totalTokens: 136, cost: { input: estimatedClassifierCostUSD, output: 0, total: estimatedClassifierCostUSD } },
      details: { calls: [{ name: "models.classify", args: "typesafe/jev-latest", status: "ok", cost: estimatedClassifierCostUSD }] },
    });
    const assistantUsage = snapshot.transcript
      .filter((item) => item.kind === "message" && item.role === "assistant" && item.usage !== undefined)
      .map((item) => item.kind === "message" ? item.usage as any : undefined)
      .filter((usage) => usage !== undefined)
      .reduce((total, usage) => ({
        input: total.input + usage.input,
        output: total.output + usage.output,
        cacheRead: total.cacheRead + usage.cacheRead,
        cacheWrite: total.cacheWrite + usage.cacheWrite,
        total: total.total + usage.totalTokens,
      }), { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 });
    expect(snapshot.stats.tokens).toEqual({
      input: assistantUsage.input + 128,
      output: assistantUsage.output + 8,
      cacheRead: assistantUsage.cacheRead,
      cacheWrite: assistantUsage.cacheWrite,
      total: assistantUsage.total + 136,
    });
    expect(snapshot.stats.cost).toBeCloseTo(estimatedClassifierCostUSD);
    expect(snapshot.transcript.filter((item) => item.kind === "message" && item.role === "toolResult")
      .reduce((total, item) => total + (item.kind === "message" && item.role === "toolResult" ? item.usage?.cost.total ?? 0 : 0), 0))
      .toBeCloseTo(estimatedClassifierCostUSD);
    expect(JSON.stringify(snapshot)).toContain('"usage":{"input":128,"output":8');

    const artifactPath = join(process.cwd(), "test-results", "pi-sdk-099-classify-cost.json");
    await mkdir(dirname(artifactPath), { recursive: true });
    await writeFile(artifactPath, `${JSON.stringify({
      requests: requests.map(({ url, authorization: _authorization, body }) => ({ url, model: body.model, authorization: "redacted" })),
      live: { toolExecutions: live!.toolExecutions, stats: live!.stats },
      classifyToolResult: result,
      sessionSnapshot: { stats: snapshot.stats, toolResult: result },
      sessionSnapshotCountedClassifierTokens: snapshot.stats.tokens,
      expectedClassifierTokens: 136,
      classifyRequestCount: requests.length,
      wallTimeMs: Date.now() - startedAt,
      codemodeCardProjection: snapshot.transcript.find((item) => item.kind === "message" && item.role === "toolResult" && item.toolCallId === "classify-parent"),
    }, null, 2)}\n`);
  });
});
