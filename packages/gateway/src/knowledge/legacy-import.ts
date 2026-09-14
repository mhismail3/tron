import { createHash } from "node:crypto";
import { execFile as execFileCallback } from "node:child_process";
import { lstat, readFile, readdir } from "node:fs/promises";
import { isAbsolute, join, relative, resolve } from "node:path";
import { promisify } from "node:util";
import type { JsonValue } from "../protocol/types.js";
import type { KnowledgeAction, KnowledgeImportRunRequest, KnowledgeRecordDraft, KnowledgeImportScope } from "./knowledge-contract.js";
import { KnowledgeStore, type KnowledgeImportCheckpoint } from "./knowledge-store.js";

const execFile = promisify(execFileCallback);
const MAX_RECORD_FILES = 20_000;
const MAX_LINE_BYTES = 2 * 1024 * 1024;
const MAX_TOTAL_INPUT_BYTES = 256 * 1024 * 1024;
const MAX_EVIDENCE_BYTES = 8 * 1024 * 1024;
const ID_MAX = 200;

type LegacyStoreName = "personal-os" | "llm-wiki";
type LegacySource = Record<string, unknown> & { source_id: string; captured_at: string; content_sha256?: string; evidence_path?: string | null; metadata?: Record<string, unknown>; origin?: Record<string, unknown>; representation?: string; sensitivity?: string };
type LegacyEntity = Record<string, unknown> & { entity_id: string; label: string; kind?: string; aliases?: unknown[]; created_at?: string };
type LegacyAssertion = Record<string, unknown> & { assertion_id: string; subject_id: string; predicate: string; value?: unknown; evidence?: unknown[]; created_at?: string; observed_at?: string; valid_from?: string; valid_to?: string; status?: string; supersedes?: string | string[]; assertion_type?: string; basis?: string; confidence?: string; object_id?: string; depends_on?: string[] };

interface SourcePlan {
  kind: "source";
  legacy: LegacySource;
  id: string;
  evidence?: { bytes: Uint8Array; mediaType: string; hash: string };
  reviewReceipt?: { id: string; resultRevision?: string };
  warning?: string;
  excluded?: boolean;
}
interface EntityPlan { kind: "entity"; legacy: LegacyEntity; id: string; }
interface AssertionPlan { kind: "assertion"; legacy: LegacyAssertion; id: string; auditId?: string; }
type PlanItem = SourcePlan | EntityPlan | AssertionPlan;

export interface LegacyImporterOptions {
  /** Named roots are convenient for a UI; an explicit absolute path is also accepted. */
  roots?: Partial<Record<LegacyStoreName, string>>;
  now?: () => string;
}
export interface LegacyImportMapping { legacyId: string; kind: "source" | "entity" | "assertion"; newId: string; }
export interface LegacyImportReport {
  operation: "dry-run" | "run";
  source: string;
  scope?: KnowledgeImportScope;
  checkpoint?: KnowledgeImportCheckpoint;

  store: LegacyStoreName;
  planHash: string;
  planned: number;
  selected: number;
  imported: number;
  resumed: number;
  skipped: number;
  failed: number;
  completed: boolean;
  progress: { completed: number; remaining: number; total: number };
  mappings: LegacyImportMapping[];
  warnings: string[];
}

function stableId(store: LegacyStoreName, kind: string, id: string): string {
  const value = `import:${store}:${kind}:${id}`;
  if (value.length <= ID_MAX) return value;
  return `${value.slice(0, 120)}:${createHash("sha256").update(value).digest("hex").slice(0, 48)}`;
}
function stableJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(",")}]`;
  if (value && typeof value === "object") return `{${Object.entries(value as Record<string, unknown>).sort(([a], [b]) => a.localeCompare(b)).map(([key, item]) => `${JSON.stringify(key)}:${stableJson(item)}`).join(",")}}`;
  return JSON.stringify(value);
}
function hash(value: unknown): string { return createHash("sha256").update(stableJson(value)).digest("hex"); }
function normalizedTimestamp(value: unknown, fallback: string): string {
  if (typeof value !== "string" || !value) return fallback;
  const parsed = new Date(value.includes("T") ? value : `${value}T00:00:00Z`);
  return Number.isNaN(parsed.valueOf()) ? fallback : parsed.toISOString();
}
function stringValue(value: unknown, maximum: number): string | undefined { return typeof value === "string" && value.length > 0 ? value.slice(0, maximum) : undefined; }
function objectValue(value: unknown, depth = 0): JsonValue {
  if (depth > 8) throw new Error("Legacy structured value exceeds its depth bound");
  if (value === null || typeof value === "string" || typeof value === "boolean") return value;
  if (typeof value === "number") { if (!Number.isFinite(value)) throw new Error("Legacy structured value contains a non-finite number"); return value; }
  if (Array.isArray(value)) { if (value.length > 100) throw new Error("Legacy structured value exceeds its item bound"); return value.map(item => objectValue(item, depth + 1)); }
  if (typeof value === "object") { const entries = Object.entries(value as Record<string, unknown>); if (entries.length > 100) throw new Error("Legacy structured value exceeds its field bound"); return Object.fromEntries(entries.map(([key, item]) => { if (key.length > 200) throw new Error("Legacy structured value has an oversized field name"); return [key, objectValue(item, depth + 1)]; })); }
  throw new Error("Legacy structured value has an unsupported type");
}
function mediaType(source: LegacySource): string {
  return stringValue(source.media_type, 160) ?? stringValue(source.metadata?.media_type, 160) ?? "text/plain";
}
function sensitivity(source: LegacySource): "public" | "restricted" | "private" {
  return source.sensitivity === "public" || source.sensitivity === "private" ? source.sensitivity : "restricted";
}
function safeJsonLine(line: string, path: string, lineNumber: number): unknown {
  if (Buffer.byteLength(line, "utf8") > MAX_LINE_BYTES) throw new Error(`${path}:${lineNumber} exceeds its size bound`);
  try { return JSON.parse(line) as unknown; } catch { throw new Error(`${path}:${lineNumber} is not valid JSON`); }
}
async function jsonl<T>(path: string, label: string): Promise<T[]> {
  let stat;
  try { stat = await lstat(path); } catch { return []; }
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > MAX_TOTAL_INPUT_BYTES) throw new Error(`${label} is not a safe regular file`);
  const text = await readFile(path, "utf8");
  const result: T[] = [];
  for (const [index, line] of text.split(/\r?\n/).entries()) {
    if (!line.trim()) continue;
    const value = safeJsonLine(line, path, index + 1);
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${path}:${index + 1} must contain an object`);
    result.push(value as T);
    if (result.length > MAX_RECORD_FILES) throw new Error(`${label} exceeds its record bound`);
  }
  return result;
}
async function regularJsonFiles(path: string): Promise<string[]> {
  let entries;
  try { entries = await readdir(path, { withFileTypes: true }); } catch { return []; }
  const paths: string[] = []; let totalBytes = 0;
  for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
    if (!/^[A-Za-z0-9._-]+\.json$/.test(entry.name) || !entry.isFile()) continue;
    const item = join(path, entry.name); const stat = await lstat(item);
    if (stat.isSymbolicLink() || !stat.isFile() || stat.size > MAX_LINE_BYTES) throw new Error(`Unsafe legacy source record: ${item}`);
    totalBytes += stat.size; if (totalBytes > MAX_TOTAL_INPUT_BYTES) throw new Error("Legacy input exceeds its aggregate byte bound");
    paths.push(item);
    if (paths.length > MAX_RECORD_FILES) throw new Error("Legacy source record count exceeds its bound");
  }
  return paths;
}
const GIT_READ_ENV = {
  ...process.env,
  GIT_NO_LAZY_FETCH: "1", GIT_TERMINAL_PROMPT: "0", GIT_OPTIONAL_LOCKS: "0",
  GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_NOGLOBAL: "1", GIT_CONFIG_COUNT: "0",
  GIT_SSH_COMMAND: "false", GIT_ASKPASS: "false",
};
async function assertContainedNoSymlink(root: string, candidate: string): Promise<void> {
  const resolvedRoot = await resolve(root);
  const resolvedCandidate = await resolve(candidate);
  const rel = relative(resolvedRoot, resolvedCandidate);
  if (rel.startsWith("..") || isAbsolute(rel)) throw new Error("Legacy path escapes its configured root");
  let current = resolvedRoot;
  for (const component of rel.split(/[\\/]/).filter(Boolean)) {
    current = join(current, component);
    let info;
    try { info = await lstat(current); } catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return; throw error; }
    if (info.isSymbolicLink()) throw new Error("Legacy path contains a symbolic-link ancestor");
  }
}
async function gitRevision(root: string): Promise<string> {
  try { const result = await execFile("git", ["--no-optional-locks", "rev-parse", "HEAD"], { cwd: root, env: GIT_READ_ENV, encoding: "utf8", maxBuffer: 256 }); return result.stdout.trim() || "unversioned"; }
  catch { return "unversioned"; }
}
async function gitBlob(root: string, objectId: string): Promise<Uint8Array | undefined> {
  if (!/^[0-9a-f]{40,64}$/i.test(objectId)) return undefined;
  try {
    const result = await execFile("git", ["--no-optional-locks", "cat-file", "blob", objectId], { cwd: root, env: GIT_READ_ENV, encoding: "buffer", maxBuffer: MAX_EVIDENCE_BYTES + 1 });
    const bytes = Buffer.from(result.stdout as unknown as Uint8Array);
    if (bytes.byteLength > MAX_EVIDENCE_BYTES) return undefined;
    return bytes;
  } catch { return undefined; }
}
async function gitPath(root: string, revision: string, relativePath: string): Promise<Uint8Array | undefined> {
  if (revision === "unversioned" || !relativePath || isAbsolute(relativePath) || relativePath.split(/[\\/]/).includes("..") || relativePath.length > 1_024) return undefined;
  try {
    const result = await execFile("git", ["--no-optional-locks", "show", `${revision}:${relativePath}`], { cwd: root, env: GIT_READ_ENV, encoding: "buffer", maxBuffer: MAX_EVIDENCE_BYTES + 1 });
    const bytes = Buffer.from(result.stdout as unknown as Uint8Array); return bytes.byteLength <= MAX_EVIDENCE_BYTES ? bytes : undefined;
  } catch { return undefined; }
}
async function evidence(root: string, source: LegacySource, revision: string): Promise<{ bytes: Uint8Array; mediaType: string; hash: string } | undefined> {
  const expected = typeof source.content_sha256 === "string" && /^[a-f0-9]{64}$/.test(source.content_sha256) ? source.content_sha256 : undefined;
  let bytes: Uint8Array | undefined;
  const evidencePath = source.evidence_path;
  if (typeof evidencePath === "string" && evidencePath.length > 0) {
    if (isAbsolute(evidencePath) || evidencePath.split(/[\\/]/).includes("..")) return undefined;
    const candidate = resolve(root, evidencePath); const rel = relative(root, candidate);
    if (rel.startsWith("..") || isAbsolute(rel)) return undefined;
    try { await assertContainedNoSymlink(root, candidate); const stat = await lstat(candidate); if (!stat.isFile() || stat.isSymbolicLink() || stat.size > MAX_EVIDENCE_BYTES) return undefined; bytes = await readFile(candidate); } catch { /* Missing retained evidence is intentional. */ }
  }
  if (!bytes) {
    const provenance = source.metadata?.legacy_provenance as Record<string, unknown> | undefined;
    const blob = stringValue(provenance?.git_blob, 80);
    if (blob) bytes = await gitBlob(root, blob);
    if (!bytes) {
      const path = stringValue(provenance?.git_path ?? provenance?.path, 1_024);
      if (path) bytes = await gitPath(root, revision, path);
    }
  }
  if (!bytes) return undefined;
  const actual = createHash("sha256").update(bytes).digest("hex");
  if ((expected && actual !== expected) || bytes.byteLength > MAX_EVIDENCE_BYTES) return undefined;
  return { bytes, mediaType: mediaType(source), hash: actual };
}
function sourceTitle(source: LegacySource): string {
  const metadata = source.metadata ?? {};
  return stringValue(metadata.reference_title, 512) ?? stringValue(metadata.title, 512) ?? stringValue((source.origin ?? {}).locator, 512) ?? source.source_id;
}
function sourceUri(source: LegacySource): string | undefined {
  const candidate = stringValue(source.metadata?.canonical_url, 4_096) ?? stringValue((source.origin ?? {}).locator, 4_096);
  if (!candidate) return undefined;
  try { const parsed = new URL(candidate); return ["http:", "https:"].includes(parsed.protocol) && !parsed.username && !parsed.password ? parsed.toString() : undefined; } catch { return undefined; }
}

export class LegacyKnowledgeImporter {
  constructor(private readonly store: KnowledgeStore, private readonly options: LegacyImporterOptions = {}) {}

  private async resolveSource(source: string): Promise<{ root: string; store: LegacyStoreName }> {
    if (typeof source !== "string" || source.length === 0 || source.length > 4_096) throw new Error("Import source must be an explicit named root or path");
    let store: LegacyStoreName | undefined;
    let root: string | undefined;
    if (source === "personal-os" || source === "llm-wiki") { store = source; root = this.options.roots?.[source]; }
    if (!root || !isAbsolute(root)) throw new Error("Import source is not configured; install an explicitly named checkout root");
    root = await resolve(root);
    const stat = await lstat(root);
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error("Import source must be a real directory");
    if (!store) {
      const [personal, wiki] = await Promise.all([lstat(join(root, "sources", "records")).then(() => true, () => false), lstat(join(root, "graph", "assertions.jsonl")).then(() => true, () => false)]);
      store = personal && !wiki ? "personal-os" : "llm-wiki";
    }
    return { root, store };
  }

  private async plan(source: string, scope?: KnowledgeImportScope): Promise<{ root: string; store: LegacyStoreName; revision: string; items: PlanItem[]; planHash: string; warnings: string[] }> {
    const { root, store } = await this.resolveSource(source); const revision = await gitRevision(root); const warnings: string[] = [];
    for (const relativePath of ["sources/records", "graph", "reviews/receipts", "audits/records"]) {
      await assertContainedNoSymlink(root, join(root, relativePath));
    }
    const kinds = scope?.kinds ? new Set(scope.kinds) : undefined; const ids = scope?.ids ? new Set(scope.ids) : undefined;
    const included = (kind: "sources" | "entities" | "assertions", id: string): boolean => (!kinds || kinds.has(kind)) && (!ids || ids.has(id));
    const receiptByBatch = new Map<string, { id: string; resultRevision?: string }>();
    for (const receiptPath of await regularJsonFiles(join(root, "reviews", "receipts"))) { const receipt = JSON.parse(await readFile(receiptPath, "utf8")) as Record<string, unknown>; const batch = receipt.batch_id; const id = receipt.receipt_id; if (typeof batch === "string" && typeof id === "string") receiptByBatch.set(batch, { id, ...(typeof receipt.result_revision === "string" ? { resultRevision: receipt.result_revision } : {}) }); }
    const sourcePaths = await regularJsonFiles(join(root, "sources", "records")); const sourceRecords: LegacySource[] = [];
    for (const path of sourcePaths) {
      const value = JSON.parse(await readFile(path, "utf8")) as LegacySource;
      if (!value || typeof value.source_id !== "string") continue;
      if (value.status && !["accepted", "excluded", "suppressed"].includes(String(value.status))) continue;
      if (included("sources", value.source_id)) sourceRecords.push(value);
    }
    sourceRecords.sort((a, b) => a.source_id.localeCompare(b.source_id));
    const items: PlanItem[] = [];
    for (const legacy of sourceRecords) {
      const retained = await evidence(root, legacy, revision); const warning = retained ? undefined : (legacy.evidence_path || (legacy.metadata?.legacy_provenance as Record<string, unknown> | undefined)?.git_blob) ? `Evidence unavailable or hash-mismatched for ${legacy.source_id}; retained as metadata-only` : `No retained raw evidence for ${legacy.source_id}`;
      if (warning) warnings.push(warning);
      const batch = typeof legacy.metadata?.review_batch === "string" ? legacy.metadata.review_batch : undefined; const reviewReceipt = batch ? receiptByBatch.get(batch) : undefined;
      items.push({ kind: "source", legacy, id: stableId(store, "source", legacy.source_id), ...(retained ? { evidence: retained } : {}), ...(reviewReceipt ? { reviewReceipt } : {}), ...(warning ? { warning } : {}), ...(legacy.status === "excluded" || legacy.status === "suppressed" ? { excluded: true } : {}) });
    }
    const entities = await jsonl<LegacyEntity>(join(root, "graph", "entities.jsonl"), "legacy entities");
    for (const legacy of entities.filter(item => typeof item.entity_id === "string" && typeof item.label === "string" && included("entities", item.entity_id)).sort((a, b) => a.entity_id.localeCompare(b.entity_id))) items.push({ kind: "entity", legacy, id: stableId(store, "entity", legacy.entity_id) });
    const assertions = await jsonl<LegacyAssertion>(join(root, "graph", "assertions.jsonl"), "legacy assertions");
    const auditByAssertion = new Map<string, string>();
    for (const auditPath of await regularJsonFiles(join(root, "audits", "records"))) {
      const audit = JSON.parse(await readFile(auditPath, "utf8")) as Record<string, unknown>; const auditId = typeof audit.audit_id === "string" ? audit.audit_id : auditPath.split("/").pop()?.replace(/\.json$/, "");
      if (!auditId || !Array.isArray(audit.assertions)) continue;
      for (const assertion of audit.assertions) { const assertionId = (assertion as Record<string, unknown>).assertion_id; if (typeof assertionId === "string") auditByAssertion.set(assertionId, auditId); }
    }
    for (const legacy of assertions.filter(item => typeof item.assertion_id === "string" && typeof item.subject_id === "string" && typeof item.predicate === "string" && included("assertions", item.assertion_id)).sort((a, b) => a.assertion_id.localeCompare(b.assertion_id))) { const auditId = auditByAssertion.get(legacy.assertion_id); items.push({ kind: "assertion", legacy, id: stableId(store, "assertion", legacy.assertion_id), ...(auditId ? { auditId } : {}) }); }
    if (revision === "unversioned") warnings.push("Legacy checkout has no readable Git HEAD; lineage is marked unversioned");
    const identity = items.map(item => ({ kind: item.kind, legacyId: item.legacy.kind === "source" ? item.legacy.source_id : item.legacy.kind === "entity" ? item.legacy.entity_id : item.legacy.assertion_id, id: item.id, payload: item.legacy, ...(item.kind === "source" ? { hash: item.legacy.content_sha256 ?? null, evidence: item.evidence?.hash ?? null } : {}) }));
    return { root, store, revision, items, planHash: hash({ store, revision, identity }), warnings };
  }

  private sourceDraft(item: SourcePlan, revision: string, importedAt: string): KnowledgeRecordDraft & { kind: "source" } {
    const legacy = item.legacy; const metadata = legacy.metadata ?? {}; const capturedAt = normalizedTimestamp(legacy.captured_at, importedAt);
    const origin = "import" as const; const usageConstraint = stringValue(metadata.usage_constraint, 20_000); const uri = sourceUri(legacy); const originalLocator = stringValue(legacy.origin?.locator, 512); const publishedAt = stringValue(metadata.published_at, 80); const text = item.evidence && item.evidence.mediaType.startsWith("text/") ? Buffer.from(item.evidence.bytes).toString("utf8").slice(0, 2_000_000) : undefined;
    const content = { title: sourceTitle(legacy), ...(uri ? { uri } : {}), ...(text ? { text } : {}), ...(item.evidence ? { object: { hash: item.evidence.hash, mediaType: item.evidence.mediaType, bytes: item.evidence.bytes.byteLength } } : {}), mediaType: mediaType(legacy), captureDisposition: item.excluded ? "reference-only" as const : item.evidence ? "complete" as const : "metadata-only" as const, capturedAt, ...(publishedAt ? { sourcePublishedAt: normalizedTimestamp(publishedAt, capturedAt) } : {}), origin, origins: [{ kind: "import" as const, capturedAt, ...(uri ? { uri } : {}), ...(originalLocator ? { annotation: `Original locator: ${originalLocator}` } : {}) }], retention: { sensitivity: sensitivity(legacy), evidenceAvailable: Boolean(item.evidence), ...(legacy.content_sha256 ? { originalHash: legacy.content_sha256 } : {}), ...(usageConstraint ? { usageConstraint } : {}) } };
    return { kind: "source", id: item.id, scope: item.legacy.representation === "llm-wiki" ? "research" : "personal", createdAt: capturedAt, updatedAt: capturedAt, provenance: { actor: "import", source: `${legacy.representation ?? "legacy"}:${legacy.source_id}@${revision}`, evidence: [] }, relations: [], importOrigin: { store: item.legacy.representation === "llm-wiki" ? "llm-wiki" : "personal-os", recordId: legacy.source_id, revision, importedAt, ...(metadata.review_batch ? { review: { batch: String(metadata.review_batch), ...(item.reviewReceipt ? { receiptId: item.reviewReceipt.id, ...(item.reviewReceipt.resultRevision ? { resultRevision: item.reviewReceipt.resultRevision } : {}) } : {}) } } : {}) }, content };
  }

  private entityDraft(item: EntityPlan, revision: string, importedAt: string, store: LegacyStoreName): KnowledgeRecordDraft & { kind: "note" } {
    const legacy = item.legacy; const createdAt = normalizedTimestamp(legacy.created_at, importedAt);
    return { kind: "note", id: item.id, scope: store === "llm-wiki" ? "research" : "personal", createdAt, updatedAt: createdAt, provenance: { actor: "import", source: `entity:${legacy.entity_id}@${revision}`, evidence: [] }, relations: [], importOrigin: { store, recordId: legacy.entity_id, revision, importedAt }, content: { title: legacy.label, role: "concept", confirmed: false, privacyScope: store === "llm-wiki" ? "shared" : "private", fields: [{ field: "legacyKind", value: String(legacy.kind ?? "unknown"), evidence: [], certainty: "historical" }, { field: "aliases", value: (legacy.aliases ?? []).slice(0, 100).map(String), evidence: [], certainty: "historical" }] } };
  }

  private assertionDraft(item: AssertionPlan, sourceRevisions: Map<string, string>, revision: string, importedAt: string, store: LegacyStoreName): KnowledgeRecordDraft & { kind: "note" } {
    const legacy = item.legacy; const createdAt = normalizedTimestamp(legacy.created_at ?? legacy.observed_at, importedAt); const superseded = legacy.status === "superseded";
    const rawEvidence = Array.isArray(legacy.evidence) ? legacy.evidence : [];
    const evidence = rawEvidence.flatMap(raw => { const value = raw as Record<string, unknown>; const sourceId = typeof value.source_id === "string" ? value.source_id : undefined; const sourceRevision = sourceId ? sourceRevisions.get(sourceId) : undefined; return sourceId && sourceRevision ? [{ recordId: stableId(store, "source", sourceId), revisionId: sourceRevision, ...(typeof value.locator === "string" ? { locator: value.locator.slice(0, 512) } : {}) }] : []; });
    const unresolvedEvidence = rawEvidence.flatMap(raw => { const sourceId = raw && typeof raw === "object" && typeof (raw as Record<string, unknown>).source_id === "string" ? (raw as Record<string, unknown>).source_id as string : undefined; return sourceId && !sourceRevisions.has(sourceId) ? [sourceId] : []; }).slice(0, 100);
    const supersededIds = (Array.isArray(legacy.supersedes) ? legacy.supersedes : legacy.supersedes ? [legacy.supersedes] : []).filter((id): id is string => typeof id === "string").slice(0, 20);
    const relations = [{ type: "related" as const, recordId: stableId(store, "entity", legacy.subject_id) }, ...(legacy.object_id ? [{ type: "related" as const, recordId: stableId(store, "entity", legacy.object_id) }] : []), ...supersededIds.map(id => ({ type: "supersedes" as const, recordId: stableId(store, "assertion", id) })), ...(legacy.depends_on ?? []).filter(id => typeof id === "string").slice(0, 20).map(id => ({ type: "derivedFrom" as const, recordId: stableId(store, "assertion", id) }))];
    const certainty = store === "llm-wiki" ? "external" as const : superseded || legacy.valid_to ? "historical" as const : legacy.basis === "user-confirmed" ? "confirmed" as const : "candidate" as const;
    const role = legacy.assertion_type === "relationship" || legacy.object_id ? "concept" as const : legacy.predicate.toLowerCase().includes("preference") ? "preference" as const : "fact" as const;
    const usageConstraint = stringValue((legacy as Record<string, unknown>).usage_constraint, 20_000);
    const fields = [{ field: "value", value: objectValue(legacy.value), subject: stableId(store, "entity", legacy.subject_id), evidence, certainty, ...(legacy.valid_from ? { validFrom: normalizedTimestamp(legacy.valid_from, createdAt) } : {}), ...(legacy.valid_to ? { validTo: normalizedTimestamp(legacy.valid_to, createdAt) } : {}) }, { field: "assertionType", value: String(legacy.assertion_type ?? "unknown"), evidence, certainty: "historical" as const }, { field: "status", value: String(legacy.status ?? "active"), evidence, certainty: "historical" as const }, { field: "evidenceQualifications", value: rawEvidence.map(value => objectValue(value)), evidence: [], certainty: "historical" as const }, ...(unresolvedEvidence.length ? [{ field: "unresolvedEvidence", value: unresolvedEvidence, evidence: [], certainty: "historical" as const }] : []), ...(legacy.confidence ? [{ field: "confidence", value: legacy.confidence, evidence, certainty: "historical" as const }] : [])];
    const content = { title: legacy.predicate, ...(superseded ? { body: "Historical assertion retained as superseded; it is not current instruction." } : {}), role, confirmed: legacy.basis === "user-confirmed", privacyScope: store === "llm-wiki" ? "shared" as const : "private" as const, ...(usageConstraint ? { usageConstraint } : {}), fields };
    const review = { ...(item.auditId ? { auditId: item.auditId } : {}), ...(legacy.basis ? { basis: legacy.basis } : {}) };
    return { kind: "note", id: item.id, scope: store === "llm-wiki" ? "research" : "personal", createdAt, updatedAt: createdAt, provenance: { actor: "import", source: `assertion:${legacy.assertion_id}@${revision}`, evidence }, relations, temporal: { ...(legacy.observed_at ? { eventAt: normalizedTimestamp(legacy.observed_at, createdAt) } : {}), ...(legacy.valid_from ? { validFrom: normalizedTimestamp(legacy.valid_from, createdAt) } : {}), ...(legacy.valid_to ? { validTo: normalizedTimestamp(legacy.valid_to, createdAt) } : {}) }, importOrigin: { store, recordId: legacy.assertion_id, revision, importedAt, ...(Object.keys(review).length ? { review } : {}) }, content };
  }

  private async importItem(item: PlanItem, plan: Awaited<ReturnType<LegacyKnowledgeImporter["plan"]>>, sourceRevisions: Map<string, string>, importedAt: string): Promise<{ imported: boolean; revision?: string }> {
    const existing = await this.store.read(item.id, undefined, true);
    if (existing) {
      if (!existing.importOrigin || existing.importOrigin.store !== plan.store || existing.importOrigin.recordId !== (item.kind === "source" ? item.legacy.source_id : item.kind === "entity" ? item.legacy.entity_id : item.legacy.assertion_id) || existing.importOrigin.revision !== plan.revision) throw new Error(`Stable import ID is already owned by another record: ${item.id}`);
      return { imported: false, revision: existing.revisionId };
    }
    if (item.kind === "source") {
      if (item.evidence) await this.store.putObject(item.evidence.bytes, item.evidence.mediaType);
      const result = await this.store.captureSource({ commandId: `import.source:${plan.planHash.slice(0, 48)}:${item.legacy.source_id}`.slice(0, 160), record: this.sourceDraft(item, plan.revision, importedAt) });
      if (item.excluded) await this.store.setExclusion(`import.exclude:${plan.planHash.slice(0, 48)}:${item.legacy.source_id}`.slice(0, 160), result.record.id, true, undefined, "Legacy source was excluded");
      sourceRevisions.set(item.legacy.source_id, result.record.revisionId); return { imported: true, revision: result.record.revisionId };
    }
    if (item.kind === "assertion" && Array.isArray(item.legacy.evidence)) {
      // A selected batch may contain an assertion without its source. Resolve
      // exact already-imported source revisions instead of silently dropping
      // those citations when the source was imported in an earlier batch.
      for (const raw of item.legacy.evidence) {
        const sourceId = raw && typeof raw === "object" && typeof (raw as Record<string, unknown>).source_id === "string" ? (raw as Record<string, unknown>).source_id as string : undefined;
        if (!sourceId || sourceRevisions.has(sourceId)) continue;
        const prior = await this.store.read(stableId(plan.store, "source", sourceId));
        if (prior?.kind === "source" && !prior.content.captureDisposition.includes("failed")) sourceRevisions.set(sourceId, prior.revisionId);
      }
    }
    const draft = item.kind === "entity" ? this.entityDraft(item, plan.revision, importedAt, plan.store) : this.assertionDraft(item, sourceRevisions, plan.revision, importedAt, plan.store);
    const result = await this.store.createNote({ commandId: `import.${item.kind}:${plan.planHash.slice(0, 48)}:${item.kind === "entity" ? item.legacy.entity_id : item.legacy.assertion_id}`.slice(0, 160), record: draft });
    return { imported: true, revision: result.record.revisionId };
  }

  async execute(request: Extract<KnowledgeAction, { operation: "knowledge.import.dry-run" | "knowledge.import.run" }>["request"] & { operation?: "knowledge.import.dry-run" | "knowledge.import.run" }): Promise<LegacyImportReport> {
    const operation = request.operation ?? ("expectedPlanHash" in request ? "knowledge.import.run" : "knowledge.import.dry-run");
    const scope: KnowledgeImportScope | undefined = request.scope; const plan = await this.plan(request.source, scope);
    const scoped = plan.items;
    const requestedLimit = request.limit === undefined ? scoped.length : Math.max(0, Math.min(20_000, Math.floor(request.limit)));
    const offset = request.offset === undefined ? 0 : Math.max(0, Math.min(scoped.length, Math.floor(request.offset)));
    if (!Number.isSafeInteger(offset) || offset > scoped.length) throw new Error("Import offset is invalid");
    const selected = scoped.slice(offset, offset + requestedLimit); const selectedPlanHash = hash({ base: plan.planHash, scope: scope ?? null, selected: selected.map(item => item.id) });
    const mappings: LegacyImportMapping[] = selected.map(item => ({ legacyId: item.kind === "source" ? item.legacy.source_id : item.kind === "entity" ? item.legacy.entity_id : item.legacy.assertion_id, kind: item.kind === "source" ? "source" : item.kind === "entity" ? "entity" : "assertion", newId: item.id }));
    const base: LegacyImportReport = { operation: operation === "knowledge.import.run" ? "run" : "dry-run", source: request.source, ...(scope ? { scope } : {}), store: plan.store, planHash: selectedPlanHash, planned: plan.items.length, selected: selected.length, imported: 0, resumed: 0, skipped: 0, failed: 0, completed: operation !== "knowledge.import.run", progress: { completed: 0, remaining: selected.length, total: selected.length }, mappings, warnings: plan.warnings.slice(0, 200) };
    if (operation !== "knowledge.import.run") return base;
    const runRequest = request as KnowledgeImportRunRequest;
    if (runRequest.expectedPlanHash !== selectedPlanHash) throw new Error("Import plan hash is stale; run dry-run again");
    const checkpoint = await this.store.beginImport(`import.begin:${runRequest.commandId}`, selectedPlanHash, selected.map(item => item.id)); base.checkpoint = checkpoint;
    const done = new Set(checkpoint.completedRecordIds); const sourceRevisions = new Map<string, string>();
    for (const item of selected) { const existing = await this.store.read(item.id, undefined, true); if (existing?.kind === "source" && item.kind === "source") sourceRevisions.set(item.legacy.source_id, existing.revisionId); }
    for (const item of selected) {
      if (done.has(item.id)) { base.resumed += 1; continue; }
      try {
        const result = await this.importItem(item, plan, sourceRevisions, this.options.now?.() ?? new Date().toISOString());
        if (result.imported) base.imported += 1; else base.resumed += 1;
        await this.store.markImportRecord(`import.progress:${selectedPlanHash.slice(0, 48)}:${item.id}`.slice(0, 160), selectedPlanHash, item.id); done.add(item.id);
      } catch (error) { base.failed += 1; base.warnings.push(`${item.id}: ${error instanceof Error ? error.message : String(error)}`); break; }
    }
    const final = await this.store.importCheckpoint(selectedPlanHash); if (final) base.checkpoint = final; const completed = final?.completedRecordIds.length ?? done.size;
    base.completed = completed === selected.length && base.failed === 0; base.progress = { completed, remaining: Math.max(0, selected.length - completed), total: selected.length }; return base;
  }
}

export function createKnowledgeImporter(store: KnowledgeStore, options: LegacyImporterOptions = {}): (action: KnowledgeAction) => Promise<unknown> {
  const importer = new LegacyKnowledgeImporter(store, options);
  return async action => {
    if (action.operation !== "knowledge.import.dry-run" && action.operation !== "knowledge.import.run") throw new Error("Unsupported knowledge importer action");
    return importer.execute({ ...action.request, operation: action.operation });
  };
}
