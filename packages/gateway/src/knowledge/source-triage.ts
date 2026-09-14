import type { KnowledgeRecord, SourceAssessment, SourceContent } from "./knowledge-contract.js";
import { KnowledgeStore, type KnowledgeMutationResult } from "./knowledge-store.js";
import type { SourceAssessmentModel } from "./source-capture.js";

export interface SourceTriageInput {
  commandId: string;
  sourceId: string;
  expectedRevision: string;
  /** Omit to use the persisted currentInterests config. */
  interests?: string[];
  signal?: AbortSignal;
}

export interface SourceTriageResult {
  source: KnowledgeRecord & { kind: "source" };
  assessment: SourceAssessment;
}

/**
 * Triage is an optional derivative of a retained source. It receives bounded
 * readable text only; the adapter is supplied by the existing model owner.
 */
export async function triageSource(store: KnowledgeStore, input: SourceTriageInput, model: SourceAssessmentModel, now: () => string = () => new Date().toISOString()): Promise<SourceTriageResult> {
  const source = await store.read(input.sourceId, input.expectedRevision);
  if (input.signal?.aborted) throw new Error("Source triage was cancelled");
  const interests = input.interests ?? (await store.config()).currentInterests ?? [];
  if (!source || source.kind !== "source") throw new Error("Source revision does not exist");
  if (!source.content.text) throw new Error("Source has no readable evidence to assess");
  const assessment = await model.assess({
    title: source.content.title,
    text: source.content.text.slice(0, 100_000),
    interests: interests.slice(0, 50).map(value => value.slice(0, 500)),
    source: { ...(source.content.uri ? { uri: source.content.uri } : {}), ...(source.content.mediaType ? { mediaType: source.content.mediaType } : {}), capturedAt: source.content.capturedAt },
  }, input.signal ?? new AbortController().signal);
  const complete: SourceAssessment = { ...assessment, generatedAt: assessment.generatedAt ?? now() };
  const content: SourceContent = { ...source.content, assessment: complete };
  const result: KnowledgeMutationResult = await store.captureSource({
    commandId: input.commandId,
    expectedRevision: source.revisionId,
    record: { kind: "source", id: source.id, createdAt: source.createdAt, scope: source.scope, provenance: source.provenance, relations: source.relations, ...(source.temporal ? { temporal: source.temporal } : {}), content },
  });
  if (result.record.kind !== "source") throw new Error("Source triage returned a non-source record");
  return { source: result.record, assessment: complete };
}
