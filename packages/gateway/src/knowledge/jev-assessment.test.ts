import { describe, expect, it } from "vitest";
import { InMemoryConnectorCredentialStore } from "./connector-credentials.js";
import { JevSourceAssessmentModel, JEV_ENDPOINT, JEV_MODEL, JEV_RUBRIC_VERSION, jevProfileVersion, prepareJevAssessmentInput } from "./jev-assessment.js";

const answer = {
  model: JEV_MODEL,
  answers: {
    admission: { type: "choice", choice: "retain", probabilities: { retain: 0.9, archive: 0.05, pending: 0.05 }, confidence: 0.9 },
    topic: { type: "choice", choice: "research", probabilities: { technical: 0.05, product: 0.05, research: 0.8, workflow: 0.05, other: 0.05 }, confidence: 0.9 },
    score: { type: "score", score: 2.5, legend: { "0": "0: no useful evidence", "1": "1: low-value or promotional", "2": "2: potentially useful", "3": "3: clearly useful" }, probabilities: { "0": 0, "1": 0, "2": 0.5, "3": 0.5 }, confidence: 0.9 },
  },
  usage: { input_tokens: 352, output_tokens: 20 },
};
function model(response: unknown = answer, calls: Array<{ url: string; init: { headers: Record<string, string>; body: string } }> = []) {
  return { model: new JevSourceAssessmentModel(new InMemoryConnectorCredentialStore(new Map([["connector:jev:personal", "synthetic-jev-key"]])), async (url, init) => { calls.push({ url, init }); return { status: 200, body: JSON.stringify(response) }; }), calls };
}
const input = { title: "Synthetic source", text: "bounded evidence", interests: ["synthetic interest"], source: { uri: "https://example.test/source", mediaType: "text/plain", capturedAt: "2026-01-01T00:00:00.000Z" } };
describe("Jev source assessment adapter", () => {
  it("uses the documented typed response schema and bounded evidence", async () => {
    const fixture = model(); const result = await fixture.model.assess(input, new AbortController().signal);
    expect(result).toMatchObject({ model: JEV_MODEL, recommendation: "retained", profileVersion: jevProfileVersion(input.interests), rubricVersion: JEV_RUBRIC_VERSION, classification: "research", usage: { inputTokens: 352, outputTokens: 20, estimatedCostCents: 352 * 42 / 10_000_000, pricing: "typesafe-jev-1.13.0-input-0.042-usd-per-million-output-free" } });
    expect(fixture.calls).toHaveLength(1); expect(fixture.calls[0]?.url).toBe(JEV_ENDPOINT); expect(fixture.calls[0]?.init.headers.authorization).toBe("Bearer synthetic-jev-key");
    const body = JSON.parse(fixture.calls[0]!.init.body); expect(body.model).toBe(JEV_MODEL); expect(body.questions.admission.type).toBe("choice"); expect(body.questions.topic.type).toBe("choice"); expect(body.questions.score.type).toBe("score"); expect(body.questions.novelty).toBeUndefined(); expect(body.state.text).toBe("bounded evidence");
  });
  it("fails closed on malformed or wrong-model results", async () => {
    await expect(model({ ...answer, model: "jev-latest" }).model.assess({ ...input, interests: [] }, new AbortController().signal)).rejects.toThrow(/Jev request or response is invalid/);
    await expect(model({ ...answer, answers: { ...answer.answers, admission: { ...answer.answers.admission, confidence: 3 } } }).model.assess({ ...input, interests: [] }, new AbortController().signal)).rejects.toThrow(/Jev request or response is invalid/);
    await expect(model({ ...answer, answers: { ...answer.answers, score: { ...answer.answers.score, probabilities: { "0": 1, "1": 0, "2": 0, "3": 0 }, score: 2 } } }).model.assess({ ...input, interests: [] }, new AbortController().signal)).rejects.toThrow(/Jev request or response is invalid/);
  });
  it("samples oversized UTF-8 evidence without changing the canonical input and labels coverage", async () => {
    const text = "😀quoted\\\"line ".repeat(8_000);
    const fixture = model(); const result = await fixture.model.assess({ ...input, text }, new AbortController().signal);
    const request = JSON.parse(fixture.calls[0]!.init.body);
    expect(result.coverage).toBe("sampled"); expect(result.recommendation).toBe("retained");
    expect(result.inputDigest).toBeDefined(); expect(result.assessmentInputDigest).toBeDefined();
    expect(request.state.evidenceCoverage).toMatchObject({ mode: "sampled", originalTextCharacters: Array.from(text).length });
    expect(request.state.text).toContain("bounded assessment excerpt");
    expect([...request.state.text].join("")).toBe(request.state.text);
    expect(Buffer.byteLength(JSON.stringify(request.state), "utf8")).toBeLessThanOrEqual(24_000);
  });
  it("keeps sampling bounded at the exact metadata boundary and preserves multibyte evidence", () => {
    const prepared = prepareJevAssessmentInput({ ...input, text: "😀\\\"".repeat(20_000) }, input.interests);
    expect(prepared.coverage).toBe("sampled");
    const body = JSON.stringify(prepared.state);
    expect(Buffer.byteLength(body, "utf8")).toBeLessThanOrEqual(24_000);
    expect(String(prepared.state.text)).not.toContain("undefined");
    expect(String(prepared.state.text).length).toBeGreaterThanOrEqual(64);
  });
  it("fails before credentials or HTTP when metadata leaves no meaningful evidence budget", async () => {
    const calls: unknown[] = [];
    const fixture = model(answer, calls as any);
    const interests = Array.from({ length: 50 }, () => "x".repeat(500));
    await expect(fixture.model.assess({ ...input, interests, text: "small evidence" }, new AbortController().signal)).rejects.toThrow(/too small|explicit bound/);
    expect(fixture.calls).toHaveLength(0);
  });
  it("does not archive from a sampled excerpt", async () => {
    const archive = { ...answer, answers: { ...answer.answers, admission: { ...answer.answers.admission, choice: "archive", probabilities: { retain: 0.05, archive: 0.9, pending: 0.05 } }, score: { ...answer.answers.score, score: 0.5, probabilities: { "0": 0.5, "1": 0.5, "2": 0, "3": 0 } } } };
    const result = await model(archive).model.assess({ ...input, text: "long 😀 evidence ".repeat(8_000) }, new AbortController().signal);
    expect(result.coverage).toBe("sampled"); expect(result.recommendation).toBe("retained");
  });
});
