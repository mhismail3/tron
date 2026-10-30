import { request as httpRequest } from "node:http";
import { request as httpsRequest } from "node:https";
import { lookup } from "node:dns/promises";
import { isIP } from "node:net";
const SOURCE_CAPTURE_USER_AGENT = "Tron/0.1 (public-source-capture)";

const PUBLIC_FETCH_LIMITS = {
  maxBytes: 8_000_000,
  maxRedirects: 3,
} as const;
type PublicFetchLimits = { [K in keyof typeof PUBLIC_FETCH_LIMITS]: number };

type ResolveHost = (hostname: string, signal?: AbortSignal) => Promise<string[]>;
type SourceFetch = (input: string | URL, init?: RequestInit) => Promise<Response>;

interface PublicFetchOptions { fetcher?: SourceFetch; resolveHost?: ResolveHost; signal?: AbortSignal; }
function invalid(message: string): Error { return new Error(message); }
class SourceNetworkError extends Error {}
class SourceSafetyError extends Error {
  constructor(readonly fetchAttempted: boolean) { super("Source destination is not publicly routable"); }
}
function isCredentialQueryKey(key: string): boolean {
  return /^(?:token|api[_-]?key|key|secret|password|passwd|auth|signature|sig|access[_-]?token|credential|session)$/i.test(key);
}
function xEmbedToken(id: string): string { return (Number(id) / 1e15 * Math.PI).toString(36).replace(/(0+|\.)/g, "") }
function isPublicXEmbedUrl(url: URL): boolean {
  const id = url.searchParams.get("id") ?? "";
  return url.origin === "https://cdn.syndication.twimg.com" && url.pathname === "/tweet-result" && /^[1-9][0-9]{0,19}$/.test(id) && url.searchParams.getAll("token").length === 1 && url.searchParams.get("token") === xEmbedToken(id);
}
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

/* --- Readable-text extraction -------------------------------------------------
 * The source owner, not a per-site rule, decides which text a saved page
 * contributes to summaries and search. Structural signals only: never a
 * hostname or class-name allowlist, which drifts and silently eats articles.
 */
export interface PublicUrlFetch {
  status?: number;
  bytes?: Uint8Array;
  mediaType?: string;
  truncated: boolean;
  finalUrl: string;
  disposition?: "inaccessible" | "failed";
}

/** Validate a public destination before disclosing it to a remote reader. Uses
 * the same credential and DNS policy as every-hop direct source capture. */
export async function validatePublicSourceUrl(url: string, options: Pick<PublicFetchOptions, "resolveHost" | "signal"> = {}): Promise<string> {
  const parsed = assertSafeUrl(url);
  await assertPublicDestination(parsed, options.resolveHost ?? defaultResolveHost, options.signal);
  return parsed.href;
}

/**
 * One bounded fetch of a public http(s) URL through capture's own transport:
 * credential-bearing URLs refused, every redirect hop DNS-resolved and refused
 * when private (SSRF), the response read to `limits.maxBytes` at most. It never
 * persists anything; the caller owns what becomes of the bytes.
 */
export async function fetchPublicUrl(
  url: string,
  options: Pick<PublicFetchOptions, "fetcher" | "resolveHost" | "signal"> & { limits?: Partial<PublicFetchLimits> } = {},
): Promise<PublicUrlFetch> {
  const fetched = await fetchSafe(url, {
    ...(options.fetcher ? { fetcher: options.fetcher } : {}),
    resolveHost: options.resolveHost ?? defaultResolveHost,
    ...(options.signal ? { signal: options.signal } : {}),
    limits: { ...PUBLIC_FETCH_LIMITS, ...(options.limits ?? {}) },
  });
  return {
    ...(fetched.response ? { status: fetched.response.status } : {}),
    ...(fetched.bytes ? { bytes: fetched.bytes } : {}),
    ...(fetched.mediaType ? { mediaType: fetched.mediaType } : {}),
    truncated: fetched.truncated,
    finalUrl: fetched.finalUrl,
    ...(fetched.disposition === "inaccessible" || fetched.disposition === "failed" ? { disposition: fetched.disposition } : {}),
  };
}

async function fetchSafe(inputUrl: string, options: { fetcher?: SourceFetch; resolveHost: ResolveHost; signal?: AbortSignal; limits: PublicFetchLimits }): Promise<{ response?: Response; bytes?: Uint8Array; truncated: boolean; finalUrl: string; disposition?: "inaccessible" | "failed"; mediaType?: string; quality?: "partial" }> {
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
