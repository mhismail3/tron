import type {
  KnowledgeEvidenceRef, KnowledgeNoteMutationRequest, KnowledgeRecordDraft, KnowledgeRecord,
  NoteContent,
} from "./knowledge-contract.js";
import { KnowledgeStore, type KnowledgeMutationResult } from "./knowledge-store.js";

export interface SemanticNoteInput {
  commandId: string;
  scope: "personal" | "research";
  title: string;
  body?: string;
  fields?: NoteContent["fields"];
  role: NoteContent["role"];
  confirmed?: boolean;
  /** Supplied by the trusted command owner; confirmation is not authorship. */
  provenanceActor?: "user" | "agent" | "connector" | "import" | "system";
  temporal?: KnowledgeRecordDraft["temporal"];
  privacyScope?: NoteContent["privacyScope"];
  freshness?: NoteContent["freshness"];
  evidence?: KnowledgeEvidenceRef[];
  contraryEvidence?: KnowledgeEvidenceRef[];
  relations?: KnowledgeRecord["relations"];
}

function draft(input: SemanticNoteInput): KnowledgeRecordDraft & { kind: "note" } {
  return {
    kind: "note", scope: input.scope,
    provenance: { actor: input.provenanceActor ?? "agent", evidence: input.evidence ?? [] },
    relations: input.relations ?? [],
    ...(input.temporal ? { temporal: input.temporal } : {}),
    content: {
      title: input.title, ...(input.body !== undefined ? { body: input.body } : {}),
      ...(input.fields ? { fields: input.fields } : {}), role: input.role, confirmed: input.confirmed ?? false,
      ...(input.privacyScope ? { privacyScope: input.privacyScope } : {}), ...(input.freshness ? { freshness: input.freshness } : {}),
      ...(input.contraryEvidence ? { contraryEvidence: input.contraryEvidence } : {}),
    },
  };
}

export async function createSemanticNote(store: KnowledgeStore, input: SemanticNoteInput): Promise<KnowledgeMutationResult> {
  return store.createNote({ commandId: input.commandId, record: draft(input) });
}

export async function updateSemanticNote(store: KnowledgeStore, input: SemanticNoteInput & { recordId: string; expectedRevision: string }): Promise<KnowledgeMutationResult> {
  return store.updateNote({ commandId: input.commandId, recordId: input.recordId, expectedRevision: input.expectedRevision, record: draft(input) });
}

export async function correctSemanticNote(store: KnowledgeStore, input: SemanticNoteInput & { recordId: string; expectedRevision: string }): Promise<KnowledgeMutationResult> {
  return store.correct(input.commandId, input.recordId, input.expectedRevision, draft(input), { type: "corrects", recordId: input.recordId, revisionId: input.expectedRevision });
}

/** Supersession creates a new maintained note; the old revision remains cited history. */
export async function supersedeSemanticNote(store: KnowledgeStore, input: SemanticNoteInput & { supersedesRecordId: string; supersedesRevisionId: string }): Promise<KnowledgeMutationResult> {
  const previous = await store.read(input.supersedesRecordId, input.supersedesRevisionId, true);
  if (!previous || previous.kind !== "note") throw new Error("Superseded note revision does not exist");
  const relations = [...(input.relations ?? []), { type: "supersedes" as const, recordId: input.supersedesRecordId, revisionId: input.supersedesRevisionId }];
  return store.createNote({ commandId: input.commandId, record: draft({ ...input, relations }) });
}

export async function readSourceObject(store: KnowledgeStore, sourceId: string, revisionId?: string): Promise<Uint8Array | null> {
  const source = await store.read(sourceId, revisionId);
  if (!source || source.kind !== "source" || !source.content.object) return null;
  return store.readObject(source.content.object);
}

/** Resolve an object citation through its exact source revision, never by hash alone. */
export async function readCitedSourceObject(store: KnowledgeStore, citation: KnowledgeEvidenceRef): Promise<Uint8Array | null> {
  if (!citation.recordId || !citation.revisionId || !citation.objectHash) return null;
  const source = await store.read(citation.recordId, citation.revisionId);
  if (!source || source.kind !== "source" || source.content.object?.hash !== citation.objectHash) return null;
  return store.readObject(source.content.object);
}

export type NoteMutationRequest = KnowledgeNoteMutationRequest;
