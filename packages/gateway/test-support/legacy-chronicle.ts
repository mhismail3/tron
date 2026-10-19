/**
 * Legacy Chronicle history as a pre-#1315 Gateway left it on disk.
 *
 * Prospective conversation observation (Chronicle generation) was retired in
 * #1315; no production writer creates observation records or coverage cuts any
 * more. Existing installations still hold them, together with the retired
 * `observation` settings and admission grants in their persisted Knowledge
 * configuration. This fixture reproduces that state through the store's own
 * storage path instead of a test hook in production code: it writes immutable
 * record revisions and a pre-catalog manifest, lets `upgradeStorage` build the
 * current catalog from them, then restores the retired config fields in the
 * catalog control row exactly as an un-upgraded installation still carries
 * them. Run it before any other Knowledge write in the test: the upgrade
 * replaces whatever catalog the namespace held.
 */
import { createHash, randomUUID } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import {
  DEFAULT_KNOWLEDGE_CONFIG, KNOWLEDGE_SCHEMA_VERSION,
  type KnowledgeEvidenceRef, type KnowledgeRecord, type ObservationCoverage, type ObservationItem, type ObservationRange,
} from "../src/knowledge/knowledge-contract.js";
import type { KnowledgeStore } from "../src/knowledge/knowledge-store.js";
import type { TronWorkspace } from "../src/workspace/tron-workspace.js";

/** Persisted Knowledge configuration of an installation that had Chronicle on
 * with the global grant, as the retired observer read it. */
export const LEGACY_CHRONICLE_CONFIG = {
  ...structuredClone(DEFAULT_KNOWLEDGE_CONFIG),
  revision: 4,
  eligibility: { allSessions: true, sessionIds: [], projectIds: ["/synthetic/legacy-project"], excludedSessionIds: [], excludedProjectIds: [] },
  observation: { enabled: true, maxInputChars: 48_000, maxOutputChars: 8_000, timeoutMs: 30_000, maxAttempts: 1 },
};

/** The retired observer's exact canonical-range digest (one JSON line per entry). */
export function legacyEntriesDigest(entries: readonly unknown[]): string {
  const digest = createHash("sha256");
  for (const entry of entries) digest.update(JSON.stringify(entry)).update("\n");
  return digest.digest("hex");
}

export interface LegacyObservationGroup {
  coverageId: string;
  range: ObservationRange;
  /** One record per item, as the retired observer published them. */
  records: Array<{ id: string; item: ObservationItem; createdAt?: string; evidence?: KnowledgeEvidenceRef[] }>;
}

export interface LegacyCoverageGap {
  coverageId: string;
  range: ObservationRange;
  disposition: "pending" | "failed" | "unavailable";
  reason: string;
}

export interface LegacyChronicle {
  records: KnowledgeRecord[];
  coverage: ObservationCoverage[];
}

const OWNER_FILE = 0o600;
const OWNER_DIRECTORY = 0o700;

export async function seedLegacyChronicle(
  workspace: TronWorkspace,
  store: KnowledgeStore,
  input: { groups: LegacyObservationGroup[]; gaps?: LegacyCoverageGap[]; recordedAt?: string },
): Promise<LegacyChronicle> {
  // A real namespace (marker, directories, workspace feature record) from the
  // store's own first write; its catalog is superseded by the upgrade below.
  await store.configure("legacy-chronicle-namespace", await store.config());
  const root = join((await workspace.describe()).root, "state", "knowledge");
  const recordedAt = input.recordedAt ?? "2026-10-01T00:00:00.000Z";
  const records: KnowledgeRecord[] = [];
  const coverage: ObservationCoverage[] = [];
  const heads: Record<string, { latestRevisionId: string; revisionIds: string[] }> = {};
  for (const group of input.groups) {
    const groupRevisionIds: string[] = [];
    for (const seed of group.records) {
      const createdAt = seed.createdAt ?? recordedAt;
      const record = {
        schemaVersion: KNOWLEDGE_SCHEMA_VERSION, id: seed.id, revisionId: randomUUID(), kind: "observation", scope: "personal",
        createdAt, updatedAt: createdAt,
        provenance: { actor: "agent", sessionId: group.range.sessionId, ...(group.range.branchId ? { branchId: group.range.branchId } : {}),
          evidence: seed.evidence ?? group.range.entryIds.map(entryId => ({ sessionEntry: { sessionId: group.range.sessionId,
            ...(group.range.branchId ? { branchId: group.range.branchId } : {}), entryId, digest: group.range.entryDigest } })) },
        relations: [],
        content: { range: group.range, items: [seed.item], observer: { promptVersion: "tron-observer-v2" } },
      } as KnowledgeRecord;
      await mkdir(join(root, "records", seed.id), { recursive: true, mode: OWNER_DIRECTORY });
      await writeFile(join(root, "records", seed.id, `${record.revisionId}.json`), `${JSON.stringify(record, null, 2)}\n`, { mode: OWNER_FILE });
      heads[seed.id] = { latestRevisionId: record.revisionId, revisionIds: [record.revisionId] };
      groupRevisionIds.push(record.revisionId);
      records.push(record);
    }
    coverage.push({ schemaVersion: KNOWLEDGE_SCHEMA_VERSION, id: group.coverageId, range: group.range, disposition: "observed",
      groupRevisionIds, reason: "terminal:completed", revisionId: randomUUID(), recordedAt } as ObservationCoverage);
  }
  for (const gap of input.gaps ?? []) {
    coverage.push({ schemaVersion: KNOWLEDGE_SCHEMA_VERSION, id: gap.coverageId, range: gap.range, disposition: gap.disposition,
      groupRevisionIds: [], reason: gap.reason, revisionId: randomUUID(), recordedAt } as ObservationCoverage);
  }
  const legacyState = {
    schemaVersion: KNOWLEDGE_SCHEMA_VERSION, stateRevision: 1, records: heads,
    coverage: Object.fromEntries(coverage.map(item => [item.id, item])),
    suppressions: {}, scopeExclusions: {}, cleanup: [], recordCleanup: [], receipts: {},
    config: LEGACY_CHRONICLE_CONFIG, connectors: {},
  };
  await writeFile(join(root, "state.json"), `${JSON.stringify(legacyState, null, 2)}\n`, { mode: OWNER_FILE });
  await store.upgradeStorage();
  // An installation upgraded before #1315 keeps the retired fields in its
  // catalog control row until its next config write.
  const { catalogID } = JSON.parse(await readFile(join(root, "state.json"), "utf8")) as { catalogID: string };
  const catalog = new DatabaseSync(join(root, `catalog-${catalogID}.sqlite`));
  try {
    catalog.prepare("UPDATE control SET value = json_set(value, '$.config', json(?)) WHERE id = 1").run(JSON.stringify(LEGACY_CHRONICLE_CONFIG));
  } finally { catalog.close(); }
  return { records, coverage };
}

/** The retired fields as the catalog control row currently persists them. */
export async function persistedKnowledgeConfig(workspace: TronWorkspace): Promise<Record<string, unknown>> {
  const root = join((await workspace.describe()).root, "state", "knowledge");
  const { catalogID } = JSON.parse(await readFile(join(root, "state.json"), "utf8")) as { catalogID: string };
  const catalog = new DatabaseSync(join(root, `catalog-${catalogID}.sqlite`), { readOnly: true });
  try {
    const row = catalog.prepare("SELECT value FROM control WHERE id = 1").get() as { value: string };
    return (JSON.parse(row.value) as { config: Record<string, unknown> }).config;
  } finally { catalog.close(); }
}
