import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { PushRelayClient, relaySignature } from "./relay-client.js";

const secret = Buffer.alloc(32, 7).toString("base64url");
const fixture = JSON.parse(readFileSync(new URL("../../../protocol-fixtures/push-v3.json", import.meta.url), "utf8")) as {
  notification: { secret: string; timestamp: string; requestId: string; path: string; bodyUTF8: string; signatureHex: string };
};
const envelope = (requestId: string, message: string, extra: Record<string, unknown> = {}) => JSON.stringify({
  version: 1, kind: "agent_alert", notificationKind: "agent_finished", requestId, message,
  expiresAt: "2026-01-01T00:00:00.000Z", ...extra,
});
const input = (relayEnvelope = envelope("request_abcdefgh", "input")) => ({
  grantId: "grant_abcdefgh", secret, requestId: "request_abcdefgh", relayEnvelope,
});

describe("PushRelayClient", () => {
  it("signs and transmits the exact persisted relay envelope", async () => {
    let captured: { url: string; init: RequestInit } | undefined;
    const body = envelope("request_abcdefgh", "hello");
    const client = new PushRelayClient("https://push.example.test", async (url, init) => {
      captured = { url, init };
      return new Response(JSON.stringify({ status: "accepted_by_apns", apnsId: "provider-id" }));
    }, () => 1_700_000_000_123);
    await expect(client.send(input(body))).resolves.toEqual({ status: "accepted_by_apns" });
    expect(captured!.url).toBe("https://push.example.test/v3/notifications");
    expect(captured!.init.redirect).toBe("error");
    expect(captured!.init.body).toBe(body);
    const headers = captured!.init.headers as Record<string, string>;
    expect(headers["x-tron-signature"]).toBe(relaySignature(secret, "POST", "/v3/notifications", "1700000000", "request_abcdefgh", body));
  });

  it("forwards the exact admitted title and session route", async () => {
    let body = "";
    const client = new PushRelayClient("https://push.example.test", async (_url, init) => {
      body = init.body as string;
      return new Response(JSON.stringify({ status: "accepted_by_apns" }));
    });
    const expected = envelope("request_abcdefgh", "The agent finished responding.", {
      title: "Release audit", sessionId: "session-abcdefgh", machineId: "machine-abcdefgh",
    });
    await client.send(input(expected));
    expect(body).toBe(expected);
  });

  it("matches the shared cross-runtime HMAC fixture", () => {
    expect(relaySignature(
      fixture.notification.secret, "POST", fixture.notification.path,
      fixture.notification.timestamp, fixture.notification.requestId, fixture.notification.bodyUTF8,
    )).toBe(fixture.notification.signatureHex);
  });

  it.each([
    "http://push.example.test", "https://user@push.example.test", "https://push.example.test/path",
    "https://push.example.test/?x=1", "https://localhost", "https://127.0.0.1", "https://[::1]", "https://relay.local",
  ])("rejects non-public exact-origin configuration %s", (origin) => {
    expect(() => new PushRelayClient(origin)).toThrow(/exact public HTTPS origin/);
  });

  it("does not follow redirects or trust malformed success bodies", async () => {
    const client = new PushRelayClient("https://push.example.test", async () => new Response("{}", { status: 200 }));
    await expect(client.send(input())).resolves.toMatchObject({ status: "ambiguous" });
  });

  it("preserves relay status and reason for active, terminal, and capability outcomes", async () => {
    let response: Record<string, string> = { status: "in_progress", reason: "provider_request_in_progress" };
    const client = new PushRelayClient("https://push.example.test", async () => new Response(JSON.stringify(response)));
    await expect(client.send(input())).resolves.toEqual({ status: "in_progress", reason: "provider_request_in_progress" });
    response = { status: "ambiguous", reason: "provider_outcome_unknown" };
    await expect(client.send(input())).resolves.toEqual({ status: "in_progress", reason: "provider_outcome_unknown" });
    response = { status: "ambiguous", reason: "ledger_result_invalid" };
    await expect(client.send(input())).resolves.toEqual({ status: "ambiguous", reason: "ledger_result_invalid" });

    let error = new Response(JSON.stringify({ error: "invalid_signature" }), { status: 401 });
    const capabilities = new PushRelayClient("https://push.example.test", async () => error);
    await expect(capabilities.send(input())).resolves.toEqual({ status: "invalid_grant", reason: "invalid_signature" });
    error = new Response(JSON.stringify({ error: "installation_unavailable" }), { status: 410 });
    await expect(capabilities.send(input())).resolves.toEqual({ status: "invalid_grant", reason: "installation_unavailable" });
  });

  it.each([
    { status: "rate_limited", reason: "daily_limit", retryAfterSeconds: 20 },
    { status: "retryable", reason: "apns_token_changed", retryAfterSeconds: 30 },
  ])("preserves $reason and exact revocation acknowledgements", async (outcome) => {
    let call = 0;
    const client = new PushRelayClient("https://push.example.test", async () => {
      call += 1;
      return call === 1
        ? new Response(JSON.stringify(outcome))
        : new Response(JSON.stringify({ version: 1, revoked: true }));
    });
    await expect(client.send(input())).resolves.toEqual({ status: outcome.status, reason: outcome.reason });
    await expect(client.revoke("grant_abcdefgh", secret, "request_abcdefgh")).resolves.toBe("revoked");
  });

  it("treats missing product configuration as unavailable without making a request", async () => {
    let called = false;
    const client = new PushRelayClient(undefined, async () => { called = true; return new Response(); });
    expect(client.available).toBe(false);
    await expect(client.send(input())).resolves.toEqual({ status: "retryable", reason: "relay_unavailable" });
    expect(called).toBe(false);
  });
});
