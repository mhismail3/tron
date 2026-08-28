import { createHash, createHmac } from "node:crypto";
import { isIP } from "node:net";
import { GatewayError } from "../errors.js";

export type RelayNotificationOutcome = "accepted_by_apns" | "retryable" | "invalid_token" | "invalid_grant" | "permanent_failure" | "ambiguous" | "rate_limited" | "in_progress";
export interface RelayFetchResponse { status: number; headers: Headers; body: ReadableStream<Uint8Array> | null; }
export type RelayFetch = (input: string, init: RequestInit) => Promise<RelayFetchResponse>;

const RESPONSE_MAX_BYTES = 16 * 1_024;
const REQUEST_MAX_BYTES = 2 * 1_024;
// APNs owns a bounded 15-second provider request; the caller must not abort first.
const TIMEOUT_MS = 20_000;
const PUBLIC_HOST_LABEL = /^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/u;

export function fixedPushOrigin(raw: string | undefined): URL | undefined {
  if (raw === undefined || raw.trim() === "") return undefined;
  let value: URL;
  try { value = new URL(raw); } catch { throw new GatewayError("invalid_request", "Tron Push service origin is invalid"); }
  const hostname = value.hostname.toLowerCase();
  if (value.protocol !== "https:" || value.username || value.password || value.pathname !== "/" || value.search || value.hash
    || value.port || isIP(hostname) !== 0 || hostname === "localhost" || hostname.endsWith(".localhost")
    || hostname.endsWith(".local") || hostname.endsWith(".internal") || !PUBLIC_HOST_LABEL.test(hostname)) {
    throw new GatewayError("invalid_request", "Tron Push service origin must be an exact public HTTPS origin");
  }
  return value;
}

async function boundedBody(response: RelayFetchResponse): Promise<string> {
  if (!response.body) return "";
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let length = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      length += value.byteLength;
      if (length > RESPONSE_MAX_BYTES) throw new GatewayError("busy", "Tron Push returned an oversized response", true);
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  return Buffer.concat(chunks.map((chunk) => Buffer.from(chunk)), length).toString("utf8");
}

export function relaySignature(secret: string, method: "POST" | "DELETE", path: string, timestamp: string, requestId: string, body: string): string {
  const digest = createHash("sha256").update(body).digest("hex");
  return createHmac("sha256", secret)
    .update(`${method}\n${path}\n${timestamp}\n${requestId}\n${digest}`)
    .digest("hex");
}

function exactResult(value: unknown): { status: Exclude<RelayNotificationOutcome, "invalid_grant">; reason?: string } | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const object = value as Record<string, unknown>;
  const allowed = new Set(["status", "apnsId", "reason", "retryAfterSeconds"]);
  if (Object.keys(object).some((key) => !allowed.has(key)) || typeof object.status !== "string") return undefined;
  if (object.apnsId !== undefined && typeof object.apnsId !== "string") return undefined;
  if (object.reason !== undefined && typeof object.reason !== "string") return undefined;
  if (object.retryAfterSeconds !== undefined && (!Number.isSafeInteger(object.retryAfterSeconds) || (object.retryAfterSeconds as number) < 1)) return undefined;
  return ["accepted_by_apns", "retryable", "invalid_token", "permanent_failure", "ambiguous", "rate_limited", "in_progress"].includes(object.status)
    ? {
      status: object.status as Exclude<RelayNotificationOutcome, "invalid_grant">,
      ...(typeof object.reason === "string" ? { reason: object.reason } : {}),
    }
    : undefined;
}

export class PushRelayClient {
  private readonly origin: URL | undefined;
  constructor(
    origin: string | undefined,
    private readonly fetcher: RelayFetch = fetch as unknown as RelayFetch,
    private readonly now: () => number = Date.now,
  ) { this.origin = fixedPushOrigin(origin); }

  get available(): boolean { return this.origin !== undefined; }
  get relayOrigin(): string | undefined { return this.origin?.origin; }

  async send(input: {
    grantId: string;
    secret: string;
    requestId: string;
    message: string;
    title?: string;
    sessionId?: string;
    machineId?: string;
    expiresAt: string;
  }): Promise<RelayNotificationOutcome> {
    if (!this.origin) return "retryable";
    const path = "/v3/notifications";
    const body = JSON.stringify({
      version: 1,
      kind: "agent_alert",
      requestId: input.requestId,
      message: input.message,
      ...(input.title ? { title: input.title } : {}),
      ...(input.sessionId ? { sessionId: input.sessionId } : {}),
      ...(input.machineId ? { machineId: input.machineId } : {}),
      expiresAt: input.expiresAt,
    });
    if (Buffer.byteLength(body) > REQUEST_MAX_BYTES) throw new GatewayError("invalid_request", "Notification request exceeds its bounded payload");
    const response = await this.request("POST", path, input.grantId, input.secret, input.requestId, body);
    const text = await boundedBody(response);
    let parsed: unknown;
    try { parsed = text ? JSON.parse(text) : undefined; } catch { return response.status >= 500 ? "retryable" : "ambiguous"; }
    const result = exactResult(parsed);
    if (response.status === 200 && result) {
      // Compatibility with relays predating the explicit in_progress status.
      // Re-querying this exact ID is still safe: their ledger never starts a
      // second APNs request, and the Gateway retry schedule remains bounded.
      if (result.status === "ambiguous" && result.reason === "provider_outcome_unknown") return "in_progress";
      return result.status;
    }
    // The relay intentionally exposes one bounded error key. An unknown,
    // disabled, or mismatched grant is recoverable only by rotating the mobile
    // capability; retrying this credential can never reach APNs.
    const relayError = parsed && typeof parsed === "object" && !Array.isArray(parsed)
      && Object.keys(parsed).length === 1 && typeof (parsed as Record<string, unknown>).error === "string"
      ? (parsed as Record<string, string>).error
      : undefined;
    if ((response.status === 401 && relayError === "invalid_signature")
      || (response.status === 410 && relayError === "installation_unavailable")) return "invalid_grant";
    return response.status === 429 || response.status >= 500 ? "retryable" : "ambiguous";
  }

  async revoke(grantId: string, secret: string, requestId: string): Promise<"revoked" | "retryable"> {
    if (!this.origin) return "retryable";
    const path = `/v3/grants/${encodeURIComponent(grantId)}`;
    const response = await this.request("DELETE", path, grantId, secret, requestId, "");
    const text = await boundedBody(response);
    if (response.status === 404) return "revoked";
    if (response.status === 200) {
      try {
        const value = JSON.parse(text) as Record<string, unknown>;
        if (Object.keys(value).length === 2 && value.version === 1 && value.revoked === true) return "revoked";
      } catch { /* retry below */ }
    }
    return "retryable";
  }

  private async request(method: "POST" | "DELETE", path: string, grantId: string, secret: string, requestId: string, body: string): Promise<RelayFetchResponse> {
    const timestamp = Math.floor(this.now() / 1_000).toString(10);
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), TIMEOUT_MS);
    timeout.unref();
    try {
      return await this.fetcher(new URL(path, this.origin).toString(), {
        method,
        redirect: "error",
        signal: controller.signal,
        headers: {
          "content-type": "application/json",
          "x-tron-grant-id": grantId,
          "x-tron-request-id": requestId,
          "x-tron-timestamp": timestamp,
          "x-tron-signature": relaySignature(secret, method, path, timestamp, requestId, body),
        },
        ...(body ? { body } : {}),
      });
    } catch (error) {
      if ((error as Error).name === "AbortError") throw new GatewayError("busy", "Tron Push request timed out", true);
      throw new GatewayError("busy", "Tron Push request failed", true);
    } finally { clearTimeout(timeout); }
  }
}
