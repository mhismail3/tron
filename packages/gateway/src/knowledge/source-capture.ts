import { createHash } from "node:crypto";
import { request as httpRequest } from "node:http";
import { request as httpsRequest } from "node:https";
import { lookup } from "node:dns/promises";
import { isIP } from "node:net";
import type {
  KnowledgeEvidenceRef, KnowledgeObjectRef, KnowledgeRecord, KnowledgeRecordDraft,
  KnowledgeScope, SourceAssessment, SourceContent,
  SourceIdentity, SourceOriginKind,
} from "./knowledge-contract.js";
import { KnowledgeStore, type KnowledgeMutationResult } from "./knowledge-store.js";
import { awaitAbortableWithSettlement } from "./model-await.js";

export const SOURCE_CAPTURE_LIMITS = {
  maxBytes: 8_000_000,
  maxReadableChars: 2_000_000,
  timeoutMs: 15_000,
  maxRedirects: 3,
} as const;

type ResolveHost = (hostname: string, signal?: AbortSignal) => Promise<string[]>;
type SourceFetch = (input: string | URL, init?: RequestInit) => Promise<Response>;

export interface SourceCaptureInput {
  commandId: string;
  url: string;
  scope: KnowledgeScope;
  title?: string;
  sourcePublishedAt?: string;
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
  limits?: Partial<typeof SOURCE_CAPTURE_LIMITS>;
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
  for (const key of parsed.searchParams.keys()) if (/^(?:token|api[_-]?key|key|secret|password|passwd|auth|signature|sig|access[_-]?token|credential|session)$/i.test(key)) throw invalid("Source URL contains a credential-bearing query parameter");
  return parsed;
}

/** URL diagnostics never include query strings or credentials. */
export function redactSourceUrl(value: string): string {
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

function extractReadable(bytes: Uint8Array, mediaType: string | undefined, maxChars: number): { text: string; truncated: boolean } | undefined {
  const normalized = (mediaType ?? "").split(";", 1)[0]!.trim().toLowerCase();
  if (!(normalized.startsWith("text/") || ["application/xhtml+xml", "application/json", "application/xml", "application/ld+json"].includes(normalized))) return undefined;
  let text = new TextDecoder("utf-8", { fatal: false }).decode(bytes);
  if (normalized === "text/html" || normalized === "application/xhtml+xml") {
    text = text.replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, " ").replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, " ").replace(/<noscript\b[^>]*>[\s\S]*?<\/noscript>/gi, " ").replace(/<!--([\s\S]*?)-->/g, " ").replace(/<[^>]*>/g, " ");
    text = text.replace(/&nbsp;/gi, " ").replace(/&amp;/gi, "&").replace(/&lt;/gi, "<").replace(/&gt;/gi, ">").replace(/&#39;/g, "'").replace(/&quot;/gi, '"');
  }
  const normalizedText = text.replace(/[\t\r ]+/g, " ").replace(/\n\s*\n+/g, "\n\n").trim();
  return normalizedText ? { text: normalizedText.slice(0, maxChars), truncated: normalizedText.length > maxChars } : undefined;
}

function titleFrom(bytes: Uint8Array, mediaType: string | undefined): string | undefined {
  const normalized = (mediaType ?? "").toLowerCase();
  if (!normalized.includes("html")) return undefined;
  const text = new TextDecoder().decode(bytes.slice(0, 100_000));
  return text.match(/<title[^>]*>([\s\S]*?)<\/title>/i)?.[1]?.replace(/<[^>]+>/g, " ").trim().slice(0, 512) || undefined;
}

async function fetchSafe(inputUrl: string, options: { fetcher?: SourceFetch; resolveHost: ResolveHost; signal?: AbortSignal; limits: typeof SOURCE_CAPTURE_LIMITS }): Promise<{ response?: Response; bytes?: Uint8Array; truncated: boolean; finalUrl: string; disposition?: SourceContent["captureDisposition"]; mediaType?: string; quality?: "partial" }> {
  let current = assertSafeUrl(inputUrl); let requestAttempted = false;
  for (let hop = 0; hop <= options.limits.maxRedirects; hop += 1) {
    try {
      const address = await assertPublicDestination(current, options.resolveHost, options.signal);
    const controller = new AbortController();
    const onAbort = () => controller.abort(options.signal?.reason);
    if (options.signal) { if (options.signal.aborted) controller.abort(options.signal.reason); else options.signal.addEventListener("abort", onAbort, { once: true }); }
    let response: Response;
    try { requestAttempted = true; response = options.fetcher ? await options.fetcher(current, { redirect: "manual", signal: controller.signal }) : await pinnedFetch(current, address, { signal: controller.signal }); }
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

async function allSourceRecords(store: KnowledgeStore): Promise<Array<KnowledgeRecord & { kind: "source" }>> {
  const result: Array<KnowledgeRecord & { kind: "source" }> = [];
  let cursor: string | undefined;
  do {
    const page = await store.list({ kind: "source", includeSuppressed: false, includeArchived: true, includePending: true, limit: 100, ...(cursor ? { cursor } : {}) });
    result.push(...page.records.filter((record): record is KnowledgeRecord & { kind: "source" } => record.kind === "source"));
    if (page.incomplete) throw new Error("Source deduplication scan is incomplete; retry after reducing the canonical corpus");
    cursor = page.nextCursor;
  } while (cursor);
  return result;
}

function normalizedUrl(value: string): string {
  const url = new URL(value); url.hash = ""; url.hostname = url.hostname.toLowerCase();
  if ((url.protocol === "https:" && url.port === "443") || (url.protocol === "http:" && url.port === "80")) url.port = "";
  return url.toString();
}

function sourceDraft(input: SourceCaptureInput, content: SourceContent, evidence: KnowledgeEvidenceRef[] = []): KnowledgeRecordDraft & { kind: "source" } {
  const admittedContent = input.origin === "connector" && !content.admission
    ? { ...content, admission: { status: "pending" as const, reason: "Connector capture awaits local admission", decidedAt: content.capturedAt } }
    : content;
  return { kind: "source", scope: input.scope, provenance: { actor: input.origin === "connector" ? "connector" : input.origin === "import" ? "import" : "user", ...(input.identity ? { source: `${input.identity.provider}:${input.identity.accountId}:${input.identity.itemId}` } : {}), evidence }, relations: [], content: admittedContent };
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
  const sourceUrl = assertSafeUrl(input.url);
  const initialConfig = await store.config();
  if (options.signal?.aborted) throw invalid("Source capture was cancelled");
  const existing = await allSourceRecords(store);
  if (options.signal?.aborted) throw invalid("Source capture was cancelled");
  const normalized = normalizedUrl(sourceUrl.toString());
  const duplicate = existing.find(record => record.scope === input.scope && record.content.captureDisposition === "complete" && ((input.identity && record.content.identity && JSON.stringify(record.content.identity) === JSON.stringify(input.identity)) || (record.content.uri && normalizedUrl(record.content.uri) === normalized)));
  const retryTarget = existing.find(record => record.scope === input.scope && record.content.captureDisposition !== "complete" && ((input.identity && record.content.identity && JSON.stringify(record.content.identity) === JSON.stringify(input.identity)) || (record.content.uri && normalizedUrl(record.content.uri) === normalized)));
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
  try {
    fetched = await fetchSafe(sourceUrl.toString(), { ...(fetcher ? { fetcher } : {}), resolveHost, signal: operationController.signal, limits });
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
        record: { ...sourceDraft(input, blockedContent), ...(retryTarget ? { id: retryTarget.id, createdAt: retryTarget.createdAt } : {}) },
      };
      try {
        const blocked = await store.captureSource(blockedRequest);
        if (blocked.record.kind !== "source") throw new Error("Blocked source capture returned a non-source record");
        return { record: blocked.record, duplicate: Boolean(retryTarget), fetched: error.fetchAttempted };
      } finally { cleanup(); }
    }
    const failedContent: SourceContent = { title: input.title?.trim() || sourceUrl.hostname, uri: sourceUrl.toString(), captureDisposition: "failed", capturedAt, origin: input.origin ?? "manual", origins: sourceOrigin(input.origin ?? "manual", capturedAt, { uri: sourceUrl.toString(), ...(input.identity ? { identity: input.identity } : {}) }), ...(input.annotations ? { annotations: input.annotations } : {}), ...(input.identity ? { identity: input.identity } : {}), ...(input.collectionId ? { collectionId: input.collectionId } : {}), ...(input.sourcePublishedAt ? { sourcePublishedAt: input.sourcePublishedAt } : {}) };
    try {
      const failed = await store.captureSource({ commandId: input.commandId, ...(input.expectedRevision ? { expectedRevision: input.expectedRevision } : {}), signal: operationController.signal, record: sourceDraft(input, failedContent) });
      if (failed.record.kind !== "source") throw new Error("Source capture returned a non-source record");
      return { record: failed.record, duplicate: false, fetched: false };
    } finally { cleanup(); }
  }
  const capturedAt = timestamp(now);
  const bytes = fetched.bytes;
  const mediaType = fetched.mediaType;
  const readable = bytes && bytes.byteLength ? extractReadable(bytes, mediaType, limits.maxReadableChars) : undefined;
  const disposition: SourceContent["captureDisposition"] = fetched.disposition ?? (bytes && bytes.byteLength > 0 ? (readable === undefined ? "metadata-only" : fetched.quality === "partial" || fetched.truncated || readable.truncated ? "partial" : "complete") : "metadata-only");
  let object: KnowledgeObjectRef | undefined;
  if (operationController.signal.aborted) throw invalid("Source capture was cancelled");
  if (bytes && bytes.byteLength > 0) {
    const contentHash = createHash("sha256").update(bytes).digest("hex");
    const contentDuplicate = existing.find(record => record.scope === input.scope && record.content.captureDisposition === "complete" && record.content.object?.hash === contentHash);
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
  const content: SourceContent = {
    title: input.title?.trim() || titleFrom(bytes ?? new Uint8Array(), mediaType) || sourceUrl.hostname,
    uri: fetched.finalUrl,
    ...(readable ? { text: readable.text } : {}), ...(object ? { object } : {}), ...(mediaType ? { mediaType } : {}),
    captureDisposition: disposition, ...(input.annotations ? { annotations: input.annotations } : {}), capturedAt,
    origin: kind, origins: [...(retryTarget?.content.origins ?? []), ...sourceOrigin(kind, capturedAt, { uri: fetched.finalUrl, ...(input.identity ? { identity: input.identity } : {}) }), ...(fetched.finalUrl !== sourceUrl.toString() ? [{ kind, capturedAt, uri: sourceUrl.toString(), ...(input.identity ? { identity: input.identity } : {}) }] : [])], ...(input.identity ? { identity: input.identity } : {}), ...(input.collectionId ? { collectionId: input.collectionId } : {}), ...(input.sourcePublishedAt ? { sourcePublishedAt: input.sourcePublishedAt } : {}),
  };
  const request = { commandId: input.commandId, ...(input.expectedRevision ? { expectedRevision: input.expectedRevision } : retryTarget ? { expectedRevision: retryTarget.revisionId } : {}), record: { ...sourceDraft(input, content), ...(retryTarget ? { id: retryTarget.id, createdAt: retryTarget.createdAt } : {}) } };
  let result: KnowledgeMutationResult;
  try { result = await store.captureSource({ ...request, signal: operationController.signal }); }
  catch (error) { cleanup(); throw error; }
  if (result.record.kind !== "source") { cleanup(); throw new Error("Source capture returned a non-source record"); }
  let sourceRecord = result.record;
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
      const assessed: SourceContent = { ...latest.content, assessment: { ...assessment, generatedAt: assessment.generatedAt ?? now() } };
      if (operationController.signal.aborted) throw new SourceNetworkError("Source assessment cancelled");
      result = await store.captureSource({ commandId: `${input.commandId}:assessment`, expectedRevision: sourceRecord.revisionId, signal: operationController.signal, record: { ...sourceDraft(input, assessed), id: sourceRecord.id, createdAt: sourceRecord.createdAt } });
      if (result.record.kind !== "source") throw new Error("Source assessment returned a non-source record");
      sourceRecord = result.record;
    } catch (error) { assessmentError = error instanceof Error ? error.message : "Source assessment failed"; }
  }
  clearTimeout(deadlineTimer); options.signal?.removeEventListener("abort", relayAbort);
  return { record: sourceRecord, duplicate: false, fetched: true, ...(assessmentError ? { assessmentError } : {}) };
}

/** Remote acknowledgements require a retained raw object and readable bytes;
 * a provider metadata/excerpt or a nominal complete label is insufficient. */
export function isVerifiedSourceCapture(record: KnowledgeRecord & { kind: "source" }): boolean {
  const content = record.content;
  return content.captureDisposition === "complete" && Boolean(content.object && content.object.bytes > 0 && content.text && content.text.trim().length > 0);
}

export { assertPublicDestination, isPrivateAddress };
