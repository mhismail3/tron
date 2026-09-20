import { createHash, randomUUID } from "node:crypto";
import type { KnowledgeAssessmentApprovalRequest, KnowledgeConnectorConfigurationRequest, KnowledgeConnectorRunRequest, KnowledgeConnectorState, KnowledgeConnectorStatus, KnowledgeAction, KnowledgeRecord, KnowledgeRaindropRequest, KnowledgeRaindropIntakeRequest } from "./knowledge-contract.js";
import { captureSource, isVerifiedSourceCapture } from "./source-capture.js";
import type { SourceAssessmentModel } from "./source-capture.js";
import { triageSource } from "./source-triage.js";
import { GatewayError } from "../errors.js";
import { AsyncMutex } from "../util/async-mutex.js";
import type { KnowledgeStore } from "./knowledge-store.js";
import type { ConnectorCredentialStore } from "./connector-credentials.js";
import { currentInvocationContext } from "../extensions/owner-attribution.js";
import { jevInputDigest, jevProfileVersion, JEV_MODEL } from "./jev-assessment.js";

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
}

interface PendingItem { id: string; title: string; url: string; excerpt?: string; annotation?: string; publishedAt?: string; collectionId?: string; apiPayload?: string }
interface Page { items: PendingItem[]; next?: string; accountId?: string; }
interface RaindropItemDTO { _id?: unknown; title?: unknown; link?: unknown; excerpt?: unknown; note?: unknown; created?: unknown; collection?: unknown; [key: string]: unknown; }
interface XBookmarkDTO { id?: unknown; text?: unknown; created_at?: unknown; author_id?: unknown; entities?: unknown; }

function bad(message: string): GatewayError { return new GatewayError("invalid_request", message); }
function command(base: string, suffix: string): string {
  const normalizedBase = base.replace(/[^A-Za-z0-9._:-]/g, "_"); const normalizedSuffix = suffix.replace(/[^A-Za-z0-9._:-]/g, "_");
  const digest = createHash("sha256").update(`${base}\u0000${suffix}`).digest("hex").slice(0, 16);
  return `${normalizedBase.slice(0, 72)}:${normalizedSuffix.slice(0, 64)}:${digest}`.slice(0, 160);
}
function id(value: unknown, label: string): string | undefined { return typeof value === "string" && value.length > 0 && value.length <= 512 ? value : typeof value === "number" && Number.isSafeInteger(value) ? String(value) : undefined; }
function text(value: unknown, maximum = 100_000): string | undefined { return typeof value === "string" && value.length > 0 ? value.slice(0, maximum) : undefined; }
function url(value: unknown): string | undefined { if (typeof value !== "string") return undefined; try { const parsed = new URL(value); return ["http:", "https:"].includes(parsed.protocol) && !parsed.username && !parsed.password ? parsed.toString() : undefined; } catch { return undefined; } }
function retryable(status: number): boolean { return status === 408 || status === 425 || status === 429 || status >= 500; }
function authFailure(status: number): boolean { return status === 401 || status === 403; }

class ConnectorBodyTooLarge extends Error { constructor() { super("Connector response exceeded its bounded body limit"); } }

async function boundedResponseText(response: Response): Promise<string> {
  if (!response.body) return "";
  const reader = response.body.getReader(); const chunks: Uint8Array[] = []; let total = 0;
  try {
    for (;;) { const next = await reader.read(); if (next.done) break; if (!next.value) continue; const remaining = BODY_LIMIT - total; if (next.value.byteLength > remaining) { await reader.cancel(); throw new ConnectorBodyTooLarge(); } chunks.push(next.value); total += next.value.byteLength; if (total === BODY_LIMIT) { const extra = await reader.read(); if (!extra.done) { await reader.cancel(); throw new ConnectorBodyTooLarge(); } break; } }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(total); let offset = 0; for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return new TextDecoder().decode(bytes);
}
async function defaultHTTP(input: string, init: { method?: "GET" | "PUT" | "POST" | "DELETE"; headers: Record<string, string>; body?: string; signal: AbortSignal }): Promise<ConnectorHTTPResponse> {
  const timeout = AbortSignal.timeout(15_000); const signal = AbortSignal.any([init.signal, timeout]);
  const response = await fetch(input, { method: init.method ?? "GET", headers: init.headers, ...(init.body !== undefined ? { body: init.body } : {}), redirect: "error", signal });
  return { status: response.status, headers: response.headers, body: await boundedResponseText(response) };
}

async function requestJson(http: ConnectorHTTP, endpoint: string, token: string | (() => Promise<string>), options: { method?: "GET" | "PUT" | "POST" | "DELETE"; body?: unknown; sleep: (milliseconds: number) => Promise<void>; signal: AbortSignal; maxAttempts?: number; beforeAttempt?: () => Promise<void> }): Promise<{ status: number; value: any; headers: Headers }> {
  const retrySafe = !options.method || options.method === "GET";
  const maxAttempts = retrySafe ? (options.maxAttempts ?? RETRIES) : 1;
  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    await options.beforeAttempt?.();
    const attemptToken = typeof token === "function" ? await token() : token;
    if (options.signal.aborted) throw options.signal.reason instanceof Error ? options.signal.reason : new Error("Connector request cancelled");
    let result: ConnectorHTTPResponse;
    try {
      result = await http(endpoint, { ...(options.method ? { method: options.method } : {}), headers: { authorization: `Bearer ${attemptToken}`, accept: "application/json", ...(options.body !== undefined ? { "content-type": "application/json" } : {}) }, ...(options.body !== undefined ? { body: JSON.stringify(options.body) } : {}), signal: options.signal });
    } catch (error) {
      if (options.signal.aborted || error instanceof ConnectorBodyTooLarge) throw error;
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
function stateStatus(state: KnowledgeConnectorState | undefined, connector: Connector): KnowledgeConnectorStatus {
  const value = state ?? initial(connector);
  const configured = Boolean(value.credentialRef && value.accountId && value.scope);
  // Health is operational state; configuration truth is derived from the
  // current authority so an old unconfigured marker cannot contradict a valid
  // enabled configuration. Disabled or incomplete connectors remain honest.
  const health = !configured || !value.enabled ? "unconfigured" : (value.health === "unconfigured" ? "ready" : value.health);
  return { connector, configured, enabled: value.enabled, health, ...(value.accountId ? { accountId: value.accountId } : {}), ...(value.scope ? { scope: value.scope } : {}), ...(value.lastRunAt ? { lastRunAt: value.lastRunAt } : {}), ...(value.lastError ? { lastError: value.lastError } : {}), remaining: value.remaining, pending: value.pending.length, paidBudgetCents: value.paidBudgetCents, allowWrites: value.allowWrites, recurringApproved: value.recurringApproved, paidAccessApproved: value.paidAccessApproved, ...(value.assessmentPilot ? { assessmentPilot: value.assessmentPilot } : {}), ...(value.assessmentApprovals ? { assessmentApprovals: value.assessmentApprovals } : {}) };
}
function parseCollection(item: RaindropItemDTO): string | undefined {
  if (!item.collection || typeof item.collection !== "object") return undefined;
  return id((item.collection as Record<string, unknown>).$id, "collection");
}
function parseRaindrop(value: any): PendingItem[] {
  if (!value || !Array.isArray(value.items)) return [];
  return value.items.map((item: RaindropItemDTO) => {
    const itemId = id(item._id, "Raindrop item"); const link = url(item.link); if (!itemId || !link) return undefined;
    const apiPayload = JSON.stringify(item); const metadataComplete = Buffer.byteLength(apiPayload, "utf8") <= 100_000;
    return { id: itemId, title: text(item.title, 512) ?? link, url: link, ...(text(item.excerpt) ? { excerpt: text(item.excerpt) } : {}), ...(text(item.note, 20_000) ? { annotation: text(item.note, 20_000) } : {}), ...(text(item.created, 80) ? { publishedAt: text(item.created, 80) } : {}), ...(parseCollection(item) ? { collectionId: parseCollection(item) } : {}), ...(metadataComplete ? { apiPayload } : {}), metadataComplete };
  }).filter((item: PendingItem | undefined): item is PendingItem => Boolean(item));
}
function parseX(value: any): PendingItem[] {
  if (!value || !Array.isArray(value.data)) return [];
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
  private readonly lanes = new Map<Connector, AsyncMutex>();
  constructor(private readonly store: KnowledgeStore, private readonly options: KnowledgeConnectorOptions) {
    this.http = options.http ?? defaultHTTP; this.sleep = options.sleep ?? (milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds))); this.now = options.now ?? (() => new Date().toISOString());
  }
  private lane(connector: Connector): AsyncMutex { const existing = this.lanes.get(connector); if (existing) return existing; const created = new AsyncMutex(); this.lanes.set(connector, created); return created; }

  async invoke(action: KnowledgeAction, signal?: AbortSignal): Promise<unknown> {
    if (action.operation === "knowledge.raindrop.read") return this.lane("raindrop").run(() => this.readRaindrop(action.request, signal));
    if (action.operation === "knowledge.connector.configure") return this.lane(action.request.connector).run(() => this.configure(action.request));
    if (action.operation === "knowledge.connector.assessment.approve") return this.lane("raindrop").run(() => this.approveAssessment(action.request));
    if (action.operation === "knowledge.connector.status") return stateStatus(await this.store.connectorState(action.request.connector), action.request.connector);
    if (action.operation === "knowledge.connector.run") return this.lane(action.request.connector).run(() => this.run(action.request, signal));
    if (action.operation === "knowledge.raindrop.intake") return this.lane("raindrop").run(() => this.intake(action.request, signal));
    throw bad("Unsupported knowledge connector operation");
  }

  private async readRaindrop(request: KnowledgeRaindropRequest, externalSignal?: AbortSignal): Promise<Record<string, unknown>> {
    const state = await this.store.connectorState("raindrop");
    if (!state?.enabled || !state.accountId || !state.credentialRef) throw new GatewayError("unsupported", "Raindrop connector is not configured; set the numeric Raindrop user _id in accountId");
    if (!/^\d+$/.test(state.accountId)) throw new GatewayError("invalid_request", "Raindrop accountId must be the numeric user _id; obtain it through a secure local /user check, never by sharing the token");
    const token = await this.options.credentials.read(state.credentialRef);
    if (!token) throw new GatewayError("unsupported", "Raindrop credential is unavailable");
    const controller = new AbortController();
    const signal = externalSignal ? AbortSignal.any([controller.signal, externalSignal]) : controller.signal;
    const deadline = setTimeout(() => controller.abort(new Error("Raindrop read deadline exceeded")), RUN_DEADLINE_MS);
    deadline.unref?.();
    const sleep = async (milliseconds: number) => {
      await new Promise<void>((resolve, reject) => {
        const timer = setTimeout(() => { signal.removeEventListener("abort", abort); resolve(); }, milliseconds);
        const abort = () => { clearTimeout(timer); signal.removeEventListener("abort", abort); reject(signal.reason instanceof Error ? signal.reason : new Error("Raindrop read cancelled")); };
        if (signal.aborted) abort(); else signal.addEventListener("abort", abort, { once: true });
      });
      if (signal.aborted) throw signal.reason instanceof Error ? signal.reason : new Error("Raindrop read cancelled");
    };
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
      const user = identity.value?.user ?? identity.value;
      const authenticatedID = id(user?._id ?? user?.id, "Raindrop account");
      if (!authenticatedID || authenticatedID !== state.accountId) throw new GatewayError("conflict", "Raindrop authenticated account does not match configured account");
      let endpoint: string;
      let value: unknown;
      let headers = identity.headers;
      const read = request.read;
      if (read.operation === "user") {
        const raw = JSON.stringify(identity.value);
        if (Buffer.byteLength(raw, "utf8") > BODY_LIMIT) throw new GatewayError("invalid_request", "Raindrop metadata exceeded 2 MB; reduce the requested metadata");
        return { operation: read.operation, data: identity.value, rateLimit: rate(identity.headers) };
      }
      const live = await this.store.connectorState("raindrop");
      if (!live?.enabled || live.accountId !== state.accountId || live.credentialRef !== state.credentialRef) throw new GatewayError("conflict", "Raindrop configuration changed during read");
      if ((read.operation === "bookmarks" || read.operation === "highlights") && (!Number.isSafeInteger(read.page ?? 0) || (read.page ?? 0) < 0 || (read.page ?? 0) > 1_000_000 || !Number.isSafeInteger(read.perpage ?? 50) || (read.perpage ?? 50) < 1 || (read.perpage ?? 50) > 50)) throw bad("Raindrop page must be 0..1000000 and perpage must be 1..50");
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
          if (read.search !== undefined && (typeof read.search !== "string" || read.search.length > 512)) throw bad("Raindrop search exceeds its limit");
          if (read.sort !== undefined && (typeof read.sort !== "string" || read.sort.length > 64)) throw bad("Raindrop sort exceeds its limit");
          if (read.search) params.set("search", read.search);
          if (read.sort) params.set("sort", read.sort);
          if (read.nested !== undefined) params.set("nested", String(read.nested));
          endpoint = `https://api.raindrop.io/rest/v1/raindrops/${encodeURIComponent(collection)}?${params}`;
        } else if (read.operation === "tags") {
          endpoint = "https://api.raindrop.io/rest/v1/tags";
        } else if (read.operation === "highlights") {
          const params = new URLSearchParams({ page: String(read.page ?? 0), perpage: String(read.perpage ?? 50) });
          if (read.collectionId) {
            if (!/^-?\d{1,18}$/.test(read.collectionId)) throw bad("Collection ID is invalid");
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
      if (error instanceof GatewayError) throw error;
      if (error instanceof ConnectorBodyTooLarge) throw new GatewayError("invalid_request", "Raindrop metadata exceeded 2 MB; reduce perpage or request narrower pages");
      if (error instanceof ConnectorAPIError || error instanceof ConnectorShapeError) throw new GatewayError("internal", "Raindrop returned an unusable response", true);
      if (error instanceof ConnectorHTTPError && authFailure(error.status)) throw new GatewayError("unsupported", "Raindrop authentication failed");
      if (error instanceof ConnectorHTTPError && error.status === 429) throw new GatewayError("internal", "Raindrop rate limit reached; retry after the provider reset", true);
      if (signal.aborted) throw new GatewayError("busy", "Raindrop read was cancelled", true);
      throw new GatewayError("internal", "Raindrop provider request failed", true);
    } finally { clearTimeout(deadline); }
  }

  private async configure(request: KnowledgeConnectorConfigurationRequest): Promise<KnowledgeConnectorStatus> {
    if (request.accountId !== undefined && (request.accountId.length < 1 || request.accountId.length > 256 || /[\r\n]/.test(request.accountId))) throw bad("Connector account is invalid");
    if (request.scope !== undefined && (request.scope.length < 1 || request.scope.length > 256 || /[\r\n]/.test(request.scope))) throw bad("Connector scope is invalid");
    if (request.destination !== undefined && (request.destination.length < 1 || request.destination.length > 256 || /[\r\n]/.test(request.destination))) throw bad("Connector destination is invalid");
    if (request.credentialRef !== undefined && !/^connector:[a-z][a-z0-9-]{0,31}:[A-Za-z0-9._:-]{1,160}$/.test(request.credentialRef)) throw bad("Connector credential reference is invalid");
    if (request.paidBudgetCents !== undefined && (!Number.isSafeInteger(request.paidBudgetCents) || request.paidBudgetCents < 0 || request.paidBudgetCents > 1_000_000)) throw bad("Connector paid budget is invalid");
    const current = await this.store.connectorState(request.connector);
    const base = current ?? initial(request.connector);
    const identityChanged = Boolean(current && ((request.accountId !== undefined && request.accountId !== current.accountId) || (request.scope !== undefined && request.scope !== current.scope) || (request.credentialRef !== undefined && request.credentialRef !== current.credentialRef)));
    if (identityChanged && (current?.pendingRemote || current?.assessmentPilot || (current?.assessmentApprovals?.length ?? 0) > 0 || Object.keys(current?.assessmentAttempts ?? {}).length > 0)) throw new GatewayError("conflict", "Connector identity cannot change while an approved pilot or remote effect is active");
    const nextAccountId = request.accountId ?? current?.accountId;
    const nextScope = request.scope ?? current?.scope;
    const nextCredentialRef = request.credentialRef ?? current?.credentialRef;
    const nextDestination = request.destination ?? current?.destination;
    const next: KnowledgeConnectorState = identityChanged ? {
      ...initial(request.connector), enabled: request.enabled,
      ...(nextAccountId ? { accountId: nextAccountId } : {}),
      ...(nextScope ? { scope: nextScope } : {}),
      ...(nextCredentialRef ? { credentialRef: nextCredentialRef } : {}),
      ...(nextDestination ? { destination: nextDestination } : {}),
      allowWrites: request.allowWrites ?? false, paidAccessApproved: request.paidAccessApproved ?? false,
      paidBudgetCents: request.paidBudgetCents ?? 0, recurringApproved: request.recurringApproved ?? false,
      health: request.enabled && Boolean(nextCredentialRef && nextAccountId && nextScope) ? "ready" : "unconfigured",
    } : { ...base, enabled: request.enabled, ...(request.accountId !== undefined ? { accountId: request.accountId } : {}), ...(request.scope !== undefined ? { scope: request.scope } : {}), ...(request.destination !== undefined ? { destination: request.destination } : {}), ...(request.credentialRef !== undefined ? { credentialRef: request.credentialRef } : {}), allowWrites: request.allowWrites ?? current?.allowWrites ?? false, paidAccessApproved: request.paidAccessApproved ?? current?.paidAccessApproved ?? false, paidBudgetCents: request.paidBudgetCents ?? current?.paidBudgetCents ?? 0, recurringApproved: request.recurringApproved ?? current?.recurringApproved ?? false, health: request.enabled && (request.credentialRef ?? current?.credentialRef) && (request.accountId ?? current?.accountId) && (request.scope ?? current?.scope) ? "ready" : "unconfigured" };
    delete next.lastError;
    const saved = await this.store.updateConnectorState(request.commandId, request.connector, () => next);
    return stateStatus(saved, request.connector);
  }

  private async approveAssessment(request: KnowledgeAssessmentApprovalRequest): Promise<KnowledgeConnectorStatus> {
    if (!request.id || request.id.length > 160 || !/^[A-Za-z0-9._:-]+$/.test(request.id)) throw bad("Assessment approval ID is invalid");
    if (!Number.isSafeInteger(request.maxItems) || request.maxItems < 1 || request.maxItems > 10 || !Number.isSafeInteger(request.budgetCents) || request.budgetCents < 1 || request.budgetCents > 100) throw bad("Assessment approval remains bounded to 10 items and 100 cents");
    if (request.itemIds !== undefined && (!Array.isArray(request.itemIds) || request.itemIds.length === 0 || request.itemIds.length > request.maxItems || new Set(request.itemIds).size !== request.itemIds.length || request.itemIds.some(item => typeof item !== "string" || !/^\d{1,18}$/.test(item)))) throw bad("Explicit assessment identities must be unique bounded Raindrop item IDs");
    const profileVersion = jevProfileVersion((await this.store.config()).currentInterests ?? []);
    const state = await this.store.connectorState("raindrop");
    if (!state?.enabled || !state.accountId || !state.scope) throw new GatewayError("unsupported", "Raindrop connector is not configured");
    const saved = await this.store.updateConnectorState(request.commandId, "raindrop", current => {
      const next = current ?? state;
      if (next.assessmentPilot?.id === request.id || next.assessmentApprovals?.some(item => item.id === request.id)) throw new GatewayError("conflict", "Assessment approval ID already exists; use a new explicit cohort ID");
      if (next.pendingRemote) throw new GatewayError("conflict", "Reconcile the unresolved remote effect before approving another cohort");
      if (request.itemIds?.some(id => !next.pending.some(item => item.id === id && item.collectionId === next.scope))) throw new GatewayError("conflict", "Explicit assessment identities must remain pending in the configured collection");
      const approval = { id: request.id, maxItems: request.maxItems, budgetCents: request.budgetCents, usedItems: 0, reservedCents: 0, accountId: next.accountId!, sourceCollection: next.scope!, profileVersion, itemIds: [...(request.itemIds ?? [])] };
      return { ...next, assessmentApprovals: [...(next.assessmentApprovals ?? []), approval] };
    }, { connector: "raindrop", approval: { id: request.id, maxItems: request.maxItems, budgetCents: request.budgetCents, ...(request.itemIds ? { itemIds: request.itemIds } : {}) } });
    return stateStatus(saved, "raindrop");
  }

  private async reserveAssessment(commandId: string, itemId: string, pilot: NonNullable<KnowledgeRaindropIntakeRequest["pilot"]>, cohortId = pilot.id): Promise<void> {
    const profileVersion = jevProfileVersion((await this.store.config()).currentInterests ?? []);
    // Reservation is a fresh paid-attempt fence on every invocation. Reusing
    // the intake command here would replay an old successful mutation receipt
    // and let a later model POST bypass the durable item/cohort fence.
    await this.store.updateConnectorState(command(`${commandId}:${randomUUID()}`, "reserve"), "raindrop", current => {
      const state = current ?? initial("raindrop");
      const attempts = state.assessmentAttempts ?? {};
      const attemptKey = state.assessmentPilot?.id === cohortId ? itemId : `${cohortId}:${itemId}`;
      if (attempts[attemptKey] || Object.entries(attempts).some(([key, attempt]) => (attempt?.itemId === itemId && attempt?.cohortId === cohortId) || (cohortId === state.assessmentPilot?.id && key === itemId))) throw new GatewayError("conflict", "This source already has a paid Jev attempt in this cohort; reconcile it instead of replaying it");
      const existing = cohortId === state.assessmentPilot?.id ? state.assessmentPilot : state.assessmentApprovals?.find(item => item.id === cohortId);
      if (!existing || existing.accountId !== state.accountId || existing.sourceCollection !== state.scope || existing.profileVersion !== profileVersion || existing.id !== pilot.id) throw new GatewayError("conflict", "Assessment cohort authority changed; use the existing approval");
      const attemptedItems = Object.values(attempts).filter(attempt => attempt?.cohortId === cohortId || (cohortId === state.assessmentPilot?.id && !attempt?.cohortId)).length;
      if (attemptedItems >= existing.maxItems || existing.reservedCents + 1 > existing.budgetCents) throw new GatewayError("conflict", "Assessment cohort allowance is exhausted");
      const nextAuthority = { ...existing, reservedCents: existing.reservedCents + 1 };
      return {
        ...state,
        ...(cohortId === state.assessmentPilot?.id ? { assessmentPilot: nextAuthority } : { assessmentApprovals: (state.assessmentApprovals ?? []).map(item => item.id === cohortId ? nextAuthority : item) }),
        assessmentAttempts: { ...attempts, [attemptKey]: { itemId, cohortId, status: "dispatched" as const, chargeCents: 1 } },
      };
    });
  }

  private async settleAssessment(commandId: string, itemId: string, cohortId: string, usage?: { inputTokens: number; outputTokens: number; estimatedCostCents: number }): Promise<void> {
    await this.store.updateConnectorState(`${commandId}:settle`, "raindrop", current => {
      const state = current ?? initial("raindrop");
      const key = cohortId === state.assessmentPilot?.id ? itemId : `${cohortId}:${itemId}`;
      const attempt = state.assessmentAttempts?.[key];
      if (!attempt || attempt.status === "settled") return state;
      const authority = cohortId === state.assessmentPilot?.id ? state.assessmentPilot : state.assessmentApprovals?.find(item => item.id === cohortId);
      if (!authority) return state;
      const settled = { ...attempt, status: "settled" as const, ...(usage ? { inputTokens: usage.inputTokens, outputTokens: usage.outputTokens, estimatedCostCents: usage.estimatedCostCents } : {}) };
      return {
        ...state,
        ...(cohortId === state.assessmentPilot?.id ? { assessmentPilot: { ...authority, usedItems: authority.usedItems + 1 } } : { assessmentApprovals: (state.assessmentApprovals ?? []).map(item => item.id === cohortId ? { ...item, usedItems: item.usedItems + 1 } : item) }),
        assessmentAttempts: { ...(state.assessmentAttempts ?? {}), [key]: settled },
      };
    });
  }

  private async attachProviderPayload(item: PendingItem, source: KnowledgeRecord & { kind: "source" }, commandId: string): Promise<KnowledgeRecord & { kind: "source" }> {
    if (!item.apiPayload) return source;
    const apiObject = await this.store.putObject(new TextEncoder().encode(item.apiPayload), "application/json");
    const representations = source.content.representations ?? [];
    if (representations.some(value => value.kind === "provider-api" && value.object.hash === apiObject.hash)) return source;
    const updated = await this.store.captureSource({ commandId, expectedRevision: source.revisionId, record: { kind: "source", id: source.id, createdAt: source.createdAt, scope: source.scope, provenance: source.provenance, relations: source.relations, ...(source.temporal ? { temporal: source.temporal } : {}), content: { ...source.content, representations: [...representations, { kind: "provider-api", object: apiObject, mediaType: "application/json" }] } } });
    if (updated.record.kind !== "source") throw new Error("Provider payload attachment returned a non-source record");
    return updated.record;
  }

  private async markUnsafeLinkedCapture(item: PendingItem, source: KnowledgeRecord & { kind: "source" }, commandId: string): Promise<KnowledgeRecord & { kind: "source" }> {
    let disposition = source.content.captureDisposition;
    try {
      const host = new URL(item.url).hostname.toLowerCase();
      if (host === "x.com" || host.endsWith(".x.com") || host === "twitter.com" || host.endsWith(".twitter.com")) disposition = "reference-only";
      else if (host === "github.com" || host.endsWith(".github.com")) disposition = disposition === "complete" ? "partial" : disposition;
    } catch { disposition = "reference-only"; }
    if (disposition === source.content.captureDisposition) return source;
    const updated = await this.store.captureSource({ commandId, expectedRevision: source.revisionId, record: { kind: "source", id: source.id, createdAt: source.createdAt, scope: source.scope, provenance: source.provenance, relations: source.relations, ...(source.temporal ? { temporal: source.temporal } : {}), content: { ...source.content, captureDisposition: disposition } } });
    if (updated.record.kind !== "source") throw new Error("Linked capture quality update returned a non-source record");
    return updated.record;
  }

  private async intake(request: KnowledgeRaindropIntakeRequest, externalSignal?: AbortSignal): Promise<Record<string, unknown>> {
    const state = await this.store.connectorState("raindrop");
    if (!state?.enabled || !state.credentialRef || !state.accountId || !state.scope) throw new GatewayError("unsupported", "Raindrop connector is not configured");
    if (currentInvocationContext()?.operationId?.startsWith("automation:") && !state.recurringApproved) throw new GatewayError("unsupported", "Raindrop intake recurrence is not approved");
    if (!/^\d+$/.test(state.accountId)) throw new GatewayError("invalid_request", "Raindrop accountId must be the numeric user _id");
    if (request.limit !== undefined && (!Number.isSafeInteger(request.limit) || request.limit < 1 || request.limit > 10)) throw bad("Raindrop intake limit must be 1..10");
    if (request.sourceCollection !== undefined && !/^-?\d{1,18}$/.test(request.sourceCollection)) throw bad("Raindrop intake source collection is invalid");
    const limit = request.limit ?? 10;
    const token = await this.options.credentials.read(state.credentialRef);
    if (!token) throw new GatewayError("unsupported", "Raindrop credential is unavailable");
    const controller = new AbortController(); const signal = externalSignal ? AbortSignal.any([controller.signal, externalSignal]) : controller.signal;
    const deadline = setTimeout(() => controller.abort(new Error("Raindrop intake deadline exceeded")), RUN_DEADLINE_MS); deadline.unref?.();
    try {
      const identity = await requestJson(this.http, "https://api.raindrop.io/rest/v1/user", token, { sleep: this.sleep, signal });
      const authenticatedID = id(identity.value?.user?._id ?? identity.value?.user?.id ?? identity.value?._id ?? identity.value?.id, "Raindrop account");
      if (!authenticatedID || authenticatedID !== state.accountId) throw new GatewayError("conflict", "Raindrop authenticated account does not match configured account");
      await this.reconcile("raindrop");
      if ((await this.store.connectorState("raindrop"))?.pendingRemote) throw new GatewayError("conflict", "Raindrop has an unresolved remote effect");
      const sourceCollection = request.sourceCollection ?? state.scope;
      if (sourceCollection !== state.scope) throw new GatewayError("conflict", "Intake source collection must match the configured connector scope");
      const profileVersion = jevProfileVersion((await this.store.config()).currentInterests ?? []);
      const approvedPilot = request.pilot;
      if (!request.dryRun) {
        if (!approvedPilot || !approvedPilot.id || !Number.isSafeInteger(approvedPilot.maxItems) || approvedPilot.maxItems < 1 || approvedPilot.maxItems > 10 || !Number.isSafeInteger(approvedPilot.budgetCents) || approvedPilot.budgetCents < 1 || approvedPilot.budgetCents > 100) throw bad("A bounded Jev pilot approval is required");
        if (state.assessmentPilot && state.assessmentPilot.id === approvedPilot.id && (state.assessmentPilot.maxItems !== approvedPilot.maxItems || state.assessmentPilot.budgetCents !== approvedPilot.budgetCents || state.assessmentPilot.accountId !== state.accountId || state.assessmentPilot.sourceCollection !== sourceCollection || state.assessmentPilot.profileVersion !== profileVersion)) throw new GatewayError("conflict", "Jev pilot authority changed; use the existing approval");
        if (state.assessmentPilot && state.assessmentPilot.id !== approvedPilot.id && !state.assessmentApprovals?.some(item => item.id === approvedPilot.id)) throw new GatewayError("conflict", "Later assessment requires a separately approved cohort");
      }
      const discovered = await this.discover("raindrop", { ...state, scope: sourceCollection }, token, limit, signal);
      let live = await this.store.connectorState("raindrop") ?? state;
      if (request.dryRun) return { connector: "raindrop", dryRun: true, discovered: discovered.discovered, pending: live.pending.filter(item => item.collectionId === sourceCollection).slice(0, limit).map(item => ({ id: item.id, title: item.title, url: item.url, metadataComplete: item.metadataComplete !== false })), assessment: "not-run", remoteWrites: false };
      if (!approvedPilot) throw new GatewayError("invalid_request", "A bounded Jev pilot approval is required");
      let authority = live.assessmentPilot?.id === approvedPilot.id ? live.assessmentPilot : live.assessmentApprovals?.find(item => item.id === approvedPilot.id);
      if (!authority && !live.assessmentPilot) {
        const itemIds = live.pending.filter(item => item.collectionId === sourceCollection).slice(0, Math.min(limit, approvedPilot.maxItems)).map(item => item.id);
        live = await this.store.updateConnectorState(command(request.commandId, "cohort"), "raindrop", current => ({ ...(current ?? live), assessmentPilot: { id: approvedPilot.id, maxItems: approvedPilot.maxItems, budgetCents: approvedPilot.budgetCents, usedItems: 0, reservedCents: 0, accountId: state.accountId!, sourceCollection, profileVersion, itemIds } }));
        authority = live.assessmentPilot;
      }
      if (!authority) throw new GatewayError("conflict", "Assessment cohort approval is unavailable");
      if (authority.itemIds.length === 0) {
        const alreadyCohorted = new Set([...(live.assessmentPilot?.itemIds ?? []), ...(live.assessmentApprovals ?? []).flatMap(item => item.itemIds)]);
        const itemIds = live.pending.filter(item => item.collectionId === sourceCollection && !alreadyCohorted.has(item.id)).slice(0, Math.min(limit, authority!.maxItems)).map(item => item.id);
        live = await this.store.updateConnectorState(command(request.commandId, `cohort-${authority.id}`), "raindrop", current => {
          const next = current ?? live; const updated = { ...authority!, itemIds };
          return authority!.id === next.assessmentPilot?.id ? { ...next, assessmentPilot: updated } : { ...next, assessmentApprovals: (next.assessmentApprovals ?? []).map(item => item.id === authority!.id ? updated : item) };
        });
        authority = authority.id === live.assessmentPilot?.id ? live.assessmentPilot : live.assessmentApprovals?.find(item => item.id === authority!.id);
      }
      if (!authority) throw new GatewayError("conflict", "Assessment cohort approval is unavailable");
      if (authority.maxItems !== approvedPilot.maxItems || authority.budgetCents !== approvedPilot.budgetCents || authority.accountId !== live.accountId || authority.sourceCollection !== sourceCollection || authority.profileVersion !== profileVersion) throw new GatewayError("conflict", "Assessment cohort authority changed; use the existing approval");
      const cohortAuthority = authority;
      const cohortId = cohortAuthority.id;
      const cohort = cohortAuthority.itemIds;
      let captured = 0; let retained = 0; let archived = 0; let pending = 0; let assessmentFailed = 0; let moved = 0; let lastError: string | undefined;
      const approvedItems = cohort.map(itemId => live.pending.find(item => item.id === itemId)).filter((item): item is NonNullable<typeof item> => Boolean(item));
      for (const item of approvedItems) {
        if ((await this.store.connectorState("raindrop"))?.pendingRemote) { lastError = "Raindrop has an unresolved remote effect"; break; }
        try {
          live = await this.store.connectorState("raindrop") ?? live;
          const result = await captureSource(this.store, { commandId: command(request.commandId, `capture-${item.id}`), url: item.url, scope: "research", title: item.title, origin: "connector", ...(item.collectionId ? { collectionId: item.collectionId } : {}), identity: { provider: "raindrop", accountId: live.accountId!, itemId: item.id }, ...(item.annotation ? { annotations: [{ text: item.annotation }] } : {}) }, { signal, ...(this.options.sourceFetch ? { fetcher: (sourceUrl, init) => this.options.sourceFetch!(sourceUrl.toString(), item.excerpt, init?.signal ?? signal) } : {}), ...(this.options.resolveHost ? { resolveHost: this.options.resolveHost } : {}) });
          let source = await this.attachProviderPayload(item, result.record, command(request.commandId, `metadata-${item.id}`));
          source = await this.markUnsafeLinkedCapture(item, source, command(request.commandId, `quality-${item.id}`));
          captured += 1;
          if (source.content.captureDisposition !== "complete" || item.metadataComplete === false || !source.content.text) {
            await this.store.setSourceAdmission({ commandId: command(request.commandId, `pending-${item.id}`), recordId: source.id, expectedRevision: source.revisionId, status: "pending", reason: "Capture is incomplete or provider metadata is bounded without complete linked evidence" });
            pending += 1; continue;
          }
          let assessment = source.content.assessment;
          const interests = (await this.store.config()).currentInterests ?? [];
          const assessmentCurrent = assessment?.model === "jev-1.13.0" && assessment.profileVersion === jevProfileVersion(interests) && assessment.rubricVersion === "tron-source-rubric-v2" && assessment.inputDigest === jevInputDigest({ title: source.content.title, text: source.content.text ?? "", interests, source: { ...(source.content.uri ? { uri: source.content.uri } : {}), ...(source.content.mediaType ? { mediaType: source.content.mediaType } : {}), ...(source.content.collectionId ? { collectionId: source.content.collectionId } : {}), captureDisposition: source.content.captureDisposition, capturedAt: source.content.capturedAt } }, interests);
          if (!assessmentCurrent) {
            if (!this.options.assessment) { pending += 1; lastError = "Jev source assessment is not configured"; continue; }
            let dispatched = false;
            try {
              const triaged = await triageSource(this.store, { commandId: command(request.commandId, `assess-${item.id}`), sourceId: source.id, expectedRevision: source.revisionId, signal, beforeDispatch: async () => { await this.reserveAssessment(command(request.commandId, `assess-${item.id}`), item.id, approvedPilot, cohortId); dispatched = true; } }, this.options.assessment);
              assessment = triaged.assessment; source = triaged.source;
              const usage = assessment?.usage ? { inputTokens: assessment.usage.inputTokens, outputTokens: assessment.usage.outputTokens, estimatedCostCents: assessment.usage.estimatedCostCents } : undefined;
              await this.settleAssessment(command(request.commandId, `assess-${item.id}`), item.id, cohortId, usage);
            } catch (error) { assessmentFailed += 1; pending += 1; lastError = dispatched ? "Jev assessment outcome is uncertain; reconcile before retrying" : (error instanceof Error ? error.message : "Jev assessment failed"); continue; }
          }
          const finalInterests = (await this.store.config()).currentInterests ?? [];
          if (!assessment || (assessment.model === JEV_MODEL && assessment.inputDigest !== undefined && (assessment.profileVersion !== jevProfileVersion(finalInterests) || assessment.inputDigest !== jevInputDigest({ title: source.content.title, text: source.content.text ?? "", interests: finalInterests, source: { ...(source.content.uri ? { uri: source.content.uri } : {}), ...(source.content.mediaType ? { mediaType: source.content.mediaType } : {}), ...(source.content.collectionId ? { collectionId: source.content.collectionId } : {}), captureDisposition: source.content.captureDisposition, capturedAt: source.content.capturedAt } }, finalInterests)))) throw new GatewayError("conflict", "Source assessment authority changed before admission");
          const status = assessment.recommendation === "archived" ? "archived" : "retained";
          const admitted = source.content.admission?.status === status ? source : (await this.store.setSourceAdmission({ commandId: command(request.commandId, `admit-${item.id}`), recordId: source.id, expectedRevision: source.revisionId, status, reason: status === "archived" ? "Jev clear low-value classification; recoverable intake archive" : "Jev intake accepted source", ...(assessment?.profileVersion ? { profileVersion: assessment.profileVersion } : {}), ...(assessment?.rubricVersion ? { rubricVersion: assessment.rubricVersion } : {}) })).record as KnowledgeRecord & { kind: "source" };
          if (status === "archived") archived += 1; else retained += 1;
          if (!live.allowWrites || !live.destination || item.collectionId === live.destination) { pending += 1; continue; }
          const movedResult = await this.moveRaindrop({ commandId: command(request.commandId, `move-${item.id}`), itemId: item.id, source: admitted, expectedRevision: admitted.revisionId, identity: { provider: "raindrop", accountId: live.accountId!, itemId: item.id }, sourceCollection, destination: live.destination }, signal);
          if (movedResult.status !== "moved") {
            pending += 1; lastError = "Raindrop destination move could not be verified";
            if ((await this.store.connectorState("raindrop"))?.pendingRemote) break;
            continue;
          }
          moved += 1;
          await this.store.updateConnectorState(command(request.commandId, `done-${item.id}`), "raindrop", current => { const next = current ?? live; return { ...next, pending: next.pending.filter(candidate => candidate.id !== item.id), capturedIds: [...new Set([...next.capturedIds, item.id])].slice(-2_000), remaining: Math.max(0, next.pending.length - 1) }; });
        } catch (error) { pending += 1; lastError = error instanceof Error ? error.message : "Raindrop intake failed"; }
      }
      const finalState = await this.store.connectorState("raindrop") ?? live;
      const finalAuthority = finalState.assessmentPilot?.id === cohortId ? finalState.assessmentPilot : finalState.assessmentApprovals?.find(item => item.id === cohortId) ?? cohortAuthority;
      // Costs describe the durable cohort, not just this invocation's loop.
      // Moved items disappear from pending; their paid receipts must not vanish
      // from the estimate on a later run. Unknown is never silently zero.
      const attempts = Object.values(finalState?.assessmentAttempts ?? {}).filter(attempt => attempt.cohortId === cohortId || (!attempt.cohortId && cohortId === finalState?.assessmentPilot?.id));
      const known = attempts.filter(attempt => attempt.estimatedCostCents !== undefined);
      return { connector: "raindrop", dryRun: false, discovered: discovered.discovered, captured, retained, archived, assessmentFailed, moved, pending, budget: { approvedCeilingCents: finalAuthority.budgetCents, conservativeReservedCents: finalAuthority.reservedCents, cohortItemCap: finalAuthority.maxItems, cohortSelectedItems: cohort.length, settledItems: finalAuthority.usedItems, ...(known.length > 0 ? { estimatedUsageCostCents: known.reduce((sum, attempt) => sum + attempt.estimatedCostCents!, 0) } : {}), usageKnownAssessments: known.length, usageUnknownAssessments: attempts.length - known.length, uncertainAttempts: attempts.filter(attempt => attempt.status === "dispatched").length, pendingOutsideCohortItems: (finalState?.pending ?? []).filter(item => !cohort.includes(item.id)).length }, ...(lastError ? { error: lastError } : {}) };
    } finally { clearTimeout(deadline); }
  }

  private async run(request: KnowledgeConnectorRunRequest, externalSignal?: AbortSignal): Promise<Record<string, unknown>> {
    const connector = request.connector; const current = await this.store.connectorState(connector);
    if (!current?.enabled || !current.credentialRef || !current.accountId || !current.scope) throw new GatewayError("unsupported", `Knowledge ${connector} connector is not configured`);
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
      await this.reconcile(connector);
      const reconciled = await this.store.connectorState(connector);
      if (reconciled?.pendingRemote) throw new GatewayError("conflict", "Connector has an unresolved remote effect");
    }
    const token = await this.options.credentials.read(current.credentialRef);
    if (!token) { await this.store.updateConnectorState(command(request.commandId, "auth"), connector, state => ({ ...(state ?? current), health: "auth-error", lastError: "Credential reference is unavailable", lastRunAt: this.now() })); throw new GatewayError("unsupported", "Connector credential is unavailable"); }
    const assertCurrentAuthority = async (): Promise<void> => {
      const live = await this.store.connectorState(connector);
      if (!live?.enabled || live.accountId !== current.accountId || live.scope !== current.scope || live.credentialRef !== current.credentialRef) throw new GatewayError("conflict", "Connector configuration changed during provider discovery");
    };
    const currentToken = async (): Promise<string> => {
      const live = await this.store.connectorState(connector);
      if (!live?.credentialRef || live.credentialRef !== current.credentialRef) throw new GatewayError("conflict", "Connector credential changed during provider discovery");
      const fresh = await this.options.credentials.read(live.credentialRef);
      if (!fresh) throw new GatewayError("unsupported", "Connector credential is unavailable");
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
      const discovered = await this.discover(connector, current, currentToken, limit, signal, xPricing?.maxAttempts, beforeProviderAttempt);
      let state = await this.store.connectorState(connector) ?? current;
      if (request.dryRun) {
        const result = { connector, dryRun: true, discovered: discovered.discovered, pending: state.pending.length, remaining: state.remaining, health: state.health };
        await this.store.updateConnectorState(command(request.commandId, "dry"), connector, value => ({ ...(value ?? state), health: "ready", remaining: value?.pending.length ?? state.pending.length }));
        return result;
      }
      let captured = 0; let partial = 0; let lastError: string | undefined;
      for (const item of [...state.pending].slice(0, limit)) {
        try {
          const live = await this.store.connectorState(connector);
          if (!live || live.accountId !== current.accountId || live.scope !== current.scope || live.credentialRef !== current.credentialRef || live.enabled !== current.enabled) throw new GatewayError("conflict", "Connector configuration changed during the run");
          state = live;
          const result = await captureSource(this.store, { commandId: command(request.commandId, `capture-${item.id}`), url: item.url, scope: "research", title: item.title, origin: "connector", identity: { provider: connector, accountId: state.accountId!, itemId: item.id }, ...(item.annotation ? { annotations: [{ text: item.annotation }] } : {}) }, { signal, ...(this.options.sourceFetch ? { fetcher: (sourceUrl, init) => this.options.sourceFetch!(sourceUrl.toString(), item.excerpt, init?.signal ?? signal) } : {}), ...(this.options.resolveHost ? { resolveHost: this.options.resolveHost } : {}) });
          let capturedRecord = result.record;
          // X API entities/author fields are authenticated evidence. Retain a
          // bounded canonical object instead of certifying a public-page fetch.
          if (item.apiPayload && capturedRecord.content.captureDisposition !== "failed") {
            const apiObject = await this.store.putObject(new TextEncoder().encode(item.apiPayload), "application/json");
            const updated = await this.store.captureSource({ commandId: command(request.commandId, `api-evidence-${item.id}`), expectedRevision: capturedRecord.revisionId, record: { kind: "source", id: capturedRecord.id, createdAt: capturedRecord.createdAt, scope: capturedRecord.scope, provenance: capturedRecord.provenance, relations: capturedRecord.relations, content: { ...capturedRecord.content, representations: [...(capturedRecord.content.representations ?? []), { kind: "provider-api", object: apiObject, mediaType: "application/json" }] } } });
            if (updated.record.kind === "source") capturedRecord = updated.record;
          }
          if (capturedRecord.content.captureDisposition !== "complete") { partial += 1; lastError = `Capture for ${item.id} is ${capturedRecord.content.captureDisposition}`; break; }
          if (connector === "raindrop" && state.allowWrites && state.destination && item.collectionId && item.collectionId !== state.destination) {
            const moved = await this.moveRaindrop({ commandId: command(request.commandId, `move-${item.id}`), itemId: item.id, source: capturedRecord, expectedRevision: capturedRecord.revisionId, identity: { provider: connector, accountId: state.accountId!, itemId: item.id }, destination: state.destination }, signal);
            if (moved.status !== "moved") { lastError = moved.status === "unsupported" ? "Approved Raindrop move is unavailable" : "Raindrop move could not be verified"; break; }
          }
          captured += 1;
          state = await this.store.updateConnectorState(command(request.commandId, `done-${item.id}`), connector, value => { const next = value ?? state; return { ...next, pending: next.pending.filter(candidate => candidate.id !== item.id), capturedIds: [...new Set([...next.capturedIds, item.id])].slice(-2_000), remaining: Math.max(0, next.pending.length - 1) }; });
        } catch (error) { lastError = error instanceof Error ? error.message : "Connector capture failed"; break; }
      }
      state = await this.store.updateConnectorState(command(request.commandId, "finish"), connector, value => ({ ...(value ?? state), health: lastError ? "partial" : "ready", ...(lastError ? { lastError } : {}), lastRunAt: this.now(), remaining: value?.pending.length ?? state.pending.length }));
      clearTimeout(deadline);
      return { connector, dryRun: false, discovered: discovered.discovered, captured, partial, pending: state.pending.length, remaining: state.remaining, health: state.health, ...(lastError ? { error: lastError } : {}) };
    } catch (error) {
      const health = error instanceof ConnectorHTTPError && authFailure(error.status) ? "auth-error" : error instanceof ConnectorHTTPError && error.status === 429 ? "rate-limited" : "error";
      const message = error instanceof ConnectorHTTPError ? `Provider request failed (${error.status})` : error instanceof Error ? error.message : "Connector failed";
      await this.store.updateConnectorState(command(request.commandId, "error"), connector, state => ({ ...(state ?? current), health, lastError: message, lastRunAt: this.now(), remaining: state?.pending.length ?? current.pending.length }));
      clearTimeout(deadline);
      throw new GatewayError(health === "auth-error" ? "unsupported" : "internal", message, true);
    }
  }

  private async discover(connector: Connector, state: KnowledgeConnectorState, token: string | (() => Promise<string>), limit: number, signal: AbortSignal, maxAttempts?: number, beforeAttempt?: () => Promise<void>): Promise<{ discovered: number }> {
    const checkpointKey = state.scope ?? "default";
    // Raindrop pagination is offset-based: moving an item shrinks earlier
    // pages, so a persisted page number can skip newly exposed items. Restart
    // each bounded sweep at page zero; the durable identity fence deduplicates
    // already captured/pending items while later pages remain discoverable.
    let cursor = connector === "raindrop" ? undefined : state.checkpoints?.[checkpointKey]; let discovered = 0; const seen = new Set([...state.pending.map(item => item.id), ...state.capturedIds]);
    for (let page = 0; page < 10 && discovered < limit; page += 1) {
      const result = connector === "raindrop" ? await requestJson(this.http, `https://api.raindrop.io/rest/v1/raindrops/${encodeURIComponent(state.scope!)}?page=${cursor ? encodeURIComponent(cursor) : "0"}&perpage=${MAX_PAGE}`, token, { sleep: this.sleep, signal, ...(beforeAttempt === undefined ? {} : { beforeAttempt }) }) : await requestJson(this.http, `https://api.x.com/2/users/${encodeURIComponent(state.scope!)}/bookmarks?max_results=${MAX_PAGE}${cursor ? `&pagination_token=${encodeURIComponent(cursor)}` : ""}&tweet.fields=created_at,entities,author_id`, token, { sleep: this.sleep, signal, ...(maxAttempts === undefined ? {} : { maxAttempts }), ...(beforeAttempt === undefined ? {} : { beforeAttempt }) });
      const items = connector === "raindrop" ? parseRaindrop(result.value) : parseX(result.value);
      const fresh = items.filter(item => !seen.has(item.id));
      const next = connector === "raindrop" ? (items.length >= MAX_PAGE ? String((Number(cursor ?? "0") || 0) + 1) : undefined) : text(result.value?.meta?.next_token, 512);
      let persisted = 0;
      await this.store.updateConnectorState(`connector-discover-${connector}-${Date.now()}-${page}`, connector, value => {
        const prior = value ?? state; const capacity = Math.max(0, 500 - prior.pending.length); const batch = fresh.slice(0, Math.min(capacity, Math.max(0, limit - discovered)));
        persisted = batch.length;
        const nextState = { ...prior, pending: [...prior.pending, ...batch], remaining: prior.pending.length + batch.length };
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

  /** Reconcile a persisted Raindrop move receipt after an effect-before-response crash. */
  async reconcile(connector: Connector): Promise<KnowledgeConnectorStatus> {
    const state = await this.store.connectorState(connector); if (!state) return stateStatus(undefined, connector);
    const pending = state.pendingRemote;
    if (!pending || connector !== "raindrop" || !state.credentialRef) return stateStatus(state, connector);
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
    try {
      const result = await requestJson(this.http, `https://api.raindrop.io/rest/v1/raindrop/${encodeURIComponent(pending.itemId)}`, token, { sleep: this.sleep, signal: new AbortController().signal });
      const collection = String(result.value?.item?.collection?.$id ?? result.value?.collection?.$id ?? "");
      if (collection === pending.destination) {
        const updated = await this.store.updateConnectorState(`${pending.operationId}:reconcile`, connector, current => { const next = current ?? state; const { pendingRemote: _pending, lastError: _error, ...rest } = next; return { ...rest, health: "ready" as const }; });
        return stateStatus(updated, connector);
      }
      const updated = await this.store.updateConnectorState(`${pending.operationId}:conflict`, connector, current => ({ ...(current ?? state), health: "partial", lastError: "Remote move is not at its requested destination" }));
      return stateStatus(updated, connector);
    } catch {
      return stateStatus(state, connector);
    }
  }

  /** Raindrop-only reversible move. Capture must be locally complete and the
   * exact pending effect is durable before the provider mutation is attempted. */
  async moveRaindrop(input: { commandId: string; itemId: string; source: KnowledgeRecord & { kind: "source" }; expectedRevision?: string; identity?: { provider: string; accountId: string; itemId: string }; sourceCollection?: string; destination: string }, externalSignal?: AbortSignal): Promise<{ status: "moved" | "conflict" | "unsupported" }> {
    const state = await this.store.connectorState("raindrop"); if (!state?.enabled || !state.allowWrites || !state.credentialRef) return { status: "unsupported" };
    if (!input.expectedRevision || !input.identity || input.identity.itemId !== input.itemId || input.source.revisionId !== input.expectedRevision) return { status: "conflict" };
    // The caller's object is only a hint. Re-read the exact revision so a held
    // JS record cannot bypass forget/exclusion or a source correction.
    let source: KnowledgeRecord | null;
    try { source = await this.store.read(input.source.id, input.expectedRevision, false, true); } catch { return { status: "conflict" }; }
    if (!source || source.kind !== "source" || !isVerifiedSourceCapture(source) || !["retained", "archived"].includes(source.content.admission?.status ?? "")) return { status: "unsupported" };
    // The source head's object reference is part of movement authority; a
    // dangling object must never be acknowledged as a successfully captured
    // item merely because readable text remains in the revision.
    if (!source.content.object || !(await this.store.readObject(source.content.object, { recordId: source.id, revisionId: source.revisionId, includeArchived: true }))) return { status: "conflict" };
    if (!state.destination || state.destination !== input.destination || state.accountId !== input.identity.accountId) return { status: "conflict" };
    if (state.paidBudgetCents > 0) return { status: "unsupported" };
    const token = await this.options.credentials.read(state.credentialRef); if (!token) return { status: "unsupported" };
    const capturedIdentity = source.content.identity;
    const incomingOrigin = source.content.origins?.some(origin => origin.identity?.provider === input.identity!.provider && origin.identity.accountId === input.identity!.accountId && origin.identity.itemId === input.identity!.itemId);
    const primaryIdentityMatches = Boolean(capturedIdentity && capturedIdentity.provider === input.identity.provider && capturedIdentity.accountId === input.identity.accountId && capturedIdentity.itemId === input.identity.itemId);
    if ((!primaryIdentityMatches && !incomingOrigin) || input.identity.provider !== "raindrop") return { status: "conflict" };
    const abort = new AbortController();
    const signal = externalSignal ? AbortSignal.any([abort.signal, externalSignal]) : abort.signal;
    // Preflight the exact item immediately before recording and applying the
    // effect. A configured collection is not proof of its current location.
    const preflight = await requestJson(this.http, `https://api.raindrop.io/rest/v1/raindrop/${encodeURIComponent(input.itemId)}`, token, { sleep: this.sleep, signal });
    if (signal.aborted) return { status: "conflict" };
    // Re-read both authorities after the await: native/user revocation and a
    // source forget/correction must win over the preflight snapshot.
    const latestState = await this.store.connectorState("raindrop");
    const latestSource = await this.store.read(source.id, input.expectedRevision, false, true).catch(() => null);
    if (!latestState?.enabled || !latestState.allowWrites || latestState.accountId !== input.identity.accountId || latestState.credentialRef !== state.credentialRef || latestState.destination !== input.destination || latestState.paidBudgetCents > 0 || !latestSource || latestSource.kind !== "source" || !isVerifiedSourceCapture(latestSource)) return { status: "conflict" };
    const remoteItemId = id(preflight.value?.item?._id ?? preflight.value?._id, "Raindrop item");
    const originalCollectionId = String(preflight.value?.item?.collection?.$id ?? preflight.value?.collection?.$id ?? "");
    if (!remoteItemId || remoteItemId !== input.identity.itemId || !originalCollectionId) return { status: "conflict" };
    // A crash may occur after the provider move and before local completion.
    // Destination is an acknowledged success; never reclassify or issue PUT again.
    if (originalCollectionId === input.destination) return { status: "moved" };
    const expectedCollection = input.sourceCollection ?? latestState.scope;
    if (originalCollectionId !== expectedCollection) return { status: "conflict" };
    const pending = { operationId: input.commandId, itemId: input.itemId, action: "move" as const, basisRecordId: latestSource.id, basisRevisionId: latestSource.revisionId, provider: input.identity.provider, accountId: input.identity.accountId, originalCollectionId, destination: input.destination, createdAt: this.now() };
    await this.store.updateConnectorState(input.commandId, "raindrop", current => ({ ...(current ?? latestState), pendingRemote: pending }));
    if (signal.aborted) return { status: "conflict" };
    // Recheck write authority at the effect boundary as well. If permission
    // is revoked after the durable receipt, retain uncertainty for reconcile
    // but never issue the remote PUT.
    const effectState = await this.store.connectorState("raindrop");
    if (!effectState?.enabled || !effectState.allowWrites || effectState.accountId !== input.identity.accountId || effectState.credentialRef !== latestState.credentialRef || effectState.destination !== input.destination || effectState.paidBudgetCents > 0) return { status: "conflict" };
    try {
      await requestJson(this.http, `https://api.raindrop.io/rest/v1/raindrop/${encodeURIComponent(input.itemId)}`, token, { method: "PUT", body: { collection: { $id: input.destination } }, sleep: this.sleep, signal });
      const verified = await requestJson(this.http, `https://api.raindrop.io/rest/v1/raindrop/${encodeURIComponent(input.itemId)}`, token, { sleep: this.sleep, signal });
      const collection = verified.value?.item?.collection?.$id ?? verified.value?.collection?.$id;
      if (String(collection) !== input.destination) return { status: "conflict" };
      await this.store.updateConnectorState(`${input.commandId}:complete`, "raindrop", current => { const next = current ?? latestState; const { pendingRemote: _pending, ...rest } = next; return rest; });
      return { status: "moved" };
    } catch { return { status: "conflict" }; }
  }
}

export function createKnowledgeConnectorExtension(store: KnowledgeStore, options: KnowledgeConnectorOptions): KnowledgeConnectorExtension {
  return new KnowledgeConnectorExtension(store, options);
}
