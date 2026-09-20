import { createHash } from "node:crypto";
import { readFile, lstat, mkdir } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { KnowledgeCatalog, type KnowledgeTable } from "../knowledge/knowledge-catalog.js";
import { durableAtomicWriteJson } from "../util/durable-json.js";
import type { ConnectionInstance, ConnectionOwnerState, ConnectionPolicy } from "./connection-contract.js";
import { CONNECTION_STATE_SCHEMA_VERSION, validateConnectionState } from "./connection-contract.js";

export const LEGACY_CONNECTOR_STATE_SCHEMA_VERSION = 1 as const;
export const CONNECTION_MIGRATION_PLAN_VERSION = 2 as const;

/** The connector map is the production Knowledge control shape. It is keyed by
 * provider today and contains provider progress plus the old generic envelope.
 * This is intentionally not an invented array/bundle format. */
export interface LegacyConnectorState {
  connector: "raindrop" | "x";
  enabled: boolean;
  accountId?: string;
  scope?: string;
  credentialRef?: string;
  allowWrites: boolean;
  paidAccessApproved: boolean;
  paidBudgetCents: number;
  recurringApproved: boolean;
  [providerField: string]: unknown;
}

export interface KnowledgeConnectorSource {
  schemaVersion: 1;
  stateRevision: number;
  catalogID?: string;
  config: unknown;
  connectors: Record<string, LegacyConnectorState>;
  receipts: Record<string, unknown>;
}

export interface MigratedProviderState {
  connectionId: string;
  connector: "raindrop" | "x";
  state: Record<string, unknown>;
}

export interface ConnectionMigrationPlan {
  planVersion: typeof CONNECTION_MIGRATION_PLAN_VERSION;
  authoritySelection: { canonicalOwner: "connection-owner"; providerStateOwner: "knowledge" };
  planHash: string;
  sourceName: string;
  sourceStateRevision: number;
  catalogID?: string;
  knowledgeConfig: unknown;
  ownerState: ConnectionOwnerState;
  providerStates: MigratedProviderState[];
  /** Knowledge receipts are global catalog authority and must not be copied per account. */
  knowledgeReceipts: Record<string, unknown>;
}

export interface ConnectionMigrationDestinations {
  ownerPath: string;
  providerPath: string;
  publicationPath: string;
}

export interface ConnectionMigrationPublication {
  publicationVersion: 1;
  planHash: string;
  phase: "prepared" | "owner-published" | "published";
  ownerPath: string;
  providerPath: string;
  publishedAt: string;
}

function invalid(message: string): Error { return new Error(`Connection migration: ${message}`); }
function clone<T>(value: T): T { return structuredClone(value); }
function validID(value: unknown): value is string { return typeof value === "string" && value.length > 0 && value.length <= 512 && !/[\u0000-\u001f\u007f]/.test(value); }
function connectionId(connector: string, accountId: string, scope: string | undefined): string {
  const digest = createHash("sha256").update(`${connector}\0${accountId}\0${scope ?? ""}`).digest("hex").slice(0, 24);
  return `connection:${connector}:${digest}`;
}
function policy(state: LegacyConnectorState): ConnectionPolicy {
  return { enabled: state.enabled, allowWrites: state.allowWrites, paidAccessApproved: state.paidAccessApproved, paidBudgetCents: state.paidBudgetCents, recurringApproved: state.recurringApproved };
}
/** Canonical JSON: sort keys at every object depth; a replacer array would
 * silently discard nested keys and make the reviewed hash non-committing. */
function canonicalJSON(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(",")}]`;
  if (value && typeof value === "object") return `{${Object.keys(value as Record<string, unknown>).sort().map(key => `${JSON.stringify(key)}:${canonicalJSON((value as Record<string, unknown>)[key])}`).join(",")}}`;
  return JSON.stringify(value);
}

function validateConnectorMap(connectors: unknown): asserts connectors is Record<string, LegacyConnectorState> {
  if (!connectors || typeof connectors !== "object" || Array.isArray(connectors) || Object.keys(connectors).length > 128) throw invalid("production connector map is invalid");
  const identities = new Set<string>();
  for (const [key, value] of Object.entries(connectors)) {
    if (!/^[A-Za-z0-9._:-]{1,160}$/.test(key) || !value || typeof value !== "object" || Array.isArray(value)) throw invalid("production connector entry is invalid");
    const state = value as LegacyConnectorState;
    if (state.connector !== "raindrop" && state.connector !== "x") throw invalid("connector kind is invalid");
    if (typeof state.enabled !== "boolean" || typeof state.allowWrites !== "boolean" || typeof state.paidAccessApproved !== "boolean" || typeof state.recurringApproved !== "boolean" || !Number.isSafeInteger(state.paidBudgetCents) || state.paidBudgetCents < 0 || state.paidBudgetCents > 1_000_000) throw invalid("connector policy is invalid");
    if (!validID(state.accountId) || (state.scope !== undefined && !validID(state.scope)) || typeof state.credentialRef !== "string" || !new RegExp(`^connector:${state.connector}:[A-Za-z0-9._:-]{1,256}$`).test(state.credentialRef)) throw invalid("connector account/ref envelope is invalid");
    if (state.connectionId !== undefined && state.connectionId !== key) throw invalid("connector connection ID does not match its map key");
    const identity = `${state.connector}\0${state.accountId}\0${state.scope ?? ""}`;
    if (identities.has(identity)) throw invalid("conflicting duplicate connector account/scope");
    identities.add(identity);
  }
}

function validateSource(value: unknown): asserts value is KnowledgeConnectorSource {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw invalid("Knowledge source is not an object");
  const source = value as Record<string, unknown>;
  if (source.schemaVersion !== 1 || !Number.isSafeInteger(source.stateRevision) || (source.stateRevision as number) < 0) throw invalid("Knowledge source schema or revision is invalid");
  if (source.catalogID !== undefined && !/^[0-9a-f-]{36}$/.test(source.catalogID as string)) throw invalid("Knowledge catalog identity is invalid");
  if (!("config" in source)) throw invalid("Knowledge config is missing");
  validateConnectorMap(source.connectors);
  if (!source.receipts || typeof source.receipts !== "object" || Array.isArray(source.receipts)) throw invalid("Knowledge receipt map is invalid");
}

/** Read the current production state.json plus its catalog control/receipts.
 * No startup fallback or mutation is allowed. */
export async function readLegacyConnectorState(path: string, fileSystem: { readFile: typeof readFile } = { readFile }): Promise<KnowledgeConnectorSource> {
  if (!path || basename(path) !== "state.json") throw invalid("source must be an explicit Knowledge state.json");
  let value: unknown;
  try { value = JSON.parse(await fileSystem.readFile(path, "utf8")); } catch { throw invalid("Knowledge state could not be read or parsed"); }
  if (!value || typeof value !== "object" || Array.isArray(value)) throw invalid("Knowledge state is invalid");
  const manifest = value as Record<string, unknown>;
  if (manifest.storageVersion !== undefined) {
    if (manifest.storageVersion !== 1 || manifest.schemaVersion !== 1 || typeof manifest.catalogID !== "string") throw invalid("Knowledge catalog manifest is newer or invalid");
    const catalogPath = join(dirname(path), `catalog-${manifest.catalogID}.sqlite`);
    let catalog: KnowledgeCatalog;
    try { catalog = new KnowledgeCatalog(catalogPath, true); } catch { throw invalid("Knowledge catalog could not be opened"); }
    try {
      const control = catalog.control<Record<string, unknown> & { schemaVersion: 1; stateRevision: number; connectors?: Record<string, LegacyConnectorState> }>();
      const receipts = Object.fromEntries((catalog.table<Record<string, unknown>>("receipts") as KnowledgeTable<Record<string, unknown>>).entries());
      const source = { schemaVersion: control.schemaVersion, stateRevision: control.stateRevision, catalogID: manifest.catalogID, config: control.config, connectors: control.connectors ?? {}, receipts };
      validateSource(source);
      return clone(source);
    } catch (error) { throw error instanceof Error && error.message.startsWith("Connection migration:") ? error : invalid("Knowledge catalog control is invalid"); }
    finally { catalog.close(); }
  }
  // Pre-catalog state is still the real Knowledge schema, not a connector-only
  // fixture. Require its complete top-level shape before selecting connectors.
  const state = value as Record<string, unknown>;
  for (const key of ["records", "coverage", "suppressions", "scopeExclusions", "cleanup", "receipts", "config"]) if (!(key in state)) throw invalid("legacy Knowledge state is incomplete");
  const source = { schemaVersion: state.schemaVersion, stateRevision: state.stateRevision, config: state.config, connectors: state.connectors ?? {}, receipts: state.receipts };
  validateSource(source);
  return clone(source);
}

/** Build a write-free plan from the production connector map. */
export function prepareConnectionMigration(input: unknown, sourceName = "knowledge/state.json"): ConnectionMigrationPlan {
  validateSource(input);
  const source = input as KnowledgeConnectorSource;
  const instances: Record<string, ConnectionInstance> = {};
  const providerStates: MigratedProviderState[] = [];
  for (const legacy of Object.values(source.connectors) as LegacyConnectorState[]) {
    const connector = legacy.connector as "raindrop" | "x";
    const accountId = legacy.accountId as string;
    const scope = legacy.scope as string | undefined;
    const credentialRef = legacy.credentialRef as string;
    const instanceId = typeof legacy.connectionId === "string" ? legacy.connectionId : connectionId(connector, accountId, scope);
    const definitionId = `knowledge.${connector}`;
    const timestamp = new Date(0).toISOString();
    const instance: ConnectionInstance = { id: instanceId, definitionId, implementation: "knowledge-connector", providerAccountId: accountId, ...(scope ? { scope } : {}), credentialRef, policy: policy(legacy), health: legacy.enabled ? "ready" : "disabled", createdAt: timestamp, updatedAt: timestamp, setupRevision: 1 };
    if (instances[instanceId]) throw invalid("conflicting duplicate connection identity");
    instances[instanceId] = instance;
    const state = clone(legacy) as Record<string, unknown>;
    state.connectionId = instanceId;
    for (const key of ["enabled", "accountId", "scope", "credentialRef", "allowWrites", "paidAccessApproved", "paidBudgetCents", "recurringApproved"]) delete state[key];
    providerStates.push({ connectionId: instanceId, connector, state });
  }
  const ownerState: ConnectionOwnerState = { schemaVersion: CONNECTION_STATE_SCHEMA_VERSION, stateRevision: 1, instances, setupOperations: {}, receipts: {} };
  validateConnectionState(ownerState);
  const unsigned = { planVersion: CONNECTION_MIGRATION_PLAN_VERSION, authoritySelection: { canonicalOwner: "connection-owner" as const, providerStateOwner: "knowledge" as const }, sourceName, sourceStateRevision: source.stateRevision, ...(source.catalogID ? { catalogID: source.catalogID } : {}), knowledgeConfig: clone(source.config), ownerState, providerStates, knowledgeReceipts: clone(source.receipts) };
  const planHash = createHash("sha256").update(canonicalJSON(unsigned)).digest("hex");
  return { ...unsigned, planHash };
}

export function verifyMigrationPlan(plan: unknown, expectedPlanHash: string): asserts plan is ConnectionMigrationPlan {
  if (!plan || typeof plan !== "object" || Array.isArray(plan)) throw invalid("migration plan is invalid");
  const value = plan as ConnectionMigrationPlan;
  if (value.planVersion !== CONNECTION_MIGRATION_PLAN_VERSION || typeof value.planHash !== "string" || !/^[a-f0-9]{64}$/.test(value.planHash) || value.planHash !== expectedPlanHash) throw invalid("migration plan hash/version does not match the reviewed plan");
  if (value.authoritySelection?.canonicalOwner !== "connection-owner" || value.authoritySelection.providerStateOwner !== "knowledge") throw invalid("migration authority selection is invalid");
  validateConnectionState(value.ownerState);
  if (!Number.isSafeInteger(value.sourceStateRevision) || !Array.isArray(value.providerStates) || !("knowledgeConfig" in value) || !value.knowledgeReceipts || typeof value.knowledgeReceipts !== "object" || Array.isArray(value.knowledgeReceipts)) throw invalid("migration provider state is invalid");
  const unsigned = { planVersion: CONNECTION_MIGRATION_PLAN_VERSION, authoritySelection: value.authoritySelection, sourceName: value.sourceName, sourceStateRevision: value.sourceStateRevision, ...(value.catalogID ? { catalogID: value.catalogID } : {}), knowledgeConfig: value.knowledgeConfig, ownerState: value.ownerState, providerStates: value.providerStates, knowledgeReceipts: value.knowledgeReceipts };
  const actual = createHash("sha256").update(canonicalJSON(unsigned)).digest("hex");
  if (actual !== expectedPlanHash) throw invalid("migration plan contents do not match its hash");
}

function destinations(value: ConnectionMigrationDestinations): ConnectionMigrationDestinations {
  for (const path of [value.ownerPath, value.providerPath, value.publicationPath]) if (!path || basename(path) === "." || basename(path) === "..") throw invalid("migration destination is invalid");
  return value;
}

/** Publish the two real authorities as a resumable operator action. This does
 * not mutate a live Gateway; destinations must be an offline staging root. */
export async function publishConnectionMigration(plan: ConnectionMigrationPlan, target: ConnectionMigrationDestinations, expectedPlanHash: string, operatorApproved: boolean): Promise<ConnectionMigrationPublication> {
  if (!operatorApproved) throw invalid("operator approval is required before publication");
  verifyMigrationPlan(plan, expectedPlanHash);
  const output = destinations(target);
  for (const path of [output.ownerPath, output.providerPath, output.publicationPath]) {
    try { await lstat(path); throw invalid("migration destination already exists; recover the prior publication before retrying"); } catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
  }
  await mkdir(dirname(output.ownerPath), { recursive: true, mode: 0o700 });
  await mkdir(dirname(output.providerPath), { recursive: true, mode: 0o700 });
  await mkdir(dirname(output.publicationPath), { recursive: true, mode: 0o700 });
  const planHash = expectedPlanHash;
  const base: ConnectionMigrationPublication = { publicationVersion: 1, planHash, phase: "prepared", ownerPath: output.ownerPath, providerPath: output.providerPath, publishedAt: new Date().toISOString() };
  await durableAtomicWriteJson(output.publicationPath, base, 0o600);
  await durableAtomicWriteJson(output.ownerPath, plan.ownerState, 0o600);
  await durableAtomicWriteJson(output.publicationPath, { ...base, phase: "owner-published" as const, publishedAt: new Date().toISOString() }, 0o600);
  await durableAtomicWriteJson(output.providerPath, { storageVersion: 1, schemaVersion: 1, ...(plan.catalogID ? { catalogID: plan.catalogID } : {}), stateRevision: plan.sourceStateRevision + 1, config: plan.knowledgeConfig, connectors: Object.fromEntries(plan.providerStates.map(item => [item.connectionId, item.state])), receipts: plan.knowledgeReceipts }, 0o600);
  const published = { ...base, phase: "published" as const, publishedAt: new Date().toISOString() };
  await durableAtomicWriteJson(output.publicationPath, published, 0o600);
  return published;
}

export async function recoverConnectionMigration(publicationPath: string): Promise<ConnectionMigrationPublication> {
  let value: unknown;
  try { value = JSON.parse(await readFile(publicationPath, "utf8")); } catch { throw invalid("migration publication cannot be read"); }
  if (!value || typeof value !== "object" || (value as ConnectionMigrationPublication).publicationVersion !== 1 || !["prepared", "owner-published", "published"].includes((value as ConnectionMigrationPublication).phase)) throw invalid("migration publication is invalid");
  const publication = value as ConnectionMigrationPublication;
  for (const path of [publication.ownerPath, publication.providerPath]) { try { await lstat(path); } catch { if ((value as ConnectionMigrationPublication).phase === "published") throw invalid("published migration is incomplete"); } }
  return publication;
}
