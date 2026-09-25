import { Type, type Static } from "@earendil-works/pi-ai";
import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { JevDecisionClient, type JevDecisionRequest } from "./jev-client.js";

const parameters = Type.Object({
  state: Type.Unknown({ description: "Bounded JSON state to evaluate." }),
  questions: Type.Record(Type.String({ pattern: "^[A-Za-z][A-Za-z0-9_-]{0,63}$" }), Type.Unknown(), { minProperties: 1, maxProperties: 16 }),
  model: Type.Optional(Type.String({ minLength: 1, maxLength: 64 })),
  maxChargeCents: Type.Number({ exclusiveMinimum: 0, maximum: 100, description: "Caller-authorized per-call estimated ceiling, checked before dispatch. This does not grant workflow or disclosure authority." }),
}, { additionalProperties: false });
type JevToolParameters = Static<typeof parameters>;

/** First-party explicit Jev evaluation tool. It owns no workflow state or budget ledger. */
export function createJevExtension(client: JevDecisionClient): ExtensionFactory {
  return (pi) => {
    pi.registerTool({
      name: "jev",
      label: "Jev Evaluate",
      description: "Evaluate explicitly supplied bounded JSON with typed Jev choice, noul, or score questions. Jev is a decision adapter, not chat completion; callers must supply their own rubric, disclosure, and budget authority.",
      promptSnippet: "Use jev only for an explicit bounded typed decision; never send secrets or unrequested source data.",
      parameters,
      executionMode: "sequential",
      execute: async (_toolCallId, request: JevToolParameters, signal) => {
        if (!Number.isFinite(request.maxChargeCents) || request.maxChargeCents <= 0 || request.maxChargeCents > 100) throw new Error("Jev requires an explicit per-call maxChargeCents");
        const result = await client.evaluate(request as unknown as JevDecisionRequest, signal ?? new AbortController().signal, { maxChargeCents: request.maxChargeCents });
        const estimatedCostCents = result.estimatedCostCents;
        return { content: [{ type: "text" as const, text: JSON.stringify({ model: result.actualModel, answers: result.answers, usage: result.usage, ...(estimatedCostCents === undefined ? {} : { estimatedCostCents }) }) }], details: { requestedModel: result.requestedModel, actualModel: result.actualModel, answers: result.answers, usage: result.usage, ...(estimatedCostCents === undefined ? {} : { estimatedCostCents }) } };
      },
    });
  };
}
