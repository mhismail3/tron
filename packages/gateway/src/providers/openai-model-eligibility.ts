import { createHash } from "node:crypto";
import type { Model } from "@earendil-works/pi-ai";
import type { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import { providerUsageLentTo } from "./provider-usage.js";

const MODELS_URL = "https://api.openai.com/v1/models";
const REQUEST_TIMEOUT_MS = 5_000;
const SUCCESS_TTL_MS = 60_000;
const MAX_DISCOVERY_MODELS = 25_000;
const installed = new WeakMap<ModelRuntime, OpenAIModelEligibility>();

type OpenAIModel = Model<any>;
interface DiscoveryEntry { slug: string; visibility: string; displayName?: string; }
interface AccountModels { entries: readonly string[]; displayNames: ReadonlyMap<string, string>; expiresAt: number; }
export interface OpenAIModelEligibilityOptions {
  /** Provider-usage has the same narrow fetch injection seam; production always uses global fetch. */
  fetch?: typeof globalThis.fetch;
  now?: () => number;
}

function firstPartyOpenAI(runtime: ModelRuntime): boolean {
  const provider = runtime.getProvider("openai");
  if (!provider || normalize(provider.baseUrl ?? "") !== "https://api.openai.com/v1") return false;
  const models = runtime.getModels("openai");
  return models.length > 0 && models.every(model => model.api === "openai-responses"
    && normalize(model.baseUrl) === "https://api.openai.com/v1");
}
function normalize(value: string): string { return value.replace(/\/+$/u, "").toLowerCase(); }
function tokenFingerprint(token: string): string { return createHash("sha256").update(token).digest("hex"); }
function parsePage(value: unknown): { entries: DiscoveryEntry[]; hasMore: boolean; lastId?: string } {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("OpenAI model discovery response is invalid");
  const root = value as Record<string, unknown>;
  if (!Array.isArray(root.models) || root.models.length > MAX_DISCOVERY_MODELS) throw new Error("OpenAI model discovery response is invalid");
  const entries: DiscoveryEntry[] = [];
  for (const item of root.models) {
    if (!item || typeof item !== "object" || Array.isArray(item)) continue;
    const row = item as Record<string, unknown>;
    if (typeof row.slug === "string" && row.slug.length <= 300 && typeof row.visibility === "string") {
      entries.push({ slug: row.slug, visibility: row.visibility, ...(typeof row.display_name === "string" && row.display_name.length <= 300 ? { displayName: row.display_name } : {}) });
    }
  }
  if (root.has_more !== undefined && typeof root.has_more !== "boolean") throw new Error("OpenAI model discovery pagination is invalid");
  if (root.last_id !== undefined && typeof root.last_id !== "string") throw new Error("OpenAI model discovery pagination is invalid");
  return { entries, hasMore: root.has_more === true, ...(typeof root.last_id === "string" ? { lastId: root.last_id } : {}) };
}

/** One runtime-bound authority for account visibility and new model choices. */
export class OpenAIModelEligibility {
  private readonly fetch: typeof globalThis.fetch;
  private readonly now: () => number;
  private readonly byAccount = new Map<string, AccountModels>();
  private currentFingerprint: string | undefined;
  private currentOAuth: boolean | undefined;
  private readonly discovery = new Map<string, Promise<void>>();
  private currentEligible: readonly string[] = [];
  private currentDisplayNames: ReadonlyMap<string, string> = new Map();
  private unregisteredAccountSlugs = 0;
  private currentAccount: string | undefined;

  constructor(private readonly runtime: ModelRuntime, options: OpenAIModelEligibilityOptions = {}) {
    this.fetch = options.fetch ?? globalThis.fetch;
    this.now = options.now ?? Date.now;
    const getAvailable = runtime.getAvailable.bind(runtime);
    runtime.getAvailable = (async (providerId?: string, options?: { signal?: AbortSignal }) => {
      await this.refresh(options?.signal);
      const models = await getAvailable(providerId, options);
      return models.filter(model => this.isEligible(model));
    }) as ModelRuntime["getAvailable"];
    const getAvailableSnapshot = runtime.getAvailableSnapshot.bind(runtime);
    runtime.getAvailableSnapshot = (() => getAvailableSnapshot().filter(model => this.isEligible(model))) as ModelRuntime["getAvailableSnapshot"];
  }

  async refresh(signal?: AbortSignal): Promise<void> {
    if (signal?.aborted) return;
    if (!firstPartyOpenAI(this.runtime)) {
      this.currentOAuth = false;
      this.currentEligible = [];
      this.currentDisplayNames = new Map();
      this.currentAccount = undefined;
      return;
    }
    let credentials;
    try {
      credentials = await this.runtime.listCredentials(signal ? { signal } : undefined);
    } catch {
      this.currentOAuth = undefined;
      this.currentEligible = [];
      this.currentDisplayNames = new Map();
      this.currentAccount = undefined;
      return;
    }
    const credential = credentials.find(item => item.providerId === "openai");
    let authType = credential?.type;
    if (!authType) {
      try {
        authType = (await this.runtime.checkAuth("openai", signal ? { signal } : undefined))?.type;
      } catch {
        this.currentOAuth = undefined;
        this.currentEligible = [];
        this.currentDisplayNames = new Map();
        this.currentAccount = undefined;
        return;
      }
    }
    this.currentOAuth = authType === "oauth";
    if (!this.currentOAuth) {
      this.currentEligible = [];
      this.currentDisplayNames = new Map();
      this.currentAccount = undefined;
      return;
    }
    const result = await this.runtime.getAuth("openai", signal ? { signal } : undefined);
    const token = result?.auth.apiKey;
    if (!token) {
      this.currentEligible = [];
      this.currentDisplayNames = new Map();
      this.currentAccount = undefined;
      return;
    }
    const fingerprint = tokenFingerprint(token);
    this.currentFingerprint = fingerprint;
    this.currentAccount = fingerprint;
    const cached = this.byAccount.get(fingerprint);
    this.currentEligible = cached?.entries ?? [];
    this.currentDisplayNames = cached?.displayNames ?? new Map();
    if (cached && cached.expiresAt > this.now()) {
      this.currentEligible = cached.entries;
      this.currentDisplayNames = cached.displayNames;
      return;
    }
    const pending = this.discovery.get(fingerprint);
    if (pending) return pending;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(new DOMException("OpenAI model discovery timed out", "TimeoutError")), REQUEST_TIMEOUT_MS);
    const abort = () => controller.abort(signal?.reason);
    signal?.addEventListener("abort", abort, { once: true });
    const task = this.discover(token, fingerprint, controller.signal).catch(() => {
      if (this.currentFingerprint !== fingerprint) return;
      const last = this.byAccount.get(fingerprint);
      this.currentEligible = last?.entries ?? [];
      this.currentDisplayNames = last?.displayNames ?? new Map();
    }).finally(() => {
      clearTimeout(timer);
      signal?.removeEventListener("abort", abort);
      this.discovery.delete(fingerprint);
    });
    this.discovery.set(fingerprint, task);
    return task;
  }

  isEligible(model: Pick<OpenAIModel, "provider" | "id">): boolean {
    if (model.provider === "openai") {
      if (this.currentOAuth === false || !firstPartyOpenAI(this.runtime)) return true;
      return this.currentOAuth === true && this.currentFingerprint !== undefined && this.currentAccount === this.currentFingerprint
        && this.currentEligible.includes(model.id);
    }
    if (model.provider === "openai-codex" && providerUsageLentTo(this.runtime, "openai-codex") === "openai") return false;
    return true;
  }

  assertEligible(provider: string, id: string): void {
    if (!this.isEligible({ provider, id })) {
      throw new GatewayError("invalid_request", "Model is not available for new selections");
    }
  }

  countChoices(providerId: string): number {
    return this.runtime.getModels(providerId).filter(model => this.isEligible(model)).length;
  }

  get ignoredUnknownSlugCount(): number { return this.unregisteredAccountSlugs; }

  displayName(provider: string, id: string): string | undefined {
    return provider === "openai" && this.currentEligible.includes(id) ? this.currentDisplayNames.get(id) : undefined;
  }

  orderAccountModels<T extends Pick<OpenAIModel, "provider" | "id">>(models: readonly T[]): T[] {
    const positions = models.flatMap((model, index) => model.provider === "openai" ? [index] : []);
    const ordered = positions.map(index => models[index]!).sort((left, right) => {
      const leftRank = this.currentEligible.indexOf(left.id);
      const rightRank = this.currentEligible.indexOf(right.id);
      if (leftRank < 0) return rightRank < 0 ? 0 : 1;
      if (rightRank < 0) return -1;
      return leftRank - rightRank;
    });
    const result = [...models];
    positions.forEach((position, index) => { result[position] = ordered[index]!; });
    return result;
  }

  private async discover(token: string, fingerprint: string, signal: AbortSignal): Promise<void> {
    const entries: DiscoveryEntry[] = [];
    let totalModels = 0;
    let after: string | undefined;
    for (let page = 0; page < 50; page += 1) {
      const url = new URL(MODELS_URL);
      if (after) url.searchParams.set("after", after);
      const response = await this.fetch(url, {
        method: "GET", redirect: "error", signal,
        headers: { Authorization: `Bearer ${token}`, Accept: "application/json" },
      });
      if (!response.ok) throw new Error(`OpenAI model discovery failed with HTTP ${response.status}`);
      const pageData = parsePage(await response.json());
      totalModels += pageData.entries.length;
      if (totalModels > MAX_DISCOVERY_MODELS) throw new Error("OpenAI model discovery exceeded its item limit");
      for (const row of pageData.entries) if (row.visibility === "list") entries.push(row);
      if (!pageData.hasMore) break;
      if (!pageData.lastId || pageData.lastId === after || page === 49) throw new Error("OpenAI model discovery pagination is invalid");
      after = pageData.lastId;
    }
    const current = await this.runtime.getAuth("openai", { signal });
    if (!current?.auth.apiKey || tokenFingerprint(current.auth.apiKey) !== fingerprint || this.currentFingerprint !== fingerprint || signal.aborted) return;
    const registered = new Set(this.runtime.getModels("openai").map(model => model.id));
    this.unregisteredAccountSlugs = entries.filter((entry, index) => !registered.has(entry.slug)
      && entries.findIndex(candidate => candidate.slug === entry.slug) === index).length;
    const recognizedEntries = entries.filter((entry, index) => registered.has(entry.slug)
      && entries.findIndex(candidate => candidate.slug === entry.slug) === index);
    const recognized = recognizedEntries.map(entry => entry.slug);
    const displayNames = new Map(recognizedEntries.flatMap(entry => entry.displayName ? [[entry.slug, entry.displayName] as const] : []));
    this.byAccount.set(fingerprint, { entries: recognized, displayNames, expiresAt: this.now() + SUCCESS_TTL_MS });
    if (this.currentFingerprint === fingerprint) {
      this.currentEligible = recognized;
      this.currentDisplayNames = displayNames;
    }
  }
}

export function installOpenAIModelEligibility(runtime: ModelRuntime, options: OpenAIModelEligibilityOptions = {}): OpenAIModelEligibility {
  const current = installed.get(runtime);
  if (current) return current;
  const policy = new OpenAIModelEligibility(runtime, options);
  installed.set(runtime, policy);
  return policy;
}
export function openAIModelEligibility(runtime: ModelRuntime): OpenAIModelEligibility | undefined { return installed.get(runtime); }
export async function assertNewModelChoice(runtime: ModelRuntime, provider: string, id: string, signal?: AbortSignal): Promise<void> {
  const policy = installed.get(runtime);
  if (!policy) return;
  await policy.refresh(signal);
  policy.assertEligible(provider, id);
}
