import { createHash, createHmac } from "node:crypto";
import { describe, expect, it } from "vitest";
import { PushRelayClient } from "./relay-client.js";

const secret = Buffer.alloc(32, 7).toString("base64url");

describe("PushRelayClient", () => {
  it("uses one fixed route, stable request identity, bounded closed body, and endpoint HMAC", async () => {
    let captured: { url: string; init: RequestInit } | undefined;
    const client = new PushRelayClient("https://push.example.test", async (url, init) => {
      captured = { url, init };
      return new Response(JSON.stringify({ outcome: "accepted_by_apns" }));
    }, () => 1_700_000_000_123);
    await expect(client.send({
      grantId: "grant_abcdefgh", secret, requestId: "request_abcdefgh", kind: "explicit",
      message: "hello", environment: "sandbox", expiresAt: "2026-01-01T00:00:00.000Z",
    })).resolves.toBe("accepted_by_apns");
    expect(captured!.url).toBe("https://push.example.test/v3/notifications");
    expect(captured!.init.redirect).toBe("error");
    const body = captured!.init.body as string;
    const headers = captured!.init.headers as Record<string, string>;
    const digest = createHash("sha256").update(body).digest("base64url");
    const expected = createHmac("sha256", Buffer.from(secret, "base64url"))
      .update(`POST\n/v3/notifications\n1700000000\nrequest_abcdefgh\n${digest}`).digest("base64url");
    expect(headers["x-tron-signature"]).toBe(expected);
    expect(JSON.parse(body)).toEqual({ version: 1, kind: "explicit", message: "hello", environment: "sandbox", expiresAt: "2026-01-01T00:00:00.000Z" });
  });

  it.each(["http://push.example.test", "https://user@push.example.test", "https://push.example.test/path", "https://push.example.test/?x=1"])("rejects non-origin configuration %s", (origin) => {
    expect(() => new PushRelayClient(origin)).toThrow(/exact HTTPS origin/);
  });

  it("does not follow redirects or trust malformed success bodies", async () => {
    const client = new PushRelayClient("https://push.example.test", async () => new Response("{}", { status: 200 }));
    await expect(client.send({ grantId: "grant_abcdefgh", secret, requestId: "request_abcdefgh", kind: "ask", message: "input", environment: "production", expiresAt: "2026-01-01T00:00:00.000Z" })).resolves.toBe("ambiguous");
  });

  it("treats missing product configuration as unavailable without making a request", async () => {
    let called = false;
    const client = new PushRelayClient(undefined, async () => { called = true; return new Response(); });
    expect(client.available).toBe(false);
    await expect(client.send({ grantId: "grant_abcdefgh", secret, requestId: "request_abcdefgh", kind: "ask", message: "input", environment: "sandbox", expiresAt: "2026-01-01T00:00:00.000Z" })).resolves.toBe("retryable");
    expect(called).toBe(false);
  });
});
