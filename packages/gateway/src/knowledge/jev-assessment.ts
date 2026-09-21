import { createHash } from "node:crypto";
import type { ConnectorCredentialStore } from "./connector-credentials.js";
import type { SourceAssessment } from "./knowledge-contract.js";
import type { SourceAssessmentModel, SourceAssessmentModelInput, SourceAssessmentDispatchContext } from "./source-capture.js";
import { JevDecisionClient, JEV_DEFAULT_MODEL, JEV_ENDPOINT, JEV_MAX_BODY_BYTES, JEV_MAX_STATE_BYTES, JEV_MAX_STATE_QUESTION_BYTES, type JevHTTP, type JevChoiceAnswer, type JevScoreAnswer, type JevQuestion } from "./jev-client.js";

export { JEV_ENDPOINT, JEV_MAX_STATE_BYTES };
export const JEV_MODEL = JEV_DEFAULT_MODEL;
export const JEV_REQUEST_MODEL = JEV_DEFAULT_MODEL;
export const JEV_PROFILE_VERSION = "tron-source-profile-v2";
export const JEV_RUBRIC_VERSION = "tron-source-rubric-v3";
const PRICING = "typesafe-jev-1.13.0-input-0.042-usd-per-million-output-free" as const;

type AssessmentCoverage = "full" | "sampled";
const MIN_SAMPLED_EVIDENCE_CHARACTERS = 64;
const EXCERPT_MARKER = "\n\n[… bounded assessment excerpt; middle omitted …]\n\n";
function digest(value: unknown): string { return createHash("sha256").update(JSON.stringify(value)).digest("hex"); }
export function jevProfileVersion(interests: readonly string[]): string { return `${JEV_PROFILE_VERSION}:${digest(interests.slice(0, 50).map(value => value.slice(0, 500)))}`; }
/** Digest of the complete source text and source metadata, independent of sampling. */
export function jevInputDigest(input: SourceAssessmentModelInput, interests: readonly string[]): string { return digest({ title: input.title, text: input.text, interests: interests.slice(0, 50).map(value => value.slice(0, 500)), source: input.source }); }
function bounded(value: string, maximum: number): string { if (value.length > maximum) throw new Error("Jev assessment input exceeds its explicit bound"); return value; }
function bytes(value: unknown): number { return Buffer.byteLength(JSON.stringify(value), "utf8"); }
function questions(): Record<string, JevQuestion> { return {
  admission: { type: "choice", instructions: "Choose retain unless this is clearly low-value hype or marketing-only material. Uncertainty favors retain; archive only with clear evidence.", criteria: { retain: "Useful or plausibly useful source.", archive: "Clearly low-value, hype, or marketing-only source.", pending: "Insufficient evidence to decide." } },
  topic: { type: "choice", instructions: "Classify the primary useful category using only the supplied source.", criteria: { technical: "Technical implementation or engineering.", product: "Product, service, or market information.", research: "Research, evidence, or analysis.", workflow: "Workflow or operational practice.", other: "None of the above." } },
  score: { type: "score", instructions: "Rate durable usefulness, not evidence quality, from 0 to 3.", criteria: ["0: no useful evidence", "1: low-value or promotional", "2: potentially useful", "3: clearly useful"] },
}; }
function stateFor(input: SourceAssessmentModelInput, interests: string[], text: string, coverage: AssessmentCoverage, originalTextCharacters: number): Record<string, unknown> {
  return { title: bounded(input.title, 512), text, source: input.source, interests, evidenceCoverage: { mode: coverage, originalTextCharacters, evaluatedTextCharacters: Array.from(text).length } };
}
function fits(state: Record<string, unknown>, rubric: Record<string, unknown>): boolean {
  if (bytes(state) > JEV_MAX_STATE_BYTES || bytes({ model: JEV_MODEL, state, questions: rubric }) > JEV_MAX_BODY_BYTES) return false;
  return Object.values(rubric).every(question => bytes(state) + bytes(question) <= JEV_MAX_STATE_QUESTION_BYTES);
}
function excerpt(points: readonly string[], maximumCharacters: number): string {
  if (points.length <= maximumCharacters) return points.join("");
  const marker = EXCERPT_MARKER;
  const markerLength = Array.from(marker).length;
  if (maximumCharacters <= markerLength) return points.slice(0, maximumCharacters).join("");
  const remaining = maximumCharacters - markerLength;
  const tailLength = Math.floor(remaining / 2);
  const headLength = remaining - tailLength;
  // Do not use slice(-0): JavaScript interprets it as slice(0), defeating the
  // bound when only one character remains after the marker.
  return points.slice(0, headLength).join("") + marker + (tailLength > 0 ? points.slice(-tailLength).join("") : "");
}
/** Prepare the smallest authoritative assessment view without changing the source bytes. */
export function prepareJevAssessmentInput(input: SourceAssessmentModelInput, interests: string[]): { state: Record<string, unknown>; questions: Record<string, JevQuestion>; coverage: AssessmentCoverage } {
  const rubric = questions();
  const points = Array.from(input.text);
  const full = stateFor(input, interests, input.text, "full", points.length);
  if (fits(full, rubric)) return { state: full, questions: rubric, coverage: "full" };
  const minimumExcerptCharacters = MIN_SAMPLED_EVIDENCE_CHARACTERS + Array.from(EXCERPT_MARKER).length;
  let low = minimumExcerptCharacters; let high = points.length; let best: Record<string, unknown> | undefined;
  while (low <= high) {
    const candidateLength = Math.floor((low + high) / 2);
    const candidate = stateFor(input, interests, excerpt(points, candidateLength), "sampled", points.length);
    if (fits(candidate, rubric)) { best = candidate; low = candidateLength + 1; } else high = candidateLength - 1;
  }
  if (!best || Array.from(String(best.text ?? "")).length < minimumExcerptCharacters) throw new Error("Jev assessment evidence is too small after applying its explicit bound");
  return { state: best, questions: rubric, coverage: "sampled" };
}
export interface JevAssessmentResult extends Omit<SourceAssessment, "generatedAt"> { generatedAt?: string; }

/** Knowledge's narrow rubric adapter over the reusable typed Jev transport. */
export class JevSourceAssessmentModel implements SourceAssessmentModel {
  private readonly client: JevDecisionClient;
  constructor(credentials: ConnectorCredentialStore, http?: JevHTTP) { this.client = new JevDecisionClient(credentials, http); }
  async assess(input: Parameters<SourceAssessmentModel["assess"]>[0], signal: AbortSignal, context?: SourceAssessmentDispatchContext): Promise<JevAssessmentResult> {
    if (signal.aborted) throw new Error("Jev assessment cancelled");
    const interests = input.interests.slice(0, 50).map(value => bounded(value, 500));
    const prepared = prepareJevAssessmentInput(input, interests);
    const result = await this.client.evaluate({ model: JEV_MODEL, state: prepared.state, questions: prepared.questions }, signal, ...(context?.beforeDispatch ? [{ beforeDispatch: context.beforeDispatch }] : []));
    const admission = result.answers.admission as JevChoiceAnswer; const topic = result.answers.topic as JevChoiceAnswer; const usefulness = result.answers.score as JevScoreAnswer;
    // A sampled excerpt cannot support a destructive archive decision. It is
    // still useful for classification, but uncertainty favors retention.
    const archive = prepared.coverage === "full" && admission.choice === "archive" && admission.confidence >= 0.8 && usefulness.score <= 1;
    const fullInputDigest = jevInputDigest(input, interests);
    const assessmentInputDigest = digest({ state: prepared.state, questions: prepared.questions });
    return { summary: archive ? "Clear low-value intake classification from complete evidence." : prepared.coverage === "sampled" ? "Sampled assessment; retained because the complete source was not evaluated." : "Useful or uncertain intake classification; retained by policy.", evidenceQuality: "unknown", freshness: "unknown", generatedAt: new Date().toISOString(), model: result.actualModel, recommendation: archive ? "archived" : "retained", confidence: admission.confidence, profileVersion: jevProfileVersion(interests), rubricVersion: JEV_RUBRIC_VERSION, classification: topic.choice, inputDigest: fullInputDigest, assessmentInputDigest, coverage: prepared.coverage, usage: { inputTokens: result.usage.input_tokens, outputTokens: result.usage.output_tokens, estimatedCostCents: result.estimatedCostCents, pricing: PRICING } };
  }
}
