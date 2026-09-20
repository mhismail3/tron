import { describe, expect, it } from "vitest";
import { InMemoryConnectorCredentialStore } from "./connector-credentials.js";
import { JevSourceAssessmentModel, JEV_ENDPOINT, JEV_MODEL, JEV_REQUEST_MODEL, jevProfileVersion } from "./jev-assessment.js";

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
    expect(result).toMatchObject({ model: JEV_MODEL, recommendation: "retained", profileVersion: jevProfileVersion(input.interests), rubricVersion: "tron-source-rubric-v2", classification: "research", usage: { inputTokens: 352, outputTokens: 20, estimatedCostCents: 352 * 42 / 10_000_000, pricing: "typesafe-jev-1.13.0-input-0.042-usd-per-million-output-free" } });
    expect(fixture.calls).toHaveLength(1); expect(fixture.calls[0]?.url).toBe(JEV_ENDPOINT); expect(fixture.calls[0]?.init.headers.authorization).toBe("Bearer synthetic-jev-key");
    const body = JSON.parse(fixture.calls[0]!.init.body); expect(body.model).toBe(JEV_REQUEST_MODEL); expect(body.questions.admission.type).toBe("choice"); expect(body.questions.topic.type).toBe("choice"); expect(body.questions.score.type).toBe("score"); expect(body.questions.novelty).toBeUndefined(); expect(body.state.text).toBe("bounded evidence");
  });
  it("fails closed on malformed or wrong-model results", async () => {
    await expect(model({ ...answer, model: "jev-latest" }).model.assess({ ...input, interests: [] }, new AbortController().signal)).rejects.toThrow(/Jev request or response is invalid/);
    await expect(model({ ...answer, answers: { ...answer.answers, admission: { ...answer.answers.admission, confidence: 3 } } }).model.assess({ ...input, interests: [] }, new AbortController().signal)).rejects.toThrow(/Jev request or response is invalid/);
    await expect(model({ ...answer, answers: { ...answer.answers, score: { ...answer.answers.score, probabilities: { "0": 1, "1": 0, "2": 0, "3": 0 }, score: 2 } } }).model.assess({ ...input, interests: [] }, new AbortController().signal)).rejects.toThrow(/Jev request or response is invalid/);
  });
  it("does not silently truncate oversized evidence or read credentials after preflight rejection", async () => {
    const fixture = model(); await expect(fixture.model.assess({ ...input, text: "x".repeat(24_001) }, new AbortController().signal)).rejects.toThrow(/bound/); expect(fixture.calls).toHaveLength(0);
  });
});
