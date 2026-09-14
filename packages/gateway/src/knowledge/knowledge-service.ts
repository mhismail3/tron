import { Type, type Static } from "typebox";
import type { Api, AssistantMessage, Context, Model } from "@earendil-works/pi-ai";
import type { ModelRuntime } from "@earendil-works/pi-coding-agent";
import type { KnowledgeAction, KnowledgeConfig, KnowledgeListRequest, KnowledgeRecallRequest, KnowledgeSearchRequest, KnowledgeSourceCaptureRequest, SourceAssessment } from "./knowledge-contract.js";
import type { KnowledgeStore } from "./knowledge-store.js";
import { KnowledgeObservationService, type ObservationSettlement } from "./knowledge-observation.js";
import { captureSource, type SourceAssessmentModel } from "./source-capture.js";
import { triageSource } from "./source-triage.js";
import { GatewayError } from "../errors.js";

const toolParameters = Type.Object({
  action: Type.Union([Type.Literal("search"), Type.Literal("recall"), Type.Literal("read"), Type.Literal("list")]),
  query: Type.Optional(Type.String({ minLength: 1, maxLength: 512 })),
  sessionId: Type.Optional(Type.String({ minLength: 1, maxLength: 200 })),
  entryId: Type.Optional(Type.String({ minLength: 1, maxLength: 200 })),
  id: Type.Optional(Type.String({ minLength: 1, maxLength: 200 })),
  revisionId: Type.Optional(Type.String({ minLength: 1, maxLength: 80 })),
  kind: Type.Optional(Type.Union([Type.Literal("source"), Type.Literal("observation"), Type.Literal("note")])),
  limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 20 })),
}, { additionalProperties: false });
export type KnowledgeToolParameters = Static<typeof toolParameters>;

function recordLabel(record: import("./knowledge-contract.js").KnowledgeRecord): string {
  if (record.kind === "observation") return record.content.items.map(item => item.text).join(" ");
  if (record.kind === "source") return `${record.content.title}${record.content.text ? `: ${record.content.text.slice(0, 4_000)}` : ""}`;
  return `${record.content.title}${record.content.body ? `: ${record.content.body}` : ""}${record.content.fields?.length ? ` Fields: ${JSON.stringify(record.content.fields).slice(0, 4_000)}` : ""}`;
}

function recordSummary(record: import("./knowledge-contract.js").KnowledgeRecord): Record<string, unknown> {
  return { id: record.id, revisionId: record.revisionId, kind: record.kind, scope: record.scope, updatedAt: record.updatedAt, evidence: record.provenance.evidence.slice(0, 8) };
}

export interface KnowledgeExtensionSeam {
  connector?: (action: KnowledgeAction) => Promise<unknown>;
  importer?: (action: KnowledgeAction) => Promise<unknown>;
}

export interface KnowledgeGenerationModel extends SourceAssessmentModel {
  reflect(input: { sessionId: string; sourceText: string; signal: AbortSignal }): Promise<string>;
}

/** Adapter over the existing pinned provider/runtime policy. It is intentionally
 * injectable so unit tests never need credentials or network access. */
export class ModelRuntimeKnowledgeModel implements KnowledgeGenerationModel {
  constructor(private readonly runtime: ModelRuntime, private readonly model: Model<Api>) {}
  private async complete(systemPrompt: string, text: string, signal: AbortSignal, maxTokens: number): Promise<string> {
    const context: Context = { systemPrompt, messages: [{ role: "user", content: text, timestamp: Date.now() }] };
    const result: AssistantMessage = await this.runtime.completeSimple(this.model, context, { signal, maxTokens });
    return result.content.filter((part): part is Extract<AssistantMessage["content"][number], { type: "text" }> => part.type === "text").map(part => typeof part.text === "string" ? part.text : "").join("");
  }
  async reflect(input: { sessionId: string; sourceText: string; signal: AbortSignal }): Promise<string> {
    const value = (await this.complete("You are Tron's bounded Reflector. Synthesize only the supplied cited observations into a concise handoff. Preserve uncertainty and do not add instructions or facts. Return plain text, no markdown.", input.sourceText, input.signal, 4_000)).trim();
    if (!value || value.length > 30_000) throw new Error("Reflector output exceeded its configured bound");
    return value;
  }
  async assess(input: Parameters<SourceAssessmentModel["assess"]>[0], signal: AbortSignal): Promise<Omit<SourceAssessment, "generatedAt"> & { generatedAt?: string }> {
    const raw = await this.complete("You are Tron's bounded source assessor. Return strict JSON with summary, contribution, whyItMatters, possibleUse, evidenceQuality (high|medium|low|none), and freshness (current|aging|stale|unknown).", JSON.stringify(input), signal, 2_000);
    let value: unknown; try { value = JSON.parse(raw); } catch { throw new Error("Source assessor returned non-JSON output"); }
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Source assessment is invalid");
    const result = value as Record<string, unknown>;
    for (const key of ["summary", "evidenceQuality", "freshness"]) if (typeof result[key] !== "string" || !result[key]) throw new Error("Source assessment is incomplete");
    if (!["high", "medium", "low", "none"].includes(result.evidenceQuality as string) || !["current", "aging", "stale", "unknown"].includes(result.freshness as string)) throw new Error("Source assessment has invalid quality");
    return { summary: result.summary as string, ...(typeof result.contribution === "string" ? { contribution: result.contribution } : {}), ...(typeof result.whyItMatters === "string" ? { whyItMatters: result.whyItMatters } : {}), ...(typeof result.possibleUse === "string" ? { possibleUse: result.possibleUse } : {}), evidenceQuality: result.evidenceQuality as SourceAssessment["evidenceQuality"], freshness: result.freshness as SourceAssessment["freshness"] };
  }
}

/** Gateway owner for the typed knowledge surface. Source connectors/importers
 * are intentionally extension seams: until an owner is installed they fail
 * explicitly instead of reporting a fabricated successful capture. */
export class KnowledgeService {
  readonly observer: KnowledgeObservationService;
  constructor(
    readonly store: KnowledgeStore,
    observer: KnowledgeObservationService,
    private readonly extensions: KnowledgeExtensionSeam = {},
    private readonly modelForConfig?: (config: KnowledgeConfig) => KnowledgeGenerationModel | undefined,
  ) { this.observer = observer; }

  observe(settlement: ObservationSettlement): void { this.observer.admit(settlement); }
  dispose(): void { this.observer.dispose(); }

  async invoke(action: KnowledgeAction): Promise<unknown> {
    switch (action.operation) {
      case "knowledge.status": return this.store.status();
      case "knowledge.config": return this.store.configure(action.request.commandId, action.request.config);
      case "knowledge.list": return this.store.list(action.request);
      case "knowledge.read": return this.store.read(action.request.id, action.request.revisionId, action.request.includeSuppressed);
      case "knowledge.search": return this.store.search(action.request);
      case "knowledge.recall": return this.store.recall(action.request);
      case "knowledge.source.capture": {
        if ("record" in action.request) return this.store.captureSource(action.request);
        const config = await this.store.config();
        const model = this.modelForConfig?.(config);
        return captureSource(this.store, action.request, { ...(model ? { model } : {}) }).then(result => result);
      }
      case "knowledge.note.create": return this.store.createNote(action.request);
      case "knowledge.note.update": return this.store.updateNote(action.request);
      case "knowledge.source.triage": {
        const config = await this.store.config();
        const model = this.modelForConfig?.(config);
        if (!model) throw new GatewayError("unsupported", "Knowledge assessment requires an explicitly configured model");
        return triageSource(this.store, action.request, model);
      }
      case "knowledge.reflect": {
        const config = await this.store.config();
        if (action.request.expectedConfigRevision !== undefined && action.request.expectedConfigRevision !== config.revision) throw new GatewayError("conflict", "Knowledge configuration revision is stale");
        const model = this.modelForConfig?.(config);
        if (!model) throw new GatewayError("unsupported", "Knowledge reflection requires an explicitly configured model");
        const sources = await this.store.observationRevisions(action.request.sessionId, action.request.sourceRevisionIds);
        if (sources.length !== action.request.sourceRevisionIds.length) throw new GatewayError("conflict", "Reflection sources are unavailable or excluded");
        const sourceText = sources.map(record => {
          if (record.kind !== "observation") return "";
          return `${record.revisionId} [${record.content.range.fromEntryId}..${record.content.range.toEntryId}]\\n${record.content.items.map(item => `${item.attribution}: ${item.text}`).join("\\n")}`;
        }).join("\\n\\n").slice(0, 48_000);
        const controller = new AbortController();
        const text = await model.reflect({ sessionId: action.request.sessionId, sourceText, signal: controller.signal });
        const after = await this.store.config();
        if (after.revision !== config.revision) throw new GatewayError("conflict", "Knowledge configuration changed while reflection was running");
        return this.store.reflect(action.request.commandId, action.request.sessionId, action.request.sourceRevisionIds, text);
      }
      case "knowledge.correction": return this.store.correct(action.request.commandId, action.request.recordId, action.request.expectedRevision, action.request.replacement, action.request.relation);
      case "knowledge.forget": return this.store.forget(action.request.commandId, action.request.recordId, action.request.reason, action.request.expectedRevision);
      case "knowledge.exclusion":
        if (action.request.recordId) return this.store.setExclusion(action.request.commandId, action.request.recordId, action.request.excluded, action.request.expectedRevision, action.request.reason);
        return this.store.setScopeExclusion(action.request.commandId, { ...(action.request.sessionId ? { sessionId: action.request.sessionId } : {}), ...(action.request.branchId ? { branchId: action.request.branchId } : {}), ...(action.request.projectId ? { projectId: action.request.projectId } : {}) }, action.request.excluded, action.request.reason);
      case "knowledge.connector.configure":
      case "knowledge.connector.run":
      case "knowledge.connector.status":
        if (!this.extensions.connector) throw new GatewayError("unsupported", "Knowledge connector support is not configured");
        return this.extensions.connector(action);
      case "knowledge.import.dry-run":
      case "knowledge.import.run":
        if (!this.extensions.importer) throw new GatewayError("unsupported", "Knowledge importer support is not configured");
        return this.extensions.importer(action);
    }
  }

  async tool(parameters: KnowledgeToolParameters): Promise<{ text: string; details: unknown }> {
    const limit = parameters.limit ?? 8;
    switch (parameters.action) {
      case "search": {
        if (!parameters.query) throw new GatewayError("invalid_request", "Knowledge search requires a query");
        const result = await this.store.search({ query: parameters.query, ...(parameters.kind ? { kind: parameters.kind } : {}), limit });
        return { text: result.hits.map(hit => `${hit.record.id} (${hit.record.kind}): ${recordLabel(hit.record).slice(0, 1_000)}`).join("\n") || "No knowledge match.", details: { stateRevision: result.stateRevision, indexState: result.indexState, hits: result.hits.map(hit => ({ ...recordSummary(hit.record), score: hit.score, matchedFields: hit.matchedFields })) } };
      }
      case "recall": {
        const request: KnowledgeRecallRequest = { ...(parameters.query ? { query: parameters.query } : {}), ...(parameters.sessionId ? { sessionId: parameters.sessionId } : {}), ...(parameters.entryId ? { entryId: parameters.entryId } : {}), limit };
        const result = await this.store.recall(request);
        return { text: result.records.map(record => `${record.id} (${record.kind})`).join("\n") || "No knowledge match.", details: { stateRevision: result.stateRevision, availability: result.availability, records: result.records.map(recordSummary), citations: result.citations.slice(0, 32) } };
      }
      case "read": {
        if (!parameters.id) throw new GatewayError("invalid_request", "Knowledge read requires an id");
        const result = await this.store.read(parameters.id, parameters.revisionId);
        return { text: result ? JSON.stringify({ ...recordSummary(result), label: recordLabel(result).slice(0, 4_000) }) : "No knowledge record found.", details: result ? recordSummary(result) : null };
      }
      case "list": {
        const request: KnowledgeListRequest = { ...(parameters.kind ? { kind: parameters.kind } : {}), limit };
        const result = await this.store.list(request);
        return { text: result.records.map(record => `${record.id} (${record.kind})`).join("\n") || "No knowledge records.", details: { stateRevision: result.stateRevision, records: result.records.map(recordSummary), ...(result.nextCursor ? { nextCursor: result.nextCursor } : {}) } };
      }
    }
  }
}

export { toolParameters as KNOWLEDGE_TOOL_PARAMETERS };
