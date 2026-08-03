import type {
  Env,
  NotificationRequest,
  RelayResult,
} from "./contracts";
import {
  base64Url,
  pemBytes,
  stableProviderId,
} from "./crypto";

const MAX_APNS_PAYLOAD_BYTES = 4096;
const JWT_CACHE_SECONDS = 50 * 60;

let cachedProviderToken:
  | { fingerprint: string; token: string; expiresAt: number }
  | undefined;

export async function sendToApns(
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

export function buildApnsPayload(request: NotificationRequest): string {
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

function sanitizeReason(value: string): string {
  return (
    [...value]
      .filter((character) => /[A-Za-z0-9_-]/.test(character))
      .slice(0, 96)
      .join("") || "provider_failure"
  );
}
