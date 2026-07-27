/**
 * Closed APNs provider relay.
 *
 * The engine supplies one already-authorized device target and one of two
 * fixed request forms. The relay verifies the engine signature, validates the
 * Beta/production route, coalesces retries by provider request ID, constructs
 * the only APNs payloads it permits, and returns sanitized provider evidence.
 */

interface Env {
  APNS_KEY_P8: string;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  TRON_RELAY_SECRET: string;
  RELAY_LEDGER: DurableObjectNamespace;
}

type Environment = "sandbox" | "production";
type NotificationKind = "alert" | "background";

interface AlertRequest {
  kind: "alert";
  requestId: string;
  deviceToken: string;
  topic: string;
  environment: Environment;
  expiresAt: string;
  collapseId: string;
  title: string;
  body: string;
  threadKey?: string;
  category: "TRON_NOTIFICATION" | "TRON_REMINDER";
  badge: number;
  serverId: string;
  deliveryId: string;
}

interface BackgroundRequest {
  kind: "background";
  requestId: string;
  deviceToken: string;
  topic: string;
  environment: Environment;
  expiresAt: string;
  collapseId: string;
  badge: number;
  serverId: string;
}

type NotificationRequest = AlertRequest | BackgroundRequest;

type RelayStatus =
  | "accepted_by_apns"
  | "retryable"
  | "permanent_failure"
  | "invalid_token"
  | "ambiguous";

interface RelayResult {
  status: RelayStatus;
  apnsId?: string;
  reason?: string;
  retryAfterSeconds?: number;
}

interface LedgerRow extends Record<string, SqlStorageValue> {
  state: string;
  response_json: string | null;
}

const PATH = "/v2/notification";
const CLOCK_SKEW_SECONDS = 300;
const MAX_BODY_BYTES = 16 * 1024;
const MAX_APNS_PAYLOAD_BYTES = 4096;
const JWT_CACHE_SECONDS = 50 * 60;
const DEVICE_TOKEN = /^[0-9a-f]{32,200}$/i;
const OPAQUE_ID = /^[A-Za-z0-9._:-]{1,128}$/;
const TOPIC_ENVIRONMENTS: Readonly<Record<string, readonly Environment[]>> = {
  "com.tron.mobile.beta": ["sandbox"],
  "com.tron.mobile": ["sandbox", "production"],
};

let cachedProviderToken:
  | { fingerprint: string; token: string; expiresAt: number }
  | undefined;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (request.method !== "POST") {
      return json({ error: "method_not_allowed" }, 405);
    }
    if (url.pathname !== PATH) {
      return json({ error: "not_found" }, 404);
    }
    if (!env.TRON_RELAY_SECRET) {
      return json({ error: "relay_not_configured" }, 503);
    }

    const body = new Uint8Array(await request.arrayBuffer());
    if (body.byteLength === 0 || body.byteLength > MAX_BODY_BYTES) {
      return json({ error: "invalid_body_size" }, 413);
    }
    const timestamp = request.headers.get("x-tron-timestamp");
    const requestId = request.headers.get("x-tron-request-id");
    const signature = request.headers.get("x-tron-signature");
    if (!timestamp || !requestId || !signature || !OPAQUE_ID.test(requestId)) {
      return json({ error: "invalid_authentication_headers" }, 401);
    }
    if (
      !(await verifyRelaySignature(
        env.TRON_RELAY_SECRET,
        timestamp,
        requestId,
        body,
        signature,
      ))
    ) {
      return json({ error: "invalid_signature" }, 401);
    }

    let value: unknown;
    try {
      value = JSON.parse(new TextDecoder().decode(body));
    } catch {
      return json({ error: "invalid_json" }, 400);
    }
    const parsed = validateNotificationRequest(value);
    if (!parsed.ok) {
      return json({ error: parsed.error }, 400);
    }
    if (parsed.value.requestId !== requestId) {
      return json({ error: "request_id_mismatch" }, 400);
    }

    const ledgerId = env.RELAY_LEDGER.idFromName("notification-relay-ledger-v1");
    const response = await env.RELAY_LEDGER.get(ledgerId).fetch(
      new Request("https://relay.internal/dispatch", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(parsed.value),
      }),
    );
    return new Response(response.body, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  },
};

export class RelayLedger {
  constructor(
    private readonly state: DurableObjectState,
    private readonly env: Env,
  ) {
    this.state.blockConcurrencyWhile(async () => {
      this.state.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS relay_requests (
          request_id TEXT PRIMARY KEY,
          state TEXT NOT NULL,
          response_json TEXT,
          updated_at INTEGER NOT NULL
        )
      `);
    });
  }

  async fetch(request: Request): Promise<Response> {
    if (request.method !== "POST") {
      return json({ error: "method_not_allowed" }, 405);
    }
    let delivery: NotificationRequest;
    try {
      const parsed = validateNotificationRequest(await request.json());
      if (!parsed.ok) {
        return json({ error: parsed.error }, 400);
      }
      delivery = parsed.value;
    } catch {
      return json({ error: "invalid_json" }, 400);
    }

    const replay = await this.beginAttempt(delivery.requestId);
    if (replay) {
      return json(replay);
    }

    let result: RelayResult;
    try {
      result = await sendToApns(this.env, delivery);
    } catch {
      result = {
        status: "retryable",
        reason: "relay_transport_error",
        retryAfterSeconds: 30,
      };
    }
    await this.finishAttempt(delivery.requestId, result);
    return json(result);
  }

  private async beginAttempt(requestId: string): Promise<RelayResult | undefined> {
    return this.state.storage.transaction(async () => {
      const existing = this.state.storage.sql
        .exec<LedgerRow>(
          "SELECT state, response_json FROM relay_requests WHERE request_id = ?",
          requestId,
        )
        .toArray()[0];
      const replay = replayResult(existing);
      if (replay) {
        return replay;
      }
      const now = Math.floor(Date.now() / 1000);
      this.state.storage.sql.exec(
        `INSERT INTO relay_requests (request_id, state, response_json, updated_at)
         VALUES (?, 'in_progress', NULL, ?)
         ON CONFLICT(request_id) DO UPDATE SET
           state = 'in_progress',
           response_json = NULL,
           updated_at = excluded.updated_at`,
        requestId,
        now,
      );
      return undefined;
    });
  }

  private async finishAttempt(requestId: string, result: RelayResult): Promise<void> {
    const terminal = isTerminal(result.status);
    await this.state.storage.transaction(async () => {
      this.state.storage.sql.exec(
        `UPDATE relay_requests
         SET state = ?, response_json = ?, updated_at = ?
         WHERE request_id = ?`,
        terminal ? "terminal" : "retryable",
        JSON.stringify(result),
        Math.floor(Date.now() / 1000),
        requestId,
      );
    });
  }
}

export function validateNotificationRequest(
  value: unknown,
):
  | { ok: true; value: NotificationRequest }
  | { ok: false; error: string } {
  if (!isRecord(value) || (value.kind !== "alert" && value.kind !== "background")) {
    return { ok: false, error: "invalid_kind" };
  }
  const common = [
    "kind",
    "requestId",
    "deviceToken",
    "topic",
    "environment",
    "expiresAt",
    "collapseId",
    "badge",
    "serverId",
  ];
  const allowed =
    value.kind === "alert"
      ? [...common, "title", "body", "threadKey", "category", "deliveryId"]
      : common;
  if (Object.keys(value).some((key) => !allowed.includes(key))) {
    return { ok: false, error: "unknown_field" };
  }
  if (
    !isOpaqueId(value.requestId) ||
    typeof value.deviceToken !== "string" ||
    !DEVICE_TOKEN.test(value.deviceToken) ||
    typeof value.topic !== "string" ||
    (value.environment !== "sandbox" && value.environment !== "production") ||
    !TOPIC_ENVIRONMENTS[value.topic]?.includes(value.environment) ||
    !validFutureDate(value.expiresAt) ||
    !isBoundedString(value.collapseId, 1, 64) ||
    !Number.isSafeInteger(value.badge) ||
    (value.badge as number) < 0 ||
    (value.badge as number) > 9999 ||
    !isOpaqueId(value.serverId)
  ) {
    return { ok: false, error: "invalid_request" };
  }
  if (value.kind === "background") {
    return { ok: true, value: value as unknown as BackgroundRequest };
  }
  if (
    !isBoundedString(value.title, 1, 120) ||
    !isBoundedString(value.body, 1, 512) ||
    (value.threadKey !== undefined &&
      !isBoundedString(value.threadKey, 1, 64)) ||
    (value.category !== "TRON_NOTIFICATION" &&
      value.category !== "TRON_REMINDER") ||
    !isOpaqueId(value.deliveryId)
  ) {
    return { ok: false, error: "invalid_alert" };
  }
  return { ok: true, value: value as unknown as AlertRequest };
}

export async function verifyRelaySignature(
  secret: string,
  timestamp: string,
  requestId: string,
  body: Uint8Array,
  provided: string,
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<boolean> {
  if (!/^\d{10,}$/.test(timestamp) || !/^[0-9a-f]{64}$/i.test(provided)) {
    return false;
  }
  const timestampNumber = Number(timestamp);
  if (
    !Number.isSafeInteger(timestampNumber) ||
    Math.abs(nowSeconds - timestampNumber) > CLOCK_SKEW_SECONDS
  ) {
    return false;
  }
  const bodyHash = await sha256Hex(body);
  const canonical = `POST\n${PATH}\n${timestamp}\n${requestId}\n${bodyHash}`;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const expected = new Uint8Array(
    await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(canonical)),
  );
  return constantTimeEqual(expected, hexBytes(provided));
}

export function replayResult(row: LedgerRow | undefined): RelayResult | undefined {
  if (!row) {
    return undefined;
  }
  if (row.state === "in_progress") {
    return { status: "ambiguous", reason: "provider_outcome_unknown" };
  }
  if (row.state === "terminal" && row.response_json) {
    try {
      return JSON.parse(row.response_json) as RelayResult;
    } catch {
      return { status: "ambiguous", reason: "ledger_result_invalid" };
    }
  }
  return undefined;
}

async function sendToApns(
  env: Env,
  request: NotificationRequest,
): Promise<RelayResult> {
  if (!env.APNS_KEY_P8 || !env.APNS_KEY_ID || !env.APNS_TEAM_ID) {
    return { status: "permanent_failure", reason: "provider_not_configured" };
  }
  const payload = buildApnsPayload(request);
  if (new TextEncoder().encode(payload).byteLength >= MAX_APNS_PAYLOAD_BYTES) {
    return { status: "permanent_failure", reason: "payload_too_large" };
  }
  const providerToken = await getProviderToken(env);
  const host =
    request.environment === "sandbox"
      ? "api.sandbox.push.apple.com"
      : "api.push.apple.com";
  const expiration = Math.max(
    0,
    Math.floor(Date.parse(request.expiresAt) / 1000),
  );
  const apnsId = await stableProviderId(request.requestId);
  const response = await fetch(
    `https://${host}/3/device/${request.deviceToken}`,
    {
      method: "POST",
      headers: {
        authorization: `bearer ${providerToken}`,
        "apns-id": apnsId,
        "apns-topic": request.topic,
        "apns-push-type": request.kind,
        "apns-priority": request.kind === "alert" ? "10" : "5",
        "apns-expiration": String(expiration),
        "apns-collapse-id": request.collapseId,
        "content-type": "application/json",
      },
      body: payload,
    },
  );
  const responseApnsId = response.headers.get("apns-id") ?? apnsId;
  if (response.ok) {
    return { status: "accepted_by_apns", apnsId: responseApnsId };
  }
  const reason = await sanitizedApnsReason(response);
  if (response.status === 429 || response.status >= 500) {
    const retryAfter = parseRetryAfter(response.headers.get("retry-after"));
    return {
      status: "retryable",
      reason,
      ...(retryAfter ? { retryAfterSeconds: retryAfter } : {}),
    };
  }
  if (
    reason === "BadDeviceToken" ||
    reason === "DeviceTokenNotForTopic" ||
    reason === "Unregistered"
  ) {
    return { status: "invalid_token", reason };
  }
  return { status: "permanent_failure", reason };
}

function buildApnsPayload(request: NotificationRequest): string {
  if (request.kind === "background") {
    return JSON.stringify({
      aps: { "content-available": 1, badge: request.badge },
      tron: {
        kind: "notification_state_refresh",
        serverId: request.serverId,
      },
    });
  }
  const aps: Record<string, unknown> = {
    alert: { title: request.title, body: request.body },
    sound: "default",
    category: request.category,
    badge: request.badge,
  };
  if (request.threadKey) {
    aps["thread-id"] = request.threadKey;
  }
  return JSON.stringify({
    aps,
    tron: {
      kind: "notification",
      serverId: request.serverId,
      deliveryId: request.deliveryId,
    },
  });
}

async function getProviderToken(env: Env): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const fingerprint = `${env.APNS_TEAM_ID}:${env.APNS_KEY_ID}:${env.APNS_KEY_P8.length}`;
  if (
    cachedProviderToken &&
    cachedProviderToken.fingerprint === fingerprint &&
    cachedProviderToken.expiresAt > now
  ) {
    return cachedProviderToken.token;
  }
  const signingKey = await crypto.subtle.importKey(
    "pkcs8",
    pemBytes(env.APNS_KEY_P8).buffer,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const header = base64Url(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID }));
  const claims = base64Url(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: now }));
  const signingInput = `${header}.${claims}`;
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      signingKey,
      new TextEncoder().encode(signingInput),
    ),
  );
  const token = `${signingInput}.${base64Url(signature)}`;
  cachedProviderToken = {
    fingerprint,
    token,
    expiresAt: now + JWT_CACHE_SECONDS,
  };
  return token;
}

async function sanitizedApnsReason(response: Response): Promise<string> {
  try {
    const value = (await response.json()) as { reason?: unknown };
    return typeof value.reason === "string"
      ? sanitizeReason(value.reason)
      : `http_${response.status}`;
  } catch {
    return `http_${response.status}`;
  }
}

function parseRetryAfter(value: string | null): number | undefined {
  if (!value) return undefined;
  const seconds = Number(value);
  return Number.isSafeInteger(seconds) && seconds > 0
    ? Math.min(seconds, 900)
    : undefined;
}

function isTerminal(status: RelayStatus): boolean {
  return (
    status === "accepted_by_apns" ||
    status === "permanent_failure" ||
    status === "invalid_token"
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isBoundedString(
  value: unknown,
  minimum: number,
  maximum: number,
): value is string {
  return (
    typeof value === "string" &&
    value.length >= minimum &&
    value.length <= maximum
  );
}

function isOpaqueId(value: unknown): value is string {
  return typeof value === "string" && OPAQUE_ID.test(value);
}

function validFutureDate(value: unknown): boolean {
  if (typeof value !== "string") return false;
  const timestamp = Date.parse(value);
  return Number.isFinite(timestamp) && timestamp > Date.now() - 60_000;
}

function sanitizeReason(value: string): string {
  return (
    [...value]
      .filter((character) => /[A-Za-z0-9_-]/.test(character))
      .slice(0, 96)
      .join("") || "provider_failure"
  );
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  return hexEncode(
    new Uint8Array(
      await crypto.subtle.digest("SHA-256", new Uint8Array(bytes).buffer),
    ),
  );
}

async function stableProviderId(requestId: string): Promise<string> {
  const digest = await sha256Hex(new TextEncoder().encode(requestId));
  return `${digest.slice(0, 8)}-${digest.slice(8, 12)}-${digest.slice(
    12,
    16,
  )}-${digest.slice(16, 20)}-${digest.slice(20, 32)}`;
}

function pemBytes(value: string): Uint8Array<ArrayBuffer> {
  const body = value
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s/g, "");
  const binary = atob(body);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes;
}

function base64Url(value: string | Uint8Array): string {
  const bytes =
    typeof value === "string" ? new TextEncoder().encode(value) : value;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

function hexEncode(bytes: Uint8Array): string {
  return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function hexBytes(value: string): Uint8Array {
  if (value.length % 2 !== 0) return new Uint8Array();
  return Uint8Array.from(
    value.match(/.{2}/g) ?? [],
    (pair) => Number.parseInt(pair, 16),
  );
}

function constantTimeEqual(left: Uint8Array, right: Uint8Array): boolean {
  if (left.byteLength !== right.byteLength) return false;
  let difference = 0;
  for (let index = 0; index < left.byteLength; index += 1) {
    difference |= left[index] ^ right[index];
  }
  return difference === 0;
}

function json(value: unknown, status = 200): Response {
  return Response.json(value, {
    status,
    headers: { "cache-control": "no-store" },
  });
}
