import { describe, expect, it } from "vitest";
import { createJevExtension } from "./jev-extension.js";
import type { JevDecisionClient } from "./jev-client.js";

const answer = { requestedModel: "jev-latest", actualModel: "jev-latest", answers: { decision: { type: "noul" as const, noul: 0.9 }, score: { type: "score" as const, score: 2, legend: { "0": "none" }, probabilities: {}, confidence: 0.8 } }, usage: { input_tokens: 3, output_tokens: 2 }, estimatedCostCents: 0.0000126, maxEstimatedChargeCents: 0.2688 };

describe("first-party Jev tool", () => {
  it("requires an explicit bounded charge ceiling and presents Pi classifier answers", async () => {
    let tool: any;
    const calls: unknown[] = [];
    createJevExtension({ async evaluate(...args: unknown[]) { calls.push(args); return answer; } } as JevDecisionClient)({ registerTool(value: unknown) { tool = value; } } as any);
    expect(tool.name).toBe("jev");
    await expect(tool.execute("call", { state: {}, questions: { decision: { type: "noul", instructions: "Is this useful?" } } }, new AbortController().signal)).rejects.toThrow(/explicit per-call maxChargeCents/);
    const result = await tool.execute("call", { state: {}, questions: { decision: { type: "noul", instructions: "Is this useful?" } }, maxChargeCents: 1 }, new AbortController().signal);
    expect(calls).toHaveLength(1);
    expect(JSON.parse(result.content[0].text)).toMatchObject({ model: "jev-latest", answers: { decision: { type: "bool", probability: 0.9 }, score: { type: "score", score: 2, confidence: 0.8 } } });
    expect(result.details.answers.score).not.toHaveProperty("legend");
    expect(result.details.answers.score).not.toHaveProperty("probabilities");
  });
});
