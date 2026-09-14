import type { KnowledgeConnectorConfigurationRequest, KnowledgeConnectorRunRequest, KnowledgeConnectorState, KnowledgeConnectorStatus, KnowledgeAction, KnowledgeRecord } from "./knowledge-contract.js";
import { captureSource, isVerifiedSourceCapture } from "./source-capture.js";
import { GatewayError } from "../errors.js";
import { AsyncMutex } from "../util/async-mutex.js";
import type { KnowledgeStore } from "./knowledge-store.js";
import type { ConnectorCredentialStore } from "./connector-credentials.js";

const MAX_PAGE = 50;
const MAX_ITEMS = 200;
const BODY_LIMIT = 2_000_000;
const RETRIES = 3;
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
}

interface PendingItem { id: string; title: string; url: string; excerpt?: string; annotation?: string; publishedAt?: string; collectionId?: string }
interface Page { items: PendingItem[]; next?: string; accountId?: string; }
interface RaindropItemDTO { _id?: unknown; title?: unknown; link?: unknown; excerpt?: unknown; note?: unknown; created?: unknown; collection?: unknown; }
interface XBookmarkDTO { id?: unknown; text?: unknown; created_at?: unknown; author_id?: unknown; entities?: unknown; }

function bad(message: string): GatewayError { return new GatewayError("invalid_request", message); }
function command(base: string, suffix: string): string { return `${base}:${suffix}`.replace(/[^A-Za-z0-9._:-]/g, "_").slice(0, 160); }
function id(value: unknown, label: string): string | undefined { return typeof value === "string" && value.length > 0 && value.length <= 512 ? value : typeof value === "number" && Number.isSafeInteger(value) ? String(value) : undefined; }
function text(value: unknown, maximum = 100_000): string | undefined { return typeof value === "string" && value.length > 0 ? value.slice(0, maximum) : undefined; }
function url(value: unknown): string | undefined { if (typeof value !== "string") return undefined; try { const parsed = new URL(value); return ["http:", "https:"].includes(parsed.protocol) && !parsed.username && !parsed.password ? parsed.toString() : undefined; } catch { return undefined; } }
function retryable(status: number): boolean { return status === 408 || status === 425 || status === 429 || status >= 500; }
function authFailure(status: number): boolean { return status === 401 || status === 403; }

async function boundedResponseText(response: Response): Promise<string> {
  if (!response.body) return "";
  const reader = response.body.getReader(); const chunks: Uint8Array[] = []; let total = 0;
  try {
    for (;;) { const next = await reader.read(); if (next.done) break; if (!next.value) continue; const remaining = BODY_LIMIT - total; if (next.value.byteLength > remaining) { if (remaining > 0) chunks.push(next.value.slice(0, remaining)); await reader.cancel(); total = BODY_LIMIT; break; } chunks.push(next.value); total += next.value.byteLength; if (total === BODY_LIMIT) { await reader.cancel(); break; } }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(total); let offset = 0; for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return new TextDecoder().decode(bytes);
}
async function defaultHTTP(input: string, init: { method?: "GET" | "PUT" | "POST" | "DELETE"; headers: Record<string, string>; body?: string; signal: AbortSignal }): Promise<ConnectorHTTPResponse> {
  const timeout = AbortSignal.timeout(15_000); const signal = AbortSignal.any([init.signal, timeout]);
  const response = await fetch(input, { method: init.method ?? "GET", headers: init.headers, ...(init.body !== undefined ? { body: init.body } : {}), redirect: "error", signal });
  return { status: response.status, headers: response.headers, body: await boundedResponseText(response) };
}

async function requestJson(http: ConnectorHTTP, endpoint: string, token: string, options: { method?: "GET" | "PUT" | "POST" | "DELETE"; body?: unknown; sleep: (milliseconds: number) => Promise<void>; signal: AbortSignal }): Promise<{ status: number; value: any; headers: Headers }> {
  for (let attempt = 1; attempt <= RETRIES; attempt += 1) {
    const result = await http(endpoint, { ...(options.method ? { method: options.method } : {}), headers: { authorization: `Bearer ${token}`, accept: "application/json", ...(options.body !== undefined ? { "content-type": "application/json" } : {}) }, ...(options.body !== undefined ? { body: JSON.stringify(options.body) } : {}), signal: options.signal });
    let value: unknown = undefined;
    if (result.body) { try { value = JSON.parse(result.body); } catch { value = undefined; } }
    if (result.status >= 200 && result.status < 300) return { status: result.status, value, headers: result.headers };
    if (!retryable(result.status) || attempt === RETRIES) throw new ConnectorHTTPError(result.status, result.headers.get("retry-after"));
    const retryAfter = Number(result.headers.get("retry-after") ?? "0");
    await options.sleep(Math.min(2_000, Math.max(50, Number.isFinite(retryAfter) ? retryAfter * 1_000 : 100 * 2 ** (attempt - 1))));
  }
  throw new ConnectorHTTPError(599);
}

class ConnectorHTTPError extends Error { constructor(readonly status: number, readonly retryAfter?: string | null) { super(`Connector HTTP ${status}`); } }

function initial(connector: Connector): KnowledgeConnectorState {
  return { connector, enabled: false, allowWrites: false, paidAccessApproved: false, paidBudgetCents: 0, recurringApproved: false, pending: [], capturedIds: [], health: "unconfigured", remaining: 0 };
}
function stateStatus(state: KnowledgeConnectorState | undefined, connector: Connector): KnowledgeConnectorStatus {
  const value = state ?? initial(connector);
  return { connector, configured: Boolean(value.credentialRef && value.accountId && value.scope), enabled: value.enabled, health: value.health, ...(value.accountId ? { accountId: value.accountId } : {}), ...(value.scope ? { scope: value.scope } : {}), ...(value.lastRunAt ? { lastRunAt: value.lastRunAt } : {}), ...(value.lastError ? { lastError: value.lastError } : {}), remaining: value.remaining, pending: value.pending.length, paidBudgetCents: value.paidBudgetCents, allowWrites: value.allowWrites, recurringApproved: value.recurringApproved, paidAccessApproved: value.paidAccessApproved };
}
function parseCollection(item: RaindropItemDTO): string | undefined {
  if (!item.collection || typeof item.collection !== "object") return undefined;
  return id((item.collection as Record<string, unknown>).$id, "collection");
}
function parseRaindrop(value: any): PendingItem[] {
  if (!value || !Array.isArray(value.items)) return [];
  return value.items.map((item: RaindropItemDTO) => { const itemId = id(item._id, "Raindrop item"); const link = url(item.link); if (!itemId || !link) return undefined; return { id: itemId, title: text(item.title, 512) ?? link, url: link, ...(text(item.excerpt) ? { excerpt: text(item.excerpt) } : {}), ...(text(item.note, 20_000) ? { annotation: text(item.note, 20_000) } : {}), ...(text(item.created, 80) ? { publishedAt: text(item.created, 80) } : {}), ...(parseCollection(item) ? { collectionId: parseCollection(item) } : {}) }; }).filter((item: PendingItem | undefined): item is PendingItem => Boolean(item));
}
function parseX(value: any): PendingItem[] {
  if (!value || !Array.isArray(value.data)) return [];
  return value.data.map((item: XBookmarkDTO) => { const itemId = id(item.id, "X bookmark"); if (!itemId) return undefined; const link = `https://x.com/i/web/status/${encodeURIComponent(itemId)}`; return { id: itemId, title: text(item.text, 512) ?? `X post ${itemId}`, url: link, ...(text(item.text, 100_000) ? { excerpt: text(item.text, 100_000) } : {}), ...(text(item.created_at, 80) ? { publishedAt: text(item.created_at, 80) } : {}) }; }).filter((item: PendingItem | undefined): item is PendingItem => Boolean(item));
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

  async invoke(action: KnowledgeAction): Promise<unknown> {
    if (action.operation === "knowledge.connector.configure") return this.configure(action.request);
    if (action.operation === "knowledge.connector.status") return stateStatus(await this.store.connectorState(action.request.connector), action.request.connector);
    if (action.operation === "knowledge.connector.run") return this.lane(action.request.connector).run(() => this.run(action.request));
    throw bad("Unsupported knowledge connector operation");
  }

  private async configure(request: KnowledgeConnectorConfigurationRequest): Promise<KnowledgeConnectorStatus> {
    if (request.accountId !== undefined && (request.accountId.length < 1 || request.accountId.length > 256 || /[\r\n]/.test(request.accountId))) throw bad("Connector account is invalid");
    if (request.scope !== undefined && (request.scope.length < 1 || request.scope.length > 256 || /[\r\n]/.test(request.scope))) throw bad("Connector scope is invalid");
    if (request.destination !== undefined && (request.destination.length < 1 || request.destination.length > 256 || /[\r\n]/.test(request.destination))) throw bad("Connector destination is invalid");
    if (request.credentialRef !== undefined && !/^connector:[a-z][a-z0-9-]{0,31}:[A-Za-z0-9._:-]{1,160}$/.test(request.credentialRef)) throw bad("Connector credential reference is invalid");
    if (request.paidBudgetCents !== undefined && (!Number.isSafeInteger(request.paidBudgetCents) || request.paidBudgetCents < 0 || request.paidBudgetCents > 1_000_000)) throw bad("Connector paid budget is invalid");
    const current = await this.store.connectorState(request.connector);
    const base = current ?? initial(request.connector);
    const next: KnowledgeConnectorState = { ...base, enabled: request.enabled, ...(request.accountId !== undefined ? { accountId: request.accountId } : {}), ...(request.scope !== undefined ? { scope: request.scope } : {}), ...(request.destination !== undefined ? { destination: request.destination } : {}), ...(request.credentialRef !== undefined ? { credentialRef: request.credentialRef } : {}), allowWrites: request.allowWrites ?? current?.allowWrites ?? false, paidAccessApproved: request.paidAccessApproved ?? current?.paidAccessApproved ?? false, paidBudgetCents: request.paidBudgetCents ?? current?.paidBudgetCents ?? 0, recurringApproved: request.recurringApproved ?? current?.recurringApproved ?? false, health: request.enabled && (request.credentialRef ?? current?.credentialRef) && (request.accountId ?? current?.accountId) && (request.scope ?? current?.scope) ? "ready" : "unconfigured" };
    delete next.lastError;
    const saved = await this.store.updateConnectorState(request.commandId, request.connector, () => next);
    return stateStatus(saved, request.connector);
  }

  private async run(request: KnowledgeConnectorRunRequest): Promise<Record<string, unknown>> {
    const connector = request.connector; const current = await this.store.connectorState(connector);
    if (!current?.enabled || !current.credentialRef || !current.accountId || !current.scope) throw new GatewayError("unsupported", `Knowledge ${connector} connector is not configured`);
    // No connector operation currently has a maintained paid-price contract.
    // Keep the stored budget authoritative and reject paid work rather than
    // guessing a provider cost.
    if (current.paidBudgetCents > 0) throw new GatewayError("unsupported", "Paid connector operations are unavailable without a priced operation");
    const token = await this.options.credentials.read(current.credentialRef);
    if (!token) { await this.store.updateConnectorState(command(request.commandId, "auth"), connector, state => ({ ...(state ?? current), health: "auth-error", lastError: "Credential reference is unavailable", lastRunAt: this.now() })); throw new GatewayError("unsupported", "Connector credential is unavailable"); }
    const limit = Math.min(request.limit ?? MAX_ITEMS, MAX_ITEMS); if (!Number.isSafeInteger(limit) || limit < 1) throw bad("Connector limit is invalid");
    await this.store.updateConnectorState(command(request.commandId, "start"), connector, state => { const next = { ...(state ?? current), health: "running" as const, lastRunAt: this.now(), remaining: state?.pending.length ?? 0 }; delete next.lastError; return next; });
    const abort = new AbortController();
    try {
      const discovered = await this.discover(connector, current, token, limit, abort.signal);
      let state = await this.store.connectorState(connector) ?? current;
      if (request.dryRun) {
        const result = { connector, dryRun: true, discovered: discovered.discovered, pending: state.pending.length, remaining: state.remaining, health: state.health };
        await this.store.updateConnectorState(command(request.commandId, "dry"), connector, value => ({ ...(value ?? state), health: "ready", remaining: value?.pending.length ?? state.pending.length }));
        return result;
      }
      let captured = 0; let partial = 0; let lastError: string | undefined;
      for (const item of [...state.pending].slice(0, limit)) {
        try {
          const result = await captureSource(this.store, { commandId: command(request.commandId, `capture-${item.id}`), url: item.url, scope: "research", title: item.title, origin: "connector", identity: { provider: connector, accountId: state.accountId!, itemId: item.id }, ...(item.annotation ? { annotations: [{ text: item.annotation }] } : {}) }, { ...(this.options.sourceFetch ? { fetcher: (sourceUrl, init) => this.options.sourceFetch!(sourceUrl.toString(), item.excerpt, init?.signal ?? new AbortController().signal) } : {}), ...(this.options.resolveHost ? { resolveHost: this.options.resolveHost } : {}) });
          if (result.record.content.captureDisposition !== "complete") { partial += 1; lastError = `Capture for ${item.id} is ${result.record.content.captureDisposition}`; break; }
          if (connector === "raindrop" && state.allowWrites && state.destination && item.collectionId && item.collectionId !== state.destination) {
            const moved = await this.moveRaindrop({ commandId: command(request.commandId, `move-${item.id}`), itemId: item.id, source: result.record, destination: state.destination });
            if (moved.status !== "moved") { lastError = moved.status === "unsupported" ? "Approved Raindrop move is unavailable" : "Raindrop move could not be verified"; break; }
          }
          captured += 1;
          state = await this.store.updateConnectorState(command(request.commandId, `done-${item.id}`), connector, value => { const next = value ?? state; return { ...next, pending: next.pending.filter(candidate => candidate.id !== item.id), capturedIds: [...new Set([...next.capturedIds, item.id])].slice(-2_000), remaining: Math.max(0, next.pending.length - 1) }; });
        } catch (error) { lastError = error instanceof Error ? error.message : "Connector capture failed"; break; }
      }
      state = await this.store.updateConnectorState(command(request.commandId, "finish"), connector, value => ({ ...(value ?? state), health: lastError ? "partial" : "ready", ...(lastError ? { lastError } : {}), lastRunAt: this.now(), remaining: value?.pending.length ?? state.pending.length }));
      return { connector, dryRun: false, discovered: discovered.discovered, captured, partial, pending: state.pending.length, remaining: state.remaining, health: state.health, ...(lastError ? { error: lastError } : {}) };
    } catch (error) {
      const health = error instanceof ConnectorHTTPError && authFailure(error.status) ? "auth-error" : error instanceof ConnectorHTTPError && error.status === 429 ? "rate-limited" : "error";
      const message = error instanceof ConnectorHTTPError ? `Provider request failed (${error.status})` : error instanceof Error ? error.message : "Connector failed";
      await this.store.updateConnectorState(command(request.commandId, "error"), connector, state => ({ ...(state ?? current), health, lastError: message, lastRunAt: this.now(), remaining: state?.pending.length ?? current.pending.length }));
      throw new GatewayError(health === "auth-error" ? "unsupported" : "internal", message, true);
    }
  }

  private async discover(connector: Connector, state: KnowledgeConnectorState, token: string, limit: number, signal: AbortSignal): Promise<{ discovered: number }> {
    let cursor = state.checkpoint; let discovered = 0; const seen = new Set([...state.pending.map(item => item.id), ...state.capturedIds]);
    for (let page = 0; page < 10 && discovered < limit; page += 1) {
      const result = connector === "raindrop" ? await requestJson(this.http, `https://api.raindrop.io/rest/v1/raindrops/${encodeURIComponent(state.scope!)}?page=${cursor ? encodeURIComponent(cursor) : "0"}&perpage=${MAX_PAGE}`, token, { sleep: this.sleep, signal }) : await requestJson(this.http, `https://api.x.com/2/users/${encodeURIComponent(state.scope!)}/bookmarks?max_results=${MAX_PAGE}${cursor ? `&pagination_token=${encodeURIComponent(cursor)}` : ""}&tweet.fields=created_at,entities,author_id`, token, { sleep: this.sleep, signal });
      const items = connector === "raindrop" ? parseRaindrop(result.value) : parseX(result.value);
      const fresh = items.filter(item => !seen.has(item.id));
      const next = connector === "raindrop" ? (items.length >= MAX_PAGE ? String((Number(cursor ?? "0") || 0) + 1) : undefined) : text(result.value?.meta?.next_token, 512);
      let persisted = 0;
      await this.store.updateConnectorState(`connector-discover-${connector}-${Date.now()}-${page}`, connector, value => {
        const prior = value ?? state; const capacity = Math.max(0, 500 - prior.pending.length); const batch = fresh.slice(0, capacity);
        persisted = batch.length;
        const nextState = { ...prior, pending: [...prior.pending, ...batch], remaining: prior.pending.length + batch.length };
        // Advance only after every discovered item from this page is durable;
        // otherwise retry the same provider page instead of silently skipping.
        if (batch.length === fresh.length && next) nextState.checkpoint = next; else if (!next && batch.length === fresh.length) delete nextState.checkpoint;
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
  async moveRaindrop(input: { commandId: string; itemId: string; source: KnowledgeRecord & { kind: "source" }; destination: string }): Promise<{ status: "moved" | "conflict" | "unsupported" }> {
    if (!isVerifiedSourceCapture(input.source)) return { status: "unsupported" };
    const state = await this.store.connectorState("raindrop"); if (!state?.enabled || !state.allowWrites || !state.credentialRef) return { status: "unsupported" };
    if (!state.destination || state.destination !== input.destination) return { status: "conflict" };
    if (state.paidBudgetCents > 0) return { status: "unsupported" };
    const token = await this.options.credentials.read(state.credentialRef); if (!token) return { status: "unsupported" };
    const pending = { operationId: input.commandId, itemId: input.itemId, action: "move" as const, basisRecordId: input.source.id, originalCollectionId: state.scope!, destination: input.destination, createdAt: this.now() };
    await this.store.updateConnectorState(input.commandId, "raindrop", current => ({ ...(current ?? state), pendingRemote: pending }));
    const abort = new AbortController();
    try {
      await requestJson(this.http, `https://api.raindrop.io/rest/v1/raindrop/${encodeURIComponent(input.itemId)}`, token, { method: "PUT", body: { collection: input.destination }, sleep: this.sleep, signal: abort.signal });
      const verified = await requestJson(this.http, `https://api.raindrop.io/rest/v1/raindrop/${encodeURIComponent(input.itemId)}`, token, { sleep: this.sleep, signal: abort.signal });
      const collection = verified.value?.item?.collection?.$id ?? verified.value?.collection?.$id;
      if (String(collection) !== input.destination) return { status: "conflict" };
      await this.store.updateConnectorState(`${input.commandId}:complete`, "raindrop", current => { const next = current ?? state; const { pendingRemote: _pending, ...rest } = next; return rest; });
      return { status: "moved" };
    } catch { return { status: "conflict" }; }
  }
}

export function createKnowledgeConnectorExtension(store: KnowledgeStore, options: KnowledgeConnectorOptions): KnowledgeConnectorExtension {
  return new KnowledgeConnectorExtension(store, options);
}
