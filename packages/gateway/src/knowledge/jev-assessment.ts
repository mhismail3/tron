import { createHash } from "node:crypto";
import type { ConnectorCredentialStore } from "./connector-credentials.js";
import type { SourceAssessment } from "./knowledge-contract.js";
import type { SourceAssessmentModel, SourceAssessmentModelInput, SourceAssessmentDispatchContext } from "./source-capture.js";
import { JevDecisionClient, JEV_DEFAULT_MODEL, JEV_ENDPOINT, JEV_MAX_STATE_BYTES, type JevHTTP, type JevChoiceAnswer, type JevScoreAnswer } from "./jev-client.js";

export { JEV_ENDPOINT, JEV_MAX_STATE_BYTES };
export const JEV_MODEL = JEV_DEFAULT_MODEL;
export const JEV_REQUEST_MODEL = JEV_DEFAULT_MODEL;
export const JEV_PROFILE_VERSION = "tron-source-profile-v2";
export const JEV_RUBRIC_VERSION = "tron-source-rubric-v2";

function digest(value: unknown): string { return createHash("sha256").update(JSON.stringify(value)).digest("hex"); }
export function jevProfileVersion(interests: readonly string[]): string { return `${JEV_PROFILE_VERSION}:${digest(interests.slice(0, 50).map(value => value.slice(0, 500)))}`; }
export function jevInputDigest(input: SourceAssessmentModelInput, interests: readonly string[]): string { return digest({ title: input.title, text: input.text, interests: interests.slice(0, 50).map(value => value.slice(0, 500)), source: input.source }); }
function bounded(value: string, maximum: number): string { if (value.length > maximum) throw new Error("Jev assessment input exceeds its explicit bound"); return value; }
export interface JevAssessmentResult extends Omit<SourceAssessment, "generatedAt"> { generatedAt?: string; }

/** Knowledge's narrow rubric adapter over the reusable typed Jev transport. */
export class JevSourceAssessmentModel implements SourceAssessmentModel {
  private readonly client: JevDecisionClient;
  constructor(credentials: ConnectorCredentialStore, http?: JevHTTP) { this.client = new JevDecisionClient(credentials, http); }
  async assess(input: Parameters<SourceAssessmentModel["assess"]>[0], signal: AbortSignal, context?: SourceAssessmentDispatchContext): Promise<JevAssessmentResult> {
    if (signal.aborted) throw new Error("Jev assessment cancelled");
    const interests = input.interests.slice(0, 50).map(value => bounded(value, 500));
    const state = { title: bounded(input.title, 512), text: input.text, source: input.source, interests };
    const result = await this.client.evaluate({ model: JEV_MODEL, state, questions: {
      admission: { type: "choice", instructions: "Choose retain unless this is clearly low-value hype or marketing-only material. Uncertainty favors retain; archive only with clear evidence.", criteria: { retain: "Useful or plausibly useful source.", archive: "Clearly low-value, hype, or marketing-only source.", pending: "Insufficient evidence to decide." } },
      topic: { type: "choice", instructions: "Classify the primary useful category using only the supplied source.", criteria: { technical: "Technical implementation or engineering.", product: "Product, service, or market information.", research: "Research, evidence, or analysis.", workflow: "Workflow or operational practice.", other: "None of the above." } },
      score: { type: "score", instructions: "Rate durable usefulness, not evidence quality, from 0 to 3.", criteria: ["0: no useful evidence", "1: low-value or promotional", "2: potentially useful", "3: clearly useful"] },
    } }, signal, ...(context?.beforeDispatch ? [{ beforeDispatch: context.beforeDispatch }] : []));
    const admission = result.answers.admission as JevChoiceAnswer; const topic = result.answers.topic as JevChoiceAnswer; const usefulness = result.answers.score as JevScoreAnswer;
    const archive = admission.choice === "archive" && admission.confidence >= 0.8 && usefulness.score <= 1;
    return { summary: archive ? "Clear low-value intake classification." : "Useful or uncertain intake classification; retained by policy.", evidenceQuality: "unknown", freshness: "unknown", generatedAt: new Date().toISOString(), model: result.actualModel, recommendation: archive ? "archived" : "retained", confidence: admission.confidence, profileVersion: jevProfileVersion(interests), rubricVersion: JEV_RUBRIC_VERSION, classification: topic.choice, inputDigest: jevInputDigest(input, interests), usage: { inputTokens: result.usage.input_tokens, outputTokens: result.usage.output_tokens, estimatedCostCents: result.estimatedCostCents, pricing: "typesafe-jev-1.13.0-input-0.042-usd-per-million-output-free" } };
  }
}
