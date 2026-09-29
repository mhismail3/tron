import { readFile, stat } from "node:fs/promises";
import { join } from "node:path";
import aliases from "./model-release-date-aliases.json" with { type: "json" };
import baseline from "./model-release-dates.json" with { type: "json" };
import { RELEASE_DATE_SOURCE, releaseDatesFromCatalog } from "./release-date-normalization.mjs";
import { durablePublishBoundedJson } from "../util/durable-json.js";

const MAX_FILE_BYTES = 32 * 1024 * 1024;
const MAXIMUM_AGE_MS = 12 * 60 * 60 * 1000;
const REFRESH_INTERVAL_MS = MAXIMUM_AGE_MS;
const REQUEST_TIMEOUT_MS = 60_000;

type PersistedCatalog = {
  fetchedAt: string;
  etag?: string;
  lastModified?: string;
  dates: Record<string, string>;
};
type Log = (level: "warning" | "info", message: string, metadata?: Record<string, unknown>) => void;

export class ModelReleaseDateCatalog {
  private readonly path: string;
  private readonly dates = new Map<string, string>();
  private fetchedAt: number | undefined;
  private etag: string | undefined;
  private lastModified: string | undefined;
  private loaded: Promise<void> | undefined;
  private inFlight: Promise<{ updated: number; error?: string }> | undefined;
  private timer: NodeJS.Timeout | undefined;
  private disposed = false;
  private activeController: AbortController | undefined;
  private readonly aliases: Record<string, string>;

  constructor(private readonly options: {
    tronHome: string;
    baseline?: Record<string, string>;
    aliases?: Record<string, string>;
    providers: () => Iterable<string>;
    log: Log;
    broadcast?: () => void;
    workRegistry?: { runtimeEpoch: string; begin(input: { kind: string; hostEpoch: string; cancellation?: () => void }): { settle(): void } };
  }) {
    this.path = join(options.tronHome, "gateway", "model-release-dates.json");
    this.aliases = options.aliases ?? aliases;
    for (const [key, date] of Object.entries(options.baseline ?? baseline)) this.dates.set(key, date);
  }

  async modelReleaseDate(provider: string, id: string): Promise<string | undefined> {
    await this.load();
    return this.dates.get(`${provider}/${id}`) ?? (this.aliases[provider] ? this.dates.get(`${this.aliases[provider]}/${id}`) : undefined);
  }

  start(signal?: AbortSignal): void {
    if (this.timer || this.disposed) return;
    void this.runBackground(signal);
    this.timer = setInterval(() => void this.runBackground(signal), REFRESH_INTERVAL_MS);
    this.timer.unref();
  }

  async refresh(options: { force?: boolean; signal?: AbortSignal } = {}): Promise<{ updated: number; error?: string }> {
    await this.load();
    if (process.env.PI_OFFLINE === "1") return { updated: 0, error: "offline mode" };
    if (this.inFlight) return this.inFlight;
    if (!options.force && this.isFresh()) return { updated: 0 };
    const operation = this.fetchAndPersist(options.signal);
    this.inFlight = operation;
    try { return await operation; } finally { if (this.inFlight === operation) this.inFlight = undefined; }
  }

  dispose(): void {
    this.disposed = true;
    this.activeController?.abort(new Error("Gateway shutting down"));
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
  }

  private async runBackground(signal?: AbortSignal): Promise<void> {
    if (this.disposed || process.env.PI_OFFLINE === "1") return;
    try { await this.refresh(signal ? { signal } : {}); }
    catch (error) { this.options.log("warning", "Background model release-date refresh failed", { reason: error instanceof Error ? error.message : String(error) }); }
  }

  private isFresh(): boolean {
    return this.fetchedAt !== undefined && Date.now() - this.fetchedAt < MAXIMUM_AGE_MS;
  }

  private async load(): Promise<void> {
    if (!this.loaded) this.loaded = (async () => {
      try {
        const info = await stat(this.path);
        if (info.size > MAX_FILE_BYTES) throw new Error("file exceeds 32 MiB");
        const text = await readFile(this.path, "utf8");
        const saved = JSON.parse(text) as PersistedCatalog;
        const fetchedAt = typeof saved?.fetchedAt === "string" ? Date.parse(saved.fetchedAt) : Number.NaN;
        if (!saved || typeof saved !== "object" || !Number.isFinite(fetchedAt) || fetchedAt > Date.now() + 5 * 60_000
          || !saved.dates || typeof saved.dates !== "object" || Array.isArray(saved.dates)
          || (saved.etag !== undefined && (typeof saved.etag !== "string" || saved.etag.length > 4_096))
          || (saved.lastModified !== undefined && (typeof saved.lastModified !== "string" || saved.lastModified.length > 4_096))
          || Object.keys(saved.dates).length > 250_000) throw new Error("invalid catalog shape");
        const normalized: Record<string, string> = {};
        for (const [key, value] of Object.entries(saved.dates)) {
          if (!/^[^/]{1,120}\/.{1,500}$/.test(key) || typeof value !== "string" || !isValidReleaseDate(value)) throw new Error("invalid date entry");
          normalized[key] = value;
        }
        for (const [key, value] of Object.entries(normalized)) this.dates.set(key, value);
        this.fetchedAt = fetchedAt;
        if (typeof saved.etag === "string") this.etag = saved.etag;
        if (typeof saved.lastModified === "string") this.lastModified = saved.lastModified;
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") this.options.log("warning", "Persisted model release dates ignored; using vendored baseline", { reason: error instanceof Error ? error.message : String(error) });
      }
    })();
    await this.loaded;
  }

  private async fetchAndPersist(signal?: AbortSignal): Promise<{ updated: number; error?: string }> {
    const controller = new AbortController();
    this.activeController = controller;
    const abort = () => controller.abort(signal?.reason);
    signal?.addEventListener("abort", abort, { once: true });
    const timeout = setTimeout(() => controller.abort(new Error("model release-date request timed out")), REQUEST_TIMEOUT_MS);
    timeout.unref();
    const work = this.options.workRegistry?.begin({ kind: "administrative-provider-package-operation", hostEpoch: this.options.workRegistry.runtimeEpoch, cancellation: () => controller.abort() });
    try {
      const headers: Record<string, string> = {};
      if (this.etag) headers["If-None-Match"] = this.etag;
      else if (this.lastModified) headers["If-Modified-Since"] = this.lastModified;
      const response = await fetch(RELEASE_DATE_SOURCE, { headers, signal: controller.signal });
      if (response.status === 304) {
        this.fetchedAt = Date.now();
        await this.persist();
        this.options.log("info", "Model release-date refresh unchanged", { updated: 0 });
        return { updated: 0 };
      }
      if (!response.ok) throw new Error(`models.dev responded ${response.status}`);
      const text = await readBoundedBody(response, MAX_FILE_BYTES);
      const parsed = JSON.parse(text) as unknown;
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("models.dev payload is not a provider catalog");
      const providerNames = [...this.options.providers()];
      if (!providerNames.some(provider => {
        const entry = (parsed as Record<string, unknown>)[provider];
        return !!entry && typeof entry === "object" && !!(entry as { models?: unknown }).models
          && typeof (entry as { models: unknown }).models === "object";
      })) throw new Error("models.dev payload contains no runtime provider catalogs");
      const result = releaseDatesFromCatalog(parsed, providerNames, this.aliases);
      const merged = new Map(this.dates);
      for (const [key, value] of Object.entries(result.dates)) merged.set(key, value);
      let updated = 0;
      for (const [key, value] of merged) if (this.dates.get(key) !== value) updated++;
      const previous = new Map(this.dates);
      this.dates.clear(); for (const [key, value] of merged) this.dates.set(key, value);
      const oldFetchedAt = this.fetchedAt, oldEtag = this.etag, oldLastModified = this.lastModified;
      this.fetchedAt = Date.now();
      this.etag = response.headers.get("etag") ?? this.etag;
      this.lastModified = response.headers.get("last-modified") ?? this.lastModified;
      try { await this.persist(); } catch (error) {
        this.dates.clear(); for (const [key, value] of previous) this.dates.set(key, value);
        this.fetchedAt = oldFetchedAt; this.etag = oldEtag; this.lastModified = oldLastModified;
        throw error;
      }
      if (updated > 0) this.options.broadcast?.();
      this.options.log("info", updated ? "Model release-date refresh updated" : "Model release-date refresh unchanged", { updated, providers: result.providers, unrecognizedDates: result.unknown.length });
      return { updated };
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      this.options.log("warning", "Model release-date refresh failed; existing dates retained", { reason: reason.slice(0, 300) });
      return { updated: 0, error: reason.slice(0, 300) };
    } finally {
      clearTimeout(timeout);
      signal?.removeEventListener("abort", abort);
      work?.settle();
      if (this.activeController === controller) this.activeController = undefined;
    }
  }

  private async persist(): Promise<void> {
    const document: PersistedCatalog = {
      fetchedAt: new Date(this.fetchedAt ?? Date.now()).toISOString(),
      ...(this.etag ? { etag: this.etag } : {}),
      ...(this.lastModified ? { lastModified: this.lastModified } : {}),
      dates: Object.fromEntries([...this.dates].sort(([a], [b]) => a.localeCompare(b))),
    };
    await durablePublishBoundedJson(this.path, document, MAX_FILE_BYTES);
  }
}

function isValidReleaseDate(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const date = new Date(`${value}T00:00:00.000Z`);
  return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === value;
}

async function readBoundedBody(response: Response, maximumBytes: number): Promise<string> {
  if (!response.body) throw new Error("models.dev response has no body");
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > maximumBytes) { await reader.cancel(); throw new Error("models.dev response exceeds 32 MiB"); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  return Buffer.concat(chunks).toString("utf8");
}
