import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { PushRelayClient, relaySignature } from "./relay-client.js";

const secret = Buffer.alloc(32, 7).toString("base64url");
const fixture = JSON.parse(readFileSync(new URL("../../../protocol-fixtures/push-v3.json", import.meta.url), "utf8")) as {
  notification: { secret: string; timestamp: string; requestId: string; path: string; bodyUTF8: string; signatureHex: string };
};

describe("PushRelayClient", () => {
  it("uses the relay's exact closed body and hex HMAC protocol", async () => {
    let captured: { url: string; init: RequestInit } | undefined;
    const client = new PushRelayClient("https://push.example.test", async (url, init) => {
      captured = { url, init };
      return new Response(JSON.stringify({ status: "accepted_by_apns", apnsId: "provider-id" }));
    }, () => 1_700_000_000_123);
    await expect(client.send({
      grantId: "grant_abcdefgh", secret, requestId: "request_abcdefgh",
      message: "hello", expiresAt: "2026-01-01T00:00:00.000Z",
    })).resolves.toBe("accepted_by_apns");
    expect(captured!.url).toBe("https://push.example.test/v3/notifications");
    expect(captured!.init.redirect).toBe("error");
    const body = captured!.init.body as string;
    const headers = captured!.init.headers as Record<string, string>;
    expect(headers["x-tron-signature"]).toBe(relaySignature(secret, "POST", "/v3/notifications", "1700000000", "request_abcdefgh", body));
    expect(JSON.parse(body)).toEqual({ version: 1, kind: "agent_alert", requestId: "request_abcdefgh", message: "hello", expiresAt: "2026-01-01T00:00:00.000Z" });
  });

  it("projects only the bounded product title and exact chat route when supplied", async () => {
    let body = "";
    const client = new PushRelayClient("https://push.example.test", async (_url, init) => {
      body = init.body as string;
      return new Response(JSON.stringify({ status: "accepted_by_apns" }));
    });
    await client.send({
      grantId: "grant_abcdefgh",
      secret,
      requestId: "request_abcdefgh",
      message: "The agent finished responding.",
      title: "Release audit",
      sessionId: "session-abcdefgh",
      machineId: "machine-abcdefgh",
      expiresAt: "2026-01-01T00:00:00.000Z",
    });
    expect(JSON.parse(body)).toEqual({
      version: 1,
      kind: "agent_alert",
      requestId: "request_abcdefgh",
      message: "The agent finished responding.",
      title: "Release audit",
      sessionId: "session-abcdefgh",
      machineId: "machine-abcdefgh",
      expiresAt: "2026-01-01T00:00:00.000Z",
    });
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
    await expect(client.send({ grantId: "grant_abcdefgh", secret, requestId: "request_abcdefgh", message: "input", expiresAt: "2026-01-01T00:00:00.000Z" })).resolves.toBe("ambiguous");
  });

  it("distinguishes an exact request still active at the relay from terminal ambiguity", async () => {
    let response = { status: "in_progress", reason: "provider_request_in_progress" };
    const client = new PushRelayClient(
      "https://push.example.test",
      async () => new Response(JSON.stringify(response)),
    );
    const input = {
      grantId: "grant_abcdefgh", secret, requestId: "request_abcdefgh",
      message: "input", expiresAt: "2026-01-01T00:00:00.000Z",
    };
    await expect(client.send(input)).resolves.toBe("in_progress");
    response = { status: "ambiguous", reason: "provider_outcome_unknown" };
    await expect(client.send(input)).resolves.toBe("in_progress");
    response = { status: "ambiguous", reason: "ledger_result_invalid" };
    await expect(client.send(input)).resolves.toBe("ambiguous");
  });

  it("classifies only exact invalid relay capabilities as recoverable grant failures", async () => {
    let response = new Response(JSON.stringify({ error: "invalid_signature" }), { status: 401 });
    const client = new PushRelayClient("https://push.example.test", async () => response);
    const input = {
      grantId: "grant_abcdefgh", secret, requestId: "request_abcdefgh",
      message: "input", expiresAt: "2026-01-01T00:00:00.000Z",
    };
    await expect(client.send(input)).resolves.toBe("invalid_grant");
    response = new Response(JSON.stringify({ error: "installation_unavailable" }), { status: 410 });
    await expect(client.send(input)).resolves.toBe("invalid_grant");
    response = new Response(JSON.stringify({ error: "invalid_authentication_headers" }), { status: 401 });
    await expect(client.send(input)).resolves.toBe("ambiguous");
  });

  it("parses relay rate limits and exact revocation acknowledgements", async () => {
    let call = 0;
    const client = new PushRelayClient("https://push.example.test", async () => {
      call += 1;
      return call === 1
        ? new Response(JSON.stringify({ status: "rate_limited", reason: "rate_limited", retryAfterSeconds: 20 }))
        : new Response(JSON.stringify({ version: 1, revoked: true }));
    });
    await expect(client.send({ grantId: "grant_abcdefgh", secret, requestId: "request_abcdefgh", message: "input", expiresAt: "2026-01-01T00:00:00.000Z" })).resolves.toBe("rate_limited");
    await expect(client.revoke("grant_abcdefgh", secret, "request_abcdefgh")).resolves.toBe("revoked");
  });

  it("treats missing product configuration as unavailable without making a request", async () => {
    let called = false;
    const client = new PushRelayClient(undefined, async () => { called = true; return new Response(); });
    expect(client.available).toBe(false);
    await expect(client.send({ grantId: "grant_abcdefgh", secret, requestId: "request_abcdefgh", message: "input", expiresAt: "2026-01-01T00:00:00.000Z" })).resolves.toBe("retryable");
    expect(called).toBe(false);
  });
});
