/**
 * Tron Push Relay — Cloudflare Worker that forwards push notification
 * requests to Apple's APNs, handling JWT signing with the .p8 key.
 *
 * Tron servers authenticate via HMAC-SHA256 signed requests.
 * The .p8 key never leaves Cloudflare's secret storage.
 */

interface Env {
  APNS_KEY_P8: string;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  APNS_BUNDLE_ID: string;
  TRON_RELAY_SECRET: string;
}

interface PushRequest {
  device_tokens: string[];
  notification: {
    title: string;
    body: string;
    data?: Record<string, string>;
    priority?: string;
    sound?: string | null;
    badge?: number | null;
    thread_id?: string | null;
  };
  environment?: string;
  /**
   * Optional APNs bundle ID (`apns-topic` header). When present and
   * non-empty, overrides `env.APNS_BUNDLE_ID` for this request.
   * Lets servers route sandbox-Beta (`com.tron.mobile.beta`) tokens to
   * the right topic on the shared relay.
   */
  bundle_id?: string | null;
}

interface DeviceResult {
  device_token: string;
  success: boolean;
  apns_id?: string;
  status_code?: number;
  reason?: string;
  error?: string;
}

// ── JWT cache ───────────────────────────────────────────────────────

let cachedJwt: { token: string; expiresAt: number } | null = null;
let cachedSigningKey: CryptoKey | null = null;

const MAX_TIMESTAMP_AGE_SEC = 300; // 5 minutes
const MAX_TOKENS_PER_REQUEST = 50;
const JWT_VALIDITY_SEC = 50 * 60; // 50 minutes (Apple allows up to 60)
const TOKEN_HEX_REGEX = /^[0-9a-f]{64}$/i;

// ── Entry point ─────────────────────────────────────────────────────

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method !== "POST") {
      return json({ error: "method not allowed" }, 405);
    }

    const url = new URL(request.url);
    if (url.pathname !== "/v1/push") {
      return json({ error: "not found" }, 404);
    }

    // Validate required secrets
    if (!env.APNS_KEY_P8 || !env.TRON_RELAY_SECRET) {
      return json({ error: "APNs credentials not configured" }, 500);
    }

    // Read body
    const bodyText = await request.text();

    // Validate HMAC signature
    const timestamp = request.headers.get("X-Tron-Timestamp");
    const signature = request.headers.get("X-Tron-Signature");

    if (!timestamp || !signature) {
      return json({ error: "missing X-Tron-Timestamp or X-Tron-Signature headers" }, 400);
    }

    const tsNum = parseInt(timestamp, 10);
    if (isNaN(tsNum)) {
      return json({ error: "invalid timestamp" }, 400);
    }

    const now = Math.floor(Date.now() / 1000);
    if (Math.abs(now - tsNum) > MAX_TIMESTAMP_AGE_SEC) {
      return json({ error: "request expired" }, 408);
    }

    const valid = await verifyHmac(env.TRON_RELAY_SECRET, timestamp, bodyText, signature);
    if (!valid) {
      return json({ error: "invalid signature" }, 401);
    }

    // Parse request
    let req: PushRequest;
    try {
      req = JSON.parse(bodyText);
    } catch {
      return json({ error: "invalid JSON" }, 400);
    }

    if (!Array.isArray(req.device_tokens) || req.device_tokens.length === 0) {
      return json({ error: "device_tokens must be a non-empty array" }, 400);
    }

    if (req.device_tokens.length > MAX_TOKENS_PER_REQUEST) {
      return json({ error: `max ${MAX_TOKENS_PER_REQUEST} tokens per request` }, 413);
    }

    // Validate tokens
    for (const token of req.device_tokens) {
      if (!TOKEN_HEX_REGEX.test(token)) {
        return json({ error: `invalid device token: ${token.substring(0, 8)}...` }, 400);
      }
    }

    if (!req.notification?.title || !req.notification?.body) {
      return json({ error: "notification.title and notification.body required" }, 400);
    }

    // Get JWT
    let jwt: string;
    try {
      jwt = await getOrRefreshJwt(env);
    } catch (e) {
      return json({ error: "internal signing error" }, 500);
    }

    // Select APNs host
    const environment = req.environment || "production";
    const host =
      environment === "sandbox"
        ? "api.sandbox.push.apple.com"
        : "api.push.apple.com";

    // Pick the APNs topic: per-request bundle_id wins; fall back to env.
    // Treats null / undefined / "" all as "use default" so pre-fix servers
    // and defensive clients keep working.
    const bundleId =
      typeof req.bundle_id === "string" && req.bundle_id.length > 0
        ? req.bundle_id
        : env.APNS_BUNDLE_ID;

    // Build APNs payload
    const payload = buildApnsPayload(req.notification);
    const priority = req.notification.priority === "high" ? "10" : "5";

    // Send to all tokens in parallel
    const results = await Promise.all(
      req.device_tokens.map((token) =>
        sendToApns(host, token, jwt, bundleId, payload, priority)
      )
    );

    return json({ results });
  },
};

// ── HMAC verification ───────────────────────────────────────────────

async function verifyHmac(
  secret: string,
  timestamp: string,
  body: string,
  providedSignature: string
): Promise<boolean> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const message = `${timestamp}.${body}`;
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(message));
  const expected = hexEncode(new Uint8Array(sig));

  // Constant-time comparison
  if (expected.length !== providedSignature.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) {
    diff |= expected.charCodeAt(i) ^ providedSignature.charCodeAt(i);
  }
  return diff === 0;
}

// ── JWT signing ─────────────────────────────────────────────────────

async function getOrRefreshJwt(env: Env): Promise<string> {
  const now = Math.floor(Date.now() / 1000);

  if (cachedJwt && now < cachedJwt.expiresAt) {
    return cachedJwt.token;
  }

  const key = await getSigningKey(env.APNS_KEY_P8);

  const header = { alg: "ES256", kid: env.APNS_KEY_ID };
  const claims = { iss: env.APNS_TEAM_ID, iat: now };

  const headerB64 = base64url(JSON.stringify(header));
  const claimsB64 = base64url(JSON.stringify(claims));
  const signingInput = `${headerB64}.${claimsB64}`;

  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput)
  );

  // Web Crypto returns raw r||s format (IEEE P1363, 64 bytes for P-256).
  // JWT ES256 expects the same raw format — no conversion needed.
  const sigB64 = base64url(new Uint8Array(sig));

  const jwt = `${signingInput}.${sigB64}`;
  cachedJwt = { token: jwt, expiresAt: now + JWT_VALIDITY_SEC };

  return jwt;
}

async function getSigningKey(pem: string): Promise<CryptoKey> {
  if (cachedSigningKey) return cachedSigningKey;

  // Strip PEM headers and decode
  const pemBody = pem
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\s/g, "");

  const der = Uint8Array.from(atob(pemBody), (c) => c.charCodeAt(0));

  cachedSigningKey = await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );

  return cachedSigningKey;
}

// ── APNs delivery ───────────────────────────────────────────────────

function buildApnsPayload(notification: PushRequest["notification"]): string {
  const aps: Record<string, unknown> = {
    alert: { title: notification.title, body: notification.body },
    "mutable-content": 1,
  };

  if (notification.sound) aps.sound = notification.sound;
  if (notification.badge != null) aps.badge = notification.badge;
  if (notification.thread_id) aps["thread-id"] = notification.thread_id;

  const payload: Record<string, unknown> = { aps };

  if (notification.data) {
    for (const [k, v] of Object.entries(notification.data)) {
      payload[k] = v;
    }
  }

  return JSON.stringify(payload);
}

async function sendToApns(
  host: string,
  deviceToken: string,
  jwt: string,
  bundleId: string,
  payload: string,
  priority: string
): Promise<DeviceResult> {
  const url = `https://${host}/3/device/${deviceToken}`;

  try {
    const response = await fetch(url, {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`,
        "apns-topic": bundleId,
        "apns-push-type": "alert",
        "apns-priority": priority,
        "apns-expiration": "0",
        "content-type": "application/json",
      },
      body: payload,
    });

    const apnsId = response.headers.get("apns-id") ?? undefined;
    const status = response.status;

    if (response.ok) {
      return {
        device_token: deviceToken,
        success: true,
        apns_id: apnsId,
        status_code: status,
      };
    }

    let reason: string | undefined;
    try {
      const body = await response.json<{ reason?: string }>();
      reason = body.reason;
    } catch {
      // ignore parse errors
    }

    return {
      device_token: deviceToken,
      success: false,
      apns_id: apnsId,
      status_code: status,
      reason,
      error: reason ?? `HTTP ${status}`,
    };
  } catch (e) {
    return {
      device_token: deviceToken,
      success: false,
      error: `APNs connection failed: ${e instanceof Error ? e.message : String(e)}`,
    };
  }
}

// ── Utilities ───────────────────────────────────────────────────────

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function hexEncode(bytes: Uint8Array): string {
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function base64url(input: string | Uint8Array): string {
  const str =
    typeof input === "string"
      ? btoa(input)
      : btoa(String.fromCharCode(...input));
  return str.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

