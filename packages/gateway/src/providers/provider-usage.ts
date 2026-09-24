import { createHash } from "node:crypto";
import type { ModelRuntime } from "@earendil-works/pi-coding-agent";

export const PROVIDER_USAGE_CAPABILITY = "provider-usage.v1";
const MAX_PROVIDERS = 16;
const MAX_WINDOWS = 16;
const MAX_BALANCES = 4;
const MAX_BODY_BYTES = 512 * 1024;
const FRESH_MS = 60_000;
const MAX_RETRY_MS = 24 * 60 * 60_000;
const REQUEST_TIMEOUT_MS = 10_000;
const MAX_INFLIGHT_WAITERS = 32;
const MAX_ACTIVE_READS = 16;
const NEGATIVE_RETRY_MS = 30_000;

type ProviderStatus = "available" | "unsupported" | "unconfigured" | "authentication_required" | "rate_limited" | "unavailable";
export interface UsageWindow {
  id: string;
  label: string;
  usedPercent: number | null;
  used: number | null;
  limit: number | null;
  remaining: number | null;
  unit: string | null;
  resetsAt: string | null;
  windowSeconds: number | null;
}
export interface UsageBalance { id: string; label: string; amount: number; currency: string; }
export interface ProviderUsageSnapshot {
  providerId: string;
  status: ProviderStatus;
  source: string | null;
  scope: "account" | "key" | null;
  updatedAt: string | null;
  retryAt: string | null;
  stale: boolean;
  message: string | null;
  windows: UsageWindow[];
  balances: UsageBalance[];
}
export interface ProviderUsageResponse { providers: ProviderUsageSnapshot[]; }

/** One wire API paired with the base URL a first-party model resolves to. */
interface ProviderShape { api: string; baseUrl: string; }
interface Adapter {
  id: string;
  /** Every first-party (api, effective base URL) shape the provider may resolve to. */
  shapes: readonly ProviderShape[];
  endpoint: string;
  source: string;
  scope: "account" | "key";
  oauthOnly?: boolean;
  headers(auth: ResolvedAuth): Record<string, string> | undefined;
  parse(body: unknown): { windows: UsageWindow[]; balances: UsageBalance[] };
  /** Optional: a first-party status the default credential/limit mapping would misreport. */
  failure?(status: number): { status: ProviderStatus; message: string } | undefined;
}
interface ResolvedAuth { apiKey?: string; headers?: Record<string, string | null>; baseUrl?: string; }
interface CacheEntry { key: string; snapshot: ProviderUsageSnapshot; expiresAt: number; }
interface Inflight { promise: Promise<ProviderUsageSnapshot>; waiters: number; }
interface ReadAdmission {
  authSettled: boolean;
  fetchStarted: boolean;
  released: boolean;
  release: () => void;
}
interface ProviderBinding {
  providerBaseUrl: string | null;
  modelSignature: string;
  authBinding: string;
}
export interface ProviderUsageOptions {
  fetch?: typeof globalThis.fetch;
  now?: () => number;
  timeoutMs?: number;
}

const adapters: Record<string, Adapter> = {
  anthropic: {
    id: "anthropic", shapes: [{ api: "anthropic-messages", baseUrl: "https://api.anthropic.com" }],
    endpoint: "https://api.anthropic.com/api/oauth/usage", source: "anthropic.oauth-usage", scope: "account", oauthOnly: true,
    headers: anthropicOAuthHeaders, parse: parseAnthropicOAuthUsage,
  },
  "openai-codex": {
    id: "openai-codex", shapes: [{ api: "openai-codex-responses", baseUrl: "https://chatgpt.com/backend-api" }],
    endpoint: "https://chatgpt.com/backend-api/wham/usage", source: "openai-codex.wham", scope: "account",
    headers: codexHeaders, parse: parseCodex,
  },
  openrouter: {
    id: "openrouter", shapes: [{ api: "openai-completions", baseUrl: "https://openrouter.ai/api/v1" }],
    endpoint: "https://openrouter.ai/api/v1/key", source: "openrouter.key", scope: "key",
    headers: bearerHeaders, parse: parseOpenRouter,
  },
  "kimi-coding": {
    id: "kimi-coding", shapes: [{ api: "anthropic-messages", baseUrl: "https://api.kimi.com/coding" }],
    endpoint: "https://api.kimi.com/coding/v1/usages", source: "kimi-coding.usages", scope: "account",
    headers: bearerHeaders, parse: parseKimi,
  },
  zai: {
    id: "zai", shapes: [{ api: "openai-completions", baseUrl: "https://api.z.ai/api/coding/paas/v4" }],
    endpoint: "https://api.z.ai/api/monitor/usage/quota/limit", source: "zai.monitor", scope: "account",
    headers: rawHeaders, parse: parseZai,
  },
  "zai-coding-cn": {
    id: "zai-coding-cn", shapes: [{ api: "openai-completions", baseUrl: "https://open.bigmodel.cn/api/coding/paas/v4" }],
    endpoint: "https://open.bigmodel.cn/api/monitor/usage/quota/limit", source: "zai-coding-cn.monitor", scope: "account",
    headers: rawHeaders, parse: parseZai,
  },
  "opencode-go": {
    // Go models resolve across three wire APIs under two base URLs; the plan's
    // account usage is the one endpoint both the console and the CLI report.
    id: "opencode-go", shapes: [
      { api: "anthropic-messages", baseUrl: "https://opencode.ai/zen/go" },
      { api: "openai-completions", baseUrl: "https://opencode.ai/zen/go/v1" },
      { api: "openai-responses", baseUrl: "https://opencode.ai/zen/go/v1" },
    ],
    endpoint: "https://opencode.ai/zen/go/v1/usage", source: "opencode-go.usage", scope: "account",
    headers: bearerHeaders, parse: parseOpenCodeGo,
    // A valid key whose account is not on Go answers 403 EntitlementError. That
    // is not a rejected credential, so it must not ask the user to sign in again.
    failure: (status) => status === 403 ? { status: "unsupported", message: "This account has no OpenCode Go subscription" } : undefined,
  },
};

function emptySnapshot(providerId: string, status: ProviderStatus, source: string | null = null, scope: "account" | "key" | null = null, message: string | null = null): ProviderUsageSnapshot {
  return { providerId, status, source, scope, updatedAt: null, retryAt: null, stale: false, message, windows: [], balances: [] };
}
function normalizeBaseUrl(baseUrl: string): string { return baseUrl.replace(/\/+$/u, ""); }
function adapterBaseUrls(adapter: Adapter): Set<string> { return new Set(adapter.shapes.map((shape) => normalizeBaseUrl(shape.baseUrl))); }
function number(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim() !== "" && Number.isFinite(Number(value))) return Number(value);
  return null;
}
function object(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : null;
}
function text(value: unknown): string | null { return typeof value === "string" && value.length <= 200 ? value : null; }
function iso(value: unknown): string | null {
  const n = number(value);
  if (n !== null) { const date = new Date(n < 10_000_000_000 ? n * 1_000 : n); return Number.isNaN(date.getTime()) ? null : date.toISOString(); }
  if (typeof value === "string") { const date = new Date(value); return Number.isNaN(date.getTime()) ? null : date.toISOString(); }
  return null;
}
function seconds(value: unknown, unit?: unknown): number | null {
  const n = number(value); if (n === null || n <= 0) return null;
  const u = typeof unit === "string" ? unit.toLowerCase() : "second";
  const factor = u.startsWith("mill") ? .001 : u.startsWith("min") || u.includes("minute") ? 60 : u.startsWith("hour") ? 3_600 : u.startsWith("day") ? 86_400 : u.startsWith("week") ? 604_800 : 1;
  const result = n * factor;
  return Number.isSafeInteger(result) && result > 0 ? result : null;
}
function window(id: string, label: string, values: Partial<UsageWindow> = {}): UsageWindow {
  const rawLimit = values.limit ?? null;
  const limit = rawLimit !== null && rawLimit > 0 ? rawLimit : null;
  const used = values.used ?? null, remaining = values.remaining ?? null;
  const rawWindowSeconds = values.windowSeconds ?? null;
  const windowSeconds = typeof rawWindowSeconds === "number" && Number.isSafeInteger(rawWindowSeconds) && rawWindowSeconds > 0 ? rawWindowSeconds : null;
  let percent = values.usedPercent ?? null;
  if (percent === null && limit !== null && limit > 0 && used !== null) {
    const calculated = used / limit * 100;
    percent = Number.isFinite(calculated) ? calculated : null;
  }
  return { id, label, usedPercent: percent, used, limit, remaining, unit: values.unit ?? null, resetsAt: values.resetsAt ?? null, windowSeconds };
}
function capWindows(windows: UsageWindow[]): UsageWindow[] {
  const identities = new Set<string>();
  const admitted: UsageWindow[] = [];
  for (const item of windows) {
    if (item.id.length === 0 || item.label.length === 0 || identities.has(item.id)) throw new Error("duplicate or invalid usage window");
    identities.add(item.id); admitted.push(item);
  }
  return admitted.slice(0, MAX_WINDOWS);
}
function capBalances(balances: UsageBalance[]): UsageBalance[] {
  const identities = new Set<string>();
  const admitted: UsageBalance[] = [];
  for (const item of balances) {
    if (item.id.length === 0 || item.label.length === 0 || identities.has(item.id)) throw new Error("duplicate or invalid usage balance");
    if (!Number.isFinite(item.amount) || item.currency.length > 16) throw new Error("invalid usage balance");
    identities.add(item.id); admitted.push(item);
  }
  return admitted.slice(0, MAX_BALANCES);
}

function authValue(auth: ResolvedAuth): string | undefined {
  const value = auth.headers?.Authorization ?? auth.headers?.authorization;
  return typeof value === "string" && value.length > 0 ? value : auth.apiKey;
}
function bearerHeaders(auth: ResolvedAuth): Record<string, string> | undefined {
  const supplied = auth.headers?.Authorization ?? auth.headers?.authorization;
  if (typeof supplied === "string" && supplied.length > 0) return { Authorization: supplied };
  return auth.apiKey ? { Authorization: `Bearer ${auth.apiKey}` } : undefined;
}
function rawHeaders(auth: ResolvedAuth): Record<string, string> | undefined {
  const value = authValue(auth); return value ? { Authorization: value } : undefined;
}
function anthropicOAuthHeaders(auth: ResolvedAuth): Record<string, string> | undefined {
  const token = auth.apiKey;
  const suppliedAuthorization = auth.headers?.Authorization ?? auth.headers?.authorization;
  if (!token || (suppliedAuthorization && suppliedAuthorization !== `Bearer ${token}`)) return undefined;
  return {
    Authorization: `Bearer ${token}`,
    Accept: "application/json",
    "Content-Type": "application/json",
    "anthropic-beta": "oauth-2025-04-20",
    // CortexKit's pinned quota endpoint contract uses this CLI identifier.
    "User-Agent": "claude-code/2.1.280",
  };
}
function codexHeaders(auth: ResolvedAuth): Record<string, string> | undefined {
  const supplied = auth.headers?.Authorization ?? auth.headers?.authorization;
  const token = typeof supplied === "string" && supplied.startsWith("Bearer ") ? supplied.slice(7) : auth.apiKey;
  if (!token) return undefined;
  let account = auth.headers?.["chatgpt-account-id"] ?? auth.headers?.["ChatGPT-Account-Id"];
  if (typeof account !== "string" || account.length === 0) {
    // Codex OAuth's public toAuth result is an access token; the existing
    // first-party client derives account context from this non-secret JWT claim.
    try {
      const part = token.split(".")[1];
      const payload = part ? JSON.parse(Buffer.from(part, "base64url").toString("utf8")) as Record<string, unknown> : undefined;
      const claim = object(payload?.["https://api.openai.com/auth"])?.chatgpt_account_id;
      account = typeof claim === "string" ? claim : undefined;
    } catch { account = undefined; }
  }
  // The first-party endpoint requires both the ChatGPT bearer and account
  // context. An arbitrary API key must never be sent to chatgpt.com.
  if (!account) return undefined;
  return { Authorization: `Bearer ${token}`, "chatgpt-account-id": account };
}

const numericUsageFields = new Set(["used_percent", "limit_window_seconds", "limit", "used", "remaining", "limit_remaining", "usage_daily", "usage_weekly", "usage_monthly", "percentage", "currentValue", "windowSeconds", "duration"]);
function validateUsageNumbers(value: unknown): void {
  const pending: unknown[] = [value]; let visited = 0;
  while (pending.length > 0) {
    const current = pending.pop(); if (++visited > 2_000) throw new Error("usage body is too large");
    if (Array.isArray(current)) { pending.push(...current); continue; }
    const row = object(current); if (!row) continue;
    for (const [key, member] of Object.entries(row)) {
      if (numericUsageFields.has(key) && member !== null && typeof member !== "object") {
        const n = number(member); if (n === null || n < 0) throw new Error("invalid usage number");
      }
      if (member !== null && typeof member === "object") pending.push(member);
    }
  }
}
function parseCodex(body: unknown) {
  const root = object(body); if (!root) throw new Error("usage body is not an object");
  const rate = object(root.rate_limit) ?? root;
  const windows: UsageWindow[] = [];
  for (const [id, label] of [["primary", "Primary"], ["secondary", "Secondary"]] as const) {
    const row = object(rate?.[`${id}_window`]) ?? object(rate?.[id]); if (!row) continue;
    const usedPercent = number(row.used_percent); const limitSeconds = seconds(row.limit_window_seconds);
    windows.push(window(id, label, { usedPercent, resetsAt: iso(row.reset_at), windowSeconds: limitSeconds }));
  }
  const additional = root.additional_rate_limits;
  if (Array.isArray(additional)) additional.slice(0, MAX_WINDOWS).forEach((entry, i) => {
    const row = object(entry); if (!row) throw new Error("invalid additional rate limit");
    const nestedRate = object(row.rate_limit) ?? row;
    for (const [id, label] of [["primary", "Primary"], ["secondary", "Secondary"]] as const) {
      const nested = object(nestedRate[`${id}_window`]) ?? object(nestedRate[id]); if (!nested) continue;
      windows.push(window(`additional-${i + 1}-${id}`, `${label} ${i + 1}`, { usedPercent: number(nested.used_percent), resetsAt: iso(nested.reset_at), windowSeconds: seconds(nested.limit_window_seconds) }));
    }
  });
  if (windows.length === 0 && !root.credits) throw new Error("usage body has no known rate limits");
  return { windows: capWindows(windows), balances: parseBalances(root.credits) };
}
function parseOpenRouter(body: unknown) {
  const root = object(body); if (!root) throw new Error("usage body is not an object");
  if (root.data !== undefined && !object(root.data)) throw new Error("invalid usage data");
  const data = object(root.data) ?? root; const windows: UsageWindow[] = [];
  const limit = number(data.limit), remaining = number(data.limit_remaining);
  const positiveLimit = limit !== null && limit > 0 ? limit : null;
  const boundedRemaining = remaining !== null ? Math.max(0, Math.min(remaining, positiveLimit ?? remaining)) : null;
  const used = positiveLimit !== null && boundedRemaining !== null ? positiveLimit - boundedRemaining : null;
  if (limit !== null || remaining !== null) windows.push(window("key", "Key limit", { limit: positiveLimit, used, remaining: boundedRemaining, unit: "USD", resetsAt: iso(data.limit_reset) }));
  for (const id of ["daily", "weekly", "monthly"] as const) {
    const usage = number(data[`usage_${id}`]); if (usage !== null) windows.push(window(`spend-${id}`, `${id[0]!.toUpperCase()}${id.slice(1)} spend`, { used: usage, unit: "USD" }));
  }
  if (windows.length === 0) throw new Error("usage body has no known key usage");
  return { windows: capWindows(windows), balances: [] };
}
function parseKimi(body: unknown) {
  const root = object(body); if (!root) throw new Error("usage body is not an object"); const windows: UsageWindow[] = [];
  const add = (id: string, label: string, row: Record<string, unknown>) => {
    const limit = number(row.limit), used = number(row.used), remaining = number(row.remaining);
    const detail = object(row.detail); const source = detail ?? row;
    windows.push(window(id, label, { limit: limit ?? number(source.limit), used: used ?? number(source.used), remaining: remaining ?? number(source.remaining), resetsAt: iso(source.resetTime), windowSeconds: seconds(object(row.window)?.duration, object(row.window)?.timeUnit) }));
  };
  const usage = object(root?.usage); if (usage) add("usage", "Usage", usage);
  if (Array.isArray(root?.limits)) root!.limits.slice(0, MAX_WINDOWS).forEach((entry, i) => { const row = object(entry); if (row) add(text(row.id) ?? `limit-${i + 1}`, text(row.label) ?? `Limit ${i + 1}`, row); });
  if (windows.length === 0) throw new Error("usage body has no known Kimi usage");
  return { windows: capWindows(windows), balances: [] };
}
function parseZai(body: unknown) {
  const root = object(body); if (!root) throw new Error("usage body is not an object");
  if (root.data !== undefined && !object(root.data)) throw new Error("invalid usage data");
  const data = object(root.data) ?? root; const windows: UsageWindow[] = [];
  if (Array.isArray(data?.limits)) data.limits.slice(0, MAX_WINDOWS).forEach((entry, i) => {
    const row = object(entry); if (!row) return;
    const usedPercent = number(row.percentage) ?? number(row.used_percent);
    windows.push(window(text(row.id) ?? `limit-${i + 1}`, text(row.name) ?? text(row.label) ?? `Quota ${i + 1}`, { usedPercent, used: number(row.used) ?? number(row.currentValue), limit: number(row.limit), remaining: number(row.remaining), unit: text(row.unit), resetsAt: iso(row.resetAt) ?? iso(row.reset_at), windowSeconds: seconds(row.windowSeconds) }));
  });
  if (windows.length === 0) throw new Error("usage body has no known Z.ai quota");
  return { windows: capWindows(windows), balances: [] };
}
function parseAnthropicOAuthUsage(body: unknown) {
  const root = object(body); if (!root) throw new Error("usage body is not an object");
  const windows: UsageWindow[] = [];
  for (const [key, id, label, duration] of [["five_hour", "five-hour", "5h", 18_000], ["seven_day", "seven-day", "Weekly", 604_800]] as const) {
    const row = root[key] === undefined || root[key] === null ? undefined : object(root[key]);
    if (root[key] !== undefined && root[key] !== null && !row) throw new Error("invalid Anthropic usage window");
    if (!row || row.utilization === undefined) continue;
    const utilization = number(row.utilization);
    if (utilization === null || utilization < 0 || utilization > 100) throw new Error("invalid Anthropic usage percent");
    windows.push(window(id, label, { usedPercent: utilization, resetsAt: iso(row.resets_at), windowSeconds: duration }));
  }
  if (root.limits !== undefined && !Array.isArray(root.limits)) throw new Error("invalid Anthropic usage limits");
  if (Array.isArray(root.limits)) {
    const seenScopedLimits = new Set<string>();
    for (const limitValue of root.limits.slice(0, MAX_WINDOWS)) {
      const limit = object(limitValue);
      if (!limit) throw new Error("invalid Anthropic usage limit");
      if (limit.kind !== "weekly_scoped" || limit.group !== "weekly") continue;
      const scope = object(limit.scope); const model = object(scope?.model);
      const modelName = text(model?.display_name); const modelId = text(model?.id);
      const percent = number(limit.percent);
      if (limit.percent !== undefined && limit.percent !== null && (percent === null || percent < 0 || percent > 100)) {
        throw new Error("invalid Anthropic model usage percent");
      }
      if (!modelName || percent === null) continue;
      const identity = (modelId ?? modelName).toLowerCase().replace(/[^a-z0-9]+/gu, "-").replace(/^-|-$/gu, "");
      if (!identity || seenScopedLimits.has(identity)) continue;
      seenScopedLimits.add(identity);
      windows.push(window(`weekly-${identity}`, `${modelName} only`, { usedPercent: percent, resetsAt: iso(limit.resets_at), windowSeconds: 604_800 }));
    }
  }
  const extra = object(root.extra_usage);
  if (extra?.is_enabled === true) {
    const usedMinor = number(extra.used_credits); const limitMinor = number(extra.monthly_limit);
    const utilization = extra.utilization === undefined || extra.utilization === null ? null : number(extra.utilization);
    const spend = object(object(root.spend)?.limit);
    const currency = spend?.currency === undefined || spend.currency === null ? "USD" : text(spend.currency);
    const exponent = spend?.exponent === undefined || spend.exponent === null ? 2 : number(spend.exponent);
    // Extra usage is optional in Anthropic's response; malformed/incomplete
    // detail must not suppress valid account quota windows above.
    if (usedMinor !== null && usedMinor >= 0 && limitMinor !== null && limitMinor >= 0
        && currency && /^[A-Za-z]{3}$/u.test(currency)
        && exponent !== null && Number.isInteger(exponent) && exponent >= 0 && exponent <= 20
        && (utilization === null || (utilization >= 0 && utilization <= 100))) {
      const divisor = 10 ** exponent;
      windows.push(window("extra-usage-monthly", "Extra usage this month", {
        used: usedMinor / divisor, limit: limitMinor / divisor, unit: currency, usedPercent: utilization,
      }));
    }
  }
  const knownFields = ["five_hour", "seven_day", "limits", "extra_usage", "spend"];
  if (!knownFields.some((key) => Object.hasOwn(root, key))) throw new Error("usage body has no known Anthropic quota fields");
  return { windows: capWindows(windows), balances: [] };
}
function parseOpenCodeGo(body: unknown) {
  const root = object(body); if (!root) throw new Error("usage body is not an object");
  const usage = object(root.usage); if (!usage) throw new Error("usage body has no usage object");
  const windows: UsageWindow[] = [];
  // The Go plan fixes these three account-wide windows; the endpoint reports a
  // used percent and reset only, so amounts stay null rather than invented.
  for (const [id, label, windowSeconds] of [["rolling", "5h", 18_000], ["weekly", "Weekly", 604_800], ["monthly", "Monthly", 2_592_000]] as const) {
    const row = object(usage[id]); if (!row) throw new Error("invalid OpenCode Go usage window");
    const usedPercent = number(row.percent);
    if (usedPercent === null || usedPercent < 0 || usedPercent > 100) throw new Error("invalid OpenCode Go usage percent");
    windows.push(window(id, label, { usedPercent, resetsAt: iso(row.resetsAt), windowSeconds }));
  }
  return { windows: capWindows(windows), balances: [] };
}
function parseBalances(value: unknown): UsageBalance[] {
  const row = object(value); if (!row) return [];
  const amount = number(row.balance) ?? number(row.amount) ?? number(row.remaining); const currency = text(row.currency) ?? "USD";
  return amount === null ? [] : capBalances([{ id: "credits", label: "Credits", amount, currency }]);
}

/** True when this runtime's effective composition has a first-party usage adapter. */
export function providerUsageSupported(runtime: ModelRuntime, providerId: string): boolean {
  const adapter = adapterFor(runtime, providerId);
  return adapter !== undefined && (!adapter.oauthOnly || !runtime.hasConfiguredAuth(providerId) || runtime.isUsingOAuth(providerId));
}

function providerBinding(runtime: ModelRuntime, id: string): ProviderBinding {
  const models = runtime.getModels(id);
  const provider = runtime.getProvider(id);
  return {
    providerBaseUrl: provider?.baseUrl ? normalizeBaseUrl(provider.baseUrl) : null,
    modelSignature: models.map((model) => `${model.api}:${normalizeBaseUrl(model.baseUrl)}`).join("|"),
    authBinding: provider
      ? `${Object.keys(provider.auth).sort().join(",")}:${(runtime as ModelRuntime & { isUsingOAuth?: (providerId: string) => boolean }).isUsingOAuth?.(id) === true ? "oauth" : "api-key"}`
      : "",
  };
}
function adapterFor(runtime: ModelRuntime, id: string): Adapter | undefined {
  const adapter = adapters[id]; if (!adapter) return undefined;
  const binding = providerBinding(runtime, id);
  // Matching the effective composed models is intentional: provider IDs alone can
  // be reused by models.json or an extension for an unrelated upstream, so every
  // resolved (api, base URL) must be a declared first-party shape.
  const declared = new Set(adapter.shapes.map((shape) => `${shape.api}:${normalizeBaseUrl(shape.baseUrl)}`));
  const models = runtime.getModels(id);
  const exactModels = models.length > 0 && models.every((model) => declared.has(`${model.api}:${normalizeBaseUrl(model.baseUrl)}`));
  const exactProvider = binding.providerBaseUrl === null || adapterBaseUrls(adapter).has(binding.providerBaseUrl);
  return exactModels && exactProvider ? adapter : undefined;
}
function sameBinding(left: ProviderBinding, right: ProviderBinding): boolean {
  return left.providerBaseUrl === right.providerBaseUrl
    && left.modelSignature === right.modelSignature
    && left.authBinding === right.authBinding;
}
function fingerprint(auth: ResolvedAuth): string {
  const safe = JSON.stringify({ apiKey: auth.apiKey, headers: auth.headers, baseUrl: auth.baseUrl });
  return createHash("sha256").update(safe).digest("hex");
}
function raceAbort<T>(promise: Promise<T>, signal?: AbortSignal): Promise<T> {
  if (!signal) return promise;
  if (signal.aborted) return Promise.reject(new DOMException("Aborted", "AbortError"));
  return new Promise<T>((resolve, reject) => { const abort = () => reject(new DOMException("Aborted", "AbortError")); signal.addEventListener("abort", abort, { once: true }); promise.then((value) => { signal.removeEventListener("abort", abort); resolve(value); }, (error) => { signal.removeEventListener("abort", abort); reject(error); }); });
}

export class ProviderUsageOwner {
  private readonly cache = new Map<string, CacheEntry>();
  private readonly inflight = new Map<string, Inflight>();
  private readonly runtimeIdentities = new WeakMap<object, number>();
  private nextRuntimeIdentity = 1;
  private activeReads = 0;
  private readonly options: Required<ProviderUsageOptions>;
  constructor(options: ProviderUsageOptions = {}) { this.options = { fetch: options.fetch ?? globalThis.fetch, now: options.now ?? Date.now, timeoutMs: options.timeoutMs ?? REQUEST_TIMEOUT_MS }; }

  async read(runtime: ModelRuntime, providerId: string | undefined, signal?: AbortSignal): Promise<ProviderUsageResponse> {
    const ids = providerId === undefined
      ? Object.keys(adapters).filter((id) => providerUsageSupported(runtime, id) && runtime.hasConfiguredAuth(id))
      : [providerId];
    const providers = await Promise.all(ids.slice(0, MAX_PROVIDERS).map((id) => this.readOne(runtime, id, signal)));
    return { providers };
  }
  private async readOne(runtime: ModelRuntime, providerId: string, signal?: AbortSignal): Promise<ProviderUsageSnapshot> {
    const admission = this.acquireAdmission();
    if (!admission) return emptySnapshot(providerId, "unavailable", adapters[providerId]?.source ?? null, adapters[providerId]?.scope ?? null, "Provider usage is busy");
    try { return await this.readOneAdmitted(runtime, providerId, signal, admission); }
    catch (error) {
      // A timed-out race may leave the credential provider physically running;
      // resolveAuth owns that release. Synchronous failures before an auth call
      // still release their admission here.
      if (!admission.fetchStarted && admission.authSettled) admission.release();
      throw error;
    }
  }
  private async readOneAdmitted(runtime: ModelRuntime, providerId: string, signal: AbortSignal | undefined, admission: ReadAdmission): Promise<ProviderUsageSnapshot> {
    const initialBinding = providerBinding(runtime, providerId);
    const adapter = adapterFor(runtime, providerId);
    if (!adapter) {
      admission.release();
      return emptySnapshot(providerId, "unsupported", adapters[providerId]?.source ?? null, adapters[providerId]?.scope ?? null, "Usage is not supported for this provider configuration");
    }
    if (adapter.oauthOnly && !runtime.isUsingOAuth(providerId)) {
      admission.release();
      return emptySnapshot(providerId, runtime.hasConfiguredAuth(providerId) ? "unsupported" : "unconfigured", adapter.source, adapter.scope,
        runtime.hasConfiguredAuth(providerId) ? "Anthropic subscription usage requires OAuth sign-in" : "Sign in with Anthropic OAuth to view subscription usage");
    }
    let authResult: { auth: ResolvedAuth } | undefined;
    try { authResult = await this.resolveAuth(runtime, providerId, signal, admission); }
    catch (error) {
      if (signal?.aborted) throw error;
      return emptySnapshot(providerId, "authentication_required", adapter.source, adapter.scope, "Provider authentication is unavailable");
    }
    if (!authResult?.auth) {
      admission.release();
      return emptySnapshot(providerId, "unconfigured", adapter.source, adapter.scope, "Provider authentication is not configured");
    }
    if (authResult.auth.baseUrl !== undefined && !adapterBaseUrls(adapter).has(normalizeBaseUrl(authResult.auth.baseUrl))) {
      admission.release();
      return emptySnapshot(providerId, "unsupported", adapter.source, adapter.scope, "Usage is not supported for this provider configuration");
    }
    // The effective model/provider composition can change while credential
    // lookup awaits. Never send the credential to a binding captured earlier.
    if (!sameBinding(initialBinding, providerBinding(runtime, providerId))) {
      admission.release();
      return emptySnapshot(providerId, "unsupported", adapter.source, adapter.scope, "Usage is not supported for this provider configuration");
    }
    if (!adapter.headers(authResult.auth)) {
      admission.release();
      return emptySnapshot(providerId, "unconfigured", adapter.source, adapter.scope, "Provider authentication is not configured");
    }
    const key = this.usageKey(runtime, adapter, authResult.auth);
    const now = this.options.now(); const cached = this.cache.get(key);
    if (cached && cached.expiresAt > now) {
      admission.release();
      const verified = await this.verifyCurrentAuth(runtime, providerId, adapter, key, signal);
      if (verified === undefined) return emptySnapshot(providerId, "unavailable", adapter.source, adapter.scope, "Provider usage is busy");
      if (!verified) return emptySnapshot(providerId, "unavailable", adapter.source, adapter.scope, "Provider usage changed while the request was in flight");
      return { ...cached.snapshot, windows: cached.snapshot.windows.map((w) => ({ ...w })), balances: cached.snapshot.balances.map((b) => ({ ...b })) };
    }
    const existing = this.inflight.get(key);
    if (existing && existing.waiters >= MAX_INFLIGHT_WAITERS) {
      admission.release();
      return emptySnapshot(providerId, "unavailable", adapter.source, adapter.scope, "Provider usage is busy");
    }
    let flight = existing;
    if (!flight) {
      admission.fetchStarted = true;
      const promise = this.fetchOne(adapter, authResult.auth, key);
      void promise.then(() => admission.release(), () => admission.release());
      flight = { promise, waiters: 0 };
      this.inflight.set(key, flight);
      void promise.then(() => {
        if (this.inflight.get(key) === flight) this.inflight.delete(key);
      }, () => {
        if (this.inflight.get(key) === flight) this.inflight.delete(key);
      });
    } else {
      admission.fetchStarted = true;
      void flight.promise.then(() => admission.release(), () => admission.release());
    }
    flight.waiters += 1;
    try {
      const snapshot = await raceAbort(flight.promise, signal);
      // Auth can be replaced while the socket is in flight. Do not publish a
      // late response under the newly selected account, even to the same client.
      const verified = await this.verifyCurrentAuth(runtime, providerId, adapter, key, signal);
      if (verified === undefined) return emptySnapshot(providerId, "unavailable", adapter.source, adapter.scope, "Provider usage is busy");
      if (!verified) {
        // Never route the old cache entry through failed(): it would preserve
        // old-account windows as a stale available projection.
        return emptySnapshot(providerId, "unavailable", adapter.source, adapter.scope, "Provider usage changed while the request was in flight");
      }
      return snapshot;
    }
    finally {
      flight.waiters -= 1;
      // Producer settlement, rather than the first waiter, owns flight cleanup.
      // A cancelled waiter must not cancel or prematurely remove the socket.
    }
  }
  private acquireAdmission(): ReadAdmission | undefined {
    if (this.activeReads >= MAX_ACTIVE_READS) return undefined;
    this.activeReads += 1;
    const admission = { authSettled: false, fetchStarted: false, released: false, release: () => undefined } as ReadAdmission;
    admission.release = () => {
      if (admission.released) return;
      admission.released = true;
      this.activeReads -= 1;
    };
    return admission;
  }
  private async verifyCurrentAuth(runtime: ModelRuntime, providerId: string, adapter: Adapter, key: string, signal?: AbortSignal): Promise<boolean | undefined> {
    const admission = this.acquireAdmission();
    if (!admission) return undefined;
    try {
      const latest = await this.resolveAuth(runtime, providerId, signal, admission);
      return !!latest?.auth && this.usageKey(runtime, adapter, latest.auth) === key;
    } catch (error) {
      if (signal?.aborted) throw error;
      return false;
    } finally {
      if (admission.authSettled) admission.release();
    }
  }
  private async resolveAuth(runtime: ModelRuntime, providerId: string, signal?: AbortSignal, admission?: ReadAdmission): Promise<{ auth: ResolvedAuth } | undefined> {
    if (signal?.aborted) {
      admission?.release();
      throw new DOMException("Aborted", "AbortError");
    }
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.options.timeoutMs);
    const cancel = () => controller.abort();
    signal?.addEventListener("abort", cancel, { once: true });
    let physical: Promise<{ auth: ResolvedAuth } | undefined> | undefined;
    try {
      const pending = runtime.getAuth(providerId, { signal: controller.signal }) as Promise<{ auth: ResolvedAuth } | undefined>;
      if (!admission) return await raceAbort(pending, controller.signal);
      admission.authSettled = false;
      // Admission remains held until a non-cooperating credential provider
      // physically settles, even when this caller's race times out.
      physical = pending.then((result) => {
        admission.authSettled = true;
        return result;
      }, (error) => {
        admission.authSettled = true;
        admission.release();
        throw error;
      });
      return await raceAbort(physical, controller.signal);
    } catch (error) {
      if (admission?.authSettled && !admission.fetchStarted) {
        admission.release();
      } else if (admission && !admission.authSettled) {
        // A cancelled/timed-out race must retain the token until the detached
        // credential operation physically settles.
        void physical?.then(() => admission.release(), () => admission.release());
      }
      throw error;
    } finally {
      clearTimeout(timer);
      signal?.removeEventListener("abort", cancel);
    }
  }
  private usageKey(runtime: ModelRuntime, adapter: Adapter, auth: ResolvedAuth): string {
    const runtimeObject = runtime as unknown as object;
    let runtimeIdentity = this.runtimeIdentities.get(runtimeObject);
    if (runtimeIdentity === undefined) {
      runtimeIdentity = this.nextRuntimeIdentity++;
      this.runtimeIdentities.set(runtimeObject, runtimeIdentity);
    }
    const binding = providerBinding(runtime, adapter.id);
    return `${runtimeIdentity}:${adapter.id}:${binding.providerBaseUrl ?? ""}:${binding.modelSignature}:${binding.authBinding}:${fingerprint(auth)}`;
  }
  private async fetchOne(adapter: Adapter, auth: ResolvedAuth, key: string): Promise<ProviderUsageSnapshot> {
    const started = this.options.now(); const controller = new AbortController(); const timer = setTimeout(() => controller.abort(), this.options.timeoutMs);
    try {
      const headers = adapter.headers(auth); if (!headers) return emptySnapshot(adapter.id, "unconfigured", adapter.source, adapter.scope, "Provider authentication is not configured");
      const response = await this.options.fetch(adapter.endpoint, { method: "GET", headers, redirect: "error", signal: controller.signal });
      const retry = response.status === 429 ? retryAfter(response.headers, started, this.options.now) : null;
      const override = response.status >= 400 ? adapter.failure?.(response.status) : undefined;
      if (override) {
        await cancelResponseBody(response);
        return this.failed(adapter, key, override.status, override.message, retry);
      }
      if (response.status === 401 || response.status === 403) {
        await cancelResponseBody(response);
        return this.failed(adapter, key, "authentication_required", "Provider authentication was rejected", retry);
      }
      if (response.status === 429) {
        await cancelResponseBody(response);
        return this.failed(adapter, key, "rate_limited", "Provider usage is temporarily rate limited", retry);
      }
      if (!response.ok) {
        await cancelResponseBody(response);
        return this.failed(adapter, key, "unavailable", "Provider usage is temporarily unavailable", retry);
      }
      const raw = await readBoundedBody(response);
      let body: unknown; try { body = JSON.parse(raw); } catch { return this.failed(adapter, key, "unavailable", "Provider usage response was malformed", null); }
      try { validateUsageNumbers(body); } catch { return this.failed(adapter, key, "unavailable", "Provider usage response was malformed", null); }
      let parsed: { windows: UsageWindow[]; balances: UsageBalance[] };
      try { parsed = adapter.parse(body); } catch { return this.failed(adapter, key, "unavailable", "Provider usage response was malformed", null); }
      const updatedAt = new Date(this.options.now()).toISOString();
      const snapshot: ProviderUsageSnapshot = { providerId: adapter.id, status: "available", source: adapter.source, scope: adapter.scope, updatedAt, retryAt: null, stale: false, message: null, windows: parsed.windows, balances: parsed.balances };
      this.cache.set(key, { key, snapshot, expiresAt: this.options.now() + FRESH_MS }); this.trimCache(); return snapshot;
    } catch (error) {
      if (error instanceof BodyTooLargeError) return this.failed(adapter, key, "unavailable", "Provider usage response was too large", null);
      if (error instanceof DOMException && error.name === "AbortError") return this.failed(adapter, key, "unavailable", "Provider usage request timed out", null);
      if (error instanceof TypeError) return this.failed(adapter, key, "unavailable", "Provider usage request failed", null);
      return this.failed(adapter, key, "unavailable", "Provider usage request failed", null);
    } finally { clearTimeout(timer); }
  }
  private failed(adapter: Adapter, key: string, status: ProviderStatus, message: string, retryAt: string | null): ProviderUsageSnapshot {
    const retry = retryAt ?? new Date(this.options.now() + NEGATIVE_RETRY_MS).toISOString();
    const prior = this.cache.get(key)?.snapshot;
    const snapshot = prior
      ? { ...prior, status, retryAt: retry, stale: true, message }
      : { ...emptySnapshot(adapter.id, status, adapter.source, adapter.scope, message), retryAt: retry };
    this.cache.set(key, { key, snapshot, expiresAt: Date.parse(retry) });
    this.trimCache();
    return snapshot;
  }
  private trimCache(): void { while (this.cache.size > MAX_PROVIDERS) this.cache.delete(this.cache.keys().next().value!); }
}
class BodyTooLargeError extends Error {}
async function cancelResponseBody(response: Response): Promise<void> {
  try { await response.body?.cancel(); } catch { /* response cleanup is best effort */ }
}
async function readBoundedBody(response: Response): Promise<string> {
  // A real fetch Response has a stream for non-empty bodies. Treat an absent
  // stream as an empty body rather than calling an unbounded text() fallback.
  if (!response.body) return "";
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = []; let size = 0;
  try {
    while (true) {
      const next = await reader.read();
      if (next.done) break;
      size += next.value.byteLength;
      if (size > MAX_BODY_BYTES) { await reader.cancel(); throw new BodyTooLargeError(); }
      chunks.push(next.value);
    }
    const bytes = new Uint8Array(size); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    return new TextDecoder().decode(bytes);
  } finally { reader.releaseLock(); }
}
function retryAfter(headers: Headers, now: number, clock: () => number): string | null {
  const raw = headers.get("retry-after");
  let delay: number;
  if (!raw) delay = 30_000;
  else if (/^\d+(?:\.\d+)?$/u.test(raw.trim())) delay = Number(raw) * 1_000;
  else {
    const at = Date.parse(raw); delay = Number.isFinite(at) ? at - Math.max(clock(), now) : 30_000;
  }
  if (!Number.isFinite(delay) || delay < 0) delay = 30_000;
  delay = Math.min(delay, MAX_RETRY_MS);
  return new Date(Math.max(clock(), now) + delay).toISOString();
}
