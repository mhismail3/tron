import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { InMemoryCredentialStore } from "@earendil-works/pi-ai";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { afterEach, describe, expect, it } from "vitest";
import { JevDecisionClient, JevEvaluationError } from "./jev-client.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map(path => rm(path, { recursive: true, force: true }))); });
async function runtime() {
  const root = await mkdtemp(join(tmpdir(), "tron-jev-classifier-")); roots.push(root);
  const value = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath: null, credentials: new InMemoryCredentialStore(), refreshOnCreate: false, allowModelNetwork: false });
  await value.setRuntimeApiKey("typesafe", "synthetic-typesafe-key");
  return value;
}
const request = { state: { text: "bounded" }, questions: { noul: { type: "noul" as const, instructions: "Is this relevant?", criteria: { true: "relevant", false: "irrelevant" } } } };

describe("Pi-backed Jev classifier", () => {
  it("captures TypeSafe's real wire shape and returns Pi bool probability under the catalog model", async () => {
    const value = await runtime();
    const calls: Array<{ url: string; headers: Headers; body: Record<string, unknown> }> = [];
    const fakeFetch: typeof fetch = async (input, init) => {
      calls.push({ url: String(input), headers: new Headers(init?.headers), body: JSON.parse(String(init?.body)) as Record<string, unknown> });
      return new Response(JSON.stringify({ model: "jev-latest", answers: { noul: { type: "noul", noul: 0.91 } }, usage: { input_tokens: 100, output_tokens: 1 } }), { status: 200, headers: { "content-type": "application/json" } });
    };
    const result = await new JevDecisionClient(value, fakeFetch).evaluate(request, new AbortController().signal, { maxChargeCents: 0.2688 });
    expect(calls).toHaveLength(1);
    expect(calls[0]).toMatchObject({ url: "https://api.typesafe.ai/v1/systemone", body: { model: "jev-latest", state: request.state, questions: { noul: { type: "noul" } } } });
    expect(calls[0]?.headers.get("authorization")).toBe("Bearer synthetic-typesafe-key");
    expect(result).toMatchObject({ requestedModel: "jev-latest", actualModel: "jev-latest", answers: { noul: { type: "noul", noul: 0.91 } } }); expect(result.estimatedCostCents).toBeCloseTo(100 * 42 / 10_000_000);
    const artifactPath = join(process.cwd(), "test-results", "pi-sdk-099-jev-classifier-wire.json");
    await mkdir(join(process.cwd(), "test-results"), { recursive: true });
    await writeFile(artifactPath, `${JSON.stringify({ endpoint: calls[0]?.url, model: calls[0]?.body.model, wireQuestionType: ((calls[0]?.body.questions as Record<string, { type: string }>).noul).type, authHeader: "redacted", result: { model: result.actualModel, answer: result.answers.noul, inputTokens: result.usage.input_tokens, estimatedCostCents: result.estimatedCostCents, maxEstimatedChargeCents: result.maxEstimatedChargeCents } }, null, 2)}\n`);
  });

  it("rejects oversized state and question counts before dispatch", async () => {
    const value = await runtime(); let calls = 0;
    const client = new JevDecisionClient(value, async () => { calls += 1; return new Response("{}", { status: 200 }); });
    await expect(client.evaluate({ state: { text: "x".repeat(24_001) }, questions: { decision: request.questions.noul } }, new AbortController().signal)).rejects.toThrow(/explicit bound/);
    const questions = Object.fromEntries(Array.from({ length: 17 }, (_, index) => [`q${index}`, request.questions.noul]));
    await expect(client.evaluate({ state: {}, questions }, new AbortController().signal)).rejects.toThrow(/explicit bound/);
    expect(calls).toBe(0);
  });

  it("rejects a ceiling below the qualified catalog-price estimate before Pi dispatch", async () => {
    const value = await runtime(); let calls = 0;
    const client = new JevDecisionClient(value, async () => { calls += 1; return new Response("{}", { status: 200 }); });
    await expect(client.evaluate(request, new AbortController().signal, { maxChargeCents: 0.2687 })).rejects.toThrow(/maxChargeCents before dispatch/);
    expect(calls).toBe(0);
  });

  it("reports pre-classify failures as notSent and classify failures as uncertain", async () => {
    const value = await runtime();
    await expect(new JevDecisionClient(value, async () => { throw new Error("network"); }).evaluate(request, new AbortController().signal, { beforeDispatch: async () => { throw new Error("policy denied"); } })).rejects.toMatchObject({ certainty: "notSent" });
    try {
      await new JevDecisionClient(value, async () => { throw new Error("network"); }).evaluate(request, new AbortController().signal);
      throw new Error("expected classifier error");
    } catch (error) { expect(error).toBeInstanceOf(JevEvaluationError); expect((error as JevEvaluationError).certainty).toBe("uncertain"); }
  });
});
