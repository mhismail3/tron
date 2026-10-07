import { createHash } from "node:crypto";
import type { Api, Credential, Model, Provider } from "@earendil-works/pi-ai";
import type { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import { providerUsageLentTo } from "./provider-usage.js";

const MODELS_URL = "https://api.openai.com/v1/models";
const REQUEST_TIMEOUT_MS = 5_000;
const SUCCESS_TTL_MS = 60_000;
const MAX_DISCOVERY_MODELS = 25_000;
const installed = new WeakMap<ModelRuntime, OpenAIModelEligibility>();

type OpenAIModel = Model<Api>;
interface DiscoveryEntry { slug: string; visibility: string; displayName?: string; }
interface AccountModels { fingerprint: string; entries: readonly string[]; displayNames: ReadonlyMap<string, string>; expiresAt: number; }
interface DiscoveryFlight { fingerprint: string; controller: AbortController; promise: Promise<AccountModels | undefined>; }
interface EligibilityState {
  generation: number;
  fingerprint: string | undefined;
  oauth: boolean | undefined;
  entries: readonly string[];
  displayNames: ReadonlyMap<string, string>;
}
type EligibilityUpdate = { fingerprint?: string | undefined; oauth?: boolean | undefined; entries: readonly string[]; displayNames: ReadonlyMap<string, string> };
export interface OpenAIModelEligibilityOptions {
  /** Production always uses the fixed OpenAI endpoint and global fetch. */
  fetch?: typeof globalThis.fetch;
  now?: () => number;
}

function normalize(value: string): string { return value.replace(/\/+$/u, "").toLowerCase(); }
function tokenFingerprint(token: string): string { return createHash("sha256").update(token).digest("hex"); }
function firstPartyOpenAI(runtime: ModelRuntime): boolean {
  const provider = runtime.getProvider("openai");
  if (!provider || normalize(provider.baseUrl ?? "") !== "https://api.openai.com/v1") return false;
  const models = runtime.getModels("openai");
  return models.length > 0 && models.every(model => model.api === "openai-responses"
    && normalize(model.baseUrl) === "https://api.openai.com/v1");
}
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
function withFilters(runtime: ModelRuntime, provider: Provider, owner: OpenAIModelEligibility): Provider {
  return {
    ...provider,
    filterModels: (models, credential) => owner.filterModels(runtime, provider.id, provider.filterModels?.(models, credential) ?? models, credential),
    filterAllModels: (models, credential) => (provider.filterAllModels?.(models, credential) ?? models)
      .filter(model => owner.isEligibleInRuntime(runtime, provider.id, model.id, credential)),
  };
}

/** One Gateway-wide account state; each runtime contributes the SDK's public provider filters. */
export class OpenAIModelEligibility {
  private readonly fetch: typeof globalThis.fetch;
  private readonly now: () => number;
  private readonly runtimes = new Set<ModelRuntime>();
  private readonly state: EligibilityState = { generation: 0, fingerprint: undefined, oauth: undefined, entries: [], displayNames: new Map() };
  private lastSuccessful: AccountModels | undefined;
  private lastFailure: { fingerprint: string; expiresAt: number } | undefined;
  private flight: DiscoveryFlight | undefined;

  constructor(options: OpenAIModelEligibilityOptions = {}) {
    this.fetch = options.fetch ?? globalThis.fetch;
    this.now = options.now ?? Date.now;
  }

  attachRuntime(runtime: ModelRuntime): () => void {
    if (!this.runtimes.has(runtime)) {
      this.runtimes.add(runtime);
      for (const providerId of ["openai", "openai-codex"]) {
        const provider = runtime.getProvider(providerId);
        if (provider) runtime.registerNativeProvider(withFilters(runtime, provider, this));
      }
      installed.set(runtime, this);
    }
    let detached = false;
    return () => {
      if (detached) return;
      detached = true;
      this.runtimes.delete(runtime);
      if (installed.get(runtime) === this) installed.delete(runtime);
    };
  }

  /** Caller cancellation only abandons this wait; the Gateway owns auth reads and discovery. */
  async refresh(signal?: AbortSignal): Promise<void> {
    const runtime = this.primaryRuntime();
    if (!runtime || signal?.aborted) return;
    const generation = ++this.state.generation;
    await this.waitFor(this.resolve(runtime, generation), signal);
  }

  private async resolve(runtime: ModelRuntime, generation: number): Promise<void> {
    if (!firstPartyOpenAI(runtime)) return;
    let credentials;
    try { credentials = await runtime.listCredentials(); }
    catch {
      this.publish(generation, { fingerprint: undefined, oauth: undefined, entries: [], displayNames: new Map() });
      this.abortFlight();
      await this.refreshSnapshots();
      return;
    }
    if (generation !== this.state.generation) return;
    const stored = credentials.find(item => item.providerId === "openai");
    // Discovery is an account-specific OAuth capability, not a generic auth probe:
    // API keys, absent credentials, and environment auth must never reach this endpoint.
    if (stored?.type !== "oauth") {
      this.lastSuccessful = undefined;
      this.lastFailure = undefined;
      this.abortFlight();
      this.publish(generation, { fingerprint: undefined, oauth: false, entries: [], displayNames: new Map() });
      await this.refreshSnapshots();
      return;
    }
    let token: string | undefined;
    try { token = (await runtime.getAuth("openai"))?.auth.apiKey; }
    catch {
      this.publish(generation, { fingerprint: undefined, oauth: true, entries: [], displayNames: new Map() });
      this.abortFlight();
      await this.refreshSnapshots();
      return;
    }
    if (generation !== this.state.generation) return;
    if (!token) {
      this.lastSuccessful = undefined;
      this.lastFailure = undefined;
      this.abortFlight();
      this.publish(generation, { fingerprint: undefined, oauth: true, entries: [], displayNames: new Map() });
      await this.refreshSnapshots();
      return;
    }
    const fingerprint = tokenFingerprint(token);
    const sameAccount = this.state.fingerprint === fingerprint;
    if (!sameAccount) {
      this.lastSuccessful = undefined;
      this.lastFailure = undefined;
      this.abortFlight();
    }
    const cached = this.lastSuccessful?.fingerprint === fingerprint ? this.lastSuccessful : undefined;
    this.publish(generation, {
      fingerprint,
      oauth: true,
      entries: cached?.entries ?? (sameAccount ? this.state.entries : []),
      displayNames: cached?.displayNames ?? (sameAccount ? this.state.displayNames : new Map()),
    });
    if (cached && cached.expiresAt > this.now()) {
      await this.refreshSnapshots();
      return;
    }
    if (this.lastFailure?.fingerprint === fingerprint && this.lastFailure.expiresAt > this.now()) {
      await this.refreshSnapshots();
      return;
    }
    let flight = this.flight;
    if (!flight || flight.fingerprint !== fingerprint) {
      this.abortFlight();
      flight = this.startDiscovery(runtime, token, fingerprint);
      this.flight = flight;
    }
    const discovered = await flight.promise;
    if (generation !== this.state.generation || this.state.fingerprint !== fingerprint) return;
    const success = discovered ?? (this.lastSuccessful?.fingerprint === fingerprint ? this.lastSuccessful : undefined);
    if (discovered) this.lastFailure = undefined;
    else this.lastFailure = { fingerprint, expiresAt: this.now() + SUCCESS_TTL_MS };
    this.publish(generation, { fingerprint, oauth: true, entries: success?.entries ?? [], displayNames: success?.displayNames ?? new Map() });
    await this.refreshSnapshots();
  }

  private publish(generation: number, update: EligibilityUpdate): void {
    if (generation !== this.state.generation) return;
    this.state.generation = generation;
    if ("fingerprint" in update) this.state.fingerprint = update.fingerprint;
    if ("oauth" in update) this.state.oauth = update.oauth;
    this.state.entries = update.entries;
    this.state.displayNames = update.displayNames;
  }

  private startDiscovery(runtime: ModelRuntime, token: string, fingerprint: string): DiscoveryFlight {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(new DOMException("OpenAI model discovery timed out", "TimeoutError")), REQUEST_TIMEOUT_MS);
    timeout.unref?.();
    const flight: DiscoveryFlight = {
      fingerprint,
      controller,
      promise: this.discover(runtime, token, fingerprint, controller.signal).catch(() => undefined).finally(() => {
        clearTimeout(timeout);
        if (this.flight === flight) this.flight = undefined;
      }),
    };
    return flight;
  }

  private abortFlight(): void {
    this.flight?.controller.abort(new Error("OpenAI account changed"));
    this.flight = undefined;
  }

  private async discover(runtime: ModelRuntime, token: string, fingerprint: string, signal: AbortSignal): Promise<AccountModels | undefined> {
    const entries: DiscoveryEntry[] = [];
    let totalModels = 0;
    let after: string | undefined;
    for (let page = 0; page < 50; page += 1) {
      const url = new URL(MODELS_URL);
      if (after) url.searchParams.set("after", after);
      const response = await this.fetch(url, { method: "GET", redirect: "error", signal, headers: { Authorization: `Bearer ${token}`, Accept: "application/json" } });
      if (!response.ok) throw new Error(`OpenAI model discovery failed with HTTP ${response.status}`);
      const pageData = parsePage(await response.json());
      totalModels += pageData.entries.length;
      if (totalModels > MAX_DISCOVERY_MODELS) throw new Error("OpenAI model discovery exceeded its item limit");
      for (const row of pageData.entries) if (row.visibility === "list") entries.push(row);
      if (!pageData.hasMore) break;
      if (!pageData.lastId || pageData.lastId === after || page === 49) throw new Error("OpenAI model discovery pagination is invalid");
      after = pageData.lastId;
    }
    const current = await runtime.getAuth("openai", { signal });
    if (signal.aborted || !current?.auth.apiKey || tokenFingerprint(current.auth.apiKey) !== fingerprint) return undefined;
    const registered = new Set([...this.runtimes].flatMap(candidate => firstPartyOpenAI(candidate) ? candidate.getModels("openai").map(model => model.id) : []));
    const recognizedEntries = entries.filter((entry, index) => registered.has(entry.slug) && entries.findIndex(candidate => candidate.slug === entry.slug) === index);
    const result = {
      fingerprint,
      entries: recognizedEntries.map(entry => entry.slug),
      displayNames: new Map(recognizedEntries.flatMap(entry => entry.displayName ? [[entry.slug, entry.displayName] as const] : [])),
      expiresAt: this.now() + SUCCESS_TTL_MS,
    };
    this.lastSuccessful = result;
    return result;
  }

  private async refreshSnapshots(): Promise<void> {
    // A provider-scoped SDK refresh first republishes every provider's unfiltered
    // configured catalog and then reapplies filters only to the named subset, which
    // would drop other providers' credential filters. Refresh full availability.
    await Promise.all([...this.runtimes].map(runtime => runtime.refresh({ allowNetwork: false }).then(() => undefined, () => undefined)));
  }

  private primaryRuntime(): ModelRuntime | undefined { return this.runtimes.values().next().value; }
  private waitFor<T>(operation: Promise<T>, signal?: AbortSignal): Promise<T> {
    if (!signal) return operation;
    if (signal.aborted) return Promise.resolve(undefined as T);
    return new Promise<T>((resolve, reject) => {
      const abort = () => { cleanup(); resolve(undefined as T); };
      const cleanup = () => signal.removeEventListener("abort", abort);
      signal.addEventListener("abort", abort, { once: true });
      operation.then(value => { cleanup(); resolve(value); }, error => { cleanup(); reject(error); });
    });
  }

  filterModels(runtime: ModelRuntime, provider: string, models: readonly OpenAIModel[], credential: Credential | undefined): OpenAIModel[] {
    return models.filter(model => this.isEligibleInRuntime(runtime, provider, model.id, credential));
  }
  isEligibleInRuntime(runtime: ModelRuntime, provider: string, id: string, credential?: Credential): boolean {
    if (provider === "openai") {
      if (!firstPartyOpenAI(runtime)) return true;
      if (credential?.type === "api_key") return true;
      if (credential?.type === "oauth") {
        const token = credential.access;
        return !!token && tokenFingerprint(token) === this.state.fingerprint && this.state.entries.includes(id);
      }
      return this.state.oauth === false || (this.state.oauth === true && this.state.fingerprint !== undefined && this.state.entries.includes(id));
    }
    if (provider === "openai-codex") return providerUsageLentTo(runtime, provider) !== "openai";
    return true;
  }
  isEligible(model: Pick<OpenAIModel, "provider" | "id">): boolean {
    const runtime = this.primaryRuntime();
    return !runtime || this.isEligibleInRuntime(runtime, model.provider, model.id);
  }
  assertEligible(runtime: ModelRuntime, provider: string, id: string): void {
    if (!this.isEligibleInRuntime(runtime, provider, id)) throw new GatewayError("invalid_request", "Model is not available for new selections");
  }
  countChoices(providerId: string, runtime = this.primaryRuntime()): number {
    return runtime?.getModels(providerId).filter(model => this.isEligibleInRuntime(runtime, providerId, model.id)).length ?? 0;
  }
  displayName(provider: string, id: string): string | undefined {
    return provider === "openai" && this.state.entries.includes(id) ? this.state.displayNames.get(id) : undefined;
  }
  orderAccountModels<T extends Pick<OpenAIModel, "provider" | "id">>(models: readonly T[]): T[] {
    const positions = models.flatMap((model, index) => model.provider === "openai" ? [index] : []);
    const ordered = positions.map(index => models[index]!).sort((left, right) => {
      const leftRank = this.state.entries.indexOf(left.id);
      const rightRank = this.state.entries.indexOf(right.id);
      if (leftRank < 0) return rightRank < 0 ? 0 : 1;
      if (rightRank < 0) return -1;
      return leftRank - rightRank;
    });
    const result = [...models];
    positions.forEach((position, index) => { result[position] = ordered[index]!; });
    return result;
  }
}

export function installOpenAIModelEligibility(runtime: ModelRuntime, options: OpenAIModelEligibilityOptions = {}): OpenAIModelEligibility {
  const current = installed.get(runtime);
  if (current) return current;
  const owner = new OpenAIModelEligibility(options);
  owner.attachRuntime(runtime);
  return owner;
}
export function openAIModelEligibility(runtime: ModelRuntime): OpenAIModelEligibility | undefined { return installed.get(runtime); }
export async function assertNewModelChoice(runtime: ModelRuntime, provider: string, id: string, signal?: AbortSignal): Promise<void> {
  const owner = installed.get(runtime);
  if (!owner) return;
  await owner.refresh(signal);
  owner.assertEligible(runtime, provider, id);
}
