import type { ClassifierContext } from "@earendil-works/pi-ai";
import type { ModelRuntime } from "@earendil-works/pi-coding-agent";

/** Tron pins the model identity to Pi's catalog, but retains a qualified cost
 * because TypeSafe's catalog currently reports zero rather than billable price. */
export const JEV_CLASSIFIER = { provider: "typesafe", model: "jev-latest", inputUsdPerMillion: 0.042, outputUsdPerMillion: 0 } as const;
export const JEV_DEFAULT_MODEL = JEV_CLASSIFIER.model;
export const JEV_MAX_STATE_BYTES = 24_000;
export const JEV_MAX_BODY_BYTES = 60_000;
export const JEV_MAX_STATE_QUESTION_BYTES = 28_000;
const JEV_MAX_QUESTIONS = 16;
const JEV_MAX_RESPONSE_BYTES = 512_000;
const JEV_MAX_JSON_DEPTH = 8;
const INPUT_TOKEN_CEILING = 64_000;

export type JevQuestion =
  | { type: "noul"; instructions: string | Record<string, unknown> | unknown[]; criteria?: { true?: unknown; false?: unknown } }
  | { type: "choice"; instructions: string | Record<string, unknown> | unknown[]; criteria: Record<string, unknown> }
  | { type: "score"; instructions: string | Record<string, unknown> | unknown[]; criteria: [unknown, unknown, ...unknown[]] };
export interface JevDecisionRequest { state: unknown; questions: Record<string, JevQuestion>; model?: string; }
export interface JevNoulAnswer { type: "noul"; noul: number }
export interface JevChoiceAnswer { type: "choice"; choice: string; probabilities: Record<string, number>; confidence: number }
export interface JevScoreAnswer { type: "score"; score: number; legend: Record<string, string>; probabilities: Record<string, number>; confidence: number }
export type JevAnswer = JevNoulAnswer | JevChoiceAnswer | JevScoreAnswer;
interface JevDecisionResponse { requestedModel: string; actualModel: string; answers: Record<string, JevAnswer>; usage: { input_tokens: number; output_tokens: number }; estimatedCostCents: number; maxEstimatedChargeCents: number }
export type JevDispatchCertainty = "notSent" | "sent" | "uncertain";

export class JevEvaluationError extends Error {
  constructor(message: string, readonly certainty: JevDispatchCertainty) { super(message); this.name = "JevEvaluationError"; }
}

export interface JevDispatchContext {
  /** Per-call bound, not a workflow allowance. Workflow owners reserve separately. */
  maxChargeCents?: number;
  beforeDispatch?: () => Promise<void>;
  /** Called immediately before classify is handed to Pi. */
  onDispatch?: (certainty: "sent") => Promise<void> | void;
}

function isRecord(value: unknown): value is Record<string, unknown> { return Boolean(value && typeof value === "object" && !Array.isArray(value)); }
function invalid(): Error { return new Error("Jev request or response is invalid"); }
function description(value: unknown): boolean { return typeof value === "string" || isRecord(value) || Array.isArray(value); }
function assertJSON(value: unknown): void {
  let nodes = 0;
  function visit(item: unknown, depth: number): void {
    if (++nodes > 20_000 || depth > JEV_MAX_JSON_DEPTH) throw invalid();
    if (item === null || typeof item === "string" || typeof item === "boolean") return;
    if (typeof item === "number" && Number.isFinite(item)) return;
    if (Array.isArray(item)) { for (const entry of item) visit(entry, depth + 1); return; }
    if (isRecord(item) && [Object.prototype, null].includes(Object.getPrototypeOf(item))) { for (const entry of Object.values(item)) visit(entry, depth + 1); return; }
    throw invalid();
  }
  visit(value, 0);
}
function byteLength(value: unknown): number { return Buffer.byteLength(JSON.stringify(value), "utf8"); }
function inputCostCents(tokens: number): number { return tokens * JEV_CLASSIFIER.inputUsdPerMillion * 100 / 1_000_000; }
export const JEV_MAX_ESTIMATED_CHARGE_CENTS = inputCostCents(INPUT_TOKEN_CEILING);
function boundedString(value: unknown): string { return typeof value === "string" ? value : JSON.stringify(value); }
function validatedContext(request: JevDecisionRequest): ClassifierContext {
  assertJSON(request.state); assertJSON(request.questions);
  if (!isRecord(request.state) || !isRecord(request.questions)) throw invalid();
  const questions = Object.entries(request.questions);
  if (!questions.length || questions.length > JEV_MAX_QUESTIONS || byteLength(request.state) > JEV_MAX_STATE_BYTES) throw new Error("Jev request exceeds its explicit bound");
  const converted: ClassifierContext["questions"] = {};
  for (const [id, question] of questions) {
    if (!/^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(id) || !isRecord(question) || !description(question.instructions) || Object.keys(question).some(key => !["type", "instructions", "criteria"].includes(key))) throw invalid();
    const instructions = boundedString(question.instructions);
    if (question.type === "choice" && isRecord(question.criteria) && Object.keys(question.criteria).length >= 2 && Object.keys(question.criteria).length <= 255) {
      converted[id] = { type: "choice", instructions, criteria: Object.fromEntries(Object.entries(question.criteria).map(([key, value]) => [key, boundedString(value)])) };
    } else if (question.type === "score" && Array.isArray(question.criteria) && question.criteria.length >= 2 && question.criteria.length <= 10) {
      converted[id] = { type: "score", instructions, criteria: question.criteria.map(boundedString) };
    } else if (question.type === "noul" && (question.criteria === undefined || isRecord(question.criteria))) {
      const criteria = isRecord(question.criteria) ? question.criteria : {};
      converted[id] = { type: "bool", instructions, criteria: { true: boundedString(criteria.true ?? "The statement is true."), false: boundedString(criteria.false ?? "The statement is false.") } };
    } else throw invalid();
    if (byteLength(request.state) + byteLength(question) > JEV_MAX_STATE_QUESTION_BYTES) throw new Error("Jev state plus question exceeds its explicit bound");
  }
  if (byteLength({ model: JEV_DEFAULT_MODEL, state: request.state, questions: converted }) > JEV_MAX_BODY_BYTES) throw new Error("Jev request exceeds its explicit bound");
  return { state: request.state as ClassifierContext["state"], questions: converted };
}
function answerRecord(result: Record<string, unknown>, request: JevDecisionRequest): Record<string, JevAnswer> {
  const answers: Record<string, JevAnswer> = Object.create(null);
  for (const [id, question] of Object.entries(request.questions)) {
    const answer = result[id];
    if (!isRecord(answer)) throw invalid();
    if (question.type === "noul" && answer.type === "bool" && typeof answer.probability === "number" && Number.isFinite(answer.probability) && answer.probability >= 0 && answer.probability <= 1) {
      answers[id] = { type: "noul", noul: answer.probability };
    } else if (question.type === "choice" && answer.type === "choice" && typeof answer.choice === "string" && isRecord(answer.probabilities) && typeof answer.confidence === "number") {
      const options = Object.keys(question.criteria);
      if (!options.includes(answer.choice) || Object.keys(answer.probabilities).length !== options.length || options.some(option => { const probability = (answer.probabilities as Record<string, unknown>)[option]; return typeof probability !== "number" || !Number.isFinite(probability) || probability < 0 || probability > 1; }) || Math.abs(Object.values(answer.probabilities as Record<string, number>).reduce((sum, value) => sum + value, 0) - 1) > 0.02 || typeof answer.confidence !== "number" || !Number.isFinite(answer.confidence) || answer.confidence < 0 || answer.confidence > 1 || (answer.probabilities as Record<string, number>)[answer.choice] !== Math.max(...Object.values(answer.probabilities as Record<string, number>))) throw invalid();
      answers[id] = { type: "choice", choice: answer.choice, probabilities: answer.probabilities as Record<string, number>, confidence: answer.confidence };
    } else if (question.type === "score" && answer.type === "score" && typeof answer.score === "number" && Number.isFinite(answer.score) && answer.score >= 0 && answer.score <= question.criteria.length - 1 && typeof answer.confidence === "number" && Number.isFinite(answer.confidence) && answer.confidence >= 0 && answer.confidence <= 1) {
      answers[id] = { type: "score", score: answer.score, legend: Object.fromEntries(question.criteria.map((criterion, index) => [String(index), boundedString(criterion)])), probabilities: {}, confidence: answer.confidence };
    } else throw invalid();
  }
  return answers;
}

/** Bounded adapter over Pi's classifier path; Pi owns provider auth and HTTP dispatch. */
export class JevDecisionClient {
  constructor(private readonly runtime: ModelRuntime, private readonly fetchImpl?: typeof fetch) {}
  async evaluate(request: JevDecisionRequest, signal: AbortSignal, context: JevDispatchContext = {}): Promise<JevDecisionResponse> {
    if (signal.aborted) throw new JevEvaluationError("Jev evaluation cancelled", "notSent");
    const requestedModel = request.model ?? JEV_DEFAULT_MODEL;
    if (requestedModel !== JEV_DEFAULT_MODEL) throw new Error("Jev model is not configured");
    const classifierContext = validatedContext(request);
    const maxEstimatedChargeCents = inputCostCents(INPUT_TOKEN_CEILING);
    if (context.maxChargeCents !== undefined && (!Number.isFinite(context.maxChargeCents) || context.maxChargeCents <= 0 || maxEstimatedChargeCents > context.maxChargeCents)) throw new Error("Jev request exceeds maxChargeCents before dispatch");
    const model = this.runtime.getModelOfType("classifier", JEV_CLASSIFIER.provider, JEV_DEFAULT_MODEL);
    if (!model) throw new Error("Pi's TypeSafe Jev classifier is unavailable");
    if (!this.runtime.getProviderAuthStatus(JEV_CLASSIFIER.provider).configured) throw new Error("TypeSafe provider credential is not configured");
    assertJSON(request);
    try {
      await context.beforeDispatch?.();
      if (signal.aborted) throw new JevEvaluationError("Jev evaluation cancelled", "notSent");
      await context.onDispatch?.("sent");
      if (signal.aborted) throw new JevEvaluationError("Jev evaluation cancelled", "notSent");
    } catch (error) {
      if (error instanceof JevEvaluationError) throw error;
      throw new JevEvaluationError("Jev evaluation was not dispatched", "notSent");
    }
    try {
      const upstreamFetch = this.fetchImpl ?? globalThis.fetch;
      const boundedFetch: typeof fetch = async (input, init) => {
        const response = await upstreamFetch(input, init);
        const declaredLength = Number(response.headers.get("content-length"));
        if (Number.isFinite(declaredLength) && declaredLength > JEV_MAX_RESPONSE_BYTES) throw new Error("Jev classifier response exceeded its explicit bound");
        const reader = response.body?.getReader();
        if (!reader) return new Response(null, { status: response.status, statusText: response.statusText, headers: response.headers });
        const chunks: Uint8Array[] = []; let total = 0;
        try {
          while (true) {
            const next = await reader.read();
            if (next.done) break;
            total += next.value.byteLength;
            if (total > JEV_MAX_RESPONSE_BYTES) { await reader.cancel(); throw new Error("Jev classifier response exceeded its explicit bound"); }
            chunks.push(next.value);
          }
        } finally { reader.releaseLock(); }
        return new Response(Buffer.concat(chunks, total), { status: response.status, statusText: response.statusText, headers: response.headers });
      };
      const result = await this.runtime.classify(model, classifierContext, { signal, fetch: boundedFetch });
      if (signal.aborted) throw new Error("Jev evaluation cancelled after dispatch");
      if (result.stopReason !== "stop" || !isRecord(result.answers)) throw new Error("Jev classifier did not complete");
      const usage = result.usage;
      const inputTokens = usage?.input ?? 0; const outputTokens = usage?.output ?? 0;
      if (!Number.isSafeInteger(inputTokens) || inputTokens < 0 || inputTokens > INPUT_TOKEN_CEILING || !Number.isSafeInteger(outputTokens) || outputTokens < 0) throw invalid();
      return { requestedModel, actualModel: result.model, answers: answerRecord(result.answers as Record<string, unknown>, request), usage: { input_tokens: inputTokens, output_tokens: outputTokens }, estimatedCostCents: inputCostCents(inputTokens), maxEstimatedChargeCents };
    } catch (error) {
      if (error instanceof JevEvaluationError) throw error;
      throw new JevEvaluationError(signal.aborted ? "Jev evaluation cancelled" : "Jev classifier request failed", "uncertain");
    }
  }
}
