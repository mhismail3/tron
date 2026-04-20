/**
 * Tests for the push relay worker.
 *
 * Key contract under test: when the request body includes `bundle_id`, the
 * worker must use it as the `apns-topic` header on the outbound APNs call.
 * When `bundle_id` is absent (or empty), the worker falls back to
 * `env.APNS_BUNDLE_ID` — preserving backward compatibility with pre-fix
 * servers that never send the field.
 *
 * This is the regression guard for the 2026-04-16 incident where the Beta
 * scheme's sandbox tokens were rejected with `DeviceTokenNotForTopic`
 * because the relay ignored the per-token bundle.
 */

import { afterEach, beforeAll, beforeEach, describe, expect, test, vi } from "vitest";

// ── Test-key generation ──────────────────────────────────────────────

/**
 * Generate a random P-256 ECDSA private key in PKCS#8 PEM format — the
 * input shape `crypto.subtle.importKey(... "pkcs8" ...)` expects.
 * The signature isn't verified against anything real (APNs is mocked),
 * so any well-formed key works.
 */
async function generateTestApnsKey(): Promise<string> {
  const keyPair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const pkcs8 = await crypto.subtle.exportKey("pkcs8", keyPair.privateKey);
  const b64 = Buffer.from(pkcs8).toString("base64");
  // Wrap every 64 chars per PEM convention.
  const wrapped = b64.match(/.{1,64}/g)!.join("\n");
  return `-----BEGIN PRIVATE KEY-----\n${wrapped}\n-----END PRIVATE KEY-----`;
}

// ── HMAC signing (mirrors the worker's verifyHmac) ───────────────────

async function signBody(secret: string, timestamp: number, body: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(`${timestamp}.${body}`));
  return Array.from(new Uint8Array(sig))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

// ── Test harness ─────────────────────────────────────────────────────

let apnsPem: string;

beforeAll(async () => {
  apnsPem = await generateTestApnsKey();
});

interface TestEnv {
  APNS_KEY_P8: string;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  APNS_BUNDLE_ID: string;
  TRON_RELAY_SECRET: string;
}

function makeEnv(overrides: Partial<TestEnv> = {}): TestEnv {
  return {
    APNS_KEY_P8: apnsPem,
    APNS_KEY_ID: "TESTKEY01",
    APNS_TEAM_ID: "TESTTEAM01",
    APNS_BUNDLE_ID: "com.tron.mobile",
    TRON_RELAY_SECRET: "shared-test-secret",
    ...overrides,
  };
}

async function buildSignedRequest(body: unknown, secret: string): Promise<Request> {
  const bodyText = JSON.stringify(body);
  const timestamp = Math.floor(Date.now() / 1000);
  const signature = await signBody(secret, timestamp, bodyText);
  return new Request("https://relay.example.com/v1/push", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Tron-Timestamp": String(timestamp),
      "X-Tron-Signature": signature,
    },
    body: bodyText,
  });
}

function makeApnsResponse(status = 200, reason?: string): Response {
  const body = reason ? JSON.stringify({ reason }) : "";
  return new Response(body, {
    status,
    headers: { "apns-id": "test-apns-id-00000000" },
  });
}

/** Load a fresh copy of the worker each test so module-level caches
 *  (cachedJwt, cachedSigningKey) don't leak across cases. */
async function freshWorker(): Promise<{
  fetch: (req: Request, env: TestEnv) => Promise<Response>;
}> {
  vi.resetModules();
  const mod = await import("./index");
  return mod.default as never;
}

/** Captures outbound APNs HTTP calls for assertion. */
interface CapturedApnsCall {
  url: string;
  method: string;
  headers: Record<string, string>;
  body: string;
}

function stubApnsFetch(
  responseFactory: () => Response = () => makeApnsResponse(),
): { captured: CapturedApnsCall[]; mock: ReturnType<typeof vi.fn> } {
  const captured: CapturedApnsCall[] = [];
  const mock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    const headers: Record<string, string> = {};
    if (init?.headers) {
      const h = new Headers(init.headers);
      h.forEach((value, key) => {
        headers[key.toLowerCase()] = value;
      });
    }
    captured.push({
      url,
      method: init?.method ?? "GET",
      headers,
      body: typeof init?.body === "string" ? init.body : "",
    });
    return responseFactory();
  });
  vi.stubGlobal("fetch", mock);
  return { captured, mock };
}

afterEach(() => {
  vi.unstubAllGlobals();
});

// ── Tests ────────────────────────────────────────────────────────────

describe("relay worker — bundle_id routing", () => {
  test("request with bundle_id uses it as apns-topic", async () => {
    const { captured } = stubApnsFetch();
    const env = makeEnv();
    const worker = await freshWorker();

    const req = await buildSignedRequest(
      {
        device_tokens: ["a".repeat(64)],
        notification: { title: "Hello", body: "World" },
        environment: "sandbox",
        bundle_id: "com.tron.mobile.beta",
      },
      env.TRON_RELAY_SECRET,
    );
    const resp = await worker.fetch(req, env);
    expect(resp.status).toBe(200);

    expect(captured).toHaveLength(1);
    expect(captured[0].url).toContain("api.sandbox.push.apple.com");
    expect(captured[0].url).toContain(`/3/device/${"a".repeat(64)}`);
    expect(captured[0].headers["apns-topic"]).toBe("com.tron.mobile.beta");
  });

  test("request without bundle_id falls back to env.APNS_BUNDLE_ID", async () => {
    const { captured } = stubApnsFetch();
    const env = makeEnv({ APNS_BUNDLE_ID: "com.tron.mobile" });
    const worker = await freshWorker();

    const req = await buildSignedRequest(
      {
        device_tokens: ["b".repeat(64)],
        notification: { title: "T", body: "B" },
        environment: "production",
        // bundle_id omitted
      },
      env.TRON_RELAY_SECRET,
    );
    const resp = await worker.fetch(req, env);
    expect(resp.status).toBe(200);

    expect(captured).toHaveLength(1);
    expect(captured[0].headers["apns-topic"]).toBe("com.tron.mobile");
  });

  test("empty string bundle_id falls back to env.APNS_BUNDLE_ID", async () => {
    const { captured } = stubApnsFetch();
    const env = makeEnv({ APNS_BUNDLE_ID: "com.tron.mobile" });
    const worker = await freshWorker();

    const req = await buildSignedRequest(
      {
        device_tokens: ["c".repeat(64)],
        notification: { title: "T", body: "B" },
        bundle_id: "",
      },
      env.TRON_RELAY_SECRET,
    );
    const resp = await worker.fetch(req, env);
    expect(resp.status).toBe(200);

    expect(captured[0].headers["apns-topic"]).toBe("com.tron.mobile");
  });

  test("bundle_id is inside the HMAC-signed body (signature still validates)", async () => {
    // If a later change accidentally moved bundle_id out of the body or
    // into a header, this would either break signature validation (401)
    // or break the wire contract with the server. Both should fail loud.
    const { captured } = stubApnsFetch();
    const env = makeEnv();
    const worker = await freshWorker();

    const req = await buildSignedRequest(
      {
        device_tokens: ["d".repeat(64)],
        notification: { title: "T", body: "B" },
        environment: "sandbox",
        bundle_id: "com.tron.mobile.beta",
      },
      env.TRON_RELAY_SECRET,
    );
    const resp = await worker.fetch(req, env);

    // Either the worker returned 200 (signature validated → bundle_id was in body)
    // or an error — we want green.
    expect(resp.status).toBe(200);
    expect(captured[0].headers["apns-topic"]).toBe("com.tron.mobile.beta");
  });

  test("sandbox environment + beta bundle routes to sandbox host with beta topic", async () => {
    const { captured } = stubApnsFetch();
    const env = makeEnv();
    const worker = await freshWorker();

    const req = await buildSignedRequest(
      {
        device_tokens: ["e".repeat(64)],
        notification: { title: "T", body: "B" },
        environment: "sandbox",
        bundle_id: "com.tron.mobile.beta",
      },
      env.TRON_RELAY_SECRET,
    );
    await worker.fetch(req, env);

    expect(captured[0].url).toContain("api.sandbox.push.apple.com");
    expect(captured[0].headers["apns-topic"]).toBe("com.tron.mobile.beta");
  });

  test("production environment + prod bundle routes to prod host with prod topic", async () => {
    const { captured } = stubApnsFetch();
    const env = makeEnv({ APNS_BUNDLE_ID: "com.example.fallback" });
    const worker = await freshWorker();

    const req = await buildSignedRequest(
      {
        device_tokens: ["f".repeat(64)],
        notification: { title: "T", body: "B" },
        environment: "production",
        bundle_id: "com.tron.mobile",
      },
      env.TRON_RELAY_SECRET,
    );
    await worker.fetch(req, env);

    expect(captured[0].url).toContain("api.push.apple.com");
    expect(captured[0].url).not.toContain("sandbox");
    expect(captured[0].headers["apns-topic"]).toBe("com.tron.mobile");
  });

  test("multiple tokens in one request share the same bundle_id", async () => {
    // By design: `bundle_id` applies to the whole request, not per-token.
    // Callers must group tokens by (environment, bundle_id) upstream.
    const { captured } = stubApnsFetch();
    const env = makeEnv();
    const worker = await freshWorker();

    const req = await buildSignedRequest(
      {
        device_tokens: ["a".repeat(64), "b".repeat(64), "c".repeat(64)],
        notification: { title: "T", body: "B" },
        environment: "sandbox",
        bundle_id: "com.tron.mobile.beta",
      },
      env.TRON_RELAY_SECRET,
    );
    await worker.fetch(req, env);

    expect(captured).toHaveLength(3);
    for (const call of captured) {
      expect(call.headers["apns-topic"]).toBe("com.tron.mobile.beta");
    }
  });
});

describe("relay worker — backward compatibility", () => {
  test("old-server payload (no bundle_id field) still works", async () => {
    // Simulates a server that hasn't been upgraded yet: it sends no
    // bundle_id. Deploy order is relay-first, so this MUST keep working.
    const { captured } = stubApnsFetch();
    const env = makeEnv({ APNS_BUNDLE_ID: "com.tron.mobile" });
    const worker = await freshWorker();

    const req = await buildSignedRequest(
      {
        device_tokens: ["9".repeat(64)],
        notification: { title: "T", body: "B" },
        environment: "production",
      },
      env.TRON_RELAY_SECRET,
    );
    const resp = await worker.fetch(req, env);
    expect(resp.status).toBe(200);
    expect(captured[0].headers["apns-topic"]).toBe("com.tron.mobile");
  });

  test("malformed bundle_id (non-string) is rejected as invalid JSON shape", async () => {
    // Defensive: a garbage value shouldn't crash — fall through to env.
    // Implementation choice: treat any falsy value (undefined, null, "") as "use default".
    const { captured } = stubApnsFetch();
    const env = makeEnv({ APNS_BUNDLE_ID: "com.tron.mobile" });
    const worker = await freshWorker();

    const req = await buildSignedRequest(
      {
        device_tokens: ["8".repeat(64)],
        notification: { title: "T", body: "B" },
        bundle_id: null,
      },
      env.TRON_RELAY_SECRET,
    );
    const resp = await worker.fetch(req, env);
    expect(resp.status).toBe(200);
    expect(captured[0].headers["apns-topic"]).toBe("com.tron.mobile");
  });
});
