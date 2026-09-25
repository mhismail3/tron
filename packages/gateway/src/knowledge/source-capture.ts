import { createHash, randomUUID } from "node:crypto";
import { request as httpRequest } from "node:http";
import { request as httpsRequest } from "node:https";
import { lookup } from "node:dns/promises";
import { isIP } from "node:net";
import { isCredentialQueryKey, normalizeKnowledgeSourceUrl, type KnowledgeEvidenceRef, type KnowledgeObjectRef, type KnowledgeRecord, type KnowledgeRecordDraft, type KnowledgeScope, type SourceAssessment, type SourceContent, type SourceIdentity, type SourceOrigin, type SourceOriginKind, type KnowledgeSourcePreviewRefreshResult } from "./knowledge-contract.js";
import { KnowledgeStore, type KnowledgeMutationResult } from "./knowledge-store.js";
import { awaitAbortableWithSettlement } from "./model-await.js";
import { isPublicXEmbedUrl, lookupPublicXPost, normalizePublicLinkedUrl, xPostIdentity, type XPublicCoverage, type XPublicLookupOptions, type XPublicPost } from "./x-public-post.js";

const SOURCE_CAPTURE_USER_AGENT = "Tron/0.1 (public-source-capture)";

/** Canonical derivative binding: only title and readable evidence determine freshness. */
export function sourceEvidenceDigest(title: string, text: string): string {
  return createHash("sha256").update(JSON.stringify({ title, text })).digest("hex");
}
export const SOURCE_CAPTURE_LIMITS = {
  maxBytes: 8_000_000,
  maxReadableChars: 2_000_000,
  timeoutMs: 15_000,
  maxRedirects: 3,
} as const;
type SourceCaptureLimits = { [K in keyof typeof SOURCE_CAPTURE_LIMITS]: number };

type ResolveHost = (hostname: string, signal?: AbortSignal) => Promise<string[]>;
type SourceFetch = (input: string | URL, init?: RequestInit) => Promise<Response>;

export interface SourceCaptureInput {
  commandId: string;
  url: string;
  scope: KnowledgeScope;
  title?: string;
  /** Explicit permission to disclose this public post ID to public providers. */
  publicPostLookup?: boolean;
  /** Explicitly requested bounded coverage; this bypasses complete-root reuse. */
  publicPostCoverage?: XPublicCoverage;
  sourcePublishedAt?: string;
  sourceSavedAt?: string;
  collectionId?: string;
  annotations?: SourceContent["annotations"];
  identity?: SourceIdentity;
  origin?: SourceOriginKind;
  expectedRevision?: string;
  interests?: string[];
}

export interface SourceAssessmentModelInput {
  title: string;
  text: string;
  interests: string[];
  source: { uri?: string; mediaType?: string; capturedAt: string; collectionId?: string; captureDisposition?: SourceContent["captureDisposition"] };
}

/** The paid adapter must invoke beforeDispatch only after its own request
 * validation and credential lookup, immediately before its one POST. */
export interface SourceAssessmentDispatchContext { beforeDispatch?: () => Promise<void>; }
export interface SourceAssessmentModel {
  assess(input: SourceAssessmentModelInput, signal: AbortSignal, context?: SourceAssessmentDispatchContext): Promise<Omit<SourceAssessment, "generatedAt"> & { generatedAt?: string }>;
}

export interface SourceCaptureOptions {
  fetcher?: SourceFetch;
  resolveHost?: ResolveHost;
  model?: SourceAssessmentModel;
  now?: () => string;
  limits?: Partial<SourceCaptureLimits>;
  signal?: AbortSignal;
  /** Internal owner handoff for provider promises that may outlive the bounded wait. */
  retirements?: Promise<void>[];
}

export interface SourceCaptureResult {
  record: KnowledgeRecord & { kind: "source" };
  duplicate: boolean;
  fetched: boolean;
  assessmentError?: string;
}

function invalid(message: string): Error { return new Error(message); }
class SourceNetworkError extends Error {}
class SourceSafetyError extends Error {
  constructor(readonly fetchAttempted: boolean) { super("Source destination is not publicly routable"); }
}
function timestamp(now: () => string): string { return now(); }
function sourceOrigin(kind: SourceOriginKind, at: string, input: { uri?: string; identity?: SourceIdentity } = {}): NonNullable<SourceContent["origins"]> { return [{ kind, capturedAt: at, ...(input.uri ? { uri: input.uri } : {}), ...(input.identity ? { identity: input.identity } : {}) }]; }

function isPrivateAddress(address: string): boolean {
  const normalized = address.toLowerCase().replace(/^\[|\]$/g, "");
  const mapped = normalized.match(/^(?:0:){5}(?:ffff|0:ffff):?(\d+\.\d+\.\d+\.\d+)$/i) ?? normalized.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/i);
  if (mapped?.[1]) return isPrivateAddress(mapped[1]);
  if (isIP(normalized) === 4) {
    const octets = normalized.split(".").map(Number);
    const [a = 0, b = 0] = octets;
    return a === 10 || a === 127 || a === 0 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127);
  }
  if (isIP(normalized) === 6) {
    const value = normalized.split("%")[0] ?? "";
    const halves = value.split("::");
    const left = halves[0] ? halves[0].split(":").filter(Boolean) : [];
    const right = halves[1] ? halves[1].split(":").filter(Boolean) : [];
    const groups = halves.length === 2 ? [...left, ...Array(8 - left.length - right.length).fill("0"), ...right] : value.split(":");
    const words = groups.map(group => Number.parseInt(group || "0", 16));
    const mapped = words.length === 8 && words.slice(0, 5).every(word => word === 0) && words[5] === 0xffff;
    if (mapped) {
      const a = (words[6]! >> 8) & 0xff; const b = words[6]! & 0xff;
      const c = (words[7]! >> 8) & 0xff; const d = words[7]! & 0xff;
      return isPrivateAddress(`${a}.${b}.${c}.${d}`);
    }
    const first = words[0] ?? 0;
    return value === "::1" || value === "::" || (first & 0xfe00) === 0xfc00 || (first & 0xffc0) === 0xfe80 || (first & 0xff00) === 0xff00;
  }
  return true;
}

function assertSafeUrl(value: string): URL {
  let parsed: URL;
  try { parsed = new URL(value); } catch { throw invalid("Source URL is invalid"); }
  if (!["http:", "https:"].includes(parsed.protocol) || parsed.username || parsed.password || parsed.hostname.length === 0) throw invalid("Source URL must be an http(s) URL without credentials");
  // Query credentials are credentials too. Reject them before the URL can be
  // persisted, logged, fetched, or passed to an assessment model.
  for (const key of parsed.searchParams.keys()) {
    if (key === "token" && isPublicXEmbedUrl(parsed)) continue; // Public deterministic embed ID, never an account token.
    if (isCredentialQueryKey(key)) throw invalid("Source URL contains a credential-bearing query parameter");
  }
  return parsed;
}

/** URL diagnostics never include query strings or credentials. */
function redactSourceUrl(value: string): string {
  try { const url = new URL(value); return `${url.protocol}//${url.host}${url.pathname}`; } catch { return "[invalid-url]"; }
}

async function defaultResolveHost(hostname: string): Promise<string[]> {
  const answers = await lookup(hostname, { all: true, verbatim: true });
  return answers.map(answer => answer.address);
}

async function pinnedFetch(url: URL, address: string, init: RequestInit = {}): Promise<Response> {
  const transport = url.protocol === "https:" ? httpsRequest : httpRequest;
  const headers = new Headers(init.headers);
  headers.set("host", url.host);
  return new Promise((resolve, reject) => {
    const requestHeaders = Object.fromEntries([...headers].map(([name, value]) => [name, value]));
    const req = transport({ hostname: address, ...(url.port ? { port: url.port } : {}), path: `${url.pathname}${url.search}`, method: "GET", headers: requestHeaders, ...(url.protocol === "https:" ? { servername: url.hostname } : {}), lookup: (_hostname, _options, callback) => callback(null, address, isIP(address)), }, response => {
      try {
        const status = response.statusCode ?? 200;
        if (!Number.isInteger(status) || status < 200 || status > 599) throw new Error("Invalid HTTP response status");
        // Node may invoke the callback for bodyless statuses. Do not attach a
        // stream (or a body) for statuses whose wire contract forbids one.
        const body = [204, 205, 304].includes(status) ? null : new ReadableStream<Uint8Array>({ start(controller) { response.on("data", chunk => controller.enqueue(new Uint8Array(chunk))); response.on("end", () => controller.close()); response.on("error", error => controller.error(error)); }, cancel() { response.destroy(); } });
        const responseHeaders = Object.fromEntries(Object.entries(response.headers).map(([name, value]) => [name, Array.isArray(value) ? value.join(", ") : value ?? ""]));
        resolve(new Response(body, { status, ...(response.statusMessage ? { statusText: response.statusMessage } : {}), headers: responseHeaders }));
      } catch (error) { response.resume(); reject(error); }
    });
    const signal = init.signal;
    const abort = () => req.destroy(new Error("Source fetch cancelled"));
    if (signal?.aborted) abort(); else signal?.addEventListener("abort", abort, { once: true });
    req.once("error", reject); req.once("close", () => signal?.removeEventListener("abort", abort)); req.end();
  });
}

async function assertPublicDestination(url: URL, resolveHost: ResolveHost, signal?: AbortSignal): Promise<string> {
  const hostname = url.hostname.toLowerCase();
  if (hostname === "localhost" || hostname.endsWith(".localhost") || hostname.endsWith(".local") || (isIP(hostname) !== 0 && isPrivateAddress(hostname))) throw new SourceSafetyError(false);
  // Resolve every hop, including the initial hostname, before issuing a request.
  const addresses = await Promise.race([
    resolveHost(url.hostname, signal),
    ...(signal ? [new Promise<string[]>((_, reject) => { if (signal.aborted) reject(new Error("Source destination resolution cancelled")); else signal.addEventListener("abort", () => reject(new Error("Source destination resolution cancelled")), { once: true }); })] : []),
  ]);
  if (addresses.length === 0 || addresses.some(isPrivateAddress)) throw new SourceSafetyError(false);
  const address = addresses[0]; if (!address) throw new SourceSafetyError(false);
  return address;
}

async function readBounded(response: Response, maxBytes: number, signal?: AbortSignal): Promise<{ bytes: Uint8Array; truncated: boolean }> {
  if (!response.body) return { bytes: new Uint8Array(), truncated: false };
  const reader = response.body.getReader();
  const abort = () => { void reader.cancel(signal?.reason); };
  if (signal?.aborted) abort(); else signal?.addEventListener("abort", abort, { once: true });
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    for (;;) {
      const next = await reader.read();
      if (next.done) break;
      if (!next.value) continue;
      const remaining = maxBytes - total;
      if (next.value.byteLength > remaining) {
        if (remaining > 0) chunks.push(next.value.slice(0, remaining));
        total = maxBytes;
        await reader.cancel();
        return { bytes: joinBytes(chunks, total), truncated: true };
      }
      chunks.push(next.value);
      total += next.value.byteLength;
      if (total === maxBytes) {
        const extra = await reader.read();
        if (!extra.done) { await reader.cancel(); return { bytes: joinBytes(chunks, total), truncated: true }; }
        return { bytes: joinBytes(chunks, total), truncated: false };
      }
    }
    return { bytes: joinBytes(chunks, total), truncated: false };
  } finally { signal?.removeEventListener("abort", abort); reader.releaseLock(); }
}

function joinBytes(chunks: Uint8Array[], length: number): Uint8Array {
  const result = new Uint8Array(length); let offset = 0;
  for (const chunk of chunks) { result.set(chunk, offset); offset += chunk.byteLength; }
  return result;
}

function extractReadable(bytes: Uint8Array, mediaType: string | undefined, maxChars: number): { text: string; truncated: boolean; quality?: "partial" } | undefined {
  const normalized = (mediaType ?? "").split(";", 1)[0]!.trim().toLowerCase();
  if (!(normalized.startsWith("text/") || ["application/xhtml+xml", "application/json", "application/xml", "application/ld+json"].includes(normalized))) return undefined;
  let text = new TextDecoder("utf-8", { fatal: false }).decode(bytes);
  const originalHtml = text;
  if (normalized === "text/html" || normalized === "application/xhtml+xml") {
    text = text.replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, " ").replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, " ").replace(/<noscript\b[^>]*>[\s\S]*?<\/noscript>/gi, " ").replace(/<!--([\s\S]*?)-->/g, " ").replace(/<[^>]*>/g, " ");
    text = text.replace(/&nbsp;/gi, " ").replace(/&amp;/gi, "&").replace(/&lt;/gi, "<").replace(/&gt;/gi, ">").replace(/&#39;/g, "'").replace(/&quot;/gi, '"');
  }
  const normalizedText = text.replace(/[\t\r ]+/g, " ").replace(/\n\s*\n+/g, "\n\n").trim();
  if (!normalizedText) return undefined;
  const appShell = (normalized === "text/html" || normalized === "application/xhtml+xml") && normalizedText.length < 1_000 && (/<(?:div|main|body)[^>]+(?:id|class)\s*=\s*["']?[^\s"'>]*(?:app|root|next|svelte|react)\b/i.test(originalHtml) || /\b(?:enable javascript|javascript required|loading\.\.\.|please wait)\b/i.test(originalHtml));
  return { text: normalizedText.slice(0, maxChars), truncated: normalizedText.length > maxChars, ...(appShell ? { quality: "partial" as const } : {}) };
}

function titleFrom(bytes: Uint8Array, mediaType: string | undefined): string | undefined {
  const normalized = (mediaType ?? "").toLowerCase();
  if (!normalized.includes("html")) return undefined;
  const text = new TextDecoder().decode(bytes.slice(0, 100_000));
  return text.match(/<title[^>]*>([\s\S]*?)<\/title>/i)?.[1]?.replace(/<[^>]+>/g, " ").trim().slice(0, 512) || undefined;
}

async function fetchSafe(inputUrl: string, options: { fetcher?: SourceFetch; resolveHost: ResolveHost; signal?: AbortSignal; limits: SourceCaptureLimits }): Promise<{ response?: Response; bytes?: Uint8Array; truncated: boolean; finalUrl: string; disposition?: SourceContent["captureDisposition"]; mediaType?: string; quality?: "partial" }> {
  let current = assertSafeUrl(inputUrl); let requestAttempted = false;
  for (let hop = 0; hop <= options.limits.maxRedirects; hop += 1) {
    try {
      const address = await assertPublicDestination(current, options.resolveHost, options.signal);
    const controller = new AbortController();
    const onAbort = () => controller.abort(options.signal?.reason);
    if (options.signal) { if (options.signal.aborted) controller.abort(options.signal.reason); else options.signal.addEventListener("abort", onAbort, { once: true }); }
    let response: Response;
    try {
      requestAttempted = true;
      const headers = { "user-agent": SOURCE_CAPTURE_USER_AGENT };
      response = options.fetcher
        ? await options.fetcher(current, { redirect: "manual", headers, signal: controller.signal })
        : await pinnedFetch(current, address, { headers, signal: controller.signal });
    }
    catch { options.signal?.removeEventListener("abort", onAbort); throw new SourceNetworkError("Source fetch failed"); }
    options.signal?.removeEventListener("abort", onAbort);
    const location = response.headers.get("location");
    if (location && [301, 302, 303, 307, 308].includes(response.status)) {
      await response.body?.cancel().catch(() => {});
      if (hop === options.limits.maxRedirects) throw invalid("Source redirect limit exceeded");
      current = assertSafeUrl(new URL(location, current).toString());
      continue;
    }
    const mediaType = response.headers.get("content-type") ?? undefined;
    if (response.status === 401 || response.status === 403 || response.status === 407 || response.status === 429) { await response.body?.cancel().catch(() => {}); return { response, truncated: false, finalUrl: current.toString(), disposition: "inaccessible", ...(mediaType ? { mediaType } : {}) }; }
    if (!response.ok) { await response.body?.cancel().catch(() => {}); return { response, truncated: false, finalUrl: current.toString(), disposition: "failed", ...(mediaType ? { mediaType } : {}) }; }
    const bounded = await readBounded(response, options.limits.maxBytes, options.signal);
    if (options.signal?.aborted) throw new SourceNetworkError("Source fetch deadline exceeded");
    const quality = response.headers.get("x-tron-source-capture-quality") === "partial" ? "partial" as const : undefined;
    return { response, bytes: bounded.bytes, truncated: bounded.truncated, finalUrl: current.toString(), ...(mediaType ? { mediaType } : {}), ...(quality ? { quality } : {}) };
    } catch (error) {
      if (error instanceof SourceSafetyError) throw new SourceSafetyError(requestAttempted || error.fetchAttempted);
      throw error;
    }
  }
  throw invalid("Source redirect limit exceeded");
}

/** Read-only X hydration shares capture's DNS-pinned, bounded transport. No
 * credentials, paid API, browser actions, or persistence are implicit. */
export async function readPublicXPost(url: string, options: Pick<SourceCaptureOptions, "fetcher" | "resolveHost" | "signal"> = {}, lookupOptions: XPublicLookupOptions = {}): Promise<XPublicPost> {
  const signal = AbortSignal.any([AbortSignal.timeout(15_000), ...(options.signal ? [options.signal] : [])]);
  return lookupPublicXPost(url, async (endpoint, parentSignal) => {
    const attemptSignal = AbortSignal.any([parentSignal, AbortSignal.timeout(5_000)]);
    const fetched = await fetchSafe(endpoint, { ...(options.fetcher ? { fetcher: options.fetcher } : {}), resolveHost: options.resolveHost ?? defaultResolveHost, signal: attemptSignal, limits: { ...SOURCE_CAPTURE_LIMITS, maxBytes: 2_000_000, maxRedirects: 0 } });
    const retryAfter = fetched.response?.headers.get("retry-after");
    const rateLimitReset = fetched.response?.headers.get("x-rate-limit-reset");
    return { status: fetched.response?.status ?? 0, ...(fetched.bytes ? { body: new TextDecoder().decode(fetched.bytes) } : {}), truncated: fetched.truncated, ...(retryAfter ? { retryAfter } : {}), ...(rateLimitReset ? { rateLimitReset } : {}) };
  }, signal, lookupOptions);
}

const PREVIEW_MAX_BYTES = 512_000;
const PREVIEW_MEDIA_TYPES = new Set(["image/jpeg", "image/png", "image/webp"]);
function validPreviewBytes(bytes: Uint8Array, type: string): boolean {
  if (bytes.byteLength < 12) return false;
  if (type === "image/png") return bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47 && bytes[4] === 0x0d && bytes[5] === 0x0a && bytes[6] === 0x1a && bytes[7] === 0x0a;
  if (type === "image/webp") return bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x46 && bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50;
  return bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
}
function previewURL(bytes: Uint8Array, base: string): string | undefined {
  const html = new TextDecoder().decode(bytes);
  const match = html.match(/<meta[^>]+(?:property|name)=["'](?:og:image|twitter:image)["'][^>]+content=["']([^"']+)["'][^>]*>/i)
    ?? html.match(/<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name)=["'](?:og:image|twitter:image)["'][^>]*>/i);
  if (!match?.[1]) return undefined;
  try { const candidate = new URL(match[1], base); assertSafeUrl(candidate.toString()); return candidate.toString(); } catch { return undefined; }
}
type PreviewAttempt = { reference?: KnowledgeObjectRef; reason: string };
async function fetchPreview(store: KnowledgeStore, bytes: Uint8Array | undefined, mediaType: string | undefined, base: string, options: { fetcher?: SourceFetch; resolveHost: ResolveHost; signal: AbortSignal; callerSignal?: AbortSignal }, declaredURL?: string): Promise<PreviewAttempt> {
  if (!declaredURL && (!bytes || !mediaType?.toLowerCase()?.split(";")[0]?.trim().includes("html"))) return { reason: "No safe preview metadata was present." };
  const url = declaredURL ?? (bytes ? previewURL(bytes, base) : undefined); if (!url) return { reason: "The source did not declare a preview image." };
  let fetched: Awaited<ReturnType<typeof fetchSafe>>;
  try {
    fetched = await fetchSafe(url, { ...(options.fetcher ? { fetcher: options.fetcher } : {}), resolveHost: options.resolveHost, signal: options.signal, limits: { ...SOURCE_CAPTURE_LIMITS, maxBytes: PREVIEW_MAX_BYTES, maxRedirects: 2 } });
  } catch (error) {
    if (options.callerSignal?.aborted) throw error;
    if (options.signal.aborted) return { reason: "The preview operation deadline elapsed; the source was retained without an image." };
    if (error instanceof Error && error.message === "Source redirect limit exceeded") return { reason: "The preview exceeded the redirect safety limit; no image was changed." };
    if (error instanceof Error && /credential-bearing|credentials/i.test(error.message)) return { reason: "The preview URL failed credential safety validation; no image was changed." };
    return { reason: "The preview fetch failed or was rejected by source safety checks; no image was changed." };
  }
  if (fetched.disposition === "inaccessible") return { reason: "The preview host was inaccessible; no image was changed." };
  if (fetched.disposition === "failed") return { reason: "The preview host returned an unsuccessful response; no image was changed." };
  const type = fetched.mediaType?.toLowerCase()?.split(";")[0]?.trim();
  if (!fetched.bytes) return { reason: "The preview response contained no bytes." };
  if (fetched.truncated || fetched.bytes.byteLength > PREVIEW_MAX_BYTES) return { reason: "The preview exceeded the 512 KB safety limit." };
  if (!type || !PREVIEW_MEDIA_TYPES.has(type)) return { reason: "The preview was not JPEG, PNG, or WebP." };
  if (!validPreviewBytes(fetched.bytes, type)) return { reason: "The preview MIME type did not match its image signature." };
  return { reference: await store.putObject(fetched.bytes, type), reason: "A bounded preview image was captured." };
}
async function optionalPreview(store: KnowledgeStore, bytes: Uint8Array | undefined, mediaType: string | undefined, base: string, options: { fetcher?: SourceFetch; resolveHost: ResolveHost; signal: AbortSignal; callerSignal?: AbortSignal }, declaredURL?: string): Promise<KnowledgeObjectRef | undefined> {
  return (await fetchPreview(store, bytes, mediaType, base, options, declaredURL)).reference;
}

export async function refreshSourcePreview(store: KnowledgeStore, request: { commandId: string; sourceId: string; expectedRevision: string }, options: SourceCaptureOptions = {}): Promise<KnowledgeSourcePreviewRefreshResult> {
  const signal = options.signal ?? new AbortController().signal;
  const unavailable = (reason: string): KnowledgeSourcePreviewRefreshResult => ({ sourceId: request.sourceId, expectedRevision: request.expectedRevision, status: "unavailable", reason });
  if (signal.aborted) throw new Error("Source preview refresh was cancelled");
  const initial = await store.read(request.sourceId, request.expectedRevision, false, true, true);
  const latest = await store.read(request.sourceId, undefined, false, true, true);
  if (!initial || !latest || initial.kind !== "source" || latest.kind !== "source") return unavailable("Source is unavailable, excluded, or forgotten.");
  if (latest.content.admission?.status === "archived") return unavailable("Archived sources are not refreshed.");
  if (latest.content.admission?.status === "pending") return unavailable("Pending sources are not refreshed until admission.");
  if (latest.revisionId !== request.expectedRevision) {
    if (latest.content.preview) return { sourceId: request.sourceId, expectedRevision: request.expectedRevision, status: "unchanged", reason: "A newer revision already has a preview; no fetch was replayed.", record: latest };
    return unavailable("Source revision changed before preview refresh; no image was published.");
  }
  if (latest.content.preview) return { sourceId: request.sourceId, expectedRevision: request.expectedRevision, status: "unchanged", reason: "A preview already exists; no fetch was replayed.", record: latest };
  const uri = latest.content.uri;
  if (!uri) return unavailable("Source has no safe URL for preview refresh.");
  const controller = AbortSignal.any([signal, AbortSignal.timeout(SOURCE_CAPTURE_LIMITS.timeoutMs)]);
  let attempt: PreviewAttempt;
  try {
    const isX = (() => { try { xPostIdentity(uri); return true; } catch { return false; } })();
    if (isX) {
      const post = await readPublicXPost(uri, { resolveHost: options.resolveHost ?? defaultResolveHost, ...(options.fetcher ? { fetcher: options.fetcher } : {}), signal: controller });
      attempt = await fetchPreview(store, undefined, undefined, uri, { resolveHost: options.resolveHost ?? defaultResolveHost, ...(options.fetcher ? { fetcher: options.fetcher } : {}), signal: controller, ...(options.signal ? { callerSignal: options.signal } : {}) }, post.article?.coverURL);
      if (!post.article?.coverURL && !attempt.reference) attempt = { reason: "The public X response did not provide a safe Article cover image." };
    } else {
      let bytes: Uint8Array | undefined;
      const type = latest.content.object?.mediaType?.toLowerCase() ?? "";
      if (latest.content.object && (type === "text/html" || type === "application/xhtml+xml")) {
        bytes = (await store.readObject(latest.content.object, { recordId: latest.id, revisionId: latest.revisionId })) ?? undefined;
      }
      if (!bytes) {
        const fetched = await fetchSafe(uri, { ...(options.fetcher ? { fetcher: options.fetcher } : {}), resolveHost: options.resolveHost ?? defaultResolveHost, signal: controller, limits: SOURCE_CAPTURE_LIMITS });
        attempt = await fetchPreview(store, fetched.bytes, fetched.mediaType, fetched.finalUrl, { resolveHost: options.resolveHost ?? defaultResolveHost, ...(options.fetcher ? { fetcher: options.fetcher } : {}), signal: controller, ...(options.signal ? { callerSignal: options.signal } : {}) });
      } else {
        // Referral origins can be X posts or other declarations; they are not
        // the fetched document's URL and must never resolve relative images.
        attempt = await fetchPreview(store, bytes, latest.content.object?.mediaType, uri, { resolveHost: options.resolveHost ?? defaultResolveHost, ...(options.fetcher ? { fetcher: options.fetcher } : {}), signal: controller, ...(options.signal ? { callerSignal: options.signal } : {}) });
      }
    }
  } catch (error) {
    if (controller.aborted) throw error;
    return unavailable("Preview lookup failed or was rejected by source safety checks; no image was changed.");
  }
  if (controller.aborted) throw new Error("Source preview refresh was cancelled");
  const current = await store.read(request.sourceId, undefined, false, true, true);
  if (!current || current.kind !== "source" || current.revisionId !== request.expectedRevision) return unavailable("Source changed or became unavailable before preview publication.");
  if (!attempt.reference) return { sourceId: request.sourceId, expectedRevision: request.expectedRevision, status: current.content.preview ? "unchanged" : "no-image", reason: attempt.reason, record: current };
  if (current.content.preview?.hash === attempt.reference.hash && current.content.preview.bytes === attempt.reference.bytes && current.content.preview.mediaType === attempt.reference.mediaType) return { sourceId: request.sourceId, expectedRevision: request.expectedRevision, status: "unchanged", reason: "Preview image is unchanged; no new source revision was created.", record: current };
  const published = await store.publishSourcePreview({ commandId: request.commandId, recordId: current.id, expectedRevision: current.revisionId, preview: attempt.reference, signal: controller });
  if (published.record.kind !== "source") throw new Error("Preview refresh returned a non-source record");
  return { sourceId: request.sourceId, expectedRevision: request.expectedRevision, status: published.record.revisionId === current.revisionId ? "unchanged" : "updated", reason: published.record.revisionId === current.revisionId ? "Preview image is unchanged; no new source revision was created." : "A bounded preview image was published without changing source content or admission.", record: published.record };
}

async function allSourceRecords(store: KnowledgeStore): Promise<Array<KnowledgeRecord & { kind: "source" }>> {
  const result: Array<KnowledgeRecord & { kind: "source" }> = [];
  let cursor: string | undefined;
  do {
    const page = await store.list({ kind: "source", includeSuppressed: true, includeArchived: true, includePending: true, limit: 100, ...(cursor ? { cursor } : {}) });
    result.push(...page.records.filter((record): record is KnowledgeRecord & { kind: "source" } => record.kind === "source"));
    if (page.incomplete) throw new Error("Source deduplication scan is incomplete; retry after reducing the canonical corpus");
    cursor = page.nextCursor;
  } while (cursor);
  return result;
}

function sourceMatches(record: KnowledgeRecord & { kind: "source" }, input: SourceCaptureInput, sourceUrl: string, normalized: string): boolean {
  if (input.identity && record.content.identity && JSON.stringify(record.content.identity) === JSON.stringify(input.identity)) return true;
  if (record.content.uri && normalizeKnowledgeSourceUrl(record.content.uri) === normalized) return true;
  if (input.publicPostLookup && record.content.uri) {
    try { return xPostIdentity(record.content.uri).id === xPostIdentity(sourceUrl).id; } catch { /* The record is not an X post alias. */ }
  }
  return false;
}

/** Redirect resolution is authoritative for URL identity. Do not inspect
 * origins here: referral origins deliberately contain the referring post and
 * may not identify this linked target. */
function finalUrlMatches(record: KnowledgeRecord & { kind: "source" }, scope: KnowledgeScope, finalUrl: string): boolean {
  return record.scope === scope && record.content.uri !== undefined && normalizeKnowledgeSourceUrl(record.content.uri) === normalizeKnowledgeSourceUrl(finalUrl);
}

function finalTarget(records: Array<KnowledgeRecord & { kind: "source" }>, input: SourceCaptureInput, finalUrl: string): KnowledgeRecord & { kind: "source" } | undefined {
  const matches = records.filter(record => finalUrlMatches(record, input.scope, finalUrl));
  if (matches.length > 1) throw invalid("Multiple sources match the validated redirect target");
  return matches[0];
}

function linkedStopReason(error: unknown): string | undefined {
  const message = error instanceof Error ? error.message : "";
  if (message === "Source redirect limit exceeded") return "redirect limit exceeded";
  if (message === "Source URL contains a credential-bearing query parameter") return "credential-query redirect rejected";
  return undefined;
}

function childCommand(base: string, suffix: string): string {
  const normalizedBase = base.replace(/[^A-Za-z0-9._:-]/g, "_");
  const normalizedSuffix = suffix.replace(/[^A-Za-z0-9._:-]/g, "_");
  const digest = createHash("sha256").update(`${base}\u0000${suffix}`).digest("hex").slice(0, 16);
  return `${normalizedBase.slice(0, 72)}:${normalizedSuffix.slice(0, 64)}:${digest}`;
}

function appendCaptureReason(existing: string | undefined, addition: string): string {
  const value = existing ? `${existing} ${addition}` : addition;
  return value.slice(0, 2_000);
}

function sourceQuality(disposition: SourceContent["captureDisposition"]): number {
  return disposition === "complete" ? 4 : disposition === "partial" ? 3 : disposition === "metadata-only" ? 2 : disposition === "reference-only" ? 1 : 0;
}

/** Retry hydration updates the existing source envelope without erasing its
 * admission, connector evidence, relations, representations, or better bytes. */
function mergeHydratedContent(existing: SourceContent, incoming: SourceContent): SourceContent {
  const failed = sourceQuality(incoming.captureDisposition) <= 1;
  const keepExistingEvidence = failed && sourceQuality(existing.captureDisposition) >= sourceQuality(incoming.captureDisposition);
  const representations = [...(existing.representations ?? [])];
  for (const representation of incoming.representations ?? []) {
    if (!representations.some(previous => previous.kind === representation.kind && previous.object.hash === representation.object.hash)) representations.push(representation);
  }
  const origins = [...(existing.origins ?? [])];
  for (const origin of incoming.origins ?? []) {
    if (!origins.some(previous => previous.kind === origin.kind && previous.uri === origin.uri && JSON.stringify(previous.identity) === JSON.stringify(origin.identity))) origins.push(origin);
  }
  const annotations = [...(existing.annotations ?? [])];
  for (const annotation of incoming.annotations ?? []) {
    if (!annotations.some(previous => previous.text === annotation.text && previous.locator === annotation.locator)) annotations.push(annotation);
  }
  return {
    ...existing,
    ...incoming,
    ...(keepExistingEvidence ? {
      captureDisposition: existing.captureDisposition,
      ...(existing.captureReason ? { captureReason: appendCaptureReason(existing.captureReason, incoming.captureReason ?? "Hydration attempt was unavailable.") } : incoming.captureReason ? { captureReason: incoming.captureReason } : {}),
    } : {}),
    ...(incoming.text === undefined && existing.text !== undefined ? { text: existing.text } : {}),
    ...(incoming.object === undefined && existing.object !== undefined ? { object: existing.object } : {}),
    ...(incoming.preview === undefined && existing.preview !== undefined ? { preview: existing.preview } : {}),
    ...(representations.length > 0 ? { representations: representations.slice(0, 20) } : {}),
    ...(origins.length > 0 ? { origins: origins.slice(-20) } : {}),
    ...(annotations.length > 0 ? { annotations: annotations.slice(-200) } : {}),
    ...(existing.title ? { title: existing.title } : {}),
    ...(existing.origin ? { origin: existing.origin } : {}),
    ...(existing.admission ? { admission: existing.admission } : {}),
    ...(existing.identity ? { identity: existing.identity } : {}),
    ...(existing.retention ? { retention: existing.retention } : {}),
    ...(existing.assessment ? { assessment: existing.assessment } : {}),
    ...(existing.collectionId && !incoming.collectionId ? { collectionId: existing.collectionId } : {}),
    ...(existing.sourcePublishedAt && !incoming.sourcePublishedAt ? { sourcePublishedAt: existing.sourcePublishedAt } : {}),
    ...(existing.linkedUrls || incoming.linkedUrls ? { linkedUrls: [...new Set([...(existing.linkedUrls ?? []), ...(incoming.linkedUrls ?? [])])].slice(0, 8) } : {}),
  };
}

function retrySourceDraft(retryTarget: KnowledgeRecord & { kind: "source" }, content: SourceContent): KnowledgeRecordDraft & { kind: "source" } {
  return {
    kind: "source", id: retryTarget.id, createdAt: retryTarget.createdAt, scope: retryTarget.scope,
    provenance: retryTarget.provenance, relations: retryTarget.relations,
    ...(retryTarget.temporal ? { temporal: retryTarget.temporal } : {}),
    content: mergeHydratedContent(retryTarget.content, content),
  };
}

function mergeRelation(relations: KnowledgeRecord["relations"], relation: KnowledgeRecord["relations"][number]): KnowledgeRecord["relations"] {
  const index = relations.findIndex(previous => previous.type === relation.type && previous.recordId === relation.recordId);
  if (index < 0) return [...relations, relation];
  if (JSON.stringify(relations[index]) === JSON.stringify(relation)) return relations;
  return relations.map((previous, position) => position === index ? relation : previous);
}

function mergeEvidence(evidence: KnowledgeEvidenceRef[], citation: KnowledgeEvidenceRef): KnowledgeEvidenceRef[] {
  const index = evidence.findIndex(previous => previous.recordId === citation.recordId && previous.locator === citation.locator);
  if (index < 0) return [...evidence, citation];
  return evidence.map((previous, position) => position === index ? citation : previous);
}

function referralOrigins(root: KnowledgeRecord & { kind: "source" }, input: SourceCaptureInput): SourceOrigin[] {
  if (root.content.origins && root.content.origins.length > 0) return root.content.origins;
  const kind = root.content.origin ?? input.origin ?? "manual";
  const identity = root.content.identity ?? input.identity;
  return [{ kind, capturedAt: root.content.capturedAt, uri: root.content.uri ?? input.url, ...(identity ? { identity } : {}) }];
}

function mergeBoundedOrigins(existing: SourceOrigin[], incoming: SourceOrigin[]): { origins: SourceOrigin[]; omitted: number } {
  const origins = [...existing]; let omitted = 0;
  for (const origin of incoming) {
    if (origins.some(previous => previous.kind === origin.kind && previous.uri === origin.uri && JSON.stringify(previous.identity) === JSON.stringify(origin.identity))) continue;
    if (origins.length >= 20) { omitted += 1; continue; }
    origins.push(origin);
  }
  return { origins, omitted };
}

function sourceDraft(input: SourceCaptureInput, content: SourceContent, evidence: KnowledgeEvidenceRef[] = []): KnowledgeRecordDraft & { kind: "source" } {
  const admittedContent = input.origin === "connector" && !content.admission
    ? { ...content, admission: { status: "pending" as const, reason: "Connector capture awaits local admission", decidedAt: content.capturedAt } }
    : content;
  return { kind: "source", scope: input.scope, provenance: { actor: input.origin === "connector" ? "connector" : input.origin === "import" ? "import" : "user", ...(input.identity ? { source: `${input.identity.provider}:${input.identity.accountId}:${input.identity.itemId}` } : {}), evidence }, relations: [], content: admittedContent };
}

/**
 * A public X response may name substantive outbound targets. Capture those
 * targets through this same source owner, but never turn provider adjacency into
 * a thread: only the reader's verified numeric author/parent selection can
 * supply continuation provenance; omitted or ambiguous replies remain commentary.
 */
async function captureLinkedPublicSources(
  store: KnowledgeStore,
  root: KnowledgeRecord & { kind: "source" },
  input: SourceCaptureInput,
  publicPost: XPublicPost,
  options: SourceCaptureOptions,
): Promise<{ record: KnowledgeRecord & { kind: "source" }; failures: string[] }> {
  let currentRoot = root;
  const failures: string[] = [];
  const linked = (publicPost.linkedReferences ?? (publicPost.linkedUrls ?? []).map(url => ({ url, postId: publicPost.id, postUrl: publicPost.url, role: "root" as const })))
    .map(reference => ({ ...reference, url: normalizePublicLinkedUrl(reference.url) }))
    .filter((reference): reference is typeof reference & { url: string } => Boolean(reference.url))
    .slice(0, 8);
  for (const [index, reference] of linked.entries()) {
    const targetUrl = reference.url;
    try {
      const target = await captureSource(store, {
        commandId: childCommand(input.commandId, `linked:${reference.postId}:${index}`),
        url: targetUrl,
        scope: input.scope,
        annotations: [{ text: `Bounded target declared by X post/reply ${reference.postId}; thread membership was verified only for the selected parent chain.`, locator: reference.postUrl }],
      }, { ...(options.fetcher ? { fetcher: options.fetcher } : {}), ...(options.resolveHost ? { resolveHost: options.resolveHost } : {}), ...(options.limits ? { limits: options.limits } : {}), ...(options.signal ? { signal: options.signal } : {}) });
      let targetRecord = target.record;
      const rootRelation = { type: "related" as const, recordId: targetRecord.id, revisionId: targetRecord.revisionId };
      const rootRelations = mergeRelation(currentRoot.relations, rootRelation);
      if (rootRelations !== currentRoot.relations) {
        const rootUpdate = await store.captureSource({
          commandId: childCommand(input.commandId, `linked-root:${index}`), expectedRevision: currentRoot.revisionId, ...(options.signal ? { signal: options.signal } : {}),
          record: { kind: "source", id: currentRoot.id, createdAt: currentRoot.createdAt, scope: currentRoot.scope, provenance: currentRoot.provenance, relations: rootRelations, ...(currentRoot.temporal ? { temporal: currentRoot.temporal } : {}), content: currentRoot.content },
        });
        if (rootUpdate.record.kind !== "source") throw new Error("Linked root relation returned a non-source record");
        currentRoot = rootUpdate.record;
      }
      const referrals = referralOrigins(currentRoot, input);
      const boundedOrigins = mergeBoundedOrigins(targetRecord.content.origins ?? [], referrals);
      const targetHost = new URL(targetUrl).hostname.toLowerCase();
      const githubUi = (targetHost === "github.com" || targetHost.endsWith(".github.com")) && targetRecord.content.captureDisposition === "complete";
      let targetCaptureReason = targetRecord.content.captureReason;
      if (githubUi) targetCaptureReason = appendCaptureReason(targetCaptureReason, "GitHub UI capture is partial; repository and file completeness are not established.");
      if (boundedOrigins.omitted > 0) targetCaptureReason = appendCaptureReason(targetCaptureReason, `Referral provenance bound reached; ${boundedOrigins.omitted} new origin(s) were not added.`);
      const targetProvenance = { ...targetRecord.provenance, evidence: mergeEvidence(targetRecord.provenance.evidence, { recordId: currentRoot.id, revisionId: currentRoot.revisionId, locator: reference.postUrl }) };
      const targetRelations = mergeRelation(targetRecord.relations, { type: "related" as const, recordId: currentRoot.id, revisionId: currentRoot.revisionId });
      const targetContent: SourceContent = {
        ...targetRecord.content,
        ...(githubUi ? { captureDisposition: "partial" as const } : {}),
        ...(boundedOrigins.origins.length > 0 ? { origins: boundedOrigins.origins } : {}),
        ...(targetCaptureReason ? { captureReason: targetCaptureReason } : {}),
      };
      if (JSON.stringify(targetProvenance) !== JSON.stringify(targetRecord.provenance) || JSON.stringify(targetRelations) !== JSON.stringify(targetRecord.relations) || JSON.stringify(targetContent) !== JSON.stringify(targetRecord.content)) {
        const targetUpdate = await store.captureSource({
          commandId: childCommand(input.commandId, `linked-target:${index}`), expectedRevision: targetRecord.revisionId, ...(options.signal ? { signal: options.signal } : {}),
          record: {
            kind: "source", id: targetRecord.id, createdAt: targetRecord.createdAt, scope: targetRecord.scope,
            provenance: targetProvenance, relations: targetRelations,
            ...(targetRecord.temporal ? { temporal: targetRecord.temporal } : {}), content: targetContent,
          },
        });
        if (targetUpdate.record.kind !== "source") throw new Error("Linked target relation returned a non-source record");
      }
    } catch (error) {
      // A child may persist its root before a linked redirect is rejected. Keep
      // that root usable and make only these bounded transport stops explicit;
      // store conflicts, cancellation, and other failures remain visible.
      if (options.signal?.aborted) throw error;
      const stop = linkedStopReason(error);
      if (stop) { failures.push(`target-${index}: ${stop}`); continue; }
      if (error instanceof Error && /timed out|cancelled/i.test(error.message)) {
        failures.push(`target-${index}: bounded capture did not settle`);
        continue;
      }
      throw error;
    }
  }
  return { record: currentRoot, failures };
}

/** Capture is durable before optional assessment. Assessment errors are returned, not promoted to capture failures. */
export async function captureSource(store: KnowledgeStore, input: SourceCaptureInput, options: SourceCaptureOptions = {}): Promise<SourceCaptureResult> {
  const now = options.now ?? (() => new Date().toISOString());
  const limits = { ...SOURCE_CAPTURE_LIMITS, ...(options.limits ?? {}) };
  if (!Number.isSafeInteger(limits.maxBytes) || limits.maxBytes < 1 || limits.maxBytes > SOURCE_CAPTURE_LIMITS.maxBytes
    || !Number.isSafeInteger(limits.maxRedirects) || limits.maxRedirects < 0 || limits.maxRedirects > SOURCE_CAPTURE_LIMITS.maxRedirects
    || !Number.isSafeInteger(limits.timeoutMs) || limits.timeoutMs < 100 || limits.timeoutMs > SOURCE_CAPTURE_LIMITS.timeoutMs
    || !Number.isSafeInteger(limits.maxReadableChars) || limits.maxReadableChars < 1 || limits.maxReadableChars > SOURCE_CAPTURE_LIMITS.maxReadableChars) {
    throw invalid("Invalid source capture limits");
  }
  if (input.publicPostLookup !== undefined && typeof input.publicPostLookup !== "boolean") throw invalid("publicPostLookup must be a boolean");
  if (input.publicPostCoverage !== undefined && !["root", "conversation", "thread"].includes(input.publicPostCoverage)) throw invalid("publicPostCoverage is invalid");
  const sourceUrl = assertSafeUrl(input.publicPostLookup ? xPostIdentity(input.url).url : input.url);
  const initialConfig = await store.config();
  if (options.signal?.aborted) throw invalid("Source capture was cancelled");
  let existing = await allSourceRecords(store);
  if (options.signal?.aborted) throw invalid("Source capture was cancelled");
  const normalized = normalizeKnowledgeSourceUrl(sourceUrl.toString());
  const refreshRequested = input.publicPostLookup === true && input.publicPostCoverage !== undefined && input.publicPostCoverage !== "root";
  const requestedMatches = existing.filter(record => record.scope === input.scope && sourceMatches(record, input, sourceUrl.toString(), normalized));
  if (requestedMatches.length > 1) throw invalid("Multiple sources match the requested source identity");
  const requestedTarget = requestedMatches[0];
  const refreshTarget = refreshRequested ? requestedTarget : undefined;
  const duplicate = refreshTarget ? undefined : requestedTarget?.content.captureDisposition === "complete" ? requestedTarget : undefined;
  let retryTarget = refreshTarget ?? (requestedTarget && requestedTarget.content.captureDisposition !== "complete" ? requestedTarget : undefined);
  if (duplicate) {
    const kind = input.origin ?? "manual";
    const origins = duplicate.content.origins ?? (duplicate.content.origin ? [{ kind: duplicate.content.origin, capturedAt: duplicate.content.capturedAt }] : []);
    const nextOrigins = origins.some(origin => origin.kind === kind && origin.uri === sourceUrl.toString() && JSON.stringify(origin.identity) === JSON.stringify(input.identity)) ? origins : [...origins, { kind, capturedAt: now(), uri: sourceUrl.toString(), ...(input.identity ? { identity: input.identity } : {}) }];
    const annotations = input.annotations ? [...(duplicate.content.annotations ?? []), ...input.annotations.filter(annotation => !(duplicate.content.annotations ?? []).some(previous => previous.text === annotation.text && previous.locator === annotation.locator))] : duplicate.content.annotations;
    if (nextOrigins.length !== origins.length || annotations?.length !== duplicate.content.annotations?.length) {
      const mergedContent: SourceContent = { ...duplicate.content, origins: nextOrigins, ...(annotations ? { annotations } : {}) };
      const merged = await store.captureSource({ commandId: input.commandId, expectedRevision: duplicate.revisionId, ...(options.signal ? { signal: options.signal } : {}), record: { kind: "source", id: duplicate.id, createdAt: duplicate.createdAt, scope: duplicate.scope, provenance: duplicate.provenance, relations: duplicate.relations, ...(duplicate.temporal ? { temporal: duplicate.temporal } : {}), content: mergedContent } });
      if (merged.record.kind !== "source") throw new Error("Source deduplication returned a non-source record");
      return { record: merged.record, duplicate: true, fetched: false };
    }
    return { record: duplicate, duplicate: true, fetched: false };
  }
  const fetcher = options.fetcher;
  const resolveHost = options.resolveHost ?? defaultResolveHost;
  const operationController = new AbortController();
  const relayAbort = () => operationController.abort(options.signal?.reason);
  if (options.signal) { if (options.signal.aborted) operationController.abort(options.signal.reason); else options.signal.addEventListener("abort", relayAbort, { once: true }); }
  const deadlineTimer = setTimeout(() => operationController.abort(new Error("Source operation deadline exceeded")), limits.timeoutMs); deadlineTimer.unref?.();
  const cleanup = () => { clearTimeout(deadlineTimer); options.signal?.removeEventListener("abort", relayAbort); };
  let fetched: Awaited<ReturnType<typeof fetchSafe>>;
  let publicPost: XPublicPost | undefined;
  try {
    if (input.publicPostLookup) {
      publicPost = input.publicPostCoverage
        ? await readPublicXPost(sourceUrl.toString(), { ...(fetcher ? { fetcher } : {}), resolveHost, signal: operationController.signal }, { coverage: input.publicPostCoverage })
        : await readPublicXPost(sourceUrl.toString(), { ...(fetcher ? { fetcher } : {}), resolveHost, signal: operationController.signal });
      const rawEvidence = publicPost.rawPages?.length ? JSON.stringify({ provider: publicPost.provider, pages: publicPost.rawPages }) : publicPost.raw;
      const raw = rawEvidence ? new TextEncoder().encode(rawEvidence) : undefined;
      fetched = { finalUrl: sourceUrl.toString(), truncated: Boolean(raw && raw.byteLength > limits.maxBytes), ...(raw ? { bytes: raw.slice(0, limits.maxBytes), mediaType: "application/json" } : {}), disposition: publicPost.disposition };
    } else {
      fetched = await fetchSafe(sourceUrl.toString(), { ...(fetcher ? { fetcher } : {}), resolveHost, signal: operationController.signal, limits });
    }
  } catch (error) {
    if (!(error instanceof SourceNetworkError) && !(error instanceof SourceSafetyError)) { cleanup(); throw error; }
    if (operationController.signal.aborted) { clearTimeout(deadlineTimer); options.signal?.removeEventListener("abort", relayAbort); throw invalid("Source fetch timed out or was cancelled"); }
    const capturedAt = timestamp(now);
    if (error instanceof SourceSafetyError) {
      const blockedContent: SourceContent = { title: input.title?.trim() || sourceUrl.hostname, uri: sourceUrl.toString(), captureDisposition: "reference-only", captureReason: error.fetchAttempted ? "Redirect target failed destination safety validation; an earlier linked request was attempted, but no request was sent to the blocked target." : "Destination safety check failed before any linked request was attempted.", capturedAt, origin: input.origin ?? "manual", origins: sourceOrigin(input.origin ?? "manual", capturedAt, { uri: sourceUrl.toString(), ...(input.identity ? { identity: input.identity } : {}) }), ...(input.annotations ? { annotations: input.annotations } : {}), ...(input.identity ? { identity: input.identity } : {}), ...(input.collectionId ? { collectionId: input.collectionId } : {}) };
      const blockedRequest = {
        commandId: input.commandId,
        ...(input.expectedRevision ? { expectedRevision: input.expectedRevision } : retryTarget ? { expectedRevision: retryTarget.revisionId } : {}),
        signal: operationController.signal,
        record: retryTarget ? retrySourceDraft(retryTarget, blockedContent) : sourceDraft(input, blockedContent),
      };
      try {
        const blocked = await store.captureSource(blockedRequest);
        if (blocked.record.kind !== "source") throw new Error("Blocked source capture returned a non-source record");
        return { record: blocked.record, duplicate: Boolean(retryTarget), fetched: error.fetchAttempted };
      } finally { cleanup(); }
    }
    const failedContent: SourceContent = { title: input.title?.trim() || sourceUrl.hostname, uri: sourceUrl.toString(), captureDisposition: "failed", capturedAt, origin: input.origin ?? "manual", origins: sourceOrigin(input.origin ?? "manual", capturedAt, { uri: sourceUrl.toString(), ...(input.identity ? { identity: input.identity } : {}) }), ...(input.annotations ? { annotations: input.annotations } : {}), ...(input.identity ? { identity: input.identity } : {}), ...(input.collectionId ? { collectionId: input.collectionId } : {}), ...(input.sourcePublishedAt ? { sourcePublishedAt: input.sourcePublishedAt } : {}), ...(input.sourceSavedAt ? { sourceSavedAt: input.sourceSavedAt } : {}) };
    try {
      const failed = await store.captureSource({ commandId: input.commandId, ...(input.expectedRevision ? { expectedRevision: input.expectedRevision } : retryTarget ? { expectedRevision: retryTarget.revisionId } : {}), signal: operationController.signal, record: retryTarget ? retrySourceDraft(retryTarget, failedContent) : sourceDraft(input, failedContent) });
      if (failed.record.kind !== "source") throw new Error("Source capture returned a non-source record");
      return { record: failed.record, duplicate: false, fetched: false };
    } finally { cleanup(); }
  }
  const capturedAt = timestamp(now);
  const bytes = fetched.bytes;
  const mediaType = fetched.mediaType;
  const preview = await optionalPreview(store, bytes, mediaType, fetched.finalUrl, { ...(fetcher ? { fetcher } : {}), resolveHost, signal: operationController.signal, ...(options.signal ? { callerSignal: options.signal } : {}) }, publicPost?.article?.coverURL);
  const publicReadable = publicPost?.readableText ?? publicPost?.text;
  const readable = publicPost ? (publicReadable ? { text: publicReadable.slice(0, limits.maxReadableChars), truncated: publicReadable.length > limits.maxReadableChars } : undefined) : bytes && bytes.byteLength ? extractReadable(bytes, mediaType, limits.maxReadableChars) : undefined;
  const disposition: SourceContent["captureDisposition"] = publicPost && (fetched.truncated || readable?.truncated) ? "partial" : fetched.disposition ?? (bytes && bytes.byteLength > 0 ? (readable === undefined ? "metadata-only" : fetched.quality === "partial" || readable.quality === "partial" || fetched.truncated || readable.truncated ? "partial" : "complete") : "metadata-only");
  // A redirect can reveal an existing canonical target that was not discoverable
  // from the requested alias. Re-scan after fetch so the owner receives the
  // best known revision; the final-URI check is repeated atomically by the
  // KnowledgeStore mutation.
  existing = await allSourceRecords(store);
  if (operationController.signal.aborted) { cleanup(); throw invalid("Source capture was cancelled"); }
  const initialRetryTarget = retryTarget;
  const resolvedTarget = finalTarget(existing, input, fetched.finalUrl);
  if (resolvedTarget) {
    retryTarget = resolvedTarget.content.captureDisposition === "complete" && !(refreshRequested && resolvedTarget.id === initialRetryTarget?.id) ? undefined : resolvedTarget;
  }
  let object: KnowledgeObjectRef | undefined;
  let sourceRecord: KnowledgeRecord & { kind: "source" };
  let result: KnowledgeMutationResult;
  let publicationDraftId: string | undefined;
  if (operationController.signal.aborted) throw invalid("Source capture was cancelled");
  if (bytes && bytes.byteLength > 0) {
    const contentHash = createHash("sha256").update(bytes).digest("hex");
    // A matching incomplete source owns this hydration even when another
    // complete source has identical bytes; otherwise a rerun could switch
    // record identity and lose its admission/provenance envelope.
    const contentDuplicate = retryTarget || resolvedTarget ? undefined : existing.find(record => record.scope === input.scope && record.content.captureDisposition === "complete" && record.content.object?.hash === contentHash);
    if (contentDuplicate) {
      const kind = input.origin ?? "manual";
      const origins = contentDuplicate.content.origins ?? (contentDuplicate.content.origin ? [{ kind: contentDuplicate.content.origin, capturedAt: contentDuplicate.content.capturedAt, ...(contentDuplicate.content.uri ? { uri: contentDuplicate.content.uri } : {}) }] : []);
      const incomingOrigin = { kind, capturedAt, uri: sourceUrl.toString(), ...(input.identity ? { identity: input.identity } : {}) };
      const annotations = input.annotations ? [...(contentDuplicate.content.annotations ?? []), ...input.annotations.filter(annotation => !(contentDuplicate.content.annotations ?? []).some(previous => previous.text === annotation.text && previous.locator === annotation.locator))] : contentDuplicate.content.annotations;
      const mergedContent: SourceContent = { ...contentDuplicate.content, origins: origins.some(origin => origin.uri === incomingOrigin.uri && JSON.stringify(origin.identity) === JSON.stringify(incomingOrigin.identity)) ? origins : [...origins, incomingOrigin], ...(annotations ? { annotations } : {}) };
      try {
        const merged = await store.captureSource({ commandId: input.commandId, expectedRevision: contentDuplicate.revisionId, signal: operationController.signal, record: { kind: "source", id: contentDuplicate.id, createdAt: contentDuplicate.createdAt, scope: contentDuplicate.scope, provenance: contentDuplicate.provenance, relations: contentDuplicate.relations, content: mergedContent } });
        if (merged.record.kind !== "source") throw new Error("Source deduplication returned a non-source record");
        return { record: merged.record, duplicate: true, fetched: true };
      } finally { cleanup(); }
    }
    try { object = await store.putObject(bytes, mediaType ?? "application/octet-stream"); }
    catch (error) { cleanup(); throw error; }
  }
  const kind = input.origin ?? "manual";
  const providerCaptureReason = publicPost ? `${publicPost.endpoint ? `Public provider: ${redactSourceUrl(publicPost.endpoint)}. ` : ""}${publicPost.limitations.join(" ")} Attempts: ${publicPost.attempts.map(attempt => `${attempt.provider}:${attempt.outcome}${attempt.status !== undefined ? ` status=${attempt.status}` : ""}${attempt.retryAt ? ` (retry after ${attempt.retryAt})` : ""}`).join(", ")}` : undefined;
  const captureReason = readable?.quality === "partial" ? appendCaptureReason(providerCaptureReason, "Linked HTML appears to be a bounded app shell; substantive article coverage was not established.") : providerCaptureReason;
  const content: SourceContent = {
    title: input.title?.trim() || publicPost?.title || titleFrom(bytes ?? new Uint8Array(), mediaType) || sourceUrl.hostname,
    uri: fetched.finalUrl,
    ...(captureReason ? { captureReason } : {}),
    ...(publicPost?.linkedUrls ? { linkedUrls: publicPost.linkedUrls } : {}),
    ...(readable ? { text: readable.text } : {}), ...(object ? { object } : {}), ...(preview ? { preview } : {}), ...(mediaType ? { mediaType } : {}),
    captureDisposition: disposition, ...(input.annotations ? { annotations: input.annotations } : {}), capturedAt,
    origin: kind, origins: [...(retryTarget?.content.origins ?? []), ...sourceOrigin(kind, capturedAt, { uri: fetched.finalUrl, ...(input.identity ? { identity: input.identity } : {}) }), ...(fetched.finalUrl !== sourceUrl.toString() ? [{ kind, capturedAt, uri: sourceUrl.toString(), ...(input.identity ? { identity: input.identity } : {}) }] : [])], ...(input.identity ? { identity: input.identity } : {}), ...(input.collectionId ? { collectionId: input.collectionId } : {}), ...(input.sourcePublishedAt ? { sourcePublishedAt: input.sourcePublishedAt } : {}), ...(input.sourceSavedAt ? { sourceSavedAt: input.sourceSavedAt } : {}),
  };
  const request = { commandId: input.commandId, ...(input.expectedRevision ? { expectedRevision: input.expectedRevision } : retryTarget ? { expectedRevision: retryTarget.revisionId } : {}), record: retryTarget ? retrySourceDraft(retryTarget, content) : { ...sourceDraft(input, content), id: randomUUID() } };
  publicationDraftId = request.record.id;
  try { result = await store.captureSource({ ...request, canonicalUri: fetched.finalUrl, signal: operationController.signal }); }
  catch (error) { cleanup(); throw error; }
  if (result.record.kind !== "source") { cleanup(); throw new Error("Source capture returned a non-source record"); }
  sourceRecord = result.record;
  try {
    if (publicPost?.linkedUrls?.length) {
      const linked = await captureLinkedPublicSources(store, sourceRecord, input, publicPost, { ...options, signal: operationController.signal });
      sourceRecord = linked.record;
      if (linked.failures.length > 0) {
        const updated = await store.captureSource({
          commandId: childCommand(input.commandId, "linked-failures"), expectedRevision: sourceRecord.revisionId, ...(options.signal ? { signal: options.signal } : {}),
          record: { kind: "source", id: sourceRecord.id, createdAt: sourceRecord.createdAt, scope: sourceRecord.scope, provenance: sourceRecord.provenance, relations: sourceRecord.relations, ...(sourceRecord.temporal ? { temporal: sourceRecord.temporal } : {}), content: { ...sourceRecord.content, captureReason: appendCaptureReason(sourceRecord.content.captureReason, `Linked target limitations: ${linked.failures.join(", ")}.`) } },
        });
        if (updated.record.kind !== "source") throw new Error("Linked failure diagnostic returned a non-source record");
        sourceRecord = updated.record;
      }
    }
  } catch (error) {
    cleanup();
    throw error;
  }
  let assessmentError: string | undefined;
  if (options.model && readable && disposition !== "inaccessible" && disposition !== "failed" && !operationController.signal.aborted) {
    try {
      const interests = input.interests ?? (await store.config()).currentInterests ?? [];
      if (operationController.signal.aborted) throw new SourceNetworkError("Source assessment cancelled");
      // Bound the assessment await: the adapter may ignore its abort signal, and
      // the deadline must not leave this capture pending after the source record
      // was already retained. A late assessment stays fenced by the signal and the
      // revision revalidation below.
      const assessmentOperation = awaitAbortableWithSettlement(
        options.model.assess({ title: sourceRecord.content.title, text: readable.text, interests: interests.slice(0, 50).map(item => item.slice(0, 500)), source: { ...(sourceRecord.content.uri ? { uri: sourceRecord.content.uri } : {}), ...(mediaType ? { mediaType } : {}), ...(sourceRecord.content.collectionId ? { collectionId: sourceRecord.content.collectionId } : {}), captureDisposition: sourceRecord.content.captureDisposition, capturedAt } }, operationController.signal),
        operationController.signal,
        () => new Error("Source assessment deadline exceeded or was cancelled"),
      );
      options.retirements?.push(assessmentOperation.settled);
      const assessment = await assessmentOperation.wait;
      if (operationController.signal.aborted) throw new SourceNetworkError("Source assessment cancelled");
      const latestConfig = await store.config();
      if (operationController.signal.aborted) throw new SourceNetworkError("Source assessment cancelled");
      const latest = await store.read(sourceRecord.id, sourceRecord.revisionId, false, true, true);
      if (operationController.signal.aborted) throw new SourceNetworkError("Source assessment cancelled");
      const excluded = latest?.kind === "source" ? await store.scopeExcluded({ ...(latest.provenance.sessionId ? { sessionId: latest.provenance.sessionId } : {}), ...(latest.provenance.branchId ? { branchId: latest.provenance.branchId } : {}) }) : false;
      if (operationController.signal.aborted) throw new SourceNetworkError("Source assessment cancelled");
      if (latestConfig.revision !== initialConfig.revision || !latest || latest.kind !== "source" || excluded) throw new Error("Source changed or became unavailable during assessment");
      const assessed: SourceContent = { ...latest.content, assessment: { ...assessment, generatedAt: assessment.generatedAt ?? now(), evidenceDigest: sourceEvidenceDigest(latest.content.title, latest.content.text ?? "") } };
      if (operationController.signal.aborted) throw new SourceNetworkError("Source assessment cancelled");
      result = await store.captureSource({ commandId: `${input.commandId}:assessment`, expectedRevision: sourceRecord.revisionId, signal: operationController.signal, record: retryTarget ? retrySourceDraft(sourceRecord, assessed) : { ...sourceDraft(input, assessed), id: sourceRecord.id, createdAt: sourceRecord.createdAt } });
      if (result.record.kind !== "source") throw new Error("Source assessment returned a non-source record");
      sourceRecord = result.record;
    } catch (error) { assessmentError = error instanceof Error ? error.message : "Source assessment failed"; }
  }
  clearTimeout(deadlineTimer); options.signal?.removeEventListener("abort", relayAbort);
  return { record: sourceRecord, duplicate: publicationDraftId !== undefined && sourceRecord.id !== publicationDraftId, fetched: true, ...(assessmentError ? { assessmentError } : {}) };
}

/** Remote acknowledgements require a retained raw object and readable bytes;
 * a provider metadata/excerpt or a nominal complete label is insufficient. */
export function isVerifiedSourceCapture(record: KnowledgeRecord & { kind: "source" }): boolean {
  const content = record.content;
  return content.captureDisposition === "complete" && Boolean(content.object && content.object.bytes > 0 && content.text && content.text.trim().length > 0);
}

export { assertPublicDestination, isPrivateAddress };
