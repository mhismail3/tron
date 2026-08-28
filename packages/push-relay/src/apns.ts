import type { ApnsEnvironment, Env, NotificationRequest, RelayResult } from "./contracts";
import { base64Url, ownedBuffer, pemBytes, sha256, stableProviderId, utf8 } from "./crypto";

const MAX_APNS_PAYLOAD_BYTES = 4096;
const MAX_APNS_RESPONSE_BYTES = 2048;
const JWT_CACHE_SECONDS = 50 * 60;
export const TRON_NOTIFICATION_SOUND = "tron-notification.caf";

let cachedProviderToken: { fingerprint: string; token: string; expiresAt: number } | undefined;

export async function sendToApns(
  env: Env,
  request: NotificationRequest,
  target: { deviceToken: string; topic: string; environment: ApnsEnvironment },
): Promise<RelayResult> {
  if (!env.APNS_KEY_P8 || !env.APNS_KEY_ID || !env.APNS_TEAM_ID) {
    return { status: "permanent_failure", reason: "provider_not_configured" };
  }
  const payload = buildApnsPayload(request);
  if (utf8(payload).byteLength > MAX_APNS_PAYLOAD_BYTES) {
    return { status: "permanent_failure", reason: "payload_too_large" };
  }
  let token: string;
  try {
    token = await providerToken(env);
  } catch {
    return { status: "retryable", reason: "provider_token_error", retryAfterSeconds: 30 };
  }
  const host = target.environment === "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  const apnsId = await stableProviderId(request.requestId);
  const expiration = Math.max(0, Math.floor(Date.parse(request.expiresAt) / 1000));
  let response: Response;
  try {
    // Keep the platform-default redirect mode. Deployed Workers reject this
    // APNs egress before any provider response when redirect is forced to
    // `error`; the host and path remain closed product-owned projections.
    response = await fetch(`https://${host}/3/device/${target.deviceToken}`, {
      method: "POST",
      signal: AbortSignal.timeout(15_000),
      headers: {
        authorization: `bearer ${token}`,
        "apns-id": apnsId,
        "apns-topic": target.topic,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-expiration": String(expiration),
        "apns-collapse-id": request.requestId.slice(0, 64),
        "content-type": "application/json",
      },
      body: payload,
    });
  } catch {
    return { status: "retryable", reason: "apns_transport_error", retryAfterSeconds: 30 };
  }
  const responseApnsId = response.headers.get("apns-id") ?? apnsId;
  if (response.ok) return { status: "accepted_by_apns", apnsId: responseApnsId };
  const reason = await sanitizedApnsReason(response);
  if (response.status === 403 && (reason === "InvalidProviderToken" || reason === "ExpiredProviderToken")) {
    cachedProviderToken = undefined;
    return { status: "retryable", reason, retryAfterSeconds: 1 };
  }
  if (response.status === 429 || response.status >= 500) {
    const retryAfterSeconds = parseRetryAfter(response.headers.get("retry-after"));
    return { status: "retryable", reason, ...(retryAfterSeconds ? { retryAfterSeconds } : {}) };
  }
  if (reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic" || reason === "Unregistered") {
    return { status: "invalid_token", reason };
  }
  return { status: "permanent_failure", reason };
}

export function buildApnsPayload(request: NotificationRequest): string {
  return JSON.stringify({
    aps: {
      alert: { title: request.title ?? "Tron", body: request.message },
      sound: TRON_NOTIFICATION_SOUND,
      category: "TRON_AGENT_NOTIFICATION",
    },
    tron: { kind: "agent_notification", requestId: request.requestId },
    ...(request.sessionId && request.machineId
      ? { sessionId: request.sessionId, machineId: request.machineId }
      : {}),
  });
}

async function providerToken(env: Env): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const fingerprint = base64Url(await sha256(utf8(JSON.stringify([
    env.APNS_TEAM_ID,
    env.APNS_KEY_ID,
    env.APNS_KEY_P8,
  ]))));
  if (cachedProviderToken?.fingerprint === fingerprint && cachedProviderToken.expiresAt > now) return cachedProviderToken.token;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemBytes(env.APNS_KEY_P8).buffer as ArrayBuffer,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const header = base64Url(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID }));
  const claims = base64Url(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: now }));
  const signingInput = `${header}.${claims}`;
  const signature = new Uint8Array(await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    ownedBuffer(utf8(signingInput)),
  ));
  const token = `${signingInput}.${base64Url(signature)}`;
  cachedProviderToken = { fingerprint, token, expiresAt: now + JWT_CACHE_SECONDS };
  return token;
}

async function sanitizedApnsReason(response: Response): Promise<string> {
  const reader = response.body?.getReader();
  if (!reader) return `http_${response.status}`;
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > MAX_APNS_RESPONSE_BYTES) {
        await reader.cancel();
        return `http_${response.status}`;
      }
      chunks.push(value);
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    const value = JSON.parse(new TextDecoder().decode(bytes)) as { reason?: unknown };
    return typeof value.reason === "string" ? sanitizeReason(value.reason) : `http_${response.status}`;
  } catch {
    return `http_${response.status}`;
  }
}

function parseRetryAfter(value: string | null): number | undefined {
  if (!value) return undefined;
  const seconds = Number(value);
  return Number.isSafeInteger(seconds) && seconds > 0 ? Math.min(seconds, 900) : undefined;
}

function sanitizeReason(value: string): string {
  return [...value].filter((character) => /[A-Za-z0-9_-]/.test(character)).slice(0, 96).join("") || "provider_failure";
}
