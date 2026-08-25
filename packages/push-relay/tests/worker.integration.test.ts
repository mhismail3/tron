import { env, SELF, reset, runInDurableObject } from "cloudflare:test";
import { encode } from "cbor-x";
import { afterEach, describe, expect, test, vi } from "vitest";
import { REGISTRY_NAME } from "../src/contracts";
import { base64Url, canonicalRegistration, concatBytes, hmacHex, ownedBuffer, sha256, sha256Hex, utf8 } from "../src/crypto";
import type { PushRegistry } from "../src/registry";
import { testGrant } from "./fixtures";

function rawEcdsaToDer(raw: Uint8Array): Uint8Array {
  function integer(value: Uint8Array): Uint8Array {
    let start = 0;
    while (start < value.byteLength - 1 && value[start] === 0) start += 1;
    let significant: Uint8Array<ArrayBufferLike> = value.slice(start);
    if ((significant[0] & 0x80) !== 0) significant = concatBytes(new Uint8Array([0]), significant);
    return concatBytes(new Uint8Array([0x02, significant.byteLength]), significant);
  }
  const r = integer(raw.slice(0, 32));
  const s = integer(raw.slice(32));
  return concatBytes(new Uint8Array([0x30, r.byteLength + s.byteLength]), r, s);
}

function stub() {
  const id = env.PUSH_REGISTRY.idFromName(REGISTRY_NAME);
  return env.PUSH_REGISTRY.get(id);
}

async function initializeAndSeed(): Promise<void> {
  const response = await SELF.fetch("https://push.test/v3/attestation/challenge", { method: "POST" });
  expect(response.status).toBe(200);
  await runInDurableObject(stub(), async (_instance: PushRegistry, state) => {
    const now = Math.floor(Date.now() / 1000);
    state.storage.sql.exec(
      `INSERT INTO installations
       (installation_id, key_id, public_key_spki, route, apns_token, token_hash, assertion_counter, enabled, created_at, updated_at)
       VALUES (?, ?, 'test-spki', 'beta', ?, 'token-hash', 1, 1, ?, ?)`,
      testGrant.installationId, testGrant.keyId, testGrant.deviceToken, now, now,
    );
    state.storage.sql.exec(
      `INSERT INTO grants
       (grant_id, installation_id, binding_hash, secret, enabled, hourly_window, hourly_count, daily_window, daily_count, created_at, updated_at)
       VALUES (?, ?, ?, ?, 1, ?, 0, ?, 0, ?, ?)`,
      testGrant.grantId, testGrant.installationId, testGrant.bindingHash, testGrant.secret,
      Math.floor(now / 3600) * 3600, Math.floor(now / 86400) * 86400, now, now,
    );
  });
}

async function signedNotification(input?: { requestId?: string; message?: string }): Promise<RequestInit> {
  const requestId = input?.requestId ?? "request-identifier-0001";
  const body = JSON.stringify({
    version: 1,
    kind: "agent_alert",
    requestId,
    message: input?.message ?? "Tron needs your input.",
    expiresAt: new Date(Date.now() + 10 * 60_000).toISOString(),
  });
  const timestamp = String(Math.floor(Date.now() / 1000));
  const hash = await sha256Hex(utf8(body));
  const canonical = `POST\n/v3/notifications\n${timestamp}\n${requestId}\n${hash}`;
  const signature = await hmacHex(testGrant.secret, canonical);
  return {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-tron-grant-id": testGrant.grantId,
      "x-tron-timestamp": timestamp,
      "x-tron-request-id": requestId,
      "x-tron-signature": signature,
    },
    body,
  };
}

async function signedRevocation(requestId = "revoke-request-0000001"): Promise<RequestInit> {
  const path = `/v3/grants/${testGrant.grantId}`;
  const timestamp = String(Math.floor(Date.now() / 1000));
  const bodyHash = await sha256Hex(new Uint8Array());
  const signature = await hmacHex(testGrant.secret, `DELETE\n${path}\n${timestamp}\n${requestId}\n${bodyHash}`);
  return {
    method: "DELETE",
    headers: {
      "x-tron-timestamp": timestamp,
      "x-tron-request-id": requestId,
      "x-tron-signature": signature,
    },
  };
}

afterEach(async () => {
  vi.unstubAllGlobals();
  await reset();
});

describe("v3 Worker boundary", () => {
  test("rejects unknown routes, query strings, wrong methods, and streamed oversize bodies", async () => {
    expect((await SELF.fetch("https://push.test/v2/notification", { method: "POST" })).status).toBe(404);
    expect((await SELF.fetch("https://push.test/v3/notifications", { method: "GET" })).status).toBe(405);
    expect((await SELF.fetch("https://push.test/v3/notifications?target=x", { method: "POST" })).status).toBe(404);
    expect((await SELF.fetch("https://push.test/v3/notifications", { method: "POST", body: "{}" })).status).toBe(415);
    const stream = new ReadableStream({ start(controller) { controller.enqueue(new Uint8Array(17_000)); controller.close(); } });
    const response = await SELF.fetch("https://push.test/v3/notifications", { method: "POST", body: stream });
    expect(response.status).toBe(413);
  });

  test("replays a terminal APNs outcome without a second provider send", async () => {
    await initializeAndSeed();
    const providerFetch = vi.fn(async (_url: string | URL | Request, _init?: RequestInit) => new Response(null, { status: 200, headers: { "apns-id": "provider-id" } }));
    vi.stubGlobal("fetch", providerFetch);
    const request = await signedNotification();
    const first = await SELF.fetch("https://push.test/v3/notifications", request);
    const second = await SELF.fetch("https://push.test/v3/notifications", request);
    expect(await first.json()).toEqual({ status: "accepted_by_apns", apnsId: "provider-id" });
    expect(await second.json()).toEqual({ status: "accepted_by_apns", apnsId: "provider-id" });
    expect(providerFetch).toHaveBeenCalledTimes(1);
    const providerRequest = providerFetch.mock.calls[0][0] as string;
    const providerInit = providerFetch.mock.calls[0][1];
    expect(providerRequest).toContain("api.sandbox.push.apple.com/3/device/");
    expect(providerRequest).not.toContain(testGrant.grantId);
    expect(providerInit?.redirect).toBeUndefined();
    expect(providerInit?.signal).toBeInstanceOf(AbortSignal);
  });

  test("rejects request-ID reuse with a different authenticated body", async () => {
    await initializeAndSeed();
    const providerFetch = vi.fn(async (_url: string | URL | Request, _init?: RequestInit) => new Response(null, { status: 200 }));
    vi.stubGlobal("fetch", providerFetch);
    const first = await SELF.fetch("https://push.test/v3/notifications", await signedNotification());
    expect((await first.json() as { status: string }).status).toBe("accepted_by_apns");
    const conflict = await SELF.fetch("https://push.test/v3/notifications", await signedNotification({ message: "Changed body" }));
    expect(await conflict.json()).toEqual({ status: "permanent_failure", reason: "request_id_conflict" });
    expect(providerFetch).toHaveBeenCalledTimes(1);
  });

  test("disables an installation and all grants after APNs rejects its token", async () => {
    await initializeAndSeed();
    vi.stubGlobal("fetch", vi.fn(async (_url: string | URL | Request, _init?: RequestInit) => new Response('{"reason":"Unregistered"}', { status: 410 })));
    const response = await SELF.fetch("https://push.test/v3/notifications", await signedNotification());
    expect(await response.json()).toEqual({ status: "invalid_token", reason: "Unregistered" });
    const state = await runInDurableObject(stub(), async (_instance: PushRegistry, durableState) => ({
      installation: durableState.storage.sql.exec<{ enabled: number }>("SELECT enabled FROM installations WHERE installation_id = ?", testGrant.installationId).one().enabled,
      grant: durableState.storage.sql.exec<{ enabled: number }>("SELECT enabled FROM grants WHERE grant_id = ?", testGrant.grantId).one().enabled,
    }));
    expect(state).toEqual({ installation: 0, grant: 0 });
  });

  test("re-admission rotates a disabled grant so an old revoke cannot disable new authority", async () => {
    await initializeAndSeed();
    const keys = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
    const publicKeySpki = base64Url(new Uint8Array(await crypto.subtle.exportKey("spki", keys.publicKey)));
    await runInDurableObject(stub(), async (_instance: PushRegistry, state) => {
      state.storage.sql.exec(
        "UPDATE installations SET public_key_spki = ?, assertion_counter = 1 WHERE installation_id = ?",
        publicKeySpki,
        testGrant.installationId,
      );
      state.storage.sql.exec("UPDATE grants SET enabled = 0 WHERE grant_id = ?", testGrant.grantId);
    });
    const challengeResponse = await SELF.fetch("https://push.test/v3/attestation/challenge", { method: "POST" });
    const challenge = await challengeResponse.json<{ challengeId: string; challenge: string }>();
    const fields = {
      version: 1 as const,
      challengeId: challenge.challengeId,
      challenge: challenge.challenge,
      keyId: testGrant.keyId,
      apnsToken: testGrant.deviceToken,
      route: "beta" as const,
      bindingHash: testGrant.bindingHash,
    };
    const clientDataHash = await sha256(canonicalRegistration(fields));
    const authenticatorData = new Uint8Array(37);
    authenticatorData.set(await sha256(utf8(`${env.APPLE_TEAM_ID}.com.tron.mobile.beta`)));
    new DataView(authenticatorData.buffer).setUint32(33, 2, false);
    const rawSignature = new Uint8Array(await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      keys.privateKey,
      ownedBuffer(concatBytes(authenticatorData, clientDataHash)),
    ));
    const assertionObject = base64Url(encode({ authenticatorData, signature: rawEcdsaToDer(rawSignature) }));
    const response = await SELF.fetch("https://push.test/v3/installations", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ ...fields, proof: "assertion", assertionObject }),
    });
    expect(response.status).toBe(201);
    const replacement = await response.json<{ grantId: string; grantSecret: string }>();
    expect(replacement.grantId).not.toBe(testGrant.grantId);
    expect(replacement.grantSecret).not.toBe(testGrant.secret);

    const staleRevoke = await SELF.fetch(`https://push.test/v3/grants/${testGrant.grantId}`, await signedRevocation());
    expect(staleRevoke.status).toBe(404);
    const active = await runInDurableObject(stub(), async (_instance: PushRegistry, state) => state.storage.sql.exec<{
      grant_id: string; enabled: number;
    }>("SELECT grant_id, enabled FROM grants WHERE installation_id = ?", testGrant.installationId).one());
    expect(active).toEqual(expect.objectContaining({ grant_id: replacement.grantId, enabled: 1 }));
  });

  test("enforces installation-wide quota across grants before contacting APNs", async () => {
    await initializeAndSeed();
    await runInDurableObject(stub(), async (_instance: PushRegistry, state) => {
      const now = Math.floor(Date.now() / 1000);
      state.storage.sql.exec(
        "INSERT INTO installation_limits (installation_id, hourly_window, hourly_count, daily_window, daily_count, updated_at) VALUES (?, ?, 50, ?, 50, ?)",
        testGrant.installationId, Math.floor(now / 3600) * 3600, Math.floor(now / 86400) * 86400, now,
      );
    });
    const providerFetch = vi.fn(async () => new Response(null, { status: 200 }));
    vi.stubGlobal("fetch", providerFetch);
    const response = await SELF.fetch("https://push.test/v3/notifications", await signedNotification({ requestId: "installation-quota-0001" }));
    expect(await response.json()).toMatchObject({ status: "rate_limited" });
    expect(providerFetch).not.toHaveBeenCalled();
  });

  test("enforces quota before contacting APNs and makes revocation idempotent", async () => {
    await initializeAndSeed();
    await runInDurableObject(stub(), async (_instance: PushRegistry, state) => {
      const now = Math.floor(Date.now() / 1000);
      state.storage.sql.exec("UPDATE grants SET hourly_window = ?, hourly_count = 30 WHERE grant_id = ?", Math.floor(now / 3600) * 3600, testGrant.grantId);
    });
    const providerFetch = vi.fn(async (_url: string | URL | Request, _init?: RequestInit) => new Response(null, { status: 200 }));
    vi.stubGlobal("fetch", providerFetch);
    const limited = await SELF.fetch("https://push.test/v3/notifications", await signedNotification({ requestId: "quota-request-00000001" }));
    expect(await limited.json()).toMatchObject({ status: "rate_limited", reason: "rate_limited" });
    expect(providerFetch).not.toHaveBeenCalled();

    const path = `https://push.test/v3/grants/${testGrant.grantId}`;
    expect(await (await SELF.fetch(path, await signedRevocation())).json()).toEqual({ version: 1, revoked: true });
    expect(await (await SELF.fetch(path, await signedRevocation("revoke-request-0000002"))).json()).toEqual({ version: 1, revoked: true });
    const enabled = await runInDurableObject(stub(), async (_instance: PushRegistry, state) =>
      state.storage.sql.exec<{ enabled: number }>("SELECT enabled FROM grants WHERE grant_id = ?", testGrant.grantId).one().enabled,
    );
    expect(enabled).toBe(0);
  });

  test("fails closed when App Attest proof is malformed", async () => {
    const challengeResponse = await SELF.fetch("https://push.test/v3/attestation/challenge", { method: "POST" });
    const challenge = await challengeResponse.json() as { challengeId: string; challenge: string };
    const registration = {
      version: 1,
      proof: "attestation",
      challengeId: challenge.challengeId,
      challenge: challenge.challenge,
      keyId: "k".repeat(43),
      apnsToken: "ab".repeat(32),
      route: "beta",
      bindingHash: "12".repeat(32),
      attestationObject: "a".repeat(64),
    };
    const response = await SELF.fetch("https://push.test/v3/installations", {
      method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(registration),
    });
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "invalid_attestation" });
  });
});
