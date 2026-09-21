import type { ConnectorCredentialStore } from "./connector-credentials.js";

export const JEV_ENDPOINT = "https://api.typesafe.ai/v1/systemone";
export const JEV_DEFAULT_MODEL = "jev-1.13.0";
export const JEV_MAX_STATE_BYTES = 24_000;
export const JEV_MAX_BODY_BYTES = 60_000;
export const JEV_MAX_STATE_QUESTION_BYTES = 28_000;
export const JEV_MAX_RESPONSE_BYTES = 512_000;
export const JEV_MAX_QUESTIONS = 16;
export const JEV_MAX_JSON_DEPTH = 8;
// Published direct price for this exact supported version: $0.042/M input,
// output free. New versions require explicit contract/pricing qualification.
function inputCostCents(tokens: number): number { return tokens * 42 / 10_000_000; }
const INPUT_TOKEN_CEILING = 64_000;

export interface JevHTTPResponse { status: number; body: string; }
export type JevHTTP = (input: string, init: { method: "POST"; headers: Record<string, string>; body: string; signal: AbortSignal }) => Promise<JevHTTPResponse>;
export type JevQuestion =
  | { type: "noul"; instructions: string | Record<string, unknown> | unknown[]; criteria?: { true?: unknown; false?: unknown } }
  | { type: "choice"; instructions: string | Record<string, unknown> | unknown[]; criteria: Record<string, unknown> }
  | { type: "score"; instructions: string | Record<string, unknown> | unknown[]; criteria: [unknown, unknown, ...unknown[]] };
export interface JevDecisionRequest { state: unknown; questions: Record<string, JevQuestion>; model?: string; }
export interface JevNoulAnswer { type: "noul"; noul: number }
export interface JevChoiceAnswer { type: "choice"; choice: string; probabilities: Record<string, number>; confidence: number }
export interface JevScoreAnswer { type: "score"; score: number; legend: Record<string, string>; probabilities: Record<string, number>; confidence: number }
export type JevAnswer = JevNoulAnswer | JevChoiceAnswer | JevScoreAnswer;
export interface JevDecisionResponse { requestedModel: string; actualModel: string; answers: Record<string, JevAnswer>; usage: { input_tokens: number; output_tokens: number }; estimatedCostCents: number; maxEstimatedChargeCents: number }
export type JevDispatchCertainty = "notSent" | "sent" | "uncertain";

export class JevEvaluationError extends Error {
  constructor(message: string, readonly certainty: JevDispatchCertainty) { super(message); this.name = "JevEvaluationError"; }
}

export interface JevDispatchContext {
  /** Per-call bound, not a workflow allowance. Workflow owners reserve separately. */
  maxChargeCents?: number;
  beforeDispatch?: () => Promise<void>;
  /** Called immediately before the POST is handed to the HTTP transport. */
  onDispatch?: (certainty: "sent") => void;
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
    if (isRecord(item) && [Object.prototype, null].includes(Object.getPrototypeOf(item))) {
      for (const entry of Object.values(item)) visit(entry, depth + 1);
      return;
    }
    throw invalid();
  }
  visit(value, 0);
}
function finiteProbabilityMap(value: unknown, expected: readonly string[]): Record<string, number> {
  if (!isRecord(value) || Object.keys(value).length !== expected.length || Object.keys(value).some(key => !expected.includes(key))) throw invalid();
  const result: Record<string, number> = Object.create(null); let sum = 0;
  for (const key of expected) {
    const probability = value[key];
    if (typeof probability !== "number" || !Number.isFinite(probability) || probability < 0 || probability > 1) throw invalid();
    result[key] = probability; sum += probability;
  }
  if (Math.abs(sum - 1) > 0.02) throw invalid();
  return result;
}
function confidence(value: unknown): number { if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || value > 1) throw invalid(); return value; }
function validateAnswer(value: unknown, question: JevQuestion): JevAnswer {
  if (!isRecord(value) || value.type !== question.type) throw invalid();
  if (question.type === "noul") return { type: "noul", noul: confidence(value.noul) };
  if (question.type === "choice") {
    const options = Object.keys(question.criteria);
    if (typeof value.choice !== "string" || !options.includes(value.choice)) throw invalid();
    const probabilities = finiteProbabilityMap(value.probabilities, options);
    if (probabilities[value.choice] !== Math.max(...Object.values(probabilities))) throw invalid();
    return { type: "choice", choice: value.choice, probabilities, confidence: confidence(value.confidence) };
  }
  const levels = question.criteria.map((_, index) => String(index));
  const legend = isRecord(value.legend) ? value.legend : undefined;
  if (typeof value.score !== "number" || !Number.isFinite(value.score) || value.score < 0 || value.score > levels.length - 1 || !legend || Object.keys(legend).length !== levels.length || levels.some(level => typeof legend[level] !== "string")) throw invalid();
  levels.forEach((level, index) => { const criterion = question.criteria[index]; if (typeof criterion === "string" && legend[level] !== criterion) throw invalid(); });
  const probabilities = finiteProbabilityMap(value.probabilities, levels);
  const expected = levels.reduce((sum, level) => sum + Number(level) * probabilities[level]!, 0);
  if (Math.abs(expected - value.score) > 0.15) throw invalid();
  return { type: "score", score: value.score, legend: legend as Record<string, string>, probabilities, confidence: confidence(value.confidence) };
}
function validateRequest(request: JevDecisionRequest, model: string): string {
  assertJSON(request.state); assertJSON(request.questions);
  if (!description(request.state) || !isRecord(request.questions)) throw invalid();
  const questions = Object.entries(request.questions);
  if (questions.length === 0 || questions.length > JEV_MAX_QUESTIONS) throw invalid();
  const stateBytes = Buffer.byteLength(JSON.stringify(request.state), "utf8");
  if (stateBytes > JEV_MAX_STATE_BYTES) throw new Error("Jev request exceeds its explicit bound");
  for (const [id, question] of questions) {
    if (!/^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(id) || !isRecord(question) || !description(question.instructions) || Object.keys(question).some(key => !["type", "instructions", "criteria"].includes(key))) throw invalid();
    if (question.type === "choice" && (!isRecord(question.criteria) || Object.keys(question.criteria).length < 2 || Object.keys(question.criteria).length > 255 || Object.values(question.criteria).some(value => value !== null && !description(value)))) throw invalid();
    if (question.type === "score" && (!Array.isArray(question.criteria) || question.criteria.length < 2 || question.criteria.length > 10 || question.criteria.some(value => !description(value)))) throw invalid();
    if (question.type === "noul" && question.criteria !== undefined && (!isRecord(question.criteria) || Object.entries(question.criteria).some(([key, value]) => !["true", "false"].includes(key) || !description(value)))) throw invalid();
    if (question.type !== "choice" && question.type !== "score" && question.type !== "noul") throw invalid();
    // State plus each question has a separate provider ceiling. UTF-8 bytes
    // are a conservative bound here, not a claim to exact provider tokenization.
    if (stateBytes + Buffer.byteLength(JSON.stringify(question), "utf8") > JEV_MAX_STATE_QUESTION_BYTES) throw new Error("Jev state plus question exceeds its explicit bound");
  }
  const body = JSON.stringify({ model, state: request.state, questions: request.questions });
  if (Buffer.byteLength(body, "utf8") > JEV_MAX_BODY_BYTES) throw new Error("Jev request exceeds its explicit bound");
  return body;
}
async function boundedResponse(response: Response): Promise<string> {
  if (!response.body) return "";
  const reader = response.body.getReader(); const chunks: Uint8Array[] = []; let total = 0;
  try {
    for (;;) {
      const next = await reader.read(); if (next.done) break; if (!next.value) continue;
      total += next.value.byteLength;
      if (total > JEV_MAX_RESPONSE_BYTES) { await reader.cancel(); throw new Error("Jev response exceeded its bounded body limit"); }
      chunks.push(next.value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(total); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return new TextDecoder().decode(bytes);
}
async function defaultHTTP(input: string, init: Parameters<JevHTTP>[1]): Promise<JevHTTPResponse> {
  const response = await fetch(input, { method: init.method, headers: init.headers, body: init.body, redirect: "error", signal: AbortSignal.any([init.signal, AbortSignal.timeout(20_000)]) });
  return { status: response.status, body: await boundedResponse(response) };
}
function assertActive(signal: AbortSignal): void { if (signal.aborted) throw new Error("Jev evaluation cancelled"); }

/** Stateless typed transport. Callers own disclosure, workflow allowances and persistence. */
export class JevDecisionClient {
  constructor(private readonly credentials: ConnectorCredentialStore, private readonly http: JevHTTP = defaultHTTP) {}
  async evaluate(request: JevDecisionRequest, signal: AbortSignal, context: JevDispatchContext = {}): Promise<JevDecisionResponse> {
    assertActive(signal);
    const requestedModel = request.model ?? JEV_DEFAULT_MODEL;
    if (requestedModel !== JEV_DEFAULT_MODEL) throw new Error("Jev model is not configured");
    // Snapshot before any await: caller mutation cannot change the transmitted
    // rubric or the response validator after the paid request is admitted.
    const body = validateRequest(request, requestedModel);
    const admitted = JSON.parse(body) as JevDecisionRequest;
    const maxEstimatedChargeCents = inputCostCents(INPUT_TOKEN_CEILING);
    if (context.maxChargeCents !== undefined && (!Number.isFinite(context.maxChargeCents) || context.maxChargeCents <= 0 || maxEstimatedChargeCents > context.maxChargeCents)) throw new Error("Jev request exceeds maxChargeCents before dispatch");
    const token = await this.credentials.read("connector:jev:personal");
    if (!token) throw new Error("Jev capability is not configured");
    assertActive(signal);
    await context.beforeDispatch?.();
    assertActive(signal);
    let response: JevHTTPResponse;
    try {
      try { context.onDispatch?.("sent"); }
      catch (error) { if (error instanceof JevEvaluationError) throw error; throw new JevEvaluationError("Jev dispatch admission was revoked", "notSent"); }
      response = await this.http(JEV_ENDPOINT, { method: "POST", headers: { authorization: `Bearer ${token}`, accept: "application/json", "content-type": "application/json" }, body, signal });
    } catch (error) {
      if (error instanceof JevEvaluationError) throw error;
      throw new JevEvaluationError(signal.aborted ? "Jev evaluation cancelled" : "Jev provider request failed", "uncertain");
    }
    try { assertActive(signal); } catch { throw new JevEvaluationError("Jev evaluation was cancelled after dispatch", "uncertain"); }
    if (response.status < 200 || response.status >= 300) throw new JevEvaluationError(`Jev request failed (${response.status})`, "uncertain");
    if (Buffer.byteLength(response.body, "utf8") > JEV_MAX_RESPONSE_BYTES) throw new JevEvaluationError("Jev response exceeded its bounded body limit", "uncertain");
    let value: unknown; try { value = JSON.parse(response.body); } catch { throw new JevEvaluationError("Jev response is invalid", "uncertain"); }
    const usage = isRecord(value) && isRecord(value.usage) ? value.usage : undefined;
    if (!isRecord(value) || value.model !== requestedModel || !isRecord(value.answers) || Object.keys(value.answers).length !== Object.keys(admitted.questions).length || !usage || !Number.isSafeInteger(usage.input_tokens) || !Number.isSafeInteger(usage.output_tokens) || (usage.input_tokens as number) < 0 || (usage.input_tokens as number) > INPUT_TOKEN_CEILING || (usage.output_tokens as number) < 0) throw invalid();
    const answers: Record<string, JevAnswer> = Object.create(null);
    for (const [id, question] of Object.entries(admitted.questions)) {
      if (!Object.hasOwn(value.answers, id)) throw invalid();
      answers[id] = validateAnswer(value.answers[id], question);
    }
    const usageResult = { input_tokens: usage.input_tokens as number, output_tokens: usage.output_tokens as number };
    return { requestedModel, actualModel: value.model, answers, usage: usageResult, estimatedCostCents: inputCostCents(usageResult.input_tokens), maxEstimatedChargeCents };
  }
}
