import { createHash, createHmac } from "node:crypto";
import { GatewayError } from "../errors.js";
import type { NotificationKind, PushEnvironment } from "./grant-store.js";

export type RelayNotificationOutcome = "accepted_by_apns" | "retryable" | "invalid_token" | "permanent_failure" | "ambiguous";
export interface RelayFetchResponse { status: number; headers: Headers; body: ReadableStream<Uint8Array> | null; }
export type RelayFetch = (input: string, init: RequestInit) => Promise<RelayFetchResponse>;

const RESPONSE_MAX_BYTES = 16 * 1_024;
const REQUEST_MAX_BYTES = 2 * 1_024;
const TIMEOUT_MS = 6_000;

function fixedOrigin(raw: string | undefined): URL | undefined {
  if (raw === undefined || raw.trim() === "") return undefined;
  let value: URL;
  try { value = new URL(raw); } catch { throw new GatewayError("invalid_request", "Tron Push service origin is invalid"); }
  if (value.protocol !== "https:" || value.username || value.password || value.pathname !== "/" || value.search || value.hash) {
    throw new GatewayError("invalid_request", "Tron Push service origin must be an exact HTTPS origin");
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

function canonicalSignature(secret: string, method: "POST" | "DELETE", path: string, timestamp: string, requestId: string, body: string): string {
  const digest = createHash("sha256").update(body).digest("base64url");
  return createHmac("sha256", Buffer.from(secret, "base64url"))
    .update(`${method}\n${path}\n${timestamp}\n${requestId}\n${digest}`)
    .digest("base64url");
}

function exactResult(value: unknown): RelayNotificationOutcome | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const object = value as Record<string, unknown>;
  if (Object.keys(object).length !== 1 || typeof object.outcome !== "string") return undefined;
  return ["accepted_by_apns", "retryable", "invalid_token", "permanent_failure", "ambiguous"].includes(object.outcome)
    ? object.outcome as RelayNotificationOutcome : undefined;
}

export class PushRelayClient {
  private readonly origin: URL | undefined;
  constructor(
    origin: string | undefined,
    private readonly fetcher: RelayFetch = fetch as unknown as RelayFetch,
    private readonly now: () => number = Date.now,
  ) { this.origin = fixedOrigin(origin); }

  get available(): boolean { return this.origin !== undefined; }

  async send(input: {
    grantId: string;
    secret: string;
    requestId: string;
    kind: NotificationKind;
    message: string;
    environment: PushEnvironment;
    expiresAt: string;
  }): Promise<RelayNotificationOutcome> {
    if (!this.origin) return "retryable";
    const path = "/v3/notifications";
    const body = JSON.stringify({ version: 1, kind: input.kind, message: input.message, environment: input.environment, expiresAt: input.expiresAt });
    if (Buffer.byteLength(body) > REQUEST_MAX_BYTES) throw new GatewayError("invalid_request", "Notification request exceeds its bounded payload");
    const response = await this.request("POST", path, input.grantId, input.secret, input.requestId, body);
    const text = await boundedBody(response);
    let parsed: unknown;
    try { parsed = text ? JSON.parse(text) : undefined; } catch { return response.status >= 500 ? "retryable" : "ambiguous"; }
    const outcome = exactResult(parsed);
    if (response.status === 200 && outcome) return outcome;
    return response.status === 429 || response.status >= 500 ? "retryable" : "ambiguous";
  }

  async revoke(grantId: string, secret: string, requestId: string): Promise<"revoked" | "retryable"> {
    if (!this.origin) return "retryable";
    const path = `/v3/grants/${encodeURIComponent(grantId)}`;
    const response = await this.request("DELETE", path, grantId, secret, requestId, "");
    await boundedBody(response);
    if (response.status === 204 || response.status === 404) return "revoked";
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
          "x-tron-signature": canonicalSignature(secret, method, path, timestamp, requestId, body),
        },
        ...(body ? { body } : {}),
      });
    } catch (error) {
      if ((error as Error).name === "AbortError") throw new GatewayError("busy", "Tron Push request timed out", true);
      throw new GatewayError("busy", "Tron Push request failed", true);
    } finally { clearTimeout(timeout); }
  }
}
