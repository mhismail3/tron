import type { KnowledgeRecord, SourceAssessment, SourceContent } from "./knowledge-contract.js";
import { KnowledgeStore, type KnowledgeMutationResult } from "./knowledge-store.js";
import { awaitAbortableWithSettlement } from "./model-await.js";
import { sourceEvidenceDigest, type SourceAssessmentModel } from "./source-capture.js";

export interface SourceTriageInput {
  commandId: string;
  sourceId: string;
  expectedRevision: string;
  /** Omit to use the persisted currentInterests config. */
  interests?: string[];
  signal?: AbortSignal;
  /** Internal owner handoff for provider promises that may outlive the bounded wait. */
  retirements?: Promise<void>[];
  /** Paid workflow authority is admitted by the model transport, not here. */
  beforeDispatch?: () => Promise<void>;
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
  const config = await store.config();
  if (input.signal?.aborted) throw new Error("Source triage was cancelled");
  const source = await store.read(input.sourceId, input.expectedRevision, false, true, true);
  if (input.signal?.aborted) throw new Error("Source triage was cancelled");
  const interests = input.interests ?? config.currentInterests ?? [];
  if (!source || source.kind !== "source") throw new Error("Source revision does not exist");
  if (!source.content.text) throw new Error("Source has no readable evidence to assess");
  const signal = input.signal ?? new AbortController().signal;
  // Bound the await: the adapter may ignore its signal, and a stalled triage must
  // not hold the caller open. A late assessment stays fenced by the signal check
  // and revision revalidation below.
  const assessmentOperation = awaitAbortableWithSettlement(model.assess({
    title: source.content.title,
    text: source.content.text,
    interests: interests.slice(0, 50).map(value => value.slice(0, 500)),
    source: { ...(source.content.uri ? { uri: source.content.uri } : {}), ...(source.content.mediaType ? { mediaType: source.content.mediaType } : {}), ...(source.content.collectionId ? { collectionId: source.content.collectionId } : {}), captureDisposition: source.content.captureDisposition, capturedAt: source.content.capturedAt },
  }, signal, ...(input.beforeDispatch ? [{ beforeDispatch: input.beforeDispatch }] : [])), signal, () => new Error("Source triage deadline exceeded or was cancelled"));
  input.retirements?.push(assessmentOperation.settled);
  const assessment = await assessmentOperation.wait;
  if (input.signal?.aborted) throw new Error("Source triage was cancelled");
  const latestConfig = await store.config();
  if (signal.aborted) throw new Error("Source triage was cancelled");
  const latest = await store.read(input.sourceId, input.expectedRevision, false, true, true);
  if (signal.aborted) throw new Error("Source triage was cancelled");
  const excluded = latest?.kind === "source" ? await store.scopeExcluded({ ...(latest.provenance.sessionId ? { sessionId: latest.provenance.sessionId } : {}), ...(latest.provenance.branchId ? { branchId: latest.provenance.branchId } : {}) }) : false;
  if (signal.aborted) throw new Error("Source triage was cancelled");
  if (latestConfig.revision !== config.revision || !latest || latest.kind !== "source" || excluded) throw new Error("Source changed or became unavailable during triage");
  const complete: SourceAssessment = { ...assessment, generatedAt: assessment.generatedAt ?? now(), evidenceDigest: sourceEvidenceDigest(source.content.title, source.content.text ?? "") };
  const content: SourceContent = { ...latest.content, assessment: complete };
  const result: KnowledgeMutationResult = await store.captureSource({
    commandId: input.commandId,
    expectedRevision: source.revisionId,
    signal,
    record: { kind: "source", id: source.id, createdAt: source.createdAt, scope: source.scope, provenance: source.provenance, relations: source.relations, ...(source.temporal ? { temporal: source.temporal } : {}), content },
  });
  if (result.record.kind !== "source") throw new Error("Source triage returned a non-source record");
  return { source: result.record, assessment: complete };
}
