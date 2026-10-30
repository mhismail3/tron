import { Type, type Static } from "../kernel/pi/ai.js";
import type { KnowledgeAction, KnowledgeRecord } from "./knowledge-contract.js";
import type { KnowledgeStore } from "./knowledge-store.js";
import { GatewayError } from "../errors.js";

/** Profile still owns live notes here until #2138. Research is ordinary files;
 * neither this owner nor its tool can read sources or retired observations. */
export const KNOWLEDGE_TOOL_PARAMETERS = Type.Object({
  action: Type.Union([Type.Literal("read"), Type.Literal("list")]),
  id: Type.Optional(Type.String({ minLength: 1, maxLength: 200 })),
  revisionId: Type.Optional(Type.String({ minLength: 1, maxLength: 80 })),
  offset: Type.Optional(Type.Integer({ minimum: 0, maximum: 8_000_000 })),
  cursor: Type.Optional(Type.String({ minLength: 1, maxLength: 200 })),
  limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 25 })),
}, { additionalProperties: false });
export type KnowledgeToolParameters = Static<typeof KNOWLEDGE_TOOL_PARAMETERS>;

function recordLabel(record: KnowledgeRecord): string {
  const temporal = record.temporal ? ` temporal=${JSON.stringify(record.temporal)}` : "";
  return `${record.content.title} [role=${record.content.role} confirmed: ${record.content.confirmed}${record.content.freshness ? ` freshness=${record.content.freshness}` : ""}]${temporal} provenance=${JSON.stringify(record.provenance)} relations=${JSON.stringify(record.relations)} note=${JSON.stringify(record.content)}`;
}
function recordSummary(record: KnowledgeRecord): Record<string, unknown> {
  return { id: record.id, revisionId: record.revisionId, kind: record.kind, scope: record.scope, updatedAt: record.updatedAt, evidence: record.provenance.evidence.slice(0, 8) };
}

export class KnowledgeService {
  constructor(readonly store: KnowledgeStore) {}

  async invoke(action: KnowledgeAction): Promise<unknown> {
    switch (action.operation) {
      case "knowledge.list": return this.store.list(action.request);
      case "knowledge.read": return this.store.read(action.request.id, action.request.revisionId, action.request.includeSuppressed);
      case "knowledge.note.create": {
        const request = action.request;
        const record = { ...request.record, content: { ...request.record.content, confirmed: request.confirmedByUser === true && request.record.content.confirmed } };
        return this.store.createNote({ ...request, record });
      }
      case "knowledge.note.update": {
        const request = action.request;
        const record = { ...request.record, content: { ...request.record.content, confirmed: request.confirmedByUser === true && request.record.content.confirmed } };
        return this.store.updateNote({ ...request, record });
      }
    }
    throw new GatewayError("unsupported", "Only active Profile note operations remain");
  }

  async tool(parameters: KnowledgeToolParameters): Promise<{ text: string; details: unknown }> {
    if (parameters.action === "read") {
      if (!parameters.id) throw new GatewayError("invalid_request", "Profile note read requires an id");
      const result = await this.store.read(parameters.id, parameters.revisionId);
      if (!result) return { text: "No Profile note found.", details: null };
      const label = recordLabel(result);
      const offset = parameters.offset ?? 0;
      if (!Number.isSafeInteger(offset) || offset < 0 || offset > label.length) throw new GatewayError("invalid_request", "Profile note read offset is invalid");
      const page = label.slice(offset, offset + 4_000);
      const nextOffset = offset + page.length < label.length ? offset + page.length : undefined;
      return { text: `${JSON.stringify({ ...recordSummary(result), label: page })}${nextOffset === undefined ? "" : `\nContinue with offset=${nextOffset}.`}`, details: { record: result, ...(nextOffset === undefined ? {} : { nextOffset, totalChars: label.length }) } };
    }
    const result = await this.store.list({ kind: "note", scope: "personal", limit: parameters.limit ?? 8, ...(parameters.cursor ? { cursor: parameters.cursor } : {}) });
    return { text: `${result.records.map(record => `${record.id} (note): ${recordLabel(record).slice(0, 1_000)}`).join("\n") || "No Profile notes."}${result.nextCursor ? `\nContinue with cursor=${result.nextCursor}.` : ""}${result.incomplete ? "\nThe bounded canonical scan is incomplete; results are not exhaustive." : ""}`, details: { stateRevision: result.stateRevision, records: result.records.map(recordSummary), ...(result.nextCursor ? { nextCursor: result.nextCursor } : {}), ...(result.incomplete ? { incomplete: true } : {}) } };
  }
}
