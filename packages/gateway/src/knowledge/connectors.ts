import { createHash, randomBytes, randomUUID } from "node:crypto";
import { KnowledgeCurationRefusal, type KnowledgeAssessmentApprovalRequest, type KnowledgeConnectorConfigurationRequest, type KnowledgeConnectorDiscoverRequest, type KnowledgeConnectorQueueRequest, type KnowledgeConnectorAckRequest, type KnowledgeRaindropMoveRequest, type KnowledgeConnectorState, type KnowledgeConnectorStatus, type KnowledgeAction, type KnowledgeXOAuthStartRequest, type KnowledgeXOAuthCompleteRequest, type KnowledgeRecord, type KnowledgeRaindropRequest, type KnowledgeRaindropIntakeRequest, type KnowledgeSourceIngestRequest } from "./knowledge-contract.js";
import { captureSource, isVerifiedSourceCapture, recoverProviderSaveTime } from "./source-capture.js";
import type { SourceAssessmentModel } from "./source-capture.js";
import { triageSource } from "./source-triage.js";
import { xPostIdentity } from "./x-public-post.js";
import { GatewayError } from "../errors.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { sourceAdmissionIsDecided, type KnowledgeStore } from "./knowledge-store.js";
import { CONNECTOR_CREDENTIAL_SERVICE, isConnectorCredentialReference, type ConnectorCredentialStore, type WritableConnectorCredentialStore } from "./connector-credentials.js";
import { currentInvocationContext } from "../extensions/owner-attribution.js";
import { jevInputDigest, jevProfileVersion } from "./jev-assessment.js";
import { JEV_DEFAULT_MODEL } from "./jev-client.js";
import type { ConnectionOwner } from "../integrations/connection-owner.js";
import type { KnowledgeTaggingBudget } from "./knowledge-tagger.js";
import { normalizeProviderDisplayName, validateConnectionPolicy, type ConnectionInstance, type ProviderAdmissionObservation } from "../integrations/connection-contract.js";
import { FixedHostBodyTooLarge, requestFixedHost } from "./fixed-host-transport.js";

function isPublicXPost(url: string): boolean {
  try { xPostIdentity(url); return true; } catch { return false; }
}

const MAX_PAGE = 50;
const MAX_ITEMS = 200;
const BODY_LIMIT = 2_000_000;
const RETRIES = 3;
const RUN_DEADLINE_MS = 120_000;
const CONNECTORS = ["raindrop", "x"] as const;
type Connector = typeof CONNECTORS[number];

export interface ConnectorHTTPResponse { status: number; headers: Headers; body: string; }
export type ConnectorHTTP = (input: string, init: { method?: "GET" | "PUT" | "POST" | "DELETE"; headers: Record<string, string>; body?: string; signal: AbortSignal }) => Promise<ConnectorHTTPResponse>;
export type ConnectorSourceFetch = (url: string, excerpt: string | undefined, signal: AbortSignal) => Promise<Response>;
export type ConnectorResolveHost = (hostname: string, signal?: AbortSignal) => Promise<string[]>;

export interface KnowledgeConnectorOptions {
  credentials: ConnectorCredentialStore;
  http?: ConnectorHTTP;
  sourceFetch?: ConnectorSourceFetch;
  resolveHost?: ConnectorResolveHost;
  sleep?: (milliseconds: number) => Promise<void>;
  now?: () => string;
  /** Host-qualified X allowance; unknown price/account remains unsupported. */
  xPricing?: { accountId: string; costCentsPerAttempt: number; maxAttempts: number };
  /** Optional bounded Jev decision adapter; absence fails intake closed. */
  assessment?: SourceAssessmentModel;
  /** Queues owned summary work after a source's save-time and extraction recovery; never awaited by intake. */
  queueSummary?: (source: KnowledgeRecord & { kind: "source" }) => void;
  /** Generic account owner. When present, connector configuration requires a connectionId. */
  connections?: ConnectionOwner;
  /** Shared Knowledge-owned monthly Jev ledger for both tagging and intake assessment. */
  jevBudget?: KnowledgeTaggingBudget;
}

interface PendingItem { id: string; title: string; url: string; excerpt?: string; annotation?: string; publishedAt?: string; savedAt?: string; collectionId?: string; apiPayload?: string }
interface Page { items: PendingItem[]; next?: string; accountId?: string; }
interface RaindropItemDTO { _id?: unknown; title?: unknown; link?: unknown; excerpt?: unknown; note?: unknown; created?: unknown; collection?: unknown; [key: string]: unknown; }
interface XBookmarkDTO { id?: unknown; text?: unknown; created_at?: unknown; author_id?: unknown; entities?: unknown; }

function bad(message: string): GatewayError { return new GatewayError("invalid_request", message); }
/** A missing Keychain item is the one connector failure a person can fix, so the
 * failure names the exact service and account to add. The credential reference
 * is an opaque Keychain account name, and no token ever appears here. */
function missingCredential(connector: Connector, credentialRef: string): GatewayError {
  return new GatewayError("unsupported", `${connector === "raindrop" ? "Raindrop" : "X"} credential is unavailable. Add it to the Mac Keychain: service '${CONNECTOR_CREDENTIAL_SERVICE}', account '${credentialRef}'.`);
}
function command(base: string, suffix: string): string {
  const normalizedBase = base.replace(/[^A-Za-z0-9._:-]/g, "_"); const normalizedSuffix = suffix.replace(/[^A-Za-z0-9._:-]/g, "_");
  const digest = createHash("sha256").update(`${base}\u0000${suffix}`).digest("hex").slice(0, 16);
  return `${normalizedBase.slice(0, 72)}:${normalizedSuffix.slice(0, 64)}:${digest}`.slice(0, 160);
}
function id(value: unknown, label: string): string | undefined { return typeof value === "string" && value.length > 0 && value.length <= 512 ? value : typeof value === "number" && Number.isSafeInteger(value) ? String(value) : undefined; }
function text(value: unknown, maximum = 100_000): string | undefined { return typeof value === "string" && value.length > 0 ? value.slice(0, maximum) : undefined; }
function raindropUser(value: unknown): { accountId?: string; displayName?: string } {
  const user = value && typeof value === "object" && !Array.isArray(value) && "user" in value
    ? (value as Record<string, unknown>).user
    : value;
  if (!user || typeof user !== "object" || Array.isArray(user)) return {};
  const record = user as Record<string, unknown>;
  const accountId = id(record._id, "Raindrop account");
  const displayName = normalizeProviderDisplayName(record.email) ?? normalizeProviderDisplayName(record.username) ?? normalizeProviderDisplayName(record.fullName);
  return { ...(accountId ? { accountId } : {}), ...(displayName ? { displayName } : {}) };
}
function url(value: unknown): string | undefined { if (typeof value !== "string") return undefined; try { const parsed = new URL(value); return ["http:", "https:"].includes(parsed.protocol) && !parsed.username && !parsed.password ? parsed.toString() : undefined; } catch { return undefined; } }
function retryable(status: number): boolean { return status === 408 || status === 425 || status === 429 || status >= 500; }
function authFailure(status: number): boolean { return status === 401 || status === 403; }

async function defaultHTTP(input: string, init: { method?: "GET" | "PUT" | "POST" | "DELETE"; headers: Record<string, string>; body?: string; signal: AbortSignal }): Promise<ConnectorHTTPResponse> {
  return requestFixedHost(input, {
    method: init.method ?? "GET", headers: init.headers, ...(init.body === undefined ? {} : { body: init.body }), signal: init.signal,
    allowedHosts: ["api.raindrop.io", "api.x.com"], timeoutMs: 15_000, maxBodyBytes: BODY_LIMIT,
  });
}

async function requestJson(http: ConnectorHTTP, endpoint: string, token: string | (() => Promise<string>), options: { method?: "GET" | "PUT" | "POST" | "DELETE"; body?: unknown; sleep: (milliseconds: number) => Promise<void>; signal: AbortSignal; maxAttempts?: number; beforeAttempt?: () => Promise<void>; onUnauthorized?: () => Promise<void> }): Promise<{ status: number; value: any; headers: Headers }> {
  const retrySafe = !options.method || options.method === "GET";
  const maxAttempts = retrySafe ? (options.maxAttempts ?? RETRIES) : 1;
  let refreshedAfterUnauthorized = false;
  let refreshedRetryPending = false;
  let attempt = 0;
  while (attempt < maxAttempts || refreshedRetryPending) {
    if (refreshedRetryPending) refreshedRetryPending = false;
    else attempt += 1;
    // Resolve the current credential before charging an attempt. A missing or
    // rotated token is an admission failure, not a billable provider try.
    const attemptToken = typeof token === "function" ? await token() : token;
    if (options.signal.aborted) throw options.signal.reason instanceof Error ? options.signal.reason : new Error("Connector request cancelled");
    await options.beforeAttempt?.();
    let result: ConnectorHTTPResponse;
    try {
      result = await http(endpoint, { ...(options.method ? { method: options.method } : {}), headers: { authorization: `Bearer ${attemptToken}`, accept: "application/json", ...(options.body !== undefined ? { "content-type": "application/json" } : {}) }, ...(options.body !== undefined ? { body: JSON.stringify(options.body) } : {}), signal: options.signal });
    } catch (error) {
      if (options.signal.aborted) throw error;
      if (!retrySafe || attempt === maxAttempts) throw new ConnectorNetworkError(error);
      await options.sleep(Math.max(50, 100 * 2 ** (attempt - 1)));
      continue;
    }
    let value: unknown = undefined;
    if (result.body) { try { value = JSON.parse(result.body); } catch { value = undefined; } }
    if (result.status >= 200 && result.status < 300) {
      if (value && typeof value === "object" && !Array.isArray(value) && (value as Record<string, unknown>).result === false) throw new ConnectorAPIError();
      return { status: result.status, value, headers: result.headers };
    }
    if (result.status === 401 && options.onUnauthorized && !refreshedAfterUnauthorized) {
      refreshedAfterUnauthorized = true;
      await options.onUnauthorized();
      refreshedRetryPending = true;
      continue;
    }
    if (!retryable(result.status) || attempt === maxAttempts) throw new ConnectorHTTPError(result.status, result.headers.get("retry-after"), result.headers.get("x-ratelimit-reset") ?? result.headers.get("ratelimit-reset"));
    if (options.signal.aborted) throw options.signal.reason instanceof Error ? options.signal.reason : new Error("Connector request cancelled");
    const retryAfterValue = result.headers.get("retry-after");
    const retryAfterSeconds = retryAfterValue && /^\d+(?:\.\d+)?$/.test(retryAfterValue) ? Number(retryAfterValue) : Number.NaN;
    const retryAfterDate = retryAfterValue && !Number.isNaN(Date.parse(retryAfterValue)) ? Math.max(0, (Date.parse(retryAfterValue) - Date.now()) / 1_000) : 0;
    const resetSeconds = Number(result.headers.get("x-ratelimit-reset") ?? result.headers.get("ratelimit-reset") ?? "0");
    const resetDelay = Number.isFinite(resetSeconds) && resetSeconds > 0 ? Math.max(0, resetSeconds - Date.now() / 1_000) : 0;
    const delay = Math.max(50, (Number.isFinite(retryAfterSeconds) ? retryAfterSeconds : retryAfterDate) * 1_000, resetDelay * 1_000, 100 * 2 ** (attempt - 1));
    // Never shorten a provider cooldown to fit our bounded operation.
    if (!Number.isFinite(delay) || delay >= RUN_DEADLINE_MS) throw new ConnectorHTTPError(result.status, result.headers.get("retry-after"), result.headers.get("x-ratelimit-reset") ?? result.headers.get("ratelimit-reset"));
    await options.sleep(delay);
    if (options.signal.aborted) throw options.signal.reason instanceof Error ? options.signal.reason : new Error("Connector request cancelled");
  }
  throw new ConnectorHTTPError(599);
}

class ConnectorHTTPError extends Error { constructor(readonly status: number, readonly retryAfter?: string | null, readonly reset?: string | null) { super(`Connector HTTP ${status}`); } }
class ConnectorAPIError extends Error { constructor() { super("Connector returned result=false"); } }
class ConnectorNetworkError extends Error { constructor(readonly underlying: unknown) { super("Connector network request failed"); } }
class ConnectorShapeError extends Error { constructor() { super("Connector returned an unexpected success shape"); } }

function initial(connector: Connector): KnowledgeConnectorState {
  return { connector, enabled: false, allowWrites: false, paidAccessApproved: false, paidBudgetCents: 0, recurringApproved: false, pending: [], capturedIds: [], health: "unconfigured", remaining: 0 };
}
/** Connector policy values for a configuration write: the request wins, then the
 * stored state on a merge, then the reset default an identity change starts from. */
function policyDefaults(request: KnowledgeConnectorConfigurationRequest, fallback?: KnowledgeConnectorState): Pick<KnowledgeConnectorState, "allowWrites" | "paidAccessApproved" | "paidBudgetCents" | "recurringApproved"> {
  return {
    allowWrites: request.allowWrites ?? fallback?.allowWrites ?? false,
    paidAccessApproved: request.paidAccessApproved ?? fallback?.paidAccessApproved ?? false,
    paidBudgetCents: request.paidBudgetCents ?? fallback?.paidBudgetCents ?? 0,
    recurringApproved: request.recurringApproved ?? fallback?.recurringApproved ?? false,
  };
}
function stateStatus(state: KnowledgeConnectorState | undefined, connector: Connector, authority?: ConnectionInstance): KnowledgeConnectorStatus {
  const value = state ?? initial(connector);
  // ConnectionOwner is the sole authority for account admission. Knowledge
  // keeps domain progress, but persisted observations cannot make a policy-reset
  // or successor instance ready.
  const configured = authority ? Boolean(authority.credentialRef && authority.providerAccountId && (connector === "raindrop" ? authority.raindropCollections?.length : authority.scope)) : Boolean(value.credentialRef && value.accountId && value.scope);
  const enabled = authority ? authority.policy.enabled : value.enabled;
  const credentialAvailability = authority?.credentialAvailability ?? value.credentialAvailability ?? "unknown";
  const providerIdentity = authority?.providerIdentity ?? value.providerIdentity ?? "unknown";
  const admitted = credentialAvailability === "available" && providerIdentity === "admitted";
  const ownerHealth = authority?.health;
  const projectedOwnerHealth = ownerHealth === "disabled" || ownerHealth === "disconnected" ? "unconfigured" : ownerHealth;
  const health = !configured || !enabled ? "unconfigured" : projectedOwnerHealth && projectedOwnerHealth !== "ready" ? projectedOwnerHealth : !admitted && authority ? "setup-required" : (value.health === "unconfigured" ? "ready" : value.health);
  const accountId = authority?.providerAccountId ?? value.accountId;
  const scope = connector === "raindrop" && authority?.raindropCollections ? undefined : authority?.scope ?? value.scope;
  const policy = authority?.policy;
  return { connector, ...(authority?.id ?? value.connectionId ? { connectionId: authority?.id ?? value.connectionId } : {}), configured, enabled, health, credentialAvailability, providerIdentity, ...(accountId ? { accountId } : {}), ...(scope ? { scope } : {}), ...(authority?.raindropCollections ? { raindropCollections: authority.raindropCollections } : {}), ...(value.lastRunAt ? { lastRunAt: value.lastRunAt } : {}), ...(value.lastError ? { lastError: value.lastError } : {}), remaining: value.remaining, pending: value.pending.length, paidBudgetCents: connector === "x" ? value.paidBudgetCents : policy?.paidBudgetCents ?? value.paidBudgetCents, allowWrites: policy?.allowWrites ?? value.allowWrites, recurringApproved: policy?.recurringApproved ?? value.recurringApproved, paidAccessApproved: policy?.paidAccessApproved ?? value.paidAccessApproved, ...(value.assessmentPilot ? { assessmentPilot: value.assessmentPilot } : {}), ...(value.assessmentPilots ? { assessmentPilots: value.assessmentPilots } : {}), ...(value.assessmentApprovals ? { assessmentApprovals: value.assessmentApprovals } : {}) };
}
function parseCollection(item: RaindropItemDTO): string | undefined {
  if (!item.collection || typeof item.collection !== "object") return undefined;
  return id((item.collection as Record<string, unknown>).$id, "collection");
}
function parseRaindrop(value: any): PendingItem[] {
  if (!value || !Array.isArray(value.items)) throw new ConnectorShapeError();
  return value.items.map((item: RaindropItemDTO) => {
    const itemId = id(item._id, "Raindrop item"); const link = url(item.link); if (!itemId || !link) return undefined;
    const apiPayload = JSON.stringify(item); const metadataComplete = Buffer.byteLength(apiPayload, "utf8") <= 100_000;
    return { id: itemId, title: text(item.title, 512) ?? link, url: link, ...(text(item.excerpt) ? { excerpt: text(item.excerpt) } : {}), ...(text(item.note, 20_000) ? { annotation: text(item.note, 20_000) } : {}), ...(text(item.created, 80) ? { savedAt: text(item.created, 80) } : {}), ...(parseCollection(item) ? { collectionId: parseCollection(item) } : {}), ...(metadataComplete ? { apiPayload } : {}), metadataComplete };
  }).filter((item: PendingItem | undefined): item is PendingItem => Boolean(item));
}
type IntakeOutcome = {
  itemId: string;
  title: string;
  disposition: "pending" | "retained" | "archived" | "already-processed";
  reason: string;
  assessment: "not-run" | "preflight-failed" | "dispatched-uncertain" | "dispatched-settled" | "dispatched-settled-sampled" | "reused";
  move: "not-attempted" | "moved" | "conflict" | "unsupported" | "blocked";
  sourceId?: string;
  sourceRevision?: string;
};

function validateRaindropReadRequest(value: unknown): KnowledgeRaindropRequest["read"] {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw bad("Raindrop read request is invalid");
  const read = value as Record<string, unknown>; const operation = read.operation;
  if (!["user", "collections", "collection", "bookmarks", "item", "highlights", "tags"].includes(operation as string)) throw bad("Raindrop read operation is invalid");
  if (operation === "collection" && (typeof read.collectionId !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(read.collectionId))) throw bad("Collection ID is invalid");
  if (operation === "item" && (typeof read.itemId !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(read.itemId))) throw bad("Item ID is invalid");
  if ((operation === "bookmarks" || operation === "highlights") && read.collectionId !== undefined && (typeof read.collectionId !== "string" || !/^-?\d{1,18}$/.test(read.collectionId))) throw bad("Collection ID is invalid");
  if ((operation === "bookmarks" || operation === "highlights") && (read.page !== undefined && (!Number.isSafeInteger(read.page) || (read.page as number) < 0 || (read.page as number) > 1_000_000) || read.perpage !== undefined && (!Number.isSafeInteger(read.perpage) || (read.perpage as number) < 1 || (read.perpage as number) > 50))) throw bad("Raindrop page is invalid");
  if (operation === "bookmarks" && read.nested !== undefined && typeof read.nested !== "boolean") throw bad("Raindrop nested flag is invalid");
  if (operation === "collections" && read.children !== undefined && typeof read.children !== "boolean") throw bad("Raindrop children flag is invalid");
  if ((operation === "bookmarks" || operation === "tags") && read.search !== undefined && (typeof read.search !== "string" || read.search.length > 512)) throw bad("Raindrop search exceeds its limit");
  if ((operation === "bookmarks" || operation === "highlights") && read.sort !== undefined && (typeof read.sort !== "string" || read.sort.length > 64)) throw bad("Raindrop sort exceeds its limit");
  const allowed = operation === "bookmarks" ? ["operation", "collectionId", "page", "perpage", "search", "sort", "nested"] : operation === "highlights" ? ["operation", "collectionId", "page", "perpage"] : operation === "collections" ? ["operation", "children"] : operation === "collection" ? ["operation", "collectionId"] : operation === "item" ? ["operation", "itemId"] : operation === "tags" ? ["operation", "search"] : ["operation"];
  if (Object.keys(read).some(key => !allowed.includes(key))) throw bad("Raindrop read request contains unsupported fields");
  return value as KnowledgeRaindropRequest["read"];
}
function parseX(value: any): PendingItem[] {
  if (!value || !Array.isArray(value.data)) throw new ConnectorShapeError();
  return value.data.map((item: XBookmarkDTO) => {
    const itemId = id(item.id, "X bookmark"); if (!itemId) return undefined;
    const link = `https://x.com/i/web/status/${encodeURIComponent(itemId)}`;
    const payload = JSON.stringify({ id: item.id, text: item.text, created_at: item.created_at, author_id: item.author_id, entities: item.entities });
    return { id: itemId, title: text(item.text, 512) ?? `X post ${itemId}`, url: link, ...(text(item.text, 100_000) ? { excerpt: text(item.text, 100_000) } : {}), ...(text(item.created_at, 80) ? { publishedAt: text(item.created_at, 80) } : {}), ...(payload.length <= 100_000 ? { apiPayload: payload } : {}) };
  }).filter((item: PendingItem | undefined): item is PendingItem => Boolean(item));
}

export class KnowledgeConnectorExtension {
  private readonly http: ConnectorHTTP;
  private readonly sleep: (milliseconds: number) => Promise<void>;
  private readonly now: () => string;
  private readonly lanes = new Map<string, AsyncMutex>();
  private readonly xOAuthAttempts = new Map<string, { instanceId: string; clientId: string; redirectUri: string; state: string; verifier: string; policy: KnowledgeXOAuthStartRequest["policy"]; createdAt: number }>();
  constructor(private readonly store: KnowledgeStore, private readonly options: KnowledgeConnectorOptions) {
    this.http = options.http ?? defaultHTTP; this.sleep = options.sleep ?? (milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds))); this.now = options.now ?? (() => new Date().toISOString());
  }
  private lane(connector: Connector, connectionId?: string): AsyncMutex { const key = connectionId ? `${connector}:${connectionId}` : connector; const existing = this.lanes.get(key); if (existing) return existing; const created = new AsyncMutex(); this.lanes.set(key, created); return created; }

  private assertCredentialNamespace(connector: Connector, credentialRef: string | undefined): void {
    if (credentialRef !== undefined && !isConnectorCredentialReference(credentialRef, connector)) {
      throw new GatewayError("invalid_request", `Credential reference must use the ${connector} connector namespace`);
    }
  }

  private async verifyRaindropAccount(state: KnowledgeConnectorState, token: string | (() => Promise<string>), signal: AbortSignal, beforeAttempt?: () => Promise<void>): Promise<Pick<ProviderAdmissionObservation, "providerDisplayName">> {
    // Raindrop account IDs are numeric by contract. Synthetic connector tests
    // may use non-provider IDs, but real configured accounts always receive the
    // live /user fence before discovery or an effect.
    if (!state.accountId || !/^\d+$/.test(state.accountId)) return {};
    const result = await requestJson(this.http, "https://api.raindrop.io/rest/v1/user", token, { sleep: this.sleep, signal, ...(beforeAttempt ? { beforeAttempt } : {}) });
    const account = raindropUser(result.value);
    if (!account.accountId || account.accountId !== state.accountId) throw new GatewayError("conflict", "Raindrop authenticated account does not match configured account");
    return account.displayName ? { providerDisplayName: account.displayName } : {};
  }

  private async cancellableSleep(signal: AbortSignal, milliseconds: number): Promise<void> {
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => { signal.removeEventListener("abort", abort); resolve(); }, milliseconds);
      const abort = () => { clearTimeout(timer); signal.removeEventListener("abort", abort); reject(signal.reason instanceof Error ? signal.reason : new Error("Connector request cancelled")); };
      if (signal.aborted) abort(); else signal.addEventListener("abort", abort, { once: true });
    });
  }

  private async connectionFor(connectionId: string | undefined, connector: Connector, required: boolean, allowDisconnected = false): Promise<ConnectionInstance | undefined> {
    if (!this.options.connections) return undefined;
    if (!connectionId) { if (required) throw new GatewayError("invalid_request", "Connector operations require a connectionId"); return undefined; }
    const instance = await this.options.connections.resolveInstance(connectionId);
    if (instance.definitionId !== `knowledge.${connector}` || instance.health === "disconnected" && !allowDisconnected) throw new GatewayError("conflict", "Connection instance is unavailable for this connector");
    return instance;
  }

  private async withConnection<T>(connector: Connector, connectionId: string | undefined, task: () => Promise<T>): Promise<T> {
    await this.connectionFor(connectionId, connector, Boolean(this.options.connections));
    return this.store.withConnectorContext(connectionId, task);
  }

  private async recordAdmission(state: KnowledgeConnectorState, credentialAvailability: "available" | "unavailable" | "unknown", providerIdentity: "admitted" | "mismatch" | "unknown", commandId: string, expectedSetupRevision?: number, display?: Pick<ProviderAdmissionObservation, "providerDisplayName">): Promise<void> {
    if (this.options.connections && state.connectionId) {
      const instance = await this.options.connections.resolveInstance(state.connectionId);
      if (expectedSetupRevision !== undefined && instance.setupRevision !== expectedSetupRevision) throw new GatewayError("conflict", "Connection setup changed during provider admission");
      await this.options.connections.recordProviderObservation(state.connectionId, expectedSetupRevision ?? instance.setupRevision, { credentialAvailability, providerIdentity, ...(credentialAvailability === "available" && providerIdentity === "admitted" && display?.providerDisplayName ? display : {}) });
      return;
    }
    await this.store.updateConnectorState(command(commandId, "admission"), state.connector, value => ({ ...(value ?? state), credentialAvailability, providerIdentity }));
  }

  async invoke(action: KnowledgeAction, signal?: AbortSignal): Promise<unknown> {
    const request = action.request as { connectionId?: string; connector?: Connector };
    const connector = request.connector ?? "raindrop";
    if (action.operation === "knowledge.raindrop.read") return this.lane("raindrop", request.connectionId).run(() => this.withConnection("raindrop", request.connectionId, () => this.readRaindrop(action.request, signal)));
    if (action.operation === "knowledge.connector.configure") return this.lane(action.request.connector, request.connectionId).run(() => this.withConnection(action.request.connector, request.connectionId, () => this.configure(action.request)));
    if (action.operation === "knowledge.connector.assessment.approve") return this.lane("raindrop", request.connectionId).run(() => this.withConnection("raindrop", request.connectionId, () => this.approveAssessment(action.request)));
    if (action.operation === "knowledge.x.oauth.begin") return this.lane("x", action.request.instanceId).run(() => this.beginXOAuth(action.request));
    if (action.operation === "knowledge.x.oauth.complete") return this.lane("x", this.xOAuthAttempts.get(action.request.operationId)?.instanceId ?? action.request.operationId).run(() => {
      const controller = new AbortController();
      const deadline = setTimeout(() => controller.abort(new Error("X OAuth setup deadline exceeded")), RUN_DEADLINE_MS);
      deadline.unref?.();
      const ownedSignal = signal ? AbortSignal.any([controller.signal, signal]) : controller.signal;
      return this.completeXOAuth(action.request, ownedSignal).finally(() => clearTimeout(deadline));
    });
    if (action.operation === "knowledge.x.credits") return this.lane("x", action.request.connectionId).run(() => this.readXCredits(action.request.connectionId, signal));
    if (action.operation === "knowledge.connector.status") return this.store.withConnectorContext(request.connectionId, async () => stateStatus(await this.store.connectorState(action.request.connector, request.connectionId), action.request.connector, await this.connectionFor(request.connectionId, action.request.connector, Boolean(this.options.connections), true)));
    if (action.operation === "knowledge.connector.discover") return this.lane(action.request.connector, request.connectionId).run(() => this.withConnection(action.request.connector, request.connectionId, () => this.discoverQueue(action.request, signal)));
    if (action.operation === "knowledge.connector.queue") return this.withConnection(action.request.connector, request.connectionId, () => this.queue(action.request));
    if (action.operation === "knowledge.connector.ack") return this.lane(action.request.connector, request.connectionId).run(() => this.withConnection(action.request.connector, request.connectionId, () => this.ack(action.request)));
    if (action.operation === "knowledge.raindrop.move") return this.lane("raindrop", request.connectionId).run(() => this.withConnection("raindrop", request.connectionId, () => this.moveOne(action.request, signal)));
    if (action.operation === "knowledge.raindrop.intake") return this.lane("raindrop", request.connectionId).run(() => this.withConnection("raindrop", request.connectionId, () => this.intake(action.request, signal)));
    if (action.operation === "knowledge.source.ingest") return this.lane(action.request.connector, request.connectionId).run(() => this.withConnection(action.request.connector, request.connectionId, () => this.ingest(action.request, signal)));
    throw bad("Unsupported knowledge connector operation");
  }

  private credentialWriter(): WritableConnectorCredentialStore {
    const writer = this.options.credentials as ConnectorCredentialStore & Partial<WritableConnectorCredentialStore>;
    if (typeof writer.write !== "function" || typeof writer.delete !== "function") throw new GatewayError("unsupported", "X OAuth requires the Mac Keychain credential writer");
    return writer as WritableConnectorCredentialStore;
  }

  private async beginXOAuth(request: KnowledgeXOAuthStartRequest): Promise<Record<string, unknown>> {
    if (!this.options.connections) throw new GatewayError("unsupported", "X OAuth requires ConnectionOwner");
    if (!request.commandId || request.commandId.length < 8 || request.commandId.length > 160 || !request.instanceId || request.instanceId.length > 160) throw bad("X OAuth setup identity is invalid");
    if (typeof request.clientId !== "string" || request.clientId.length < 1 || request.clientId.length > 256 || /[\u0000-\u001f\u007f]/.test(request.clientId)) throw bad("X OAuth client ID is invalid");
    let redirect: URL;
    try { redirect = new URL(request.redirectUri); } catch { throw bad("X OAuth redirect URI is invalid"); }
    if (redirect.protocol !== "https:" || redirect.username || redirect.password || redirect.hash || redirect.search) throw bad("X OAuth redirect URI must be HTTPS without credentials, query, or fragment");
    try { validateConnectionPolicy(request.policy); } catch { throw bad("X OAuth policy is invalid"); }
    if ([...this.xOAuthAttempts.values()].some(attempt => attempt.instanceId === request.instanceId && Date.now() - attempt.createdAt < 10 * 60_000)) throw new GatewayError("conflict", "X OAuth setup is already pending for this connection");
    this.credentialWriter();
    const operation = await this.options.connections.execute({ kind: "setup.begin", commandId: command(request.commandId, "x-oauth-setup"), instanceId: request.instanceId, definitionId: "knowledge.x", method: "oauth" }) as { operationId: string };
    const verifier = randomBytes(32).toString("base64url");
    const state = randomBytes(32).toString("base64url");
    const challenge = createHash("sha256").update(verifier).digest("base64url");
    const authorization = new URL("https://twitter.com/i/oauth2/authorize");
    authorization.search = new URLSearchParams({ response_type: "code", client_id: request.clientId, redirect_uri: request.redirectUri, scope: "tweet.read users.read bookmark.read offline.access", state, code_challenge: challenge, code_challenge_method: "S256" }).toString();
    this.xOAuthAttempts.set(operation.operationId, { instanceId: request.instanceId, clientId: request.clientId, redirectUri: redirect.toString(), state, verifier, policy: structuredClone(request.policy), createdAt: Date.now() });
    return { operationId: operation.operationId, instanceId: request.instanceId, authorizationUrl: authorization.toString(), state };
  }

  private async completeXOAuth(request: KnowledgeXOAuthCompleteRequest, externalSignal?: AbortSignal): Promise<Record<string, unknown>> {
    if (!this.options.connections) throw new GatewayError("unsupported", "X OAuth requires ConnectionOwner");
    if (!request.commandId || request.commandId.length < 8 || request.commandId.length > 160) throw bad("X OAuth completion commandId is invalid");
    const attempt = this.xOAuthAttempts.get(request.operationId);
    if (!attempt || Date.now() - attempt.createdAt > 10 * 60_000) throw new GatewayError("conflict", "X OAuth setup expired; start authorization again");
    let code: string | undefined;
    if (request.callbackUrl !== undefined) {
      if (request.code !== undefined || request.state !== undefined) throw bad("Provide either the full X OAuth redirect URL or its code and state");
      let callback: URL;
      try { callback = new URL(request.callbackUrl); } catch { throw bad("Paste the complete X OAuth redirect URL"); }
      const expected = new URL(attempt.redirectUri);
      const codes = callback.searchParams.getAll("code");
      const states = callback.searchParams.getAll("state");
      if (callback.origin !== expected.origin || callback.pathname !== expected.pathname || callback.username || callback.password || callback.hash || states.length !== 1 || states[0] !== attempt.state || callback.searchParams.has("error") || codes.length !== 1) throw new GatewayError("conflict", "X OAuth redirect does not match this authorization state or callback");
      code = codes[0];
    } else if (request.code !== undefined && request.state === attempt.state) code = request.code;
    else throw new GatewayError("conflict", "X OAuth code or redirect does not match this authorization state");
    if (!code || code.length > 4_096 || /[\u0000-\u001f\u007f]/.test(code)) throw bad("X OAuth authorization code is invalid");
    const signal = externalSignal ?? new AbortController().signal;
    const writer = this.credentialWriter();
    const tokenResponse = await this.xOAuthToken({ client_id: attempt.clientId, grant_type: "authorization_code", code, redirect_uri: attempt.redirectUri, code_verifier: attempt.verifier }, signal);
    const tokens = this.validXTokenResponse(tokenResponse);
    const credentialRef = `connector:x:${attempt.instanceId}`;
    await writer.write(credentialRef, JSON.stringify({ accessToken: tokens.accessToken, refreshToken: tokens.refreshToken, clientId: attempt.clientId, expiresAt: new Date(Date.now() + tokens.expiresIn * 1_000).toISOString() }));
    let userId: string;
    try {
      const profile = await this.http("https://api.x.com/2/users/me?user.fields=id,username", { headers: { authorization: `Bearer ${tokens.accessToken}`, accept: "application/json" }, signal });
      const body = this.parseXResponse(profile);
      if (typeof body?.data?.id !== "string" || !/^\d{1,32}$/.test(body.data.id) || typeof body.data.username !== "string") throw new ConnectorShapeError();
      userId = body.data.id;
    } catch {
      await writer.delete(credentialRef);
      throw new GatewayError("unsupported", "X OAuth account verification failed; the temporary credential was removed");
    }
    let result: unknown;
    try { result = await this.options.connections.execute({ kind: "setup.complete", commandId: command(request.commandId, "x-oauth-complete"), operationId: request.operationId, instanceId: attempt.instanceId, providerAccountId: userId, scope: userId, credentialRef, policy: attempt.policy }); }
    catch (error) { await writer.delete(credentialRef); throw error; }
    this.xOAuthAttempts.delete(request.operationId);
    const setupRevision = Number((result as Record<string, unknown>).setupRevision);
    await this.options.connections.recordProviderObservation(attempt.instanceId, setupRevision, { credentialAvailability: "available", providerIdentity: "admitted" });
    await this.store.updateConnectorState(command(request.commandId, "x-oauth-state"), "x", current => {
      const sameAccount = current?.accountId === userId;
      return { ...(sameAccount ? current! : initial("x")), connectionId: attempt.instanceId, setupRevision, accountId: userId, scope: userId, credentialRef, enabled: attempt.policy.enabled, allowWrites: attempt.policy.allowWrites, paidAccessApproved: attempt.policy.paidAccessApproved, paidBudgetCents: sameAccount ? current!.paidBudgetCents : attempt.policy.paidBudgetCents, recurringApproved: attempt.policy.recurringApproved, health: "ready" };
    }, undefined, attempt.instanceId);
    return result as Record<string, unknown>;
  }

  private parseXResponse(response: ConnectorHTTPResponse): any {
    if (response.status < 200 || response.status >= 300 || Buffer.byteLength(response.body, "utf8") > 64_000) throw new GatewayError("unsupported", "X OAuth request failed");
    try { return JSON.parse(response.body); } catch { throw new ConnectorShapeError(); }
  }

  private async xOAuthToken(parameters: Record<string, string>, signal: AbortSignal): Promise<unknown> {
    let response: ConnectorHTTPResponse;
    try { response = await this.http("https://api.x.com/2/oauth2/token", { method: "POST", headers: { accept: "application/json", "content-type": "application/x-www-form-urlencoded" }, body: new URLSearchParams(parameters).toString(), signal }); }
    catch { throw new GatewayError("unsupported", "X OAuth token exchange failed"); }
    return this.parseXResponse(response);
  }

  private validXTokenResponse(value: unknown): { accessToken: string; refreshToken: string; expiresIn: number } {
    const token = value as Record<string, unknown> | null;
    if (!token || typeof token !== "object" || typeof token.access_token !== "string" || token.access_token.length < 1 || token.access_token.length > 4_096 || typeof token.refresh_token !== "string" || token.refresh_token.length < 1 || token.refresh_token.length > 4_096 || !Number.isSafeInteger(token.expires_in) || (token.expires_in as number) < 60 || (token.expires_in as number) > 31_536_000 || token.token_type !== "bearer") throw new ConnectorShapeError();
    return { accessToken: token.access_token, refreshToken: token.refresh_token, expiresIn: token.expires_in as number };
  }

  private async storedXOAuth(reference: string): Promise<{ accessToken: string; refreshToken: string; clientId: string; expiresAt: string }> {
    const value = await this.options.credentials.read(reference);
    if (!value) throw missingCredential("x", reference);
    let parsed: unknown;
    try { parsed = JSON.parse(value); } catch { throw new GatewayError("unsupported", "X OAuth credential is malformed; reconnect the account"); }
    const token = parsed as Record<string, unknown> | null;
    if (!token || typeof token.accessToken !== "string" || typeof token.refreshToken !== "string" || typeof token.clientId !== "string" || typeof token.expiresAt !== "string" || !Number.isFinite(Date.parse(token.expiresAt))) throw new GatewayError("unsupported", "X OAuth credential is malformed; reconnect the account");
    return token as { accessToken: string; refreshToken: string; clientId: string; expiresAt: string };
  }

  private async markXAuthorizationError(connectionId: string, setupRevision: number): Promise<void> {
    try { await this.options.connections?.recordProviderObservation(connectionId, setupRevision, { credentialAvailability: "unavailable", providerIdentity: "unknown" }); } catch { return; }
    const live = await this.connectionFor(connectionId, "x", true);
    if (!live || live.setupRevision !== setupRevision) return;
    await this.store.updateConnectorState(command(connectionId, "x-auth-error"), "x", state => state?.connectionId === connectionId && state.setupRevision === setupRevision ? { ...state, health: "auth-error", lastError: "X authorization expired; reconnect the account" } : state ?? initial("x"), undefined, connectionId);
  }

  private async refreshXToken(connectionId: string, credentialRef: string, setupRevision: number, signal: AbortSignal): Promise<void> {
    try {
      const live = await this.connectionFor(connectionId, "x", true);
      if (!live || live.setupRevision !== setupRevision || live.credentialRef !== credentialRef || !live.policy.enabled) throw new GatewayError("conflict", "X connection changed before token refresh");
      const current = await this.storedXOAuth(credentialRef);
      const response = await this.xOAuthToken({ client_id: current.clientId, grant_type: "refresh_token", refresh_token: current.refreshToken }, signal);
      const rotated = this.validXTokenResponse(response);
      // Rotation is single-use. Persist its only valid refresh token even if
      // setup changes while X responds, but never issue the stale access token.
      await this.credentialWriter().write(credentialRef, JSON.stringify({ accessToken: rotated.accessToken, refreshToken: rotated.refreshToken, clientId: current.clientId, expiresAt: new Date(Date.now() + rotated.expiresIn * 1_000).toISOString() }));
      const afterRotation = await this.connectionFor(connectionId, "x", true);
      if (!afterRotation || afterRotation.setupRevision !== setupRevision || afterRotation.credentialRef !== credentialRef || !afterRotation.policy.enabled) throw new GatewayError("conflict", "X connection changed during token refresh");
    } catch (error) {
      await this.markXAuthorizationError(connectionId, setupRevision);
      if (error instanceof GatewayError && error.code === "conflict") throw error;
      throw new GatewayError("unsupported", "X authorization refresh failed; reconnect the account");
    }
  }

  private async xAccessToken(connectionId: string, credentialRef: string, setupRevision: number, signal: AbortSignal): Promise<string> {
    const current = await this.storedXOAuth(credentialRef);
    if (Date.parse(current.expiresAt) <= Date.now() + 60_000) await this.refreshXToken(connectionId, credentialRef, setupRevision, signal);
    return (await this.storedXOAuth(credentialRef)).accessToken;
  }

  private async readXCredits(connectionId: string, externalSignal?: AbortSignal): Promise<{ freeBalance: number; prepaidBalance: number; totalBalance: number }> {
    const authority = await this.connectionFor(connectionId, "x", true);
    if (!authority?.policy.enabled || !authority.credentialRef || !authority.scope) throw new GatewayError("unsupported", "X credits require an enabled OAuth X connection");
    const state = await this.store.connectorState("x", connectionId);
    if (!state?.enabled || state.credentialRef !== authority.credentialRef || state.accountId !== authority.providerAccountId) throw new GatewayError("conflict", "X connector configuration is not admitted by this connection");
    const controller = new AbortController(); const signal = externalSignal ? AbortSignal.any([controller.signal, externalSignal]) : controller.signal;
    const deadline = setTimeout(() => controller.abort(new Error("X credits read deadline exceeded")), RUN_DEADLINE_MS); deadline.unref?.();
    try {
      const result = await requestJson(this.http, "https://api.x.com/2/usage/credits", () => this.xAccessToken(connectionId, authority.credentialRef!, authority.setupRevision, signal), { sleep: this.sleep, signal, onUnauthorized: () => this.refreshXToken(connectionId, authority.credentialRef!, authority.setupRevision, signal) });
      const data = result.value?.data;
      const free = data?.free_balance; const prepaid = data?.prepaid_balance; const total = data?.total_balance;
      if (![free, prepaid, total].every(value => typeof value === "number" && Number.isFinite(value)) || free < 0 || total < 0) throw new ConnectorShapeError();
      return { freeBalance: free, prepaidBalance: prepaid, totalBalance: total };
    } catch (error) {
      if (error instanceof GatewayError) throw error;
      throw new GatewayError("unsupported", "X credit balance is unavailable");
    } finally { clearTimeout(deadline); }
  }

  private async readRaindrop(request: KnowledgeRaindropRequest, externalSignal?: AbortSignal): Promise<Record<string, unknown>> {
    const read = validateRaindropReadRequest((request as unknown as { read?: unknown })?.read);
    const authority = await this.connectionFor(request.connectionId, "raindrop", Boolean(this.options.connections));
    const state = await this.store.connectorState("raindrop");
    if (!state?.enabled || !state.accountId || !state.credentialRef) throw new GatewayError("unsupported", "Raindrop connector is not configured; set the numeric Raindrop user _id in accountId");
    this.assertCredentialNamespace("raindrop", state.credentialRef);
    if (!/^\d+$/.test(state.accountId)) throw new GatewayError("invalid_request", "Raindrop accountId must be the numeric user _id; obtain it through a secure local /user check, never by sharing the token");
    const observe = async (observation: ProviderAdmissionObservation): Promise<void> => {
      if (authority && this.options.connections) await this.options.connections.recordProviderObservation(authority.id, authority.setupRevision, observation);
    };
    const token = await this.options.credentials.read(state.credentialRef);
    if (!token) {
      await observe({ credentialAvailability: "unavailable", providerIdentity: "unknown" });
      throw missingCredential("raindrop", state.credentialRef);
    }
    const controller = new AbortController();
    const signal = externalSignal ? AbortSignal.any([controller.signal, externalSignal]) : controller.signal;
    const deadline = setTimeout(() => controller.abort(new Error("Raindrop read deadline exceeded")), RUN_DEADLINE_MS);
    deadline.unref?.();
    const sleep = (milliseconds: number) => this.cancellableSleep(signal, milliseconds);
    const requestEndpoint = async (endpoint: string): Promise<{ value: any; headers: Headers }> => requestJson(this.http, endpoint, token, { sleep, signal });
    const safeID = (value: string, label: string): string => {
      if (!/^[A-Za-z0-9_-]{1,128}$/.test(value)) throw bad(`${label} is invalid`);
      return encodeURIComponent(value);
    };
    const rate = (headers: Headers): Record<string, unknown> => {
      const limit = headers.get("x-ratelimit-limit") ?? headers.get("ratelimit-limit");
      const remaining = headers.get("x-ratelimit-remaining") ?? headers.get("ratelimit-remaining");
      const reset = headers.get("x-ratelimit-reset") ?? headers.get("ratelimit-reset");
      return { ...(limit ? { limit } : {}), ...(remaining ? { remaining } : {}), ...(reset ? { reset } : {}) };
    };
    try {
      // The configured account ID is an authority fence, not a display label.
      // Verify it on every read so a stale token cannot expose another account.
      const identity = await requestEndpoint("https://api.raindrop.io/rest/v1/user");
      const account = raindropUser(identity.value);
      if (!account.accountId || account.accountId !== state.accountId) throw new GatewayError("conflict", "Raindrop authenticated account does not match configured account");
      await observe({ credentialAvailability: "available", providerIdentity: "admitted", ...(account.displayName ? { providerDisplayName: account.displayName } : {}) });
      let endpoint: string;
      let value: unknown;
      let headers = identity.headers;
      if (read.operation === "user") {
        const raw = JSON.stringify(identity.value);
        if (Buffer.byteLength(raw, "utf8") > BODY_LIMIT) throw new GatewayError("invalid_request", "Raindrop metadata exceeded 2 MB; reduce the requested metadata");
        return { operation: read.operation, data: identity.value, rateLimit: rate(identity.headers) };
      }
      const live = await this.store.connectorState("raindrop");
      if (!live?.enabled || live.accountId !== state.accountId || live.credentialRef !== state.credentialRef) throw new GatewayError("conflict", "Raindrop configuration changed during read");
      if (read.operation === "collections") {
        const root = await requestEndpoint("https://api.raindrop.io/rest/v1/collections");
        headers = root.headers; value = root.value;
        if (read.children) {
          const children = await requestEndpoint("https://api.raindrop.io/rest/v1/collections/childrens");
          headers = children.headers; value = { root: root.value, children: children.value };
        }
      } else {
        if (read.operation === "collection") endpoint = `https://api.raindrop.io/rest/v1/collection/${safeID(read.collectionId, "Collection ID")}`;
        else if (read.operation === "item") endpoint = `https://api.raindrop.io/rest/v1/raindrop/${safeID(read.itemId, "Item ID")}`;
        else if (read.operation === "bookmarks") {
          const collection = read.collectionId ?? state.scope ?? "0";
          if (!/^-?\d{1,18}$/.test(collection)) throw bad("Collection ID is invalid");
          const params = new URLSearchParams({ page: String(read.page ?? 0), perpage: String(read.perpage ?? 50) });
          if (read.search) params.set("search", read.search);
          if (read.sort) params.set("sort", read.sort);
          if (read.nested !== undefined) params.set("nested", String(read.nested));
          endpoint = `https://api.raindrop.io/rest/v1/raindrops/${encodeURIComponent(collection)}?${params}`;
        } else if (read.operation === "tags") {
          endpoint = "https://api.raindrop.io/rest/v1/tags";
        } else if (read.operation === "highlights") {
          const params = new URLSearchParams({ page: String(read.page ?? 0), perpage: String(read.perpage ?? 50) });
          if (read.collectionId) {
            endpoint = `https://api.raindrop.io/rest/v1/highlights/${encodeURIComponent(read.collectionId)}?${params}`;
          } else endpoint = `https://api.raindrop.io/rest/v1/highlights?${params}`;
        } else throw bad("Unsupported Raindrop read operation");
        const result = await requestEndpoint(endpoint); headers = result.headers; value = result.value;
      }
      const objectWithItems = (candidate: unknown): candidate is { items: unknown[] } => Boolean(candidate && typeof candidate === "object" && !Array.isArray(candidate) && Array.isArray((candidate as Record<string, unknown>).items));
      if (read.operation === "collections" && (read.children ? (!objectWithItems((value as any)?.root) || !objectWithItems((value as any)?.children)) : !objectWithItems(value))) throw new ConnectorShapeError();
      if (["bookmarks", "highlights", "tags"].includes(read.operation) && !objectWithItems(value)) throw new ConnectorShapeError();
      if (read.operation === "collection" && id((value as any)?.item?._id, "collection") !== read.collectionId) throw new ConnectorShapeError();
      if (read.operation === "item" && id((value as any)?.item?._id, "item") !== read.itemId) throw new ConnectorShapeError();
      const raw = JSON.stringify(value);
      if (Buffer.byteLength(raw, "utf8") > BODY_LIMIT) throw new GatewayError("invalid_request", "Raindrop metadata exceeded 2 MB; reduce perpage or request narrower pages");
      const result: Record<string, unknown> = { operation: read.operation, data: value, rateLimit: rate(headers) };
      if (read.operation === "bookmarks" || read.operation === "highlights") {
        const page = read.page ?? 0; const perpage = read.perpage ?? 50;
        if (Array.isArray((value as any)?.items) && (value as any).items.length >= perpage) result.nextPage = page + 1;
        result.snapshot = "not-atomic; provider pagination can shift between requests";
      }
      return result;
    } catch (error) {
      if (error instanceof ConnectorHTTPError && authFailure(error.status)) await observe({ credentialAvailability: "unavailable", providerIdentity: "unknown" });
      if (error instanceof GatewayError && error.message.includes("authenticated account does not match")) await observe({ credentialAvailability: "available", providerIdentity: "mismatch" });
      if (error instanceof GatewayError) throw error;
      if (error instanceof FixedHostBodyTooLarge) throw new GatewayError("invalid_request", "Raindrop metadata exceeded 2 MB; reduce perpage or request narrower pages");
      if (error instanceof ConnectorAPIError || error instanceof ConnectorShapeError) throw new GatewayError("internal", "Raindrop returned an unusable response", true);
      if (error instanceof ConnectorHTTPError && authFailure(error.status)) throw new GatewayError("unsupported", "Raindrop authentication failed");
      if (error instanceof ConnectorHTTPError && error.status === 429) throw new GatewayError("internal", "Raindrop rate limit reached; retry after the provider reset", true);
      if (signal.aborted) throw new GatewayError("busy", "Raindrop read was cancelled", true);
      throw new GatewayError("internal", "Raindrop provider request failed", true);
    } finally { clearTimeout(deadline); }
  }

  private async configure(request: KnowledgeConnectorConfigurationRequest): Promise<KnowledgeConnectorStatus> {
    const authority = await this.connectionFor(request.connectionId, request.connector, Boolean(this.options.connections));
    if (this.options.connections && (request.accountId !== undefined || request.scope !== undefined || request.credentialRef !== undefined)) throw bad("Account, scope, and credentials are owned by ConnectionOwner; complete setup before connector configuration");
    if (Object.keys(request as unknown as Record<string, unknown>).some(key => !["commandId", "connector", "connectionId", "enabled", "accountId", "scope", "credentialRef", "allowWrites", "paidAccessApproved", "paidBudgetCents", "recurringApproved"].includes(key))) throw bad("Connector configuration contains unsupported fields");
    if (request.accountId !== undefined && (request.accountId.length < 1 || request.accountId.length > 256 || /[\r\n]/.test(request.accountId))) throw bad("Connector account is invalid");
    if (request.scope !== undefined && (request.scope.length < 1 || request.scope.length > 256 || /[\r\n]/.test(request.scope))) throw bad("Connector scope is invalid");
    this.assertCredentialNamespace(request.connector, request.credentialRef);
    if (request.paidBudgetCents !== undefined && (!Number.isSafeInteger(request.paidBudgetCents) || request.paidBudgetCents < 0 || request.paidBudgetCents > 1_000_000)) throw bad("Connector paid budget is invalid");
    const current = await this.store.connectorState(request.connector);
    if (request.credentialRef === undefined) this.assertCredentialNamespace(request.connector, current?.credentialRef);
    const base = current ?? (authority ? { ...initial(request.connector), enabled: authority.policy.enabled, accountId: authority.providerAccountId, ...(authority.scope ? { scope: authority.scope } : {}), credentialRef: authority.credentialRef, allowWrites: authority.policy.allowWrites, paidAccessApproved: authority.policy.paidAccessApproved, paidBudgetCents: authority.policy.paidBudgetCents, recurringApproved: authority.policy.recurringApproved } : initial(request.connector));
    const ownerIdentityChanged = Boolean(authority && current && (authority.providerAccountId !== current.accountId || authority.scope !== current.scope || authority.credentialRef !== current.credentialRef));
    const identityChanged = Boolean(current && (ownerIdentityChanged || (request.accountId !== undefined && request.accountId !== current.accountId) || (request.scope !== undefined && request.scope !== current.scope) || (request.credentialRef !== undefined && request.credentialRef !== current.credentialRef)));
    if (identityChanged && (current?.pendingRemote || current?.assessmentPilot || (current?.assessmentApprovals?.length ?? 0) > 0 || Object.keys(current?.assessmentAttempts ?? {}).length > 0)) throw new GatewayError("conflict", "Connector identity cannot change while an approved pilot or remote effect is active");
    const nextAccountId = request.accountId ?? authority?.providerAccountId ?? current?.accountId;
    const nextScope = request.scope ?? authority?.scope ?? current?.scope;
    const nextCredentialRef = request.credentialRef ?? authority?.credentialRef ?? current?.credentialRef;
    const next: KnowledgeConnectorState = identityChanged ? {
      ...initial(request.connector), enabled: request.enabled,
      ...(nextAccountId ? { accountId: nextAccountId } : {}),
      ...(nextScope ? { scope: nextScope } : {}),
      ...(nextCredentialRef ? { credentialRef: nextCredentialRef } : {}),
      ...policyDefaults(request),
      health: request.enabled && Boolean(nextCredentialRef && nextAccountId && (request.connector === "raindrop" && authority ? authority.raindropCollections?.length : nextScope)) ? "ready" : "unconfigured",
    } : { ...base, enabled: request.enabled, ...(request.accountId !== undefined ? { accountId: request.accountId } : {}), ...(request.scope !== undefined ? { scope: request.scope } : {}), ...(request.credentialRef !== undefined ? { credentialRef: request.credentialRef } : {}), ...policyDefaults(request, current ?? base), health: request.enabled && (request.credentialRef ?? current?.credentialRef) && (request.accountId ?? current?.accountId) && (request.connector === "raindrop" && authority ? authority.raindropCollections?.length : request.scope ?? current?.scope) ? "ready" : "unconfigured" };
    delete next.lastError;
    let currentAuthority = authority;
    if (this.options.connections) {
      const policy = authority!.policy;
      await this.options.connections.execute({ kind: "policy.update", commandId: command(request.commandId, "connection-policy"), instanceId: authority!.id, expectedSetupRevision: authority!.setupRevision, policy: { enabled: request.enabled, allowWrites: request.allowWrites ?? policy.allowWrites, paidAccessApproved: request.paidAccessApproved ?? policy.paidAccessApproved, paidBudgetCents: request.paidBudgetCents ?? policy.paidBudgetCents, recurringApproved: request.recurringApproved ?? policy.recurringApproved } });
      currentAuthority = await this.options.connections.resolveInstance(authority!.id);
      delete next.credentialAvailability;
      delete next.providerIdentity;
    }
    const saved = await this.store.updateConnectorState(request.commandId, request.connector, () => next);
    return stateStatus(saved, request.connector, currentAuthority);
  }

  private async approveAssessment(request: KnowledgeAssessmentApprovalRequest): Promise<KnowledgeConnectorStatus> {
    if (!request.id || request.id.length > 160 || !/^[A-Za-z0-9._:-]+$/.test(request.id)) throw bad("Assessment approval ID is invalid");
    if (!Number.isSafeInteger(request.maxItems) || request.maxItems < 1 || request.maxItems > 10 || !Number.isSafeInteger(request.budgetCents) || request.budgetCents < 1 || request.budgetCents > 100) throw bad("Assessment approval remains bounded to 10 items and 100 cents");
    if (request.itemIds !== undefined && (!Array.isArray(request.itemIds) || request.itemIds.length === 0 || request.itemIds.length > request.maxItems || new Set(request.itemIds).size !== request.itemIds.length || request.itemIds.some(item => typeof item !== "string" || !/^\d{1,18}$/.test(item)))) throw bad("Explicit assessment identities must be unique bounded Raindrop item IDs");
    const profileVersion = jevProfileVersion((await this.store.config()).currentInterests ?? []);
    const state = await this.store.connectorState("raindrop");
    if (!state?.enabled || !state.accountId || (!state.scope && !this.options.connections)) throw new GatewayError("unsupported", "Raindrop connector is not configured");
    const connection = await this.connectionFor(request.connectionId, "raindrop", Boolean(this.options.connections));
    const mappings = connection?.raindropCollections;
    const sourceCollection = request.sourceCollection ?? (mappings?.length === 1 ? mappings[0]!.collectionId : undefined) ?? (mappings ? undefined : state.scope);
    if (!sourceCollection || (mappings && !mappings.some(item => item.collectionId === sourceCollection))) throw new GatewayError("unsupported", "Assessment approval requires a mapped Raindrop collection");
    const saved = await this.store.updateConnectorState(request.commandId, "raindrop", current => {
      const next = current ?? state;
      if (next.assessmentPilot?.id === request.id || Object.values(next.assessmentPilots ?? {}).some(item => item.id === request.id) || next.assessmentApprovals?.some(item => item.id === request.id)) throw new GatewayError("conflict", "Assessment approval ID already exists; use a new explicit cohort ID");
      if (next.pendingRemote) throw new GatewayError("conflict", "Reconcile the unresolved remote effect before approving another cohort");
      if (request.itemIds?.some(id => !next.pending.some(item => item.id === id && item.collectionId === sourceCollection))) throw new GatewayError("conflict", "Explicit assessment identities must remain pending in the selected collection");
      const approval = { id: request.id, maxItems: request.maxItems, budgetCents: request.budgetCents, usedItems: 0, reservedCents: 0, accountId: next.accountId!, sourceCollection, profileVersion, itemIds: [...(request.itemIds ?? [])] };
      return { ...next, assessmentApprovals: [...(next.assessmentApprovals ?? []), approval] };
    }, { connector: "raindrop", approval: { id: request.id, maxItems: request.maxItems, budgetCents: request.budgetCents, sourceCollection, ...(request.itemIds ? { itemIds: request.itemIds } : {}) } });
    return stateStatus(saved, "raindrop");
  }

  private async reserveAssessment(commandId: string, itemId: string, pilot: NonNullable<KnowledgeRaindropIntakeRequest["pilot"]>, sourceCollection: string, jevConnectionId: string, cohortId = pilot.id): Promise<string> {
    const profileVersion = jevProfileVersion((await this.store.config()).currentInterests ?? []);
    // Reservation is a fresh paid-attempt fence on every invocation. Reusing
    // the intake command here would replay an old successful mutation receipt.
    if (!this.options.jevBudget) throw new GatewayError("unsupported", "Shared Knowledge Jev budget is unavailable");
    const monthlyAttempt = await this.options.jevBudget.reserveAssessment(jevConnectionId, commandId);
    try {
    await this.store.updateConnectorState(command(`${commandId}:${randomUUID()}`, "reserve"), "raindrop", current => {
      const state = current ?? initial("raindrop");
      const pilots = state.assessmentPilots ?? {};
      const mappedPilot = pilots[sourceCollection]?.id === cohortId ? pilots[sourceCollection] : undefined;
      const legacyPilot = state.assessmentPilot?.id === cohortId && state.assessmentPilot.sourceCollection === sourceCollection ? state.assessmentPilot : undefined;
      const legacy = !mappedPilot && Boolean(legacyPilot);
      const attempts = state.assessmentAttempts ?? {};
      const attemptKey = legacy ? itemId : `${cohortId}:${itemId}`;
      if (attempts[attemptKey] || Object.entries(attempts).some(([key, attempt]) => (attempt?.itemId === itemId && attempt?.cohortId === cohortId) || (legacy && key === itemId))) throw new GatewayError("conflict", "This source already has a paid Jev attempt in this cohort; reconcile it instead of replaying it");
      const existing = mappedPilot ?? legacyPilot ?? state.assessmentApprovals?.find(item => item.id === cohortId && item.sourceCollection === sourceCollection);
      if (!existing || existing.accountId !== state.accountId || existing.sourceCollection !== sourceCollection || existing.profileVersion !== profileVersion || existing.id !== pilot.id) throw new GatewayError("conflict", "Assessment cohort authority changed; use the existing approval");
      const attemptedItems = Object.values(attempts).filter(attempt => attempt?.cohortId === cohortId || (legacy && !attempt?.cohortId)).length;
      if (attemptedItems >= existing.maxItems || existing.reservedCents + 1 > existing.budgetCents) throw new GatewayError("conflict", "Assessment cohort allowance is exhausted");
      const nextAuthority = { ...existing, reservedCents: existing.reservedCents + 1 };
      return {
        ...state,
        ...(mappedPilot ? { assessmentPilots: { ...pilots, [sourceCollection]: nextAuthority } } : legacy ? { assessmentPilot: nextAuthority } : { assessmentApprovals: (state.assessmentApprovals ?? []).map(item => item.id === cohortId ? nextAuthority : item) }),
        assessmentAttempts: { ...attempts, [attemptKey]: { itemId, cohortId, status: "dispatched" as const, chargeCents: 1 } },
      };
    });
    return monthlyAttempt;
    } catch (error) {
      await this.options.jevBudget.releaseUndispatched(jevConnectionId, monthlyAttempt);
      throw error;
    }
  }

  private async settleAssessment(commandId: string, itemId: string, cohortId: string, jevConnectionId: string, monthlyAttempt: string, usage?: { inputTokens: number; outputTokens: number; estimatedCostCents: number }): Promise<void> {
    await this.store.updateConnectorState(`${commandId}:settle`, "raindrop", current => {
      const state = current ?? initial("raindrop");
      const mappedEntry = Object.entries(state.assessmentPilots ?? {}).find(([, item]) => item.id === cohortId);
      const mappedPilot = mappedEntry?.[1];
      const legacyPilot = state.assessmentPilot?.id === cohortId ? state.assessmentPilot : undefined;
      const legacy = !mappedPilot && Boolean(legacyPilot);
      const key = legacy ? itemId : `${cohortId}:${itemId}`;
      const attempt = state.assessmentAttempts?.[key];
      if (!attempt || attempt.status === "settled") return state;
      const authority = mappedPilot ?? legacyPilot ?? state.assessmentApprovals?.find(item => item.id === cohortId);
      if (!authority) return state;
      const settled = { ...attempt, status: "settled" as const, ...(usage ? { inputTokens: usage.inputTokens, outputTokens: usage.outputTokens, estimatedCostCents: usage.estimatedCostCents } : {}) };
      return {
        ...state,
        ...(mappedPilot && mappedEntry ? { assessmentPilots: { ...(state.assessmentPilots ?? {}), [mappedEntry[0]]: { ...authority, usedItems: authority.usedItems + 1 } } } : legacy ? { assessmentPilot: { ...authority, usedItems: authority.usedItems + 1 } } : { assessmentApprovals: (state.assessmentApprovals ?? []).map(item => item.id === cohortId ? { ...item, usedItems: item.usedItems + 1 } : item) }),
        assessmentAttempts: { ...(state.assessmentAttempts ?? {}), [key]: settled },
      };
    });
    if (usage) await this.options.jevBudget!.settle(jevConnectionId, monthlyAttempt, usage);
    else await this.options.jevBudget!.reconcileUncertain(jevConnectionId, monthlyAttempt);
  }

  private async ingestItem(request: KnowledgeSourceIngestRequest, item: PendingItem, state: KnowledgeConnectorState, signal?: AbortSignal): Promise<KnowledgeRecord & { kind: "source" }> {
    if (!request.scope) throw bad("Ingestion scope must be resolved before source capture");
    if (!state.accountId) throw new GatewayError("unsupported", "Connector account is not configured");
    const identity = { provider: request.connector, accountId: state.accountId, itemId: item.id };
    const existing = await this.store.sourceByIdentity(identity);
    const activeSignal = signal ?? new AbortController().signal;
    const captured = await captureSource(this.store, {
      commandId: request.commandId, url: item.url, scope: existing?.scope ?? request.scope, title: item.title,
      origin: "connector", identity, ...(request.connector === "raindrop" && item.collectionId ? { collectionId: item.collectionId } : {}),
      ...(request.connector === "raindrop" && item.annotation ? { annotations: [{ text: item.annotation }] } : {}),
      ...(request.connector === "x" || isPublicXPost(item.url) ? { publicPostLookup: true } : {}),
    }, { writer: "connector", signal: activeSignal, ...(this.options.sourceFetch ? { fetcher: (sourceUrl, init) => this.options.sourceFetch!(sourceUrl.toString(), item.excerpt, init?.signal ?? activeSignal) } : {}), ...(this.options.resolveHost ? { resolveHost: this.options.resolveHost } : {}) });
    let source = captured.record;
    if (source.scope !== request.scope && !sourceAdmissionIsDecided(source)) {
      try {
        const placed = await this.store.curateSource({ commandId: `${request.commandId}:scope`, operation: "placement", producer: { actor: "connector" }, item: { recordId: source.id, expectedRevision: source.revisionId, placement: { scope: request.scope } } });
        source = placed.record as KnowledgeRecord & { kind: "source" };
      } catch (error) {
        if (!(error instanceof KnowledgeCurationRefusal) || error.code !== "decision-authority") throw error;
      }
    }
    const attached = await this.attachProviderPayload(item, source, `${request.commandId}:provider-payload`);
    source = attached.record;
    source = await this.recoverSaveTime(source, `${request.commandId}:save-time`, attached.evidence);
    source = await this.markUnsafeLinkedCapture(item, source, `${request.commandId}:capture-safety`);
    return source;
  }

  private async ingest(request: KnowledgeSourceIngestRequest, externalSignal?: AbortSignal): Promise<KnowledgeRecord & { kind: "source" }> {
    if (!request.commandId || !request.connectionId || !request.itemId || (request.scope !== undefined && request.scope !== "personal" && request.scope !== "research")) throw bad("Ingest requires commandId, connectionId, itemId, and a valid Knowledge scope");
    const state = await this.store.connectorState(request.connector);
    if (!state?.enabled || !state.accountId) throw new GatewayError("unsupported", `${request.connector} connector is not configured`);
    const authority = await this.connectionFor(request.connectionId, request.connector, Boolean(this.options.connections));
    const item = state.pending.find(candidate => candidate.id === request.itemId);
    if (!item) {
      const existing = await this.store.sourceByIdentity({ provider: request.connector, accountId: state.accountId, itemId: request.itemId });
      if (existing) return existing;
      throw new GatewayError("not_found", "Connector item is not in the pending queue");
    }
    let ingestScope = request.scope;
    if (request.connector === "raindrop") {
      const mapping = authority?.raindropCollections?.find(candidate => candidate.collectionId === item.collectionId);
      if (authority?.raindropCollections?.length && !mapping) throw new GatewayError("unsupported", "Queued Raindrop collection is not mapped in the current connection");
      if (mapping?.role === "archive") throw new GatewayError("unsupported", "Archive-role collections are never ingested");
      if (mapping?.role === "triage" && !ingestScope) throw bad("Triage ingestion requires an explicit Knowledge scope");
      if ((mapping?.role === "research" || mapping?.role === "personal") && ingestScope && ingestScope !== mapping.role) throw bad("Home collection ingestion scope must match its role");
      ingestScope ??= mapping?.role === "research" || mapping?.role === "personal" ? mapping.role : undefined;
    }
    if (!ingestScope) throw bad("Ingest requires an explicit Knowledge scope for this collection");
    if (authority && (authority.providerAccountId !== state.accountId || !authority.policy.enabled)) throw new GatewayError("conflict", "Connector account is not admitted by the current connection");
    const controller = new AbortController();
    const signal = externalSignal ? AbortSignal.any([controller.signal, externalSignal]) : controller.signal;
    const deadline = setTimeout(() => controller.abort(new Error("Source ingestion deadline exceeded")), RUN_DEADLINE_MS);
    deadline.unref?.();
    try { return await this.ingestItem({ ...request, scope: ingestScope }, item, state, signal); } finally { clearTimeout(deadline); }
  }

  private async recoverSaveTime(source: KnowledgeRecord & { kind: "source" }, commandId: string, evidence?: { objectHash: string; bytes: Uint8Array }): Promise<KnowledgeRecord & { kind: "source" }> {
    if (source.content.identity?.provider.toLowerCase() !== "raindrop" || source.content.sourceSavedAt) return source;
    const recovered = await recoverProviderSaveTime(this.store, { commandId, sourceId: source.id, expectedRevision: source.revisionId, writer: "connector", ...(evidence ? { evidence } : {}) });
    if (recovered.status !== "recovered" || !recovered.revisionId) return source;
    const current = await this.store.read(source.id, recovered.revisionId, false, true, true);
    return current?.kind === "source" ? current : source;
  }

  private async attachProviderPayload(item: PendingItem, source: KnowledgeRecord & { kind: "source" }, commandId: string): Promise<{ record: KnowledgeRecord & { kind: "source" }; evidence?: { objectHash: string; bytes: Uint8Array } }> {
    if (!item.apiPayload) return { record: source };
    const bytes = new TextEncoder().encode(item.apiPayload);
    const apiObject = await this.store.putObject(bytes, "application/json");
    const evidence = { objectHash: apiObject.hash, bytes };
    const representations = source.content.representations ?? [];
    if (representations.some(value => value.kind === "provider-api" && value.object.hash === apiObject.hash)) return { record: source, evidence };
    const updated = await this.store.captureSource({ writer: "connector", commandId, expectedRevision: source.revisionId, record: { kind: "source", id: source.id, createdAt: source.createdAt, scope: source.scope, provenance: source.provenance, relations: source.relations, ...(source.temporal ? { temporal: source.temporal } : {}), content: { ...source.content, representations: [...representations, { kind: "provider-api", object: apiObject, mediaType: "application/json" }] } } });
    if (updated.record.kind !== "source") throw new Error("Provider payload attachment returned a non-source record");
    return { record: updated.record, evidence };
  }

  private async markUnsafeLinkedCapture(item: PendingItem, source: KnowledgeRecord & { kind: "source" }, commandId: string): Promise<KnowledgeRecord & { kind: "source" }> {
    let disposition = source.content.captureDisposition;
    // Public post permalinks were read through the X provider; only HTML fetches
    // of other X pages need the app-shell capture downgrade.
    if (isPublicXPost(item.url)) return source;
    try {
      const host = new URL(item.url).hostname.toLowerCase();
      if (host === "x.com" || host.endsWith(".x.com") || host === "twitter.com" || host.endsWith(".twitter.com")) disposition = "reference-only";
      else if (host === "github.com" || host.endsWith(".github.com")) disposition = disposition === "complete" ? "partial" : disposition;
    } catch { disposition = "reference-only"; }
    if (disposition === source.content.captureDisposition) return source;
    const updated = await this.store.captureSource({ writer: "connector", commandId, expectedRevision: source.revisionId, record: { kind: "source", id: source.id, createdAt: source.createdAt, scope: source.scope, provenance: source.provenance, relations: source.relations, ...(source.temporal ? { temporal: source.temporal } : {}), content: { ...source.content, captureDisposition: disposition } } });
    if (updated.record.kind !== "source") throw new Error("Linked capture quality update returned a non-source record");
    return updated.record;
  }

  /** Enrichment follows an entry once its intake has settled, against the
   * latest committed revision, so it never races admission or a move. Any
   * readable text qualifies: partial captures (every X post) are summarized as
   * sampled evidence. Queue admission cannot roll back captured evidence. */
  private async queueSettledEnrichment(sourceId: string | undefined): Promise<void> {
    if (!sourceId || !this.options.queueSummary) return;
    try {
      const latest = await this.store.read(sourceId, undefined, false, true, true);
      if (latest?.kind === "source" && latest.content.text) this.options.queueSummary(latest);
    } catch { /* A later intake or explicit summarize retries. */ }
  }

  private async intake(request: KnowledgeRaindropIntakeRequest, externalSignal?: AbortSignal): Promise<Record<string, unknown>> {
    const connectionAuthority = await this.connectionFor(request.connectionId, "raindrop", Boolean(this.options.connections));
    const jevConnectionId = await this.options.jevBudget?.connectionId();
    const state = await this.store.connectorState("raindrop");
    if (!state?.enabled || !state.credentialRef || !state.accountId || (!state.scope && !this.options.connections)) throw new GatewayError("unsupported", "Raindrop connector is not configured");
    const mappings = connectionAuthority?.raindropCollections;
    if (this.options.connections && (!mappings || mappings.length === 0)) throw new GatewayError("unsupported", "Configure at least one Raindrop collection mapping before intake");
    this.assertCredentialNamespace("raindrop", state.credentialRef);
    if (currentInvocationContext()?.operationId?.startsWith("automation:") && !state.recurringApproved) throw new GatewayError("unsupported", "Raindrop intake recurrence is not approved");
    if (!/^\d+$/.test(state.accountId)) throw new GatewayError("invalid_request", "Raindrop accountId must be the numeric user _id");
    if (request.limit !== undefined && (!Number.isSafeInteger(request.limit) || request.limit < 1 || request.limit > 10)) throw bad("Raindrop intake limit must be 1..10");
    if (request.sourceCollection !== undefined && !/^-?\d{1,18}$/.test(request.sourceCollection)) throw bad("Raindrop intake source collection is invalid");
    const sourceCollection = request.sourceCollection ?? (mappings?.length === 1 ? mappings[0]!.collectionId : undefined) ?? (mappings ? undefined : state.scope);
    if (!sourceCollection) throw bad("Choose a mapped Raindrop source collection for intake");
    const mapping = mappings?.find(item => item.collectionId === sourceCollection);
    if (mappings && !mapping) throw new GatewayError("unsupported", "Raindrop source collection is not mapped to a Knowledge role");
    if (mapping?.role === "triage") throw new GatewayError("unsupported", "Legacy Raindrop intake cannot choose a triage item's scope; use the ingestion routine");
    if (mapping?.role === "archive") throw new GatewayError("unsupported", "Archive-role collections are never ingested");
    const mappedScope = mapping?.role === "personal" ? "personal" : "research";
    const expectedSetupRevision = connectionAuthority?.setupRevision;
    const limit = request.limit ?? 10;
    const token = await this.options.credentials.read(state.credentialRef);
    if (!token) throw missingCredential("raindrop", state.credentialRef);
    const controller = new AbortController(); const signal = externalSignal ? AbortSignal.any([controller.signal, externalSignal]) : controller.signal;
    const deadline = setTimeout(() => controller.abort(new Error("Raindrop intake deadline exceeded")), RUN_DEADLINE_MS); deadline.unref?.();
    try {
      const identity = await requestJson(this.http, "https://api.raindrop.io/rest/v1/user", token, { sleep: this.sleep, signal });
      const account = raindropUser(identity.value);
      if (!account.accountId || account.accountId !== state.accountId) throw new GatewayError("conflict", "Raindrop authenticated account does not match configured account");
      await this.reconcile("raindrop", signal);
      if ((await this.store.connectorState("raindrop"))?.pendingRemote) throw new GatewayError("conflict", "Raindrop has an unresolved remote effect");
      const profileVersion = jevProfileVersion((await this.store.config()).currentInterests ?? []);
      const approvedPilot = request.pilot;
      const savedPilot = connectionAuthority ? state.assessmentPilots?.[sourceCollection] : state.assessmentPilot?.sourceCollection === sourceCollection ? state.assessmentPilot : undefined;
      if (!request.dryRun && mappedScope === "research") {
        if (!approvedPilot || !approvedPilot.id || !Number.isSafeInteger(approvedPilot.maxItems) || approvedPilot.maxItems < 1 || approvedPilot.maxItems > 10 || !Number.isSafeInteger(approvedPilot.budgetCents) || approvedPilot.budgetCents < 1 || approvedPilot.budgetCents > 100) throw bad("A bounded Jev pilot approval is required");
        if (savedPilot && savedPilot.id === approvedPilot.id && (savedPilot.maxItems !== approvedPilot.maxItems || savedPilot.budgetCents !== approvedPilot.budgetCents || savedPilot.accountId !== state.accountId || savedPilot.sourceCollection !== sourceCollection || savedPilot.profileVersion !== profileVersion)) throw new GatewayError("conflict", "Jev pilot authority changed; use the existing approval");
        if (savedPilot && savedPilot.id !== approvedPilot.id && !state.assessmentApprovals?.some(item => item.id === approvedPilot.id && item.sourceCollection === sourceCollection)) throw new GatewayError("conflict", "Later assessment requires a separately approved cohort");
      }
      const discovered = await this.discover(request.commandId, "raindrop", { ...state, scope: sourceCollection }, token, limit, signal);
      if (connectionAuthority && expectedSetupRevision !== (await this.connectionFor(request.connectionId, "raindrop", true))?.setupRevision) throw new GatewayError("conflict", "Raindrop collection mapping changed during intake; retry with the current setup revision");
      let live = await this.store.connectorState("raindrop") ?? state;
      if (request.dryRun) return { connector: "raindrop", dryRun: true, discovered: discovered.discovered, pending: live.pending.filter(item => item.collectionId === sourceCollection).slice(0, limit).map(item => ({ id: item.id, title: item.title, url: item.url, metadataComplete: item.metadataComplete !== false })), assessment: "not-run", remoteWrites: false };
      let cohortAuthority: NonNullable<KnowledgeConnectorState["assessmentPilot"]> | undefined;
      if (mappedScope === "research") {
        if (!approvedPilot) throw new GatewayError("invalid_request", "A bounded Jev pilot approval is required");
        const currentPilot = connectionAuthority ? live.assessmentPilots?.[sourceCollection] : live.assessmentPilot?.sourceCollection === sourceCollection ? live.assessmentPilot : undefined;
        cohortAuthority = currentPilot?.id === approvedPilot.id ? currentPilot : live.assessmentApprovals?.find(item => item.id === approvedPilot.id && item.sourceCollection === sourceCollection);
        if (!cohortAuthority && !currentPilot) {
          const itemIds = live.pending.filter(item => item.collectionId === sourceCollection).slice(0, Math.min(limit, approvedPilot.maxItems)).map(item => item.id);
          const created = { id: approvedPilot.id, maxItems: approvedPilot.maxItems, budgetCents: approvedPilot.budgetCents, usedItems: 0, reservedCents: 0, accountId: state.accountId!, sourceCollection, profileVersion, itemIds };
          live = await this.store.updateConnectorState(command(request.commandId, `cohort-${sourceCollection}`), "raindrop", current => ({ ...(current ?? live), ...(connectionAuthority ? { assessmentPilots: { ...(current?.assessmentPilots ?? {}), [sourceCollection]: created } } : { assessmentPilot: created }) }));
          cohortAuthority = connectionAuthority ? live.assessmentPilots?.[sourceCollection] : live.assessmentPilot;
        }
        if (!cohortAuthority) throw new GatewayError("conflict", "Assessment cohort approval is unavailable");
        if (cohortAuthority.itemIds.length === 0) {
          const alreadyCohorted = new Set([...(live.assessmentPilots?.[sourceCollection]?.itemIds ?? []), ...(live.assessmentPilot?.sourceCollection === sourceCollection ? live.assessmentPilot.itemIds : []), ...(live.assessmentApprovals ?? []).filter(item => item.sourceCollection === sourceCollection).flatMap(item => item.itemIds)]);
          const itemIds = live.pending.filter(item => item.collectionId === sourceCollection && !alreadyCohorted.has(item.id)).slice(0, Math.min(limit, cohortAuthority.maxItems)).map(item => item.id);
          live = await this.store.updateConnectorState(command(request.commandId, `cohort-items-${sourceCollection}-${cohortAuthority.id}`), "raindrop", current => {
            const next = current ?? live; const updated = { ...cohortAuthority!, itemIds };
            if (connectionAuthority) return { ...next, assessmentPilots: { ...(next.assessmentPilots ?? {}), [sourceCollection]: updated } };
            return cohortAuthority!.id === next.assessmentPilot?.id ? { ...next, assessmentPilot: updated } : { ...next, assessmentApprovals: (next.assessmentApprovals ?? []).map(item => item.id === cohortAuthority!.id ? updated : item) };
          });
          cohortAuthority = connectionAuthority ? live.assessmentPilots?.[sourceCollection] : live.assessmentPilot?.id === cohortAuthority.id ? live.assessmentPilot : live.assessmentApprovals?.find(item => item.id === cohortAuthority!.id);
        }
        if (!cohortAuthority) throw new GatewayError("conflict", "Assessment cohort approval is unavailable");
        if (cohortAuthority.maxItems !== approvedPilot.maxItems || cohortAuthority.budgetCents !== approvedPilot.budgetCents || cohortAuthority.accountId !== live.accountId || cohortAuthority.sourceCollection !== sourceCollection || cohortAuthority.profileVersion !== profileVersion) throw new GatewayError("conflict", "Assessment cohort authority changed; use the existing approval");
      }
      const cohortId = cohortAuthority?.id ?? `personal-${sourceCollection}`;
      const cohort = cohortAuthority?.itemIds ?? live.pending.filter(item => item.collectionId === sourceCollection).slice(0, limit).map(item => item.id);
      let captured = 0; let retained = 0; let archived = 0; let pending = 0; let assessmentFailed = 0; let moved = 0; let lastError: string | undefined;
      const outcomeMap = new Map<string, IntakeOutcome>();
      const setOutcome = (item: Pick<PendingItem, "id" | "title">, patch: Partial<Omit<IntakeOutcome, "itemId" | "title">>) => {
        const previous = outcomeMap.get(item.id);
        outcomeMap.set(item.id, { ...(previous ?? { itemId: item.id, title: item.title.slice(0, 512) }), ...patch, ...(patch.reason !== undefined ? { reason: patch.reason.slice(0, 2_000) } : {}) } as IntakeOutcome);
      };
      const canonicalFor = (itemId: string): Promise<KnowledgeRecord & { kind: "source" } | undefined> => this.store.sourceByIdentity({ provider: "raindrop", accountId: state.accountId!, itemId });
      const markDone = async (itemId: string, disposition: "processed" | "skipped" = "processed", why = "Processed by the bounded legacy Raindrop intake") => this.ack({ commandId: command(request.commandId, `done-${itemId}`), connector: "raindrop", ...(request.connectionId ? { connectionId: request.connectionId } : {}), itemId, disposition, reason: why });
      const approvedItems = cohort.map(itemId => live.pending.find(item => item.id === itemId)).filter((item): item is NonNullable<typeof item> => Boolean(item));
      const approvedSet = new Set(approvedItems.map(item => item.id));
      for (const itemId of cohort) if (!approvedSet.has(itemId)) {
        const stateNow = await this.store.connectorState("raindrop");
        const canonical = await canonicalFor(itemId);
        setOutcome({ id: itemId, title: canonical?.content.title ?? "" }, stateNow?.capturedIds.includes(itemId) || canonical ? { ...(canonical ? { sourceId: canonical.id, sourceRevision: canonical.revisionId } : {}), disposition: "already-processed", reason: canonical ? "Canonical source exists; remote location was not reverified by this run" : "Connector receipt says processed; canonical source lookup was unavailable", assessment: canonical?.content.assessment ? "reused" : "not-run", move: "blocked" } : { disposition: "pending", reason: "Cohort identity is no longer pending and no canonical source was found", assessment: "not-run", move: "blocked" });
      }
      for (const item of approvedItems) {
        if ((await this.store.connectorState("raindrop"))?.pendingRemote) { lastError = "Raindrop has an unresolved remote effect"; for (const tail of approvedItems.slice(approvedItems.indexOf(item))) setOutcome(tail, { disposition: "pending", reason: "Blocked by unresolved remote effect; reconcile before processing", assessment: "not-run", move: "blocked" }); break; }
        try {
          live = await this.store.connectorState("raindrop") ?? live;
          if (connectionAuthority && expectedSetupRevision !== (await this.connectionFor(request.connectionId, "raindrop", true))?.setupRevision) throw new GatewayError("conflict", "Raindrop collection mapping changed during intake; retry with the current setup revision");
          if (mapping && item.collectionId !== mapping.collectionId) throw new GatewayError("conflict", "Raindrop item collection does not match the selected mapping");
          let source = await this.ingestItem({ commandId: command(request.commandId, `ingest-${item.id}`), connector: "raindrop", connectionId: request.connectionId ?? "legacy", itemId: item.id, scope: mappedScope }, item, live, signal);
          setOutcome(item, { sourceId: source.id, sourceRevision: source.revisionId, disposition: "pending", assessment: "not-run", move: "not-attempted", reason: "Source captured; processing not yet complete" });
          let sourceRef = { sourceId: source.id, sourceRevision: source.revisionId };
          captured += 1;
          if (sourceAdmissionIsDecided(source)) {
            const status = source.content.admission?.status;
            const disposition = status === "archived" ? "archived" : status === "retained" ? "retained" : "pending";
            if (disposition === "archived") archived += 1;
            else if (disposition === "retained") retained += 1;
            else pending += 1;
            setOutcome(item, { ...sourceRef, disposition, assessment: "not-run", move: "not-attempted", reason: "Canonical source admission was already decided by a user or agent" });
            await markDone(item.id, "skipped", "Admission already decided by a user or agent; intake left it unchanged");
            continue;
          }
          // The entry's own scope, not the collection mapping, decides the path:
          // a source a user or agent placed in personal never reaches Jev.
          if (source.scope === "personal") {
            if (connectionAuthority && expectedSetupRevision !== (await this.connectionFor(request.connectionId, "raindrop", true))?.setupRevision) throw new GatewayError("conflict", "Raindrop collection mapping changed during intake; retry with the current setup revision");
            const admitted = source.content.admission?.status === "retained" ? source : (await this.store.setSourceAdmission({ commandId: command(request.commandId, `admit-personal-${item.id}`), recordId: source.id, expectedRevision: source.revisionId, status: "retained", producer: { actor: "connector" }, reason: "Personal collection uses Raindrop link, title, preview and saved note as sufficient evidence" })).record as KnowledgeRecord & { kind: "source" };
            source = admitted; sourceRef = { sourceId: source.id, sourceRevision: source.revisionId }; retained += 1;
              if (live.allowWrites && connectionAuthority) {
              const result = await this.moveOne({ commandId: command(request.commandId, `move-${item.id}`), itemId: item.id, sourceId: admitted.id, expectedRevision: admitted.revisionId, connectionId: request.connectionId! }, signal);
              if (result.status === "moved" || result.status === "already-home") { moved += 1; setOutcome(item, { ...sourceRef, disposition: "retained", reason: "Personal source is in its derived home collection", assessment: "not-run", move: "moved" }); }
              else { setOutcome(item, { ...sourceRef, disposition: "retained", reason: "Personal source admitted; approved remote move remains unresolved", assessment: "not-run", move: result.status }); await markDone(item.id); continue; }
            } else setOutcome(item, { ...sourceRef, disposition: "retained", reason: "Personal source admitted from its saved Raindrop link and metadata", assessment: "not-run", move: "not-attempted" });
            await markDone(item.id);
           
            continue;
          }
          if (source.content.captureDisposition !== "complete" || item.metadataComplete === false || !source.content.text) {
            // An incomplete re-capture leaves the bookmark pending but must not
            // revoke an admission already decided for the same canonical source.
            if (source.content.admission?.status !== "retained" && source.content.admission?.status !== "archived") {
              const admission = await this.store.setSourceAdmission({ commandId: command(request.commandId, `pending-${item.id}`), recordId: source.id, expectedRevision: source.revisionId, status: "pending", producer: { actor: "connector" }, reason: "Capture is incomplete or provider metadata is bounded without complete linked evidence" });
              source = admission.record as KnowledgeRecord & { kind: "source" }; sourceRef = { sourceId: source.id, sourceRevision: source.revisionId };
            }
            pending += 1; setOutcome(item, { ...sourceRef, disposition: "pending", reason: source.content.captureReason ?? "Capture is incomplete or provider metadata is bounded without complete linked evidence", assessment: "not-run", move: "not-attempted" }); continue;
          }
          let assessment = source.content.assessment;
          let assessmentOutcome: IntakeOutcome["assessment"] = "not-run";
          const interests = (await this.store.config()).currentInterests ?? [];
          // Recovery reuses an immutable decision bound to unchanged evidence
          // and interests. A code/rubric upgrade alone is not paid re-triage authority.
          const assessmentCurrent = assessment?.model === JEV_DEFAULT_MODEL && assessment.profileVersion === jevProfileVersion(interests) && Boolean(assessment.rubricVersion) && assessment.inputDigest === jevInputDigest({ title: source.content.title, text: source.content.text ?? "", interests, source: { ...(source.content.uri ? { uri: source.content.uri } : {}), ...(source.content.mediaType ? { mediaType: source.content.mediaType } : {}), ...(source.content.collectionId ? { collectionId: source.content.collectionId } : {}), captureDisposition: source.content.captureDisposition, capturedAt: source.content.capturedAt } }, interests);
          if (assessmentCurrent) assessmentOutcome = "reused";
          setOutcome(item, { ...sourceRef, disposition: "pending", assessment: assessmentOutcome, move: "not-attempted", reason: "Assessment and admission in progress" });
          if (!assessmentCurrent) {
            if (!this.options.assessment) { pending += 1; lastError = "Jev source assessment is not configured"; setOutcome(item, { ...sourceRef, disposition: "pending", reason: lastError, assessment: "not-run", move: "not-attempted" }); continue; }
            let dispatched = false;
            let reservationReleased = false;
            let monthlyAttempt: string | undefined;
            const releaseReservation = async () => {
              if (monthlyAttempt && !dispatched && !reservationReleased) {
                await this.options.jevBudget!.releaseUndispatched(jevConnectionId!, monthlyAttempt);
                reservationReleased = true;
              }
            };
            try {
              const assessmentConnectionId = jevConnectionId;
              if (!assessmentConnectionId) throw new GatewayError("unsupported", "Jev intake assessment requires exactly one enabled knowledge.jev connection with approved paid access");
              const triaged = await triageSource(this.store, { commandId: command(request.commandId, `assess-${item.id}`), sourceId: source.id, expectedRevision: source.revisionId, signal, beforeDispatch: async () => {
                monthlyAttempt = await this.reserveAssessment(command(request.commandId, `assess-${item.id}`), item.id, approvedPilot!, sourceCollection, assessmentConnectionId, cohortId);
              }, onDispatch: async () => {
                try { await this.options.jevBudget!.markDispatch(assessmentConnectionId, monthlyAttempt!); dispatched = true; }
                catch (error) { await releaseReservation(); throw error; }
              } }, this.options.assessment);
              assessment = triaged.assessment; source = triaged.source; sourceRef = { sourceId: source.id, sourceRevision: source.revisionId }; assessmentOutcome = assessment.coverage === "sampled" ? "dispatched-settled-sampled" : "dispatched-settled";
              setOutcome(item, { ...sourceRef, assessment: assessmentOutcome });
              const usage = assessment?.usage ? { inputTokens: assessment.usage.inputTokens, outputTokens: assessment.usage.outputTokens, estimatedCostCents: assessment.usage.estimatedCostCents } : undefined;
              await this.settleAssessment(command(request.commandId, `assess-${item.id}`), item.id, cohortId, jevConnectionId, monthlyAttempt!, usage);
            } catch (error) { if (!dispatched) await releaseReservation(); assessmentFailed += 1; pending += 1; lastError = dispatched ? "Jev assessment outcome is uncertain; reconcile before retrying" : (error instanceof Error ? error.message : "Jev assessment failed"); setOutcome(item, { ...sourceRef, disposition: "pending", reason: lastError, assessment: dispatched ? "dispatched-uncertain" : "preflight-failed", move: "not-attempted" }); continue; }
          }
          const finalInterests = (await this.store.config()).currentInterests ?? [];
          if (!assessment || (assessment.model === JEV_DEFAULT_MODEL && assessment.coverage !== undefined && (assessment.coverage !== "full" && assessment.coverage !== "sampled")) || (assessment.model === JEV_DEFAULT_MODEL && assessment.inputDigest !== undefined && (assessment.profileVersion !== jevProfileVersion(finalInterests) || assessment.inputDigest !== jevInputDigest({ title: source.content.title, text: source.content.text ?? "", interests: finalInterests, source: { ...(source.content.uri ? { uri: source.content.uri } : {}), ...(source.content.mediaType ? { mediaType: source.content.mediaType } : {}), ...(source.content.collectionId ? { collectionId: source.content.collectionId } : {}), captureDisposition: source.content.captureDisposition, capturedAt: source.content.capturedAt } }, finalInterests)))) throw new GatewayError("conflict", "Source assessment authority changed before admission");
          const status = assessment.recommendation === "archived" ? "archived" : "retained";
          let admitted: KnowledgeRecord & { kind: "source" };
          try {
            admitted = (await this.store.setSourceAdmission({ commandId: command(request.commandId, `admit-${item.id}`), recordId: source.id, expectedRevision: source.revisionId, status, producer: { actor: "connector" }, reason: status === "archived" ? "Jev clear low-value classification; recoverable intake archive" : "Jev intake accepted source", ...(assessment?.profileVersion ? { profileVersion: assessment.profileVersion } : {}), ...(assessment?.rubricVersion ? { rubricVersion: assessment.rubricVersion } : {}) })).record as KnowledgeRecord & { kind: "source" };
          } catch (error) {
            if (!(error instanceof KnowledgeCurationRefusal) || error.code !== "decision-authority") throw error;
            const authoritative = await this.store.read(source.id, undefined, false, true, true);
            if (!authoritative || authoritative.kind !== "source") throw error;
            admitted = authoritative;
            const decision = admitted.content.admission?.status;
            const disposition = decision === "archived" ? "archived" : decision === "retained" ? "retained" : "pending";
            if (disposition === "archived") archived += 1; else if (disposition === "retained") retained += 1; else pending += 1;
            sourceRef = { sourceId: admitted.id, sourceRevision: admitted.revisionId };
            setOutcome(item, { ...sourceRef, disposition, assessment: assessmentOutcome, move: "not-attempted", reason: "The Knowledge store preserved an existing authoritative admission" });
            await markDone(item.id);
            continue;
          }
          source = admitted; sourceRef = { sourceId: source.id, sourceRevision: source.revisionId };
          setOutcome(item, { ...sourceRef, disposition: status, assessment: assessmentOutcome });
          if (status === "archived") archived += 1; else retained += 1;
          if (!live.allowWrites || !connectionAuthority) { setOutcome(item, { ...sourceRef, disposition: status, reason: "Remote move is not authorized by a mapped connection", assessment: assessmentOutcome, move: "not-attempted" }); await markDone(item.id); continue; }
          const movedResult = await this.moveOne({ commandId: command(request.commandId, `move-${item.id}`), itemId: item.id, sourceId: admitted.id, expectedRevision: admitted.revisionId, connectionId: request.connectionId! }, signal);
          if (movedResult.status !== "moved" && movedResult.status !== "already-home") {
            lastError = "Raindrop destination move could not be verified";
            setOutcome(item, { ...sourceRef, disposition: status, reason: lastError, assessment: assessmentOutcome, move: movedResult.status });
            await markDone(item.id);
            if (source.content.text && source.content.captureDisposition === "complete") { }
            if ((await this.store.connectorState("raindrop"))?.pendingRemote) { for (const tail of approvedItems.slice(approvedItems.indexOf(item) + 1)) setOutcome(tail, { disposition: "pending", reason: "Blocked by unresolved remote effect; reconcile before processing", assessment: "not-run", move: "blocked" }); break; }
            continue;
          }
          moved += 1;
          setOutcome(item, { ...sourceRef, disposition: status, reason: "Locally admitted and remotely verified", assessment: assessmentOutcome, move: "moved" });
          await markDone(item.id);
          if (source.content.text && source.content.captureDisposition === "complete") { }
        } catch (error) { pending += 1; lastError = error instanceof Error ? error.message : "Raindrop intake failed"; const prior = outcomeMap.get(item.id); if (prior?.move === "moved") setOutcome(item, { reason: "Remote move verified; local completion receipt requires reconciliation", assessment: prior.assessment, move: "moved" }); else setOutcome(item, { disposition: prior?.disposition ?? "pending", reason: lastError, assessment: prior?.assessment ?? "not-run", move: prior?.move ?? "not-attempted" }); } finally { await this.queueSettledEnrichment(outcomeMap.get(item.id)?.sourceId); }
      }
      const finalState = await this.store.connectorState("raindrop") ?? live;
      const finalAuthority = cohortAuthority ? (finalState.assessmentPilots?.[sourceCollection]?.id === cohortId ? finalState.assessmentPilots[sourceCollection] : finalState.assessmentPilot?.id === cohortId ? finalState.assessmentPilot : finalState.assessmentApprovals?.find(item => item.id === cohortId) ?? cohortAuthority) : undefined;
      // Costs describe the durable cohort, not just this invocation's loop.
      // Moved items disappear from pending; their paid receipts must not vanish
      // from the estimate on a later run. Unknown is never silently zero.
      const attempts = Object.values(finalState?.assessmentAttempts ?? {}).filter(attempt => attempt.cohortId === cohortId || (!attempt.cohortId && cohortId === finalState?.assessmentPilot?.id));
      const known = attempts.filter(attempt => attempt.estimatedCostCents !== undefined);
      return { connector: "raindrop", dryRun: false, discovered: discovered.discovered, captured, retained, archived, assessmentFailed, moved, pending, outcomes: cohort.map(itemId => outcomeMap.get(itemId)!).filter(Boolean), ...(finalAuthority ? { budget: { approvedCeilingCents: finalAuthority.budgetCents, conservativeReservedCents: finalAuthority.reservedCents, cohortItemCap: finalAuthority.maxItems, cohortSelectedItems: cohort.length, settledItems: finalAuthority.usedItems, ...(known.length > 0 ? { estimatedUsageCostCents: known.reduce((sum, attempt) => sum + attempt.estimatedCostCents!, 0) } : {}), usageKnownAssessments: known.length, usageUnknownAssessments: attempts.length - known.length, uncertainAttempts: attempts.filter(attempt => attempt.status === "dispatched").length, pendingOutsideCohortItems: (finalState?.pending ?? []).filter(item => !cohort.includes(item.id)).length } } : {}), ...(lastError ? { error: lastError } : {}) };
    } finally { clearTimeout(deadline); }
  }

  private async queue(request: KnowledgeConnectorQueueRequest): Promise<Record<string, unknown>> {
    if (!request.connectionId) throw bad("Connector queue requires a connectionId");
    const limit = request.limit ?? 25;
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 25) throw bad("Connector queue limit must be 1..25");
    const state = await this.store.connectorState(request.connector, request.connectionId);
    if (!state?.enabled) throw new GatewayError("unsupported", "Connector is not configured for this connection");
    const authority = await this.connectionFor(request.connectionId, request.connector, Boolean(this.options.connections));
    let collectionId = request.sourceCollection;
    let scope: "research" | "personal" | undefined;
    if (request.connector === "raindrop") {
      const mappings = authority?.raindropCollections;
      if (this.options.connections && !mappings?.length) throw new GatewayError("unsupported", "Configure Raindrop collection mappings before reading the queue");
      if (collectionId === undefined && mappings?.length === 1) collectionId = mappings[0]!.collectionId;
      if (mappings && !collectionId) throw bad("Choose a mapped Raindrop collection");
      const mapping = mappings?.find(item => item.collectionId === collectionId);
      if (mappings && !mapping) throw new GatewayError("unsupported", "Raindrop source collection is not mapped to a Knowledge role");
      scope = mapping?.role === "research" || mapping?.role === "personal" ? mapping.role : undefined;
    } else if (request.sourceCollection !== undefined) throw bad("Only Raindrop queues accept sourceCollection");
    const pending = state.pending.filter(item => request.connector !== "raindrop" || item.collectionId === collectionId).slice(0, limit);
    const entries = await Promise.all(pending.map(async item => {
      const source = await this.store.sourceByIdentity({ provider: request.connector, accountId: state.accountId!, itemId: item.id });
      const role = request.connector === "raindrop" ? authority?.raindropCollections?.find(mapping => mapping.collectionId === item.collectionId)?.role : undefined;
      return { id: item.id, url: item.url, title: item.title.slice(0, 512), ...(item.collectionId ? { collectionId: item.collectionId } : {}), ...(role ? { role } : {}), ...(item.savedAt ? { savedAt: item.savedAt } : {}), sourceExists: Boolean(source), ...(source ? { sourceId: source.id, revisionId: source.revisionId, admission: source.content.admission?.status ?? "pending", scope: source.scope } : {}) };
    }));
    return { connector: request.connector, connectionId: request.connectionId, ...(collectionId ? { sourceCollection: collectionId } : {}), items: entries, remaining: Math.max(0, state.pending.filter(item => request.connector !== "raindrop" || item.collectionId === collectionId).length - entries.length) };
  }

  private async ack(request: KnowledgeConnectorAckRequest): Promise<Record<string, unknown>> {
    if (!request.commandId || request.commandId.length > 160 || !request.itemId || request.itemId.length > 128 || !request.reason.trim() || request.reason.length > 500) throw bad("Connector acknowledgment requires a bounded itemId and reason");
    const state = await this.store.connectorState(request.connector, request.connectionId);
    const item = state?.pending.find(candidate => candidate.id === request.itemId);
    if (!item) {
      const prior = state?.processedItems?.find(candidate => candidate.id === request.itemId);
      if (prior) return { ...prior, idempotent: true };
      throw new GatewayError("not_found", "Connector item is not in the pending queue");
    }
    const authority = await this.connectionFor(request.connectionId, request.connector, Boolean(this.options.connections));
    if (request.connector === "raindrop" && authority?.raindropCollections?.length && !authority.raindropCollections.some(mapping => mapping.collectionId === item.collectionId)) throw new GatewayError("conflict", "Queued Raindrop item is no longer mapped to this connection");
    const processedAt = this.now();
    const processed = { id: item.id, disposition: request.disposition, reason: request.reason.trim(), ...(item.collectionId ? { collectionId: item.collectionId } : {}), processedAt };
    const updated = await this.store.updateConnectorState(request.commandId, request.connector, current => {
      const live = current ?? state!;
      const prior = live.processedItems?.find(candidate => candidate.id === item.id);
      if (prior) return { ...live, pending: live.pending.filter(candidate => candidate.id !== item.id), processedItems: [...(live.processedItems ?? []).filter(candidate => candidate.id !== item.id), { ...prior, ...(item.collectionId ? { collectionId: item.collectionId } : {}) }].slice(-2_000), ...(item.collectionId ? { capturedCollections: { ...(live.capturedCollections ?? {}), [item.id]: item.collectionId } } : {}), remaining: Math.max(0, live.pending.length - 1) };
      if (!live.pending.some(candidate => candidate.id === item.id)) throw new GatewayError("conflict", "Connector queue item changed before acknowledgment");
      return { ...live, pending: live.pending.filter(candidate => candidate.id !== item.id), processedItems: [...(live.processedItems ?? []).filter(candidate => candidate.id !== item.id), processed].slice(-2_000), capturedIds: request.disposition === "processed" ? [...new Set([...live.capturedIds, item.id])].slice(-2_000) : live.capturedIds, ...(item.collectionId ? { capturedCollections: { ...(live.capturedCollections ?? {}), [item.id]: item.collectionId } } : {}), remaining: Math.max(0, live.pending.length - 1) };
    }, undefined, request.connectionId);
    return updated.processedItems?.find(candidate => candidate.id === item.id) ?? processed;
  }

  private async moveOne(request: KnowledgeRaindropMoveRequest, signal?: AbortSignal): Promise<{ status: "moved" | "already-home" | "conflict" | "unsupported" }> {
    if (!request.connectionId || !request.commandId || !request.sourceId || !request.expectedRevision) throw bad("Raindrop move requires an exact source revision and connection");
    if (Object.keys(request as unknown as Record<string, unknown>).some(key => !["connectionId", "commandId", "itemId", "sourceId", "expectedRevision"].includes(key))) throw bad("Raindrop move does not accept a caller-chosen destination");
    const source = await this.store.read(request.sourceId, undefined, false, true, true);
    if (!source || source.kind !== "source" || source.revisionId !== request.expectedRevision) return { status: "conflict" };
    const state = await this.store.connectorState("raindrop", request.connectionId);
    const authority = await this.connectionFor(request.connectionId, "raindrop", Boolean(this.options.connections));
    const mappings = authority?.raindropCollections ?? [];
    const sourceCollection = source.content.collectionId;
    if (!state?.allowWrites || !authority?.policy.enabled || !authority.policy.allowWrites || authority.providerAccountId !== state.accountId || !sourceCollection) return { status: "unsupported" };
    const admission = source.content.admission?.status;
    const role = admission === "archived" ? "archive" : source.scope;
    const home = mappings.find(item => item.role === role);
    if (!home) return { status: "unsupported" };
    const identity = source.content.identity;
    const itemId = identity?.provider === "raindrop" ? identity.itemId : source.content.origins?.find(origin => origin.identity?.provider === "raindrop")?.identity?.itemId;
    const accountId = identity?.provider === "raindrop" ? identity.accountId : source.content.origins?.find(origin => origin.identity?.provider === "raindrop")?.identity?.accountId;
    if (!itemId || !accountId || itemId !== request.itemId || accountId !== state.accountId) return { status: "conflict" };
    if (sourceCollection === home.collectionId) return { status: "already-home" };
    return this.moveRaindrop({ commandId: request.commandId, itemId, source, expectedRevision: request.expectedRevision, identity: { provider: "raindrop", accountId, itemId }, connectionId: request.connectionId, expectedSetupRevision: authority.setupRevision }, signal);
  }

  private async discoverQueue(request: KnowledgeConnectorDiscoverRequest, externalSignal?: AbortSignal): Promise<Record<string, unknown>> {
    const connector = request.connector; const authority = await this.connectionFor(request.connectionId, connector, Boolean(this.options.connections)); const current = await this.store.connectorState(connector);
    if (!current?.enabled || !current.credentialRef || !current.accountId || (connector === "x" && !current.scope) || (connector === "raindrop" && !current.scope && !authority?.raindropCollections?.length)) throw new GatewayError("unsupported", `Knowledge ${connector} connector is not configured`);
    if (request.sourceCollection !== undefined && !/^-?\d{1,18}$/.test(request.sourceCollection)) throw bad("Connector source collection is invalid");
    const mappings = connector === "raindrop" ? authority?.raindropCollections : undefined;
    if (connector === "raindrop" && this.options.connections && !mappings?.length) throw new GatewayError("unsupported", "Configure Raindrop collection mappings before connector runs");
    if (connector !== "raindrop" && request.sourceCollection !== undefined) throw bad("Only Raindrop connector runs accept a source collection");
    const selectedCollection = connector === "raindrop" ? request.sourceCollection ?? (mappings?.length === 1 ? mappings[0]!.collectionId : undefined) ?? (mappings ? undefined : current.scope) : undefined;
    if (connector === "raindrop" && !selectedCollection) throw bad("Choose a mapped Raindrop source collection for connector runs");
    const mapping = selectedCollection ? mappings?.find(item => item.collectionId === selectedCollection) : undefined;
    if (mappings && selectedCollection && !mapping) throw new GatewayError("unsupported", "Raindrop source collection is not mapped to a Knowledge scope");
    if (authority && (!authority.policy.enabled || authority.health === "disconnected" || authority.providerAccountId !== current.accountId || authority.scope !== current.scope || authority.credentialRef !== current.credentialRef)) throw new GatewayError("conflict", "Connector configuration is not admitted by the current connection instance");
    const expectedSetupRevision = authority?.setupRevision;
    this.assertCredentialNamespace(connector, current.credentialRef);
    if (connector === "raindrop" && !/^\d+$/.test(current.accountId)) throw new GatewayError("invalid_request", "Raindrop accountId must be the numeric user _id");
    // X access requires a host-qualified account price and an explicit user
    // allowance. Charge immediately before every possible paid HTTP attempt;
    // this covers pagination, provider retries, and a fresh replay without
    // allowing an over-budget request to leave the Gateway.
    const xPricing = connector === "x" ? this.options.xPricing : undefined;
    const invocation = currentInvocationContext();
    if (invocation?.operationId?.startsWith("automation:") && !current.recurringApproved) {
      throw new GatewayError("unsupported", `Knowledge ${connector} recurrence is not approved`);
    }
    if (connector === "x") {
      if (!xPricing || xPricing.accountId !== current.accountId || !current.paidAccessApproved
        || !Number.isSafeInteger(xPricing.costCentsPerAttempt) || xPricing.costCentsPerAttempt < 1
        || !Number.isSafeInteger(xPricing.maxAttempts) || xPricing.maxAttempts < 1
        || xPricing.maxAttempts > RETRIES) throw new GatewayError("unsupported", "X connector pricing or allowance is unavailable");
    }
    if (connector === "raindrop" && current.paidBudgetCents > 0) throw new GatewayError("unsupported", "Paid connector operations are unavailable without a priced operation");
    if (current.pendingRemote) {
      await this.reconcile(connector, externalSignal);
      const reconciled = await this.store.connectorState(connector);
      if (reconciled?.pendingRemote) throw new GatewayError("conflict", "Connector has an unresolved remote effect");
    }
    const token = connector === "x" && authority && request.connectionId
      ? await this.xAccessToken(request.connectionId, current.credentialRef, expectedSetupRevision!, externalSignal ?? new AbortController().signal)
      : await this.options.credentials.read(current.credentialRef);
    if (!token) { await this.recordAdmission(current, "unavailable", "unknown", request.commandId, expectedSetupRevision); await this.store.updateConnectorState(command(request.commandId, "auth"), connector, state => ({ ...(state ?? current), health: "auth-error", lastError: "Credential reference is unavailable", lastRunAt: this.now() })); throw missingCredential(connector, current.credentialRef); }
    const assertCurrentAuthority = async (): Promise<void> => {
      const live = await this.store.connectorState(connector);
      if (!live?.enabled || live.accountId !== current.accountId || live.scope !== current.scope || live.credentialRef !== current.credentialRef) throw new GatewayError("conflict", "Connector configuration changed during provider discovery");
      if (this.options.connections && request.connectionId) {
        const liveAuthority = await this.connectionFor(request.connectionId, connector, true);
        if (!authority || !liveAuthority || liveAuthority.setupRevision !== expectedSetupRevision || liveAuthority.policy.enabled !== true || liveAuthority.providerAccountId !== current.accountId || liveAuthority.scope !== current.scope || liveAuthority.credentialRef !== current.credentialRef) throw new GatewayError("conflict", "Connection admission changed during provider discovery");
      }
    };
    let credentialUnavailable = false;
    const currentToken = async (): Promise<string> => {
      const live = await this.store.connectorState(connector);
      if (!live?.credentialRef || live.credentialRef !== current.credentialRef) throw new GatewayError("conflict", "Connector credential changed during provider discovery");
      const fresh = connector === "x" && authority && request.connectionId
        ? await this.xAccessToken(request.connectionId, live.credentialRef, expectedSetupRevision!, externalSignal ?? new AbortController().signal)
        : await this.options.credentials.read(live.credentialRef);
      if (!fresh) { credentialUnavailable = true; throw missingCredential(connector, live.credentialRef); }
      return fresh;
    };
    const limit = Math.min(request.limit ?? MAX_ITEMS, MAX_ITEMS); if (!Number.isSafeInteger(limit) || limit < 1) throw bad("Connector limit is invalid");
    await this.store.updateConnectorState(command(request.commandId, "start"), connector, state => { const next = { ...(state ?? current), health: "running" as const, lastRunAt: this.now(), remaining: state?.pending.length ?? 0 }; delete next.lastError; return next; });
    const abort = new AbortController();
    const signal = externalSignal ? AbortSignal.any([abort.signal, externalSignal]) : abort.signal;
    const deadline = setTimeout(() => abort.abort(new Error("Connector run deadline exceeded")), RUN_DEADLINE_MS);
    deadline.unref?.();
    try {
      let xAttempt = 0;
      const beforeXAttempt = xPricing ? async () => {
        xAttempt += 1;
        const attemptID = `${request.commandId}:x-attempt:${xAttempt}:${randomUUID()}`;
        await this.store.updateConnectorState(attemptID, "x", state => {
          const next = state ?? current;
          if (next.accountId !== xPricing.accountId || !next.paidAccessApproved || next.paidBudgetCents < xPricing.costCentsPerAttempt) throw new GatewayError("conflict", "X connector allowance exhausted or changed");
          return { ...next, paidBudgetCents: next.paidBudgetCents - xPricing.costCentsPerAttempt };
        });
      } : undefined;
      const beforeProviderAttempt = async (): Promise<void> => {
        await assertCurrentAuthority();
        await beforeXAttempt?.();
      };
      // The provider account fence precedes generic sweep discovery. It is
      // intentionally separate from the configured account label and from the
      // source URL capture policy.
      if (connector === "raindrop") {
        const profile = await this.verifyRaindropAccount(current, currentToken, signal, beforeProviderAttempt);
        await this.recordAdmission(current, "available", "admitted", request.commandId, expectedSetupRevision, profile);
      }
      const discovered = await this.discover(request.commandId, connector, selectedCollection ? { ...current, scope: selectedCollection } : current, currentToken, limit, signal, xPricing?.maxAttempts, beforeProviderAttempt, connector === "x" && authority && request.connectionId ? () => this.refreshXToken(request.connectionId!, current.credentialRef!, expectedSetupRevision!, signal) : undefined);
      let state = await this.store.connectorState(connector) ?? current;
      const scopedPending = connector === "raindrop" ? state.pending.filter(item => item.collectionId === selectedCollection) : state.pending;
      state = await this.store.updateConnectorState(command(request.commandId, "finish"), connector, value => ({ ...(value ?? state), health: "ready", lastRunAt: this.now(), remaining: value?.pending.length ?? state.pending.length }));
      clearTimeout(deadline);
      return { connector, discovered: discovered.discovered, pending: scopedPending.length, remaining: state.remaining, health: state.health };
    } catch (error) {
      const health = credentialUnavailable || error instanceof ConnectorHTTPError && authFailure(error.status) ? "auth-error" : error instanceof ConnectorHTTPError && error.status === 429 ? "rate-limited" : "error";
      const message = error instanceof ConnectorHTTPError ? `Provider request failed (${error.status})` : error instanceof Error ? error.message : "Connector discovery failed";
      if (health === "auth-error") await this.recordAdmission(current, "unavailable", "unknown", request.commandId, expectedSetupRevision);
      if (message.includes("authenticated account does not match")) await this.recordAdmission(current, "available", "mismatch", request.commandId, expectedSetupRevision);
      await this.store.updateConnectorState(command(request.commandId, "error"), connector, state => ({ ...(state ?? current), health, lastError: message, lastRunAt: this.now(), remaining: state?.pending.length ?? current.pending.length }));
      clearTimeout(deadline);
      throw new GatewayError(health === "auth-error" ? "unsupported" : "internal", message, true);
    }
  }

  private async discover(commandId: string, connector: Connector, state: KnowledgeConnectorState, token: string | (() => Promise<string>), limit: number, signal: AbortSignal, maxAttempts?: number, beforeAttempt?: () => Promise<void>, onUnauthorized?: () => Promise<void>): Promise<{ discovered: number }> {
    const checkpointKey = state.scope ?? "default";
    // Raindrop pagination is offset-based: moving an item shrinks earlier
    // pages, so a persisted page number can skip newly exposed items. Restart
    // each bounded sweep at page zero; the durable identity fence deduplicates
    // already captured/pending items while later pages remain discoverable.
    let cursor = connector === "raindrop" ? undefined : state.checkpoints?.[checkpointKey]; let discovered = 0;
    const processedIds = (state.processedItems ?? []).filter(item => connector !== "raindrop" || item.collectionId === state.scope).map(item => item.id);
    const seen = connector === "raindrop"
      ? new Set([...state.pending.filter(item => item.collectionId === state.scope).map(item => item.id), ...state.capturedIds.filter(id => state.capturedCollections?.[id] === state.scope), ...processedIds])
      : new Set([...state.pending.map(item => item.id), ...state.capturedIds, ...processedIds]);
    for (let page = 0; page < 10 && discovered < limit; page += 1) {
      const result = connector === "raindrop" ? await requestJson(this.http, `https://api.raindrop.io/rest/v1/raindrops/${encodeURIComponent(state.scope!)}?page=${cursor ? encodeURIComponent(cursor) : "0"}&perpage=${MAX_PAGE}`, token, { sleep: this.sleep, signal, ...(beforeAttempt === undefined ? {} : { beforeAttempt }) }) : await requestJson(this.http, `https://api.x.com/2/users/${encodeURIComponent(state.scope!)}/bookmarks?max_results=${MAX_PAGE}${cursor ? `&pagination_token=${encodeURIComponent(cursor)}` : ""}&tweet.fields=created_at,entities,author_id`, token, { sleep: this.sleep, signal, ...(maxAttempts === undefined ? {} : { maxAttempts }), ...(beforeAttempt === undefined ? {} : { beforeAttempt }), ...(onUnauthorized === undefined ? {} : { onUnauthorized }) });
      const parsed = connector === "raindrop" ? parseRaindrop(result.value) : parseX(result.value);
      // The requested collection endpoint is authoritative when an item omits
      // its collection field. A contradictory provider field is never routed.
      const items = connector === "raindrop" ? parsed.filter(item => !item.collectionId || item.collectionId === state.scope).map(item => ({ ...item, collectionId: item.collectionId ?? state.scope! })) : parsed;
      const fresh = items.filter(item => !seen.has(item.id));
      const next = connector === "raindrop" ? (items.length >= MAX_PAGE ? String((Number(cursor ?? "0") || 0) + 1) : undefined) : text(result.value?.meta?.next_token, 512);
      let persisted = 0;
      const pageReceipt = command(commandId, `discover:${connector}:${state.scope ?? "default"}:${cursor ?? "start"}:${page}`);
      await this.store.updateConnectorState(pageReceipt, connector, value => {
        const prior = value ?? state;
        const batch = fresh.slice(0, Math.max(0, limit - discovered));
        const batchIds = new Set(batch.map(item => item.id));
        const basePending = prior.pending.filter(item => !batchIds.has(item.id));
        const capacity = Math.max(0, 500 - basePending.length);
        const boundedBatch = batch.slice(0, Math.min(batch.length, capacity));
        const boundedIds = new Set(boundedBatch.map(item => item.id));
        const nextPending = [...basePending, ...boundedBatch];
        persisted = boundedBatch.length;
        const nextState = { ...prior, pending: nextPending, remaining: nextPending.length };
        // Advance only after every discovered item from this page is durable;
        // otherwise retry the same provider page instead of silently skipping.
        const checkpoints = { ...(nextState.checkpoints ?? {}) };
        if (connector !== "raindrop" && batch.length === fresh.length && next) checkpoints[checkpointKey] = next; else if (connector !== "raindrop" && !next && batch.length === fresh.length) delete checkpoints[checkpointKey];
        if (Object.keys(checkpoints).length > 0) nextState.checkpoints = checkpoints; else delete nextState.checkpoints;
        return nextState;
      });
      discovered += persisted; fresh.slice(0, persisted).forEach(item => seen.add(item.id));
      if (persisted < fresh.length || !next || items.length === 0 || discovered >= limit) break;
      cursor = next;
    }
    return { discovered };
  }

  /** Reconcile a persisted Raindrop move receipt after an effect-before-response crash.
   * Cancellation only retires the waiter; the durable receipt remains pending. */
  async reconcile(connector: Connector, externalSignal?: AbortSignal): Promise<KnowledgeConnectorStatus> {
    const state = await this.store.connectorState(connector); if (!state) return stateStatus(undefined, connector);
    const pending = state.pendingRemote;
    if (!pending || connector !== "raindrop" || !state.credentialRef) return stateStatus(state, connector);
    this.assertCredentialNamespace(connector, state.credentialRef);
    const basis = await this.store.read(pending.basisRecordId, pending.basisRevisionId, false, true);
    const basisIdentity = basis?.kind === "source" ? basis.content.identity : undefined;
    const basisOrigin = basis?.kind === "source" && basis.content.origins?.some(origin => origin.identity?.provider === pending.provider && origin.identity.accountId === pending.accountId && origin.identity.itemId === pending.itemId);
    if (!basis || basis.kind !== "source" || basis.revisionId !== pending.basisRevisionId || !isVerifiedSourceCapture(basis)
      || (!basisIdentity && !basisOrigin)
      || (basisIdentity && basisIdentity.provider !== pending.provider && !basisOrigin)
      || (basisIdentity && basisIdentity.accountId !== pending.accountId && !basisOrigin)
      || (basisIdentity && basisIdentity.itemId !== pending.itemId && !basisOrigin)) {
      await this.store.updateConnectorState(`${pending.operationId}:basis-conflict`, connector, current => ({ ...(current ?? state), health: "partial", lastError: "Remote effect basis source changed or is unavailable" }));
      return stateStatus(await this.store.connectorState(connector), connector);
    }
    if (state.paidBudgetCents > 0) return stateStatus(state, connector);
    const token = await this.options.credentials.read(state.credentialRef);
    if (!token) return stateStatus(state, connector);
    const controller = new AbortController();
    const signal = externalSignal ? AbortSignal.any([controller.signal, externalSignal]) : controller.signal;
    const deadline = setTimeout(() => controller.abort(new Error("Connector reconcile deadline exceeded")), RUN_DEADLINE_MS);
    deadline.unref?.();
    try {
      await this.verifyRaindropAccount(state, token, signal);
      const result = await requestJson(this.http, `https://api.raindrop.io/rest/v1/raindrop/${encodeURIComponent(pending.itemId)}`, token, { sleep: milliseconds => this.cancellableSleep(signal, milliseconds), signal });
      const collection = String(result.value?.item?.collection?.$id ?? result.value?.collection?.$id ?? "");
      const live = await this.store.connectorState(connector);
      if (!live || !live.enabled || live.accountId !== state.accountId || live.credentialRef !== state.credentialRef || live.pendingRemote?.operationId !== pending.operationId) return stateStatus(live ?? state, connector);
      if (collection === pending.destination) {
        const updated = await this.store.updateConnectorState(`${pending.operationId}:reconcile`, connector, current => {
          const next = current ?? state;
          if (next.pendingRemote?.operationId !== pending.operationId || next.accountId !== pending.accountId || next.credentialRef !== state.credentialRef) return next;
          const { pendingRemote: _pending, lastError: _error, ...rest } = next; return { ...rest, health: "ready" as const };
        });
        return stateStatus(updated, connector);
      }
      const updated = await this.store.updateConnectorState(`${pending.operationId}:conflict`, connector, current => ({ ...(current ?? state), health: "partial", lastError: "Remote move is not at its requested destination" }));
      return stateStatus(updated, connector);
    } catch (error) {
      if (signal.aborted) throw new GatewayError("busy", "Connector reconcile was cancelled; the remote effect remains pending", true);
      return stateStatus(state, connector);
    } finally { clearTimeout(deadline); }
  }

  /** Raindrop-only reversible move. Capture must be locally complete and the
   * exact pending effect is durable before the provider mutation is attempted. */
  private async moveRaindrop(input: { commandId: string; itemId: string; source: KnowledgeRecord & { kind: "source" }; expectedRevision?: string; identity?: { provider: string; accountId: string; itemId: string }; connectionId?: string; expectedSetupRevision?: number }, externalSignal?: AbortSignal): Promise<{ status: "moved" | "conflict" | "unsupported" }> {
    const state = await this.store.connectorState("raindrop"); if (!state?.enabled || !state.allowWrites || !state.credentialRef) return { status: "unsupported" };
    try { this.assertCredentialNamespace("raindrop", state.credentialRef); } catch { return { status: "unsupported" }; }
    if (!input.expectedRevision || !input.identity || input.identity.itemId !== input.itemId || input.source.revisionId !== input.expectedRevision) return { status: "conflict" };
    // The caller's object is only a hint. Re-read the exact revision so a held
    // JS record cannot bypass forget/exclusion or a source correction.
    let source: KnowledgeRecord | null;
    try { source = await this.store.read(input.source.id, input.expectedRevision, false, true); } catch { return { status: "conflict" }; }
    if (!source || source.kind !== "source" || !isVerifiedSourceCapture(source) || !["retained", "archived"].includes(source.content.admission?.status ?? "")) return { status: "unsupported" };
    const sourceCollection = source.content.collectionId;
    const targetRole = source.content.admission?.status === "archived" ? "archive" : source.scope;
    const initialAuthority = await this.connectionFor(input.connectionId, "raindrop", Boolean(this.options.connections));
    const destination = initialAuthority?.raindropCollections?.find(mapping => mapping.role === targetRole)?.collectionId;
    if (!sourceCollection || !destination) return { status: "unsupported" };
    // The source head's object reference is part of movement authority; a
    // dangling object must never be acknowledged as a successfully captured
    // item merely because readable text remains in the revision.
    if (!source.content.object || !(await this.store.readObject(source.content.object, { recordId: source.id, revisionId: source.revisionId, includeArchived: true }))) return { status: "conflict" };
    const moveAuthorityCurrent = async (): Promise<boolean> => {
      if (this.options.connections) {
        const instance = await this.connectionFor(input.connectionId, "raindrop", true);
        const targetMapping = instance?.raindropCollections?.find(candidate => candidate.role === targetRole);
        return Boolean(instance && instance.setupRevision === input.expectedSetupRevision && instance.policy.enabled && instance.policy.allowWrites && targetMapping?.collectionId === destination);
      }
      return false;
    };
    if (!(await moveAuthorityCurrent()) || state.accountId !== input.identity.accountId) return { status: "conflict" };
    if (state.paidBudgetCents > 0) return { status: "unsupported" };
    const token = await this.options.credentials.read(state.credentialRef); if (!token) return { status: "unsupported" };
    const capturedIdentity = source.content.identity;
    const incomingOrigin = source.content.origins?.some(origin => origin.identity?.provider === input.identity!.provider && origin.identity.accountId === input.identity!.accountId && origin.identity.itemId === input.identity!.itemId);
    const primaryIdentityMatches = Boolean(capturedIdentity && capturedIdentity.provider === input.identity.provider && capturedIdentity.accountId === input.identity.accountId && capturedIdentity.itemId === input.identity.itemId);
    if ((!primaryIdentityMatches && !incomingOrigin) || input.identity.provider !== "raindrop") return { status: "conflict" };
    const abort = new AbortController();
    const signal = externalSignal ? AbortSignal.any([abort.signal, externalSignal]) : abort.signal;
    // Preflight the provider identity and exact item immediately before
    // recording and applying the effect. A configured collection is not proof
    // of its current location or account.
    await this.verifyRaindropAccount(state, token, signal);
    const preflight = await requestJson(this.http, `https://api.raindrop.io/rest/v1/raindrop/${encodeURIComponent(input.itemId)}`, token, { sleep: this.sleep, signal });
    if (signal.aborted) return { status: "conflict" };
    // Re-read both authorities after the await: native/user revocation and a
    // source forget/correction must win over the preflight snapshot.
    const latestState = await this.store.connectorState("raindrop");
    const latestSource = await this.store.read(source.id, undefined, false, true).catch(() => null);
    if (!latestState?.enabled || !latestState.allowWrites || latestState.accountId !== input.identity.accountId || latestState.credentialRef !== state.credentialRef || !(await moveAuthorityCurrent()) || latestState.paidBudgetCents > 0 || !latestSource || latestSource.kind !== "source" || latestSource.revisionId !== input.expectedRevision || !isVerifiedSourceCapture(latestSource)) return { status: "conflict" };
    await this.verifyRaindropAccount(latestState, token, signal);
    const remoteItemId = id(preflight.value?.item?._id ?? preflight.value?._id, "Raindrop item");
    const originalCollectionId = String(preflight.value?.item?.collection?.$id ?? preflight.value?.collection?.$id ?? "");
    if (!remoteItemId || remoteItemId !== input.identity.itemId || !originalCollectionId) return { status: "conflict" };
    // A crash may occur after the provider move and before local completion.
    // Destination is an acknowledged success; never reclassify or issue PUT again.
    if (originalCollectionId === destination) return { status: "moved" };
    const liveAuthority = await this.connectionFor(input.connectionId, "raindrop", Boolean(this.options.connections));
    if (!liveAuthority?.raindropCollections?.some(mapping => mapping.collectionId === originalCollectionId)) return { status: "conflict" };
    const pending = { operationId: input.commandId, itemId: input.itemId, action: "move" as const, basisRecordId: latestSource.id, basisRevisionId: latestSource.revisionId, provider: input.identity.provider, accountId: input.identity.accountId, originalCollectionId, destination, createdAt: this.now() };
    await this.store.updateConnectorState(input.commandId, "raindrop", current => ({ ...(current ?? latestState), pendingRemote: pending }));
    if (signal.aborted) return { status: "conflict" };
    // Recheck write authority at the effect boundary as well. If permission
    // is revoked after the durable receipt, retain uncertainty for reconcile
    // but never issue the remote PUT.
    const effectState = await this.store.connectorState("raindrop");
    const effectAuthority = await this.connectionFor(input.connectionId, "raindrop", Boolean(this.options.connections));
    if (!effectState?.enabled || !effectState.allowWrites || effectState.accountId !== input.identity.accountId || effectState.credentialRef !== latestState.credentialRef || !(await moveAuthorityCurrent()) || !effectAuthority?.raindropCollections?.some(mapping => mapping.collectionId === originalCollectionId) || effectState.paidBudgetCents > 0) return { status: "conflict" };
    try {
      await requestJson(this.http, `https://api.raindrop.io/rest/v1/raindrop/${encodeURIComponent(input.itemId)}`, token, { method: "PUT", body: { collection: { $id: destination } }, sleep: this.sleep, signal });
      const verified = await requestJson(this.http, `https://api.raindrop.io/rest/v1/raindrop/${encodeURIComponent(input.itemId)}`, token, { sleep: this.sleep, signal });
      const collection = verified.value?.item?.collection?.$id ?? verified.value?.collection?.$id;
      if (String(collection) !== destination) return { status: "conflict" };
      await this.store.updateConnectorState(`${input.commandId}:complete`, "raindrop", current => { const next = current ?? latestState; const { pendingRemote: _pending, ...rest } = next; return rest; });
      return { status: "moved" };
    } catch { return { status: "conflict" }; }
  }
}
