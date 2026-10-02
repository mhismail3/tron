import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { InMemoryCredentialStore } from "@earendil-works/pi-ai";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { afterEach, describe, expect, it } from "vitest";
import { JEV_DEFAULT_MODEL } from "./jev-client.js";
import { JevSourceAssessmentModel, JEV_RUBRIC_VERSION, jevProfileVersion, prepareJevAssessmentInput } from "./jev-assessment.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map(path => rm(path, { recursive: true, force: true }))); });
const answer = { model: JEV_DEFAULT_MODEL, answers: {
  admission: { type: "choice", choice: "retain", probabilities: { retain: 0.9, archive: 0.05, pending: 0.05 }, confidence: 0.9 },
  topic: { type: "choice", choice: "research", probabilities: { technical: 0.05, product: 0.05, research: 0.8, workflow: 0.05, other: 0.05 }, confidence: 0.9 },
  score: { type: "score", score: 2.5, confidence: 0.9 },
}, usage: { input_tokens: 352, output_tokens: 20 } };
async function model(response: unknown = answer, calls: Array<{ url: string; body: Record<string, unknown> }> = []) {
  const root = await mkdtemp(join(tmpdir(), "tron-jev-assessment-")); roots.push(root);
  const runtime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath: null, credentials: new InMemoryCredentialStore(), refreshOnCreate: false, allowModelNetwork: false });
  await runtime.setRuntimeApiKey("typesafe", "synthetic-jev-key");
  const fakeFetch: typeof fetch = async (url, init) => { calls.push({ url: String(url), body: JSON.parse(String(init?.body)) as Record<string, unknown> }); return new Response(JSON.stringify(response), { status: 200, headers: { "content-type": "application/json" } }); };
  return { model: new JevSourceAssessmentModel(runtime, fakeFetch), calls };
}
const input = { title: "Synthetic source", text: "bounded evidence", interests: ["synthetic interest"], source: { uri: "https://example.test/source", mediaType: "text/plain", capturedAt: "2026-01-01T00:00:00.000Z" } };
describe("Pi-backed Jev source assessment", () => {
  it("preserves the assessment contract while sending bounded TypeSafe classifier context", async () => {
    const fixture = await model(); const dispatchOrder: string[] = []; const result = await fixture.model.assess(input, new AbortController().signal, { async beforeDispatch() { dispatchOrder.push("reserved"); }, onDispatch() { dispatchOrder.push("sent"); } });
    expect(result).toMatchObject({ model: JEV_DEFAULT_MODEL, recommendation: "retained", profileVersion: jevProfileVersion(input.interests), rubricVersion: JEV_RUBRIC_VERSION, classification: "research", usage: { inputTokens: 352, outputTokens: 20, pricing: "typesafe-jev-latest-input-0.042-usd-per-million-output-free-estimate" } }); expect(result.usage?.estimatedCostCents).toBeCloseTo(352 * 42 / 10_000_000);
    expect(fixture.calls).toHaveLength(1); expect(fixture.calls[0]?.url).toBe("https://api.typesafe.ai/v1/systemone"); expect(dispatchOrder).toEqual(["reserved", "sent"]);
    const body = fixture.calls[0]!.body; expect(body.model).toBe("jev-latest"); expect(body.questions.admission.type).toBe("choice"); expect(body.questions.topic.type).toBe("choice"); expect(body.questions.score.type).toBe("score"); expect(body.questions.novelty).toBeUndefined(); expect(body.state.text).toBe("bounded evidence");
  });
  it("rejects malformed classifier answers and bad confidence", async () => {
    await expect((await model({ ...answer, answers: { ...answer.answers, admission: { ...answer.answers.admission, confidence: 3 } } })).model.assess({ ...input, interests: [] }, new AbortController().signal)).rejects.toThrow(/Jev classifier request failed/);
    await expect((await model({ ...answer, answers: { ...answer.answers, score: { ...answer.answers.score, score: 8 } } })).model.assess({ ...input, interests: [] }, new AbortController().signal)).rejects.toThrow(/Jev classifier request failed/);
  });
  it("samples oversized UTF-8 evidence without changing the canonical input and labels coverage", async () => {
    const text = "😀quoted\\\"line ".repeat(8_000); const fixture = await model(); const result = await fixture.model.assess({ ...input, text }, new AbortController().signal);
    const request = fixture.calls[0]!.body;
    expect(result.coverage).toBe("sampled"); expect(result.recommendation).toBe("retained"); expect(result.inputDigest).toBeDefined(); expect(result.assessmentInputDigest).toBeDefined();
    expect(request.state.evidenceCoverage).toMatchObject({ mode: "sampled", originalTextCharacters: Array.from(text).length }); expect(request.state.text).toContain("bounded assessment excerpt");
    expect([...String(request.state.text)].join("")).toBe(request.state.text); expect(Buffer.byteLength(JSON.stringify(request.state), "utf8")).toBeLessThanOrEqual(24_000);
  });
  it("keeps sampling bounded at the exact metadata boundary and preserves multibyte evidence", () => {
    const prepared = prepareJevAssessmentInput({ ...input, text: "😀\\\"".repeat(20_000) }, input.interests);
    expect(prepared.coverage).toBe("sampled"); expect(Buffer.byteLength(JSON.stringify(prepared.state), "utf8")).toBeLessThanOrEqual(24_000); expect(String(prepared.state.text)).not.toContain("undefined"); expect(String(prepared.state.text).length).toBeGreaterThanOrEqual(64);
  });
  it("fails before classifier dispatch when metadata leaves no meaningful evidence budget", async () => {
    const calls: Array<{ url: string; body: Record<string, unknown> }> = []; const fixture = await model(answer, calls);
    const interests = Array.from({ length: 50 }, () => "x".repeat(500));
    await expect(fixture.model.assess({ ...input, interests, text: "small evidence" }, new AbortController().signal)).rejects.toThrow(/too small|explicit bound/); expect(calls).toHaveLength(0);
  });
  it("does not archive from a sampled excerpt", async () => {
    const archive = { ...answer, answers: { ...answer.answers, admission: { ...answer.answers.admission, choice: "archive", probabilities: { retain: 0.05, archive: 0.9, pending: 0.05 } }, score: { ...answer.answers.score, score: 0.5 } } };
    const result = await (await model(archive)).model.assess({ ...input, text: "long 😀 evidence ".repeat(8_000) }, new AbortController().signal);
    expect(result.coverage).toBe("sampled"); expect(result.recommendation).toBe("retained");
  });
});
