import { createHash } from "node:crypto";
import { readFile, lstat, mkdir } from "node:fs/promises";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { KnowledgeCatalog, type KnowledgeTable } from "../knowledge/knowledge-catalog.js";
import { CATALOG_STORAGE_VERSION } from "../knowledge/knowledge-store.js";
import type { TronWorkspace } from "../workspace/tron-workspace.js";
import { durableAtomicWriteJson } from "../util/durable-json.js";
import type { ConnectionInstance, ConnectionOwnerState, ConnectionPolicy } from "./connection-contract.js";
import { CONNECTION_STATE_SCHEMA_VERSION, validateConnectionState } from "./connection-contract.js";
import { connectionStatePath } from "./connection-owner.js";

export const CONNECTION_MIGRATION_PLAN_VERSION = 3 as const;
export const CONNECTION_MIGRATION_JOURNAL_VERSION = 1 as const;

type ConnectorKind = "raindrop" | "x";

/** The pre-migration Knowledge control shape. It is deliberately read from the
 * real catalog control rather than a connector-only sidecar. */
export interface LegacyConnectorState {
  connector: ConnectorKind;
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
  storageVersion?: 1 | typeof CATALOG_STORAGE_VERSION;
  stateRevision: number;
  catalogID?: string;
  config: unknown;
  connectors: Record<string, LegacyConnectorState>;
  receipts: Record<string, unknown>;
}

export interface MigratedProviderState {
  sourceKey: string;
  connectionId: string;
  connector: ConnectorKind;
  state: Record<string, unknown>;
}

export interface ConnectionMigrationPaths {
  readonly tronHome: string;
  readonly knowledgeRoot: string;
  readonly statePath: string;
  readonly catalogPath: string;
  readonly ownerPath: string;
}

export interface ConnectionMigrationPlan {
  planVersion: typeof CONNECTION_MIGRATION_PLAN_VERSION;
  authoritySelection: { canonicalOwner: "connection-owner"; providerStateOwner: "knowledge" };
  planHash: string;
  sourceName: string;
  sourceStatePath: string;
  sourceCatalogPath: string;
  sourceStateDigest: string;
  sourceCatalogDigest: string;
  sourceStateRevision: number;
  catalogID: string;
  knowledgeConfig: unknown;
  ownerState: ConnectionOwnerState;
  providerStates: MigratedProviderState[];
  /** Retained as plan evidence; receipt rows remain in the catalog authority. */
  knowledgeReceipts: Record<string, unknown>;
  ownerPath: string;
}

export interface ConnectionMigrationJournal {
  journalVersion: typeof CONNECTION_MIGRATION_JOURNAL_VERSION;
  planHash: string;
  phase: "prepared" | "owner-published" | "knowledge-published" | "published";
  ownerPath: string;
  catalogPath: string;
  sourceStatePath: string;
  sourceStateDigest: string;
  sourceCatalogDigest: string;
  updatedAt: string;
}

interface StagedMigration {
  plan: ConnectionMigrationPlan;
  journal: ConnectionMigrationJournal;
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
function canonicalJSON(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(",")}]`;
  if (value && typeof value === "object") return `{${Object.keys(value as Record<string, unknown>).sort().map(key => `${JSON.stringify(key)}:${canonicalJSON((value as Record<string, unknown>)[key])}`).join(",")}}`;
  return JSON.stringify(value);
}
function hashValue(value: unknown): string { return createHash("sha256").update(canonicalJSON(value)).digest("hex"); }
async function digest(path: string): Promise<string> { return createHash("sha256").update(await readFile(path)).digest("hex"); }
/** SQLite may have an externally visible WAL/SHM pair. Hash every present
 * sidecar without opening a writable connection; preflight must not checkpoint
 * or otherwise mutate the source catalog. */
async function catalogDigest(path: string): Promise<string> {
  const hash = createHash("sha256");
  for (const suffix of ["", "-wal", "-shm"]) {
    const candidate = `${path}${suffix}`;
    try {
      await ownerOnlyRegular(candidate, `Knowledge catalog${suffix}`);
      hash.update(suffix).update("\\0").update(await readFile(candidate));
    } catch (error) {
      if (!(error instanceof Error && error.message.endsWith(" is missing"))) throw error;
      hash.update(suffix).update("\\0missing");
    }
  }
  return hash.digest("hex");
}
function now(): string { return new Date().toISOString(); }

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
  if (source.storageVersion !== undefined && source.storageVersion !== CATALOG_STORAGE_VERSION) throw invalid("Knowledge catalog storage version is invalid");
  if (source.catalogID !== undefined && !/^[0-9a-f-]{36}$/.test(source.catalogID as string)) throw invalid("Knowledge catalog identity is invalid");
  if (!source.catalogID || source.storageVersion !== CATALOG_STORAGE_VERSION) throw invalid("migration requires a catalog-v2 Knowledge source");
  if (!("config" in source)) throw invalid("Knowledge config is missing");
  validateConnectorMap(source.connectors);
  if (!source.receipts || typeof source.receipts !== "object" || Array.isArray(source.receipts)) throw invalid("Knowledge receipt map is invalid");
}

async function ownerOnlyRegular(path: string, label: string): Promise<void> {
  let info;
  try { info = await lstat(path); } catch { throw invalid(`${label} is missing`); }
  if (!info.isFile() || info.isSymbolicLink() || info.nlink !== 1 || info.uid !== process.getuid?.() || (info.mode & 0o077) !== 0) throw invalid(`${label} must be an owner-only regular file`);
}
async function ownerOnlyDirectory(path: string, label: string, allowMissing = false): Promise<void> {
  let info;
  try { info = await lstat(path); } catch (error) {
    if (allowMissing && (error as NodeJS.ErrnoException).code === "ENOENT") return;
    throw invalid(`${label} is missing`);
  }
  if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid?.() || (info.mode & 0o077) !== 0) throw invalid(`${label} must be an owner-only real directory`);
}
async function missing(path: string, label: string): Promise<void> {
  try { await lstat(path); throw invalid(`${label} already exists; recover the prior publication before retrying`); }
  catch (error) { if (error instanceof Error && error.message.startsWith("Connection migration:")) throw error; if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw invalid(`${label} cannot be inspected safely`); }
}

/** Resolve both authorities through their owning resolvers. In particular,
 * ConnectionOwner's path is not inferred from the Knowledge workspace path. */
export async function resolveConnectionMigrationPaths(workspace: Pick<TronWorkspace, "describe">, tronHome: string): Promise<ConnectionMigrationPaths> {
  const descriptor = await workspace.describe();
  if (!descriptor.available) throw invalid(`Knowledge workspace is unavailable${descriptor.reason ? ` (${descriptor.reason})` : ""}`);
  const home = resolve(tronHome);
  await ownerOnlyDirectory(home, "Tron home");
  const knowledgeRoot = join(descriptor.root, "state", "knowledge");
  await ownerOnlyDirectory(join(descriptor.root, "state"), "Knowledge state directory");
  await ownerOnlyDirectory(knowledgeRoot, "Knowledge directory");
  const statePath = join(knowledgeRoot, "state.json");
  await ownerOnlyRegular(statePath, "Knowledge state manifest");
  let manifest: unknown;
  try { manifest = JSON.parse(await readFile(statePath, "utf8")); } catch { throw invalid("Knowledge state manifest is not valid JSON"); }
  const value = manifest as Record<string, unknown>;
  if (!value || value.storageVersion !== CATALOG_STORAGE_VERSION || typeof value.catalogID !== "string" || !/^[0-9a-f-]{36}$/.test(value.catalogID)) throw invalid("Knowledge state is not a catalog-v2 manifest");
  const catalogPath = join(knowledgeRoot, `catalog-${value.catalogID}.sqlite`);
  await ownerOnlyRegular(catalogPath, "Knowledge catalog");
  const ownerPath = connectionStatePath(home);
  await ownerOnlyDirectory(dirname(ownerPath), "ConnectionOwner directory", true);
  return { tronHome: home, knowledgeRoot, statePath, catalogPath, ownerPath };
}

/** Read the current production state.json plus its catalog control/receipts.
 * ownerPath is explicit because the ConnectionOwner lives under tronHome/state,
 * while Knowledge lives under the resolved workspace. */
export async function readLegacyConnectorState(path: string, ownerPath?: string, fileSystem: { readFile: typeof readFile } = { readFile }): Promise<KnowledgeConnectorSource> {
  if (!path || basename(path) !== "state.json") throw invalid("source must be an explicit Knowledge state.json");
  let value: unknown;
  try { value = JSON.parse(await fileSystem.readFile(path, "utf8")); } catch { throw invalid("Knowledge state could not be read or parsed"); }
  if (!value || typeof value !== "object" || Array.isArray(value)) throw invalid("Knowledge state is invalid");
  const manifest = value as Record<string, unknown>;
  if (manifest.storageVersion !== CATALOG_STORAGE_VERSION || manifest.schemaVersion !== 1 || typeof manifest.catalogID !== "string") throw invalid("Knowledge source must be catalog-v2");
  const catalogPath = join(dirname(path), `catalog-${manifest.catalogID}.sqlite`);
  let catalog: KnowledgeCatalog;
  try { catalog = new KnowledgeCatalog(catalogPath, true); } catch { throw invalid("Knowledge catalog could not be opened"); }
  try {
    const control = catalog.control<Record<string, unknown> & { schemaVersion: 1; stateRevision: number; catalogID: string; config: unknown; connectors?: Record<string, LegacyConnectorState> }>();
    if (control.catalogID !== manifest.catalogID || control.schemaVersion !== 1 || !Number.isSafeInteger(control.stateRevision)) throw invalid("Knowledge catalog control is invalid");
    const receipts = Object.fromEntries((catalog.table<Record<string, unknown>>("receipts") as KnowledgeTable<Record<string, unknown>>).entries());
    let connectors = control.connectors ?? {};
    if (Object.values(connectors).some(value => value && (value.accountId === undefined || value.credentialRef === undefined))) {
      if (!ownerPath) throw invalid("Knowledge catalog connector envelope is unavailable; supply the ConnectionOwner path");
      let owner: ConnectionOwnerState;
      try { owner = JSON.parse(await fileSystem.readFile(ownerPath, "utf8")) as ConnectionOwnerState; validateConnectionState(owner); }
      catch (error) { throw error instanceof Error && error.message.startsWith("Connection migration:") ? error : invalid("Knowledge catalog connector envelope is unavailable"); }
      connectors = Object.fromEntries(Object.entries(connectors).map(([key, state]) => {
        const envelope = owner.instances[key];
        if (!envelope) throw invalid("Knowledge catalog connector has no matching connection owner");
        return [key, { ...state, enabled: envelope.policy.enabled, accountId: envelope.providerAccountId, ...(envelope.scope ? { scope: envelope.scope } : {}), credentialRef: envelope.credentialRef, allowWrites: envelope.policy.allowWrites, paidAccessApproved: envelope.policy.paidAccessApproved, paidBudgetCents: envelope.policy.paidBudgetCents, recurringApproved: envelope.policy.recurringApproved, connectionId: key }];
      }));
    }
    const source = { storageVersion: CATALOG_STORAGE_VERSION, schemaVersion: control.schemaVersion, stateRevision: control.stateRevision, catalogID: manifest.catalogID, config: control.config, connectors, receipts };
    validateSource(source);
    return clone(source);
  } catch (error) { throw error instanceof Error && error.message.startsWith("Connection migration:") ? error : invalid("Knowledge catalog control is invalid"); }
  finally { catalog.close(); }
}

function unsignedPlan(plan: ConnectionMigrationPlan | Omit<ConnectionMigrationPlan, "planHash">): Omit<ConnectionMigrationPlan, "planHash"> {
  const { planHash: _planHash, ...unsigned } = plan as ConnectionMigrationPlan;
  return unsigned;
}

/** Build a write-free plan from the production catalog. */
export async function prepareConnectionMigration(paths: ConnectionMigrationPaths): Promise<ConnectionMigrationPlan>;
export function prepareConnectionMigration(input: unknown, sourceName?: string): ConnectionMigrationPlan;
export function prepareConnectionMigration(input: unknown, sourceName = "knowledge/state.json"): ConnectionMigrationPlan | Promise<ConnectionMigrationPlan> {
  if (isPaths(input)) return prepareFromPaths(input);
  validateSource(input);
  return planFromSource(input, sourceName);
}
function isPaths(value: unknown): value is ConnectionMigrationPaths { return Boolean(value && typeof value === "object" && "statePath" in value && "catalogPath" in value && "ownerPath" in value); }
async function prepareFromPaths(paths: ConnectionMigrationPaths): Promise<ConnectionMigrationPlan> {
  const source = await readLegacyConnectorState(paths.statePath, paths.ownerPath);
  const plan = planFromSource(source, paths.statePath);
  plan.sourceStatePath = paths.statePath; plan.sourceCatalogPath = paths.catalogPath; plan.ownerPath = paths.ownerPath;
  plan.sourceStateDigest = await digest(paths.statePath); plan.sourceCatalogDigest = await catalogDigest(paths.catalogPath);
  plan.planHash = hashValue(unsignedPlan(plan));
  return plan;
}
function planFromSource(input: KnowledgeConnectorSource, sourceName: string): ConnectionMigrationPlan {
  const source = input;
  const instances: Record<string, ConnectionInstance> = {};
  const providerStates: MigratedProviderState[] = [];
  for (const [sourceKey, legacy] of Object.entries(source.connectors)) {
    const connector = legacy.connector;
    const accountId = legacy.accountId as string;
    const scope = legacy.scope as string | undefined;
    const credentialRef = legacy.credentialRef as string;
    const instanceId = typeof legacy.connectionId === "string" ? legacy.connectionId : connectionId(connector, accountId, scope);
    const timestamp = new Date(0).toISOString();
    const instance: ConnectionInstance = { id: instanceId, definitionId: `knowledge.${connector}`, implementation: "knowledge-connector", providerAccountId: accountId, ...(scope ? { scope } : {}), credentialRef, policy: policy(legacy), health: legacy.enabled ? "setup-required" : "disabled", createdAt: timestamp, updatedAt: timestamp, setupRevision: 1, credentialAvailability: "unknown", providerIdentity: "unknown" };
    if (instances[instanceId]) throw invalid("conflicting duplicate connection identity");
    instances[instanceId] = instance;
    const state = clone(legacy) as Record<string, unknown>;
    state.connectionId = instanceId;
    for (const key of ["enabled", "accountId", "scope", "credentialRef", "allowWrites", "paidAccessApproved", "paidBudgetCents", "recurringApproved"]) delete state[key];
    providerStates.push({ sourceKey, connectionId: instanceId, connector, state });
  }
  const ownerState: ConnectionOwnerState = { schemaVersion: CONNECTION_STATE_SCHEMA_VERSION, stateRevision: 1, instances, setupOperations: {}, receipts: {} };
  validateConnectionState(ownerState);
  const plan = { planVersion: CONNECTION_MIGRATION_PLAN_VERSION, authoritySelection: { canonicalOwner: "connection-owner" as const, providerStateOwner: "knowledge" as const }, sourceName, sourceStatePath: "", sourceCatalogPath: "", sourceStateDigest: "", sourceCatalogDigest: "", sourceStateRevision: source.stateRevision, catalogID: source.catalogID!, knowledgeConfig: clone(source.config), ownerState, providerStates, knowledgeReceipts: clone(source.receipts), ownerPath: "" };
  return { ...plan, planHash: hashValue(unsignedPlan(plan)) };
}

export function verifyMigrationPlan(plan: unknown, expectedPlanHash: string): asserts plan is ConnectionMigrationPlan {
  if (!plan || typeof plan !== "object" || Array.isArray(plan)) throw invalid("migration plan is invalid");
  const value = plan as ConnectionMigrationPlan;
  if (value.planVersion !== CONNECTION_MIGRATION_PLAN_VERSION || typeof value.planHash !== "string" || !/^[a-f0-9]{64}$/.test(value.planHash) || value.planHash !== expectedPlanHash) throw invalid("migration plan hash/version does not match the reviewed plan");
  if (value.authoritySelection?.canonicalOwner !== "connection-owner" || value.authoritySelection.providerStateOwner !== "knowledge") throw invalid("migration authority selection is invalid");
  if (!value.sourceStatePath || !value.sourceCatalogPath || !value.ownerPath || !/^[a-f0-9]{64}$/.test(value.sourceStateDigest) || !/^[a-f0-9]{64}$/.test(value.sourceCatalogDigest) || !/^[0-9a-f-]{36}$/.test(value.catalogID)) throw invalid("migration source evidence is invalid");
  validateConnectionState(value.ownerState);
  if (!Number.isSafeInteger(value.sourceStateRevision) || !Array.isArray(value.providerStates) || !("knowledgeConfig" in value) || !value.knowledgeReceipts || typeof value.knowledgeReceipts !== "object" || Array.isArray(value.knowledgeReceipts)) throw invalid("migration provider state is invalid");
  const unsigned = { planVersion: value.planVersion, authoritySelection: value.authoritySelection, sourceName: value.sourceName, sourceStatePath: value.sourceStatePath, sourceCatalogPath: value.sourceCatalogPath, sourceStateDigest: value.sourceStateDigest, sourceCatalogDigest: value.sourceCatalogDigest, sourceStateRevision: value.sourceStateRevision, catalogID: value.catalogID, knowledgeConfig: value.knowledgeConfig, ownerState: value.ownerState, providerStates: value.providerStates, knowledgeReceipts: value.knowledgeReceipts, ownerPath: value.ownerPath };
  if (hashValue(unsigned) !== expectedPlanHash) throw invalid("migration plan contents do not match its hash");
}

function planPath(staging: string): string { return join(staging, "plan.json"); }
function journalPath(staging: string): string { return join(staging, "journal.json"); }
async function readJSON(path: string): Promise<unknown> { try { return JSON.parse(await readFile(path, "utf8")); } catch { throw invalid(`migration file cannot be read: ${basename(path)}`); } }
async function readStaged(stagingInput: string): Promise<StagedMigration> {
  const staging = resolve(stagingInput);
  await ownerOnlyRegular(planPath(staging), "migration plan");
  await ownerOnlyRegular(journalPath(staging), "migration journal");
  const planValue = await readJSON(planPath(staging));
  const journalValue = await readJSON(journalPath(staging));
  const plan = planValue as ConnectionMigrationPlan;
  verifyMigrationPlan(plan, plan.planHash);
  const journal = journalValue as ConnectionMigrationJournal;
  if (!journal || journal.journalVersion !== CONNECTION_MIGRATION_JOURNAL_VERSION || journal.planHash !== plan.planHash || !["prepared", "owner-published", "knowledge-published", "published"].includes(journal.phase)) throw invalid("migration journal is invalid");
  return { plan, journal };
}
async function sourceStillMatches(plan: ConnectionMigrationPlan): Promise<void> {
  await ownerOnlyRegular(plan.sourceStatePath, "source Knowledge manifest");
  await ownerOnlyRegular(plan.sourceCatalogPath, "source Knowledge catalog");
  if (await digest(plan.sourceStatePath) !== plan.sourceStateDigest || await catalogDigest(plan.sourceCatalogPath) !== plan.sourceCatalogDigest) throw invalid("source changed after preparation; preserve it and prepare a new plan");
}
function journalFor(plan: ConnectionMigrationPlan, phase: ConnectionMigrationJournal["phase"]): ConnectionMigrationJournal {
  return { journalVersion: CONNECTION_MIGRATION_JOURNAL_VERSION, planHash: plan.planHash, phase, ownerPath: plan.ownerPath, catalogPath: plan.sourceCatalogPath, sourceStatePath: plan.sourceStatePath, sourceStateDigest: plan.sourceStateDigest, sourceCatalogDigest: plan.sourceCatalogDigest, updatedAt: now() };
}
async function writeJournal(staging: string, value: ConnectionMigrationJournal): Promise<void> { await durableAtomicWriteJson(journalPath(staging), value, 0o600); }

/** Write only private staging. No authority is changed by this operation. */
export async function stageConnectionMigration(plan: ConnectionMigrationPlan, stagingInput: string): Promise<ConnectionMigrationPlan> {
  verifyMigrationPlan(plan, plan.planHash);
  const staging = resolve(stagingInput);
  await missing(staging, "migration staging");
  await mkdir(staging, { recursive: true, mode: 0o700 });
  await ownerOnlyDirectory(staging, "migration staging");
  await sourceStillMatches(plan);
  await durableAtomicWriteJson(planPath(staging), plan, 0o600);
  await writeJournal(staging, journalFor(plan, "prepared"));
  return clone(plan);
}

function expectedProviderMap(plan: ConnectionMigrationPlan): Record<string, Record<string, unknown>> {
  return Object.fromEntries(plan.providerStates.map(item => [item.connectionId, { ...clone(item.state), connectionId: item.connectionId }]));
}
async function ownerMatches(plan: ConnectionMigrationPlan): Promise<boolean> {
  try { const value = JSON.parse(await readFile(plan.ownerPath, "utf8")); validateConnectionState(value); return hashValue(value) === hashValue(plan.ownerState); }
  catch { return false; }
}
async function publishOwner(plan: ConnectionMigrationPlan): Promise<void> {
  if (await ownerMatches(plan)) return;
  await missing(plan.ownerPath, "ConnectionOwner state");
  await mkdir(dirname(plan.ownerPath), { recursive: true, mode: 0o700 });
  await ownerOnlyDirectory(dirname(plan.ownerPath), "ConnectionOwner directory");
  await durableAtomicWriteJson(plan.ownerPath, plan.ownerState, 0o600);
  if (!(await ownerMatches(plan))) throw invalid("ConnectionOwner publication could not be verified");
}
async function catalogMatches(plan: ConnectionMigrationPlan): Promise<boolean> {
  const catalog = new KnowledgeCatalog(plan.sourceCatalogPath, true);
  try {
    const control = catalog.control<Record<string, unknown> & { catalogID: string; stateRevision: number; connectors?: unknown }>();
    return control.catalogID === plan.catalogID && control.stateRevision === plan.sourceStateRevision + 1 && canonicalJSON(control.connectors ?? {}) === canonicalJSON(expectedProviderMap(plan));
  } finally { catalog.close(); }
}
async function publishCatalog(plan: ConnectionMigrationPlan): Promise<void> {
  if (await catalogMatches(plan)) return;
  await sourceStillMatches(plan);
  const catalog = new KnowledgeCatalog(plan.sourceCatalogPath, false);
  try {
    const control = catalog.control<Record<string, unknown> & { schemaVersion: 1; catalogID: string; stateRevision: number; config: unknown; connectors?: Record<string, unknown> }>();
    if (control.catalogID !== plan.catalogID || control.stateRevision !== plan.sourceStateRevision) throw invalid("Knowledge catalog revision or identity changed after preparation");
    if (canonicalJSON(control.config) !== canonicalJSON(plan.knowledgeConfig)) throw invalid("Knowledge configuration changed after preparation");
    catalog.begin();
    catalog.setControl({ ...control, stateRevision: control.stateRevision + 1, connectors: expectedProviderMap(plan) });
    catalog.commit();
  } finally { catalog.close(); }
  if (!(await catalogMatches(plan))) throw invalid("Knowledge catalog publication could not be verified");
}

/** Publish the two existing authorities. There is no provider JSON sidecar and
 * no snapshot replacement: the owner file is published, then the existing
 * catalog control row is transactionally rewritten while all catalog tables,
 * immutable records, config and receipts remain in place. */
export async function publishConnectionMigration(stagingInput: string, operatorApproved: boolean): Promise<ConnectionMigrationJournal> {
  if (!operatorApproved) throw invalid("operator approval is required before publication");
  const staging = resolve(stagingInput);
  const staged = await readStaged(staging);
  let journal = staged.journal;
  if (journal.phase === "published") return journal;
  await sourceStillMatches(staged.plan);
  await writeJournal(staging, journalFor(staged.plan, "prepared"));
  await publishOwner(staged.plan);
  journal = journalFor(staged.plan, "owner-published"); await writeJournal(staging, journal);
  await publishCatalog(staged.plan);
  journal = journalFor(staged.plan, "knowledge-published"); await writeJournal(staging, journal);
  journal = journalFor(staged.plan, "published"); await writeJournal(staging, journal);
  return journal;
}

/** Explicit operator recovery. It resumes only the journal's selected
 * authorities after rechecking source hashes and exact destination contents. */
export async function recoverConnectionMigration(stagingInput: string): Promise<ConnectionMigrationJournal> {
  const staging = resolve(stagingInput);
  const staged = await readStaged(staging);
  if (staged.journal.phase === "published") return staged.journal;
  const catalogAlreadyPublished = staged.journal.phase !== "prepared" && await catalogMatches(staged.plan);
  if (staged.journal.phase === "prepared" || (staged.journal.phase === "owner-published" && !catalogAlreadyPublished)) await sourceStillMatches(staged.plan);
  if (staged.journal.phase === "prepared") await publishOwner(staged.plan);
  if (!(await ownerMatches(staged.plan))) throw invalid("ConnectionOwner authority is incomplete or conflicting");
  await writeJournal(staging, journalFor(staged.plan, "owner-published"));
  await publishCatalog(staged.plan);
  await writeJournal(staging, journalFor(staged.plan, "knowledge-published"));
  const published = journalFor(staged.plan, "published"); await writeJournal(staging, published); return published;
}

function argument(args: readonly string[], name: string): string | undefined { const index = args.indexOf(name); return index < 0 ? undefined : args[index + 1]; }
function usage(): never { console.error("Usage: scripts/tron connection-migrate <preflight|prepare|stage|publish|recover> --tron-home <path> [--staging <path>] [--confirm-offline]"); process.exit(64); }

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [operation, ...args] = process.argv.slice(2);
  try {
    const tronHome = argument(args, "--tron-home");
    const staging = argument(args, "--staging");
    if (!operation || !tronHome) usage();
    const { TronWorkspace } = await import("../workspace/tron-workspace.js");
    const workspace = { describe: () => TronWorkspace.describeExisting(tronHome!) };
    const paths = await resolveConnectionMigrationPaths(workspace, tronHome!);
    let result: unknown;
    if (operation === "preflight") result = paths;
    else if (operation === "prepare") result = await prepareConnectionMigration(paths);
    else if (operation === "stage") { if (!staging) usage(); result = await stageConnectionMigration(await prepareConnectionMigration(paths), staging); }
    else if (operation === "publish") { if (!staging || !args.includes("--confirm-offline")) usage(); result = await publishConnectionMigration(staging, true); }
    else if (operation === "recover") { if (!staging) usage(); result = await recoverConnectionMigration(staging); }
    else usage();
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } catch (error) { console.error(error instanceof Error ? error.message : "connection migration failed"); process.exitCode = 2; }
}
