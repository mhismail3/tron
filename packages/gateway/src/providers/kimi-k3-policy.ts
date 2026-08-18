import type { FetchFunction, Model } from "@earendil-works/pi-ai";
import type { ModelRuntime } from "@earendil-works/pi-coding-agent";

/**
 * Moonshot accounts reserve the requested completion budget against TPM, even
 * when the model emits fewer tokens. Keep the default agent request useful for
 * coding while leaving headroom for large K3 contexts on ordinary accounts.
 */
export const KIMI_K3_MAX_COMPLETION_TOKENS = 32_768;
const installedRuntimes = new WeakSet<ModelRuntime>();
const KIMI_K3_MAX_CONCURRENCY_RETRY_DELAY_MS = 10_000;

export function isKimiK3Model(model: Pick<Model<any>, "provider" | "id">): boolean {
  return (model.provider === "moonshotai" || model.provider === "moonshotai-cn") && model.id === "kimi-k3";
}

function record(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : undefined;
}

/** Apply K3's current Chat Completions parameter contract to a provider payload. */
export function normalizeKimiK3Payload(payload: unknown): unknown {
  const source = record(payload);
  if (!source) return payload;
  const next = { ...source };
  const legacyMaxTokens = next.max_tokens;
  const completionTokens = next.max_completion_tokens;
  const requested = typeof completionTokens === "number"
    ? completionTokens
    : typeof legacyMaxTokens === "number" ? legacyMaxTokens : undefined;
  if (requested !== undefined) {
    // max_completion_tokens is the documented K3 field. Keep an explicit lower
    // caller limit, but never send the catalog's 131,072-token default.
    next.max_completion_tokens = Math.min(requested, KIMI_K3_MAX_COMPLETION_TOKENS);
    delete next.max_tokens;
  }
  return next;
}

function accountError(body: unknown): { type: string; message: string } | undefined {
  const error = record(record(body)?.error);
  if (!error) return undefined;
  return {
    type: typeof error.type === "string" ? error.type : "",
    message: typeof error.message === "string" ? error.message : "",
  };
}

function retryAfterMs(response: Response, body: unknown): number | undefined {
  const error = accountError(body);
  if (!error || error.type !== "rate_limit_reached_error") return undefined;
  // A max-concurrency response is recoverable when Moonshot supplies explicit
  // retry guidance. Only perform one short, provider-advised retry; TPM/RPM/TPD
  // budget failures without guidance remain terminal for this request.
  if (!/(?:concurrenc|try again after|retry after)/i.test(error.message)) return undefined;
  const retryAfterMsHeader = Number.parseFloat(response.headers.get("retry-after-ms") ?? "");
  if (Number.isFinite(retryAfterMsHeader)) return Math.min(Math.max(0, retryAfterMsHeader), KIMI_K3_MAX_CONCURRENCY_RETRY_DELAY_MS);
  const retryAfterHeader = Number.parseFloat(response.headers.get("retry-after") ?? "");
  if (Number.isFinite(retryAfterHeader)) return Math.min(Math.max(0, retryAfterHeader * 1_000), KIMI_K3_MAX_CONCURRENCY_RETRY_DELAY_MS);
  const match = error.message.match(/(?:try again|retry) after\s+(\d+(?:\.\d+)?)\s*(?:seconds?|s)/i);
  if (!match) return undefined;
  const seconds = Number.parseFloat(match[1]!);
  return Number.isFinite(seconds)
    ? Math.min(Math.max(0, seconds * 1_000), KIMI_K3_MAX_CONCURRENCY_RETRY_DELAY_MS)
    : undefined;
}

function terminalAccountLimit(body: unknown): boolean {
  const error = accountError(body);
  if (!error) return false;
  // engine_overloaded_error is transient; account/org limit and quota errors
  // are deterministic for this request and must not enter another retry loop.
  if (error.type === "engine_overloaded_error") return false;
  return error.type === "rate_limit_reached_error"
    || error.type === "exceeded_current_quota_error"
    || error.type === "insufficient_quota"
    || /(?:organization|account|\b(?:TPM|RPM|TPD)\b|quota)/i.test(error.message);
}

function nonRetryingMessage(body: unknown): string {
  const message = accountError(body)?.message || "Moonshot account limit reached";
  // The pinned agent's generic retry classifier intentionally treats the words
  // "429" and "rate limit" as transient. Preserve useful provider detail while
  // rewriting those markers because this response has already been classified
  // as a terminal account/org limit.
  return message
    .replace(/rate[_ -]?limit(?:ed|ing)?/gi, "account limit")
    .replace(/too many requests/gi, "provider request budget")
    .replace(/\b429\b/g, "HTTP throttling response");
}

function responseWithBody(response: Response, body: string): Response {
  const headers = new Headers(response.headers);
  headers.delete("content-length");
  headers.delete("content-encoding");
  headers.delete("transfer-encoding");
  return new Response(body, { status: response.status, statusText: response.statusText, headers });
}

/** Sleep without making provider retry delays un-abortable. */
function abortableSleep(delayMs: number, signal: AbortSignal | null | undefined): Promise<void> {
  if (delayMs <= 0) return Promise.resolve();
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(new DOMException("The request was aborted", "AbortError"));
      return;
    }
    const timer = setTimeout(() => {
      signal?.removeEventListener("abort", onAbort);
      resolve();
    }, delayMs);
    const onAbort = () => {
      clearTimeout(timer);
      reject(new DOMException("The request was aborted", "AbortError"));
    };
    signal?.addEventListener("abort", onAbort, { once: true });
  });
}

/** Prevent terminal Moonshot account limits from being retried by either layer. */
export function wrapKimiK3Fetch(fetch: FetchFunction): FetchFunction {
  return async (input, init) => {
    const retryInput = input instanceof Request ? input.clone() : input;
    const signal = init?.signal ?? (input instanceof Request ? input.signal : undefined);
    let response = await fetch(input, init);
    if (response.status !== 429) return response;
    let rawBody = "";
    let body: unknown;
    try {
      rawBody = await response.text();
      body = JSON.parse(rawBody) as unknown;
    } catch {
      return responseWithBody(response, rawBody);
    }
    const delayMs = retryAfterMs(response, body);
    if (delayMs !== undefined) {
      await abortableSleep(delayMs, signal);
      response = await fetch(retryInput, init);
      if (response.status !== 429) return response;
      try {
        rawBody = await response.text();
        body = JSON.parse(rawBody) as unknown;
      } catch {
        return responseWithBody(response, rawBody);
      }
    }
    if (!terminalAccountLimit(body)) return responseWithBody(response, rawBody);
    const headers = new Headers(response.headers);
    headers.set("content-type", "application/json");
    headers.set("x-should-retry", "false");
    return new Response(JSON.stringify({
      error: {
        message: nonRetryingMessage(body),
        type: "account_limit_reached",
      },
    }), { status: 400, headers });
  };
}

/** Install the narrow K3 request policy on one session-scoped model runtime. */
export function installKimiK3Policy(modelRuntime: ModelRuntime): ModelRuntime {
  if (installedRuntimes.has(modelRuntime)) return modelRuntime;
  installedRuntimes.add(modelRuntime);
  const originalStreamSimple = modelRuntime.streamSimple.bind(modelRuntime);
  modelRuntime.streamSimple = ((model, context, options) => {
    if (!isKimiK3Model(model)) return originalStreamSimple(model, context, options);
    const originalOnPayload = options?.onPayload;
    const originalFetch = options?.fetch ?? globalThis.fetch;
    return originalStreamSimple(model, context, {
      ...options,
      fetch: wrapKimiK3Fetch(originalFetch),
      onPayload: async (payload, requestModel) => {
        const transformed = originalOnPayload ? await originalOnPayload(payload, requestModel) : undefined;
        return normalizeKimiK3Payload(transformed === undefined ? payload : transformed);
      },
    });
  }) as ModelRuntime["streamSimple"];
  return modelRuntime;
}
