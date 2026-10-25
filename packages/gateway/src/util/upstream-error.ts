import { redact, redactCredentials, redactCredentialField } from "./credential-redaction.js";

/** Transport-independent classification of an upstream failure. Queue policy,
 * account-usage reads and transcript presentation consume these same facts. */
export interface UpstreamErrorInfo {
  message: string;
  providerMessage: string;
  category: "overloaded" | "rate-limit" | "usage-limit" | "authentication" | "entitlement" | "forbidden" | "unavailable" | "network" | "timeout" | "aborted" | "not-found" | "unknown";
  type?: string;
  requestId?: string;
  httpStatus?: number;
}

export const UPSTREAM_USAGE_LIMIT = /GoUsageLimitError|FreeUsageLimitError|usage.?limit|insufficient_quota|quota exceeded|out of budget|subscription_sharing_usage_limit_exceeded|available balance|\b429\b|rate.?limit|too many requests/iu;

function object(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : undefined;
}
function string(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

/** Preserve JSON syntax while masking secret-valued fields as well as known
 * credential shapes. Request IDs, model names and ordinary diagnostic fields
 * remain useful; the canonical SDK record is never rewritten. */
export function redactedUpstreamError(raw: string): string {
  const start = raw.indexOf("{");
  if (start >= 0) {
    try {
      const value: unknown = JSON.parse(raw.slice(start));
      const clean = JSON.stringify(value, redactCredentialField);
      return redactCredentials(raw.slice(0, start)) + clean;
    } catch { /* Non-JSON diagnostics keep their original layout. */ }
  }
  return redactCredentials(redact(raw));
}

/** Account endpoints may only infer credential/plan facts from these typed
 * refusals, never from general prose such as an edge page's "unauthorized". */
export function upstreamAccountRefusal(body: unknown): "entitlement" | "credential" | undefined {
  const type = object(object(body)?.error)?.type;
  if (type === "EntitlementError") return "entitlement";
  if (type === "AuthError") return "credential";
  return undefined;
}

export function upstreamErrorInfo(raw: string, provider: string): UpstreamErrorInfo {
  const safe = redactedUpstreamError(raw);
  let root: Record<string, unknown> | undefined;
  try { root = object(JSON.parse(safe.slice(Math.max(0, safe.indexOf("{"))))); } catch { /* Text fallback below. */ }
  const error = object(root?.error) ?? root;
  const type = string(error?.type) ?? string(error?.code);
  const message = string(error?.message) ?? string(root?.message) ?? string(root?.error) ?? safe;
  const requestId = string(root?.request_id) ?? string(root?.requestId) ?? string(error?.request_id);
  const statusValue = root?.status ?? root?.statusCode ?? error?.status ?? error?.status_code;
  const numericStatus = typeof statusValue === "number" ? statusValue : typeof statusValue === "string" ? Number(statusValue) : undefined;
  const httpStatus = numericStatus && numericStatus >= 400 && numericStatus <= 599 ? numericStatus
    : Number(safe.match(/(?:^|\bHTTP(?:\/\d(?:\.\d)?)?\s*|\bstatus(?:\s+code)?\s*[:=]?\s*)([45]\d\d)\b/iu)?.[1]) || undefined;
  const text = `${type ?? ""} ${message}`;
  const accountRefusal = upstreamAccountRefusal({ error });
  const name = ({ anthropic: "Anthropic", openai: "OpenAI", "openai-codex": "OpenAI", "opencode-go": "OpenCode Go", opencode: "OpenCode" } as Record<string, string>)[provider] ?? (provider || "The provider");
  let category: UpstreamErrorInfo["category"] = "unknown";
  let friendly = message;
  if (accountRefusal === "entitlement") { category = "entitlement"; friendly = `${name} requires an active subscription`; }
  else if (accountRefusal === "credential" || httpStatus === 401 || /authentication_error|invalid_api_key|unauthorized/iu.test(text)) { category = "authentication"; friendly = `Authentication failed for ${name}`; }
  else if (httpStatus === 403 || /permission_error|permission denied|forbidden/iu.test(text)) { category = "forbidden"; friendly = `Access denied by ${name}`; }
  else if (/overload|engine_overloaded/iu.test(text) || httpStatus === 529) { category = "overloaded"; friendly = `${name} is overloaded`; }
  else if (/abort|cancelled|canceled/iu.test(text)) { category = "aborted"; friendly = "Request cancelled"; }
  else if (/timeout|timed?\s*out|ETIMEDOUT/iu.test(text)) { category = "timeout"; friendly = `The connection to ${name} timed out`; }
  else if (/ECONNRESET|ECONNREFUSED|ENOTFOUND|EAI_AGAIN|fetch failed|network|connection (?:reset|closed|failed)|socket hang up/iu.test(text)) { category = "network"; friendly = `Could not connect to ${name}`; }
  else if (UPSTREAM_USAGE_LIMIT.test(text) || httpStatus === 429) {
    category = /usage.?limit|insufficient_quota|quota|out of budget|available balance|subscription_sharing/iu.test(text) ? "usage-limit" : "rate-limit";
    friendly = category === "usage-limit" ? `Usage limit reached for ${name}` : `Rate limited by ${name}`;
  }
  else if (httpStatus && httpStatus >= 500) { category = "unavailable"; friendly = `${name} is temporarily unavailable`; }
  else if (httpStatus === 404 || /^(?:error\s*:?\s*)?not found\s*:?$/iu.test(message.trim())) { category = "not-found"; friendly = `The selected model was not found by ${name}`; }
  return { message: friendly.slice(0, 512), providerMessage: message.slice(0, 2_048), category, ...(type ? { type: type.slice(0, 256) } : {}), ...(requestId ? { requestId: requestId.slice(0, 256) } : {}), ...(httpStatus ? { httpStatus } : {}) };
}
