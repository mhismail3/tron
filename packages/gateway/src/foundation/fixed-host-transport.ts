import { URL } from "node:url";

export interface FixedHostRequest {
  readonly method: "GET" | "PUT" | "POST" | "DELETE";
  readonly headers: Record<string, string>;
  readonly body?: string;
  readonly signal: AbortSignal;
  readonly allowedHosts: readonly string[];
  readonly timeoutMs: number;
  readonly maxBodyBytes: number;
}

export interface FixedHostResponse {
  readonly status: number;
  readonly headers: Headers;
  readonly body: string;
}

export class FixedHostBodyTooLarge extends Error {
  constructor() { super("Fixed-host response exceeded its bounded body limit"); }
}

/**
 * Bounded transport for providers whose endpoint is fixed by the adapter.
 * Endpoint construction, credential policy, retries, and paid admission stay
 * with callers. Arbitrary source URLs must use source-capture's DNS/SSRF
 * transport instead of this host-only check.
 */
export async function requestFixedHost(
  input: string,
  init: FixedHostRequest,
  fetchImpl: typeof fetch = fetch,
): Promise<FixedHostResponse> {
  let endpoint: URL;
  try { endpoint = new URL(input); } catch { throw new Error("Fixed-host endpoint is invalid"); }
  if (endpoint.protocol !== "https:" || !init.allowedHosts.includes(endpoint.hostname)) {
    throw new Error("Fixed-host endpoint is not allowlisted");
  }
  const timeout = AbortSignal.timeout(init.timeoutMs);
  const signal = AbortSignal.any([init.signal, timeout]);
  const response = await fetchImpl(endpoint, {
    method: init.method,
    headers: init.headers,
    ...(init.body === undefined ? {} : { body: init.body }),
    redirect: "error",
    signal,
  });
  if (!response.body) return { status: response.status, headers: response.headers, body: "" };
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const next = await reader.read();
      if (next.done) break;
      if (!next.value) continue;
      total += next.value.byteLength;
      if (total > init.maxBodyBytes) {
        await reader.cancel();
        throw new FixedHostBodyTooLarge();
      }
      chunks.push(next.value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return { status: response.status, headers: response.headers, body: new TextDecoder().decode(bytes) };
}
