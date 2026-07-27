import { describe, expect, test } from "vitest";

import {
  replayResult,
  validateNotificationRequest,
  verifyRelaySignature,
} from "../src/index";

const alert = {
  kind: "alert",
  requestId: "target-1",
  deviceToken: "ab".repeat(32),
  topic: "com.tron.mobile.beta",
  environment: "sandbox",
  expiresAt: "2099-01-01T00:00:00Z",
  collapseId: "delivery-1",
  title: "Reminder",
  body: "Do the thing.",
  threadKey: "reminders",
  category: "TRON_REMINDER",
  badge: 1,
  serverId: "server-1",
  deliveryId: "delivery-1",
};

describe("closed request validation", () => {
  test("accepts the fixed alert shape", () => {
    expect(validateNotificationRequest(alert)).toEqual({
      ok: true,
      value: alert,
    });
  });

  test("rejects arbitrary APNs and device-control fields", () => {
    for (const field of [
      "payload",
      "url",
      "sound",
      "priority",
      "actions",
      "media",
      "customData",
    ]) {
      expect(
        validateNotificationRequest({ ...alert, [field]: "untrusted" }),
      ).toEqual({ ok: false, error: "unknown_field" });
    }
  });

  test("allows only the fixed topic and environment pairs", () => {
    expect(
      validateNotificationRequest({ ...alert, environment: "production" }),
    ).toEqual({ ok: false, error: "invalid_request" });
    expect(
      validateNotificationRequest({
        ...alert,
        topic: "com.tron.mobile",
        environment: "sandbox",
      }),
    ).toMatchObject({ ok: true });
    expect(
      validateNotificationRequest({
        ...alert,
        topic: "com.tron.mobile",
        environment: "production",
      }),
    ).toMatchObject({ ok: true });
  });
});

describe("relay authentication", () => {
  test("covers method, path, timestamp, request id, and body hash", async () => {
    const timestamp = "2000000000";
    const body = new TextEncoder().encode('{"kind":"alert"}');
    const bodyHash = await crypto.subtle.digest("SHA-256", body);
    const hashHex = [...new Uint8Array(bodyHash)]
      .map((byte) => byte.toString(16).padStart(2, "0"))
      .join("");
    const canonical = `POST\n/v2/notification\n${timestamp}\ntarget-1\n${hashHex}`;
    const key = await crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode("0123456789abcdef"),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"],
    );
    const signature = [...new Uint8Array(
      await crypto.subtle.sign(
        "HMAC",
        key,
        new TextEncoder().encode(canonical),
      ),
    )]
      .map((byte) => byte.toString(16).padStart(2, "0"))
      .join("");

    await expect(
      verifyRelaySignature(
        "0123456789abcdef",
        timestamp,
        "target-1",
        body,
        signature,
        2000000000,
      ),
    ).resolves.toBe(true);
    await expect(
      verifyRelaySignature(
        "0123456789abcdef",
        timestamp,
        "target-2",
        body,
        signature,
        2000000000,
      ),
    ).resolves.toBe(false);
  });

  test("rejects timestamps outside the five-minute window", async () => {
    await expect(
      verifyRelaySignature(
        "0123456789abcdef",
        "1000",
        "target-1",
        new Uint8Array([1]),
        "00".repeat(32),
        2000,
      ),
    ).resolves.toBe(false);
  });
});

describe("durable retry coalescing", () => {
  test("admits an unseen provider request", () => {
    expect(replayResult(undefined)).toBeUndefined();
  });

  test("replays terminal APNs acceptance", () => {
    expect(
      replayResult({
        state: "terminal",
        response_json: JSON.stringify({
          status: "accepted_by_apns",
          apnsId: "provider-id",
        }),
      }),
    ).toEqual({ status: "accepted_by_apns", apnsId: "provider-id" });
  });

  test("blocks an ambiguously interrupted attempt instead of resending", () => {
    expect(
      replayResult({ state: "in_progress", response_json: null }),
    ).toEqual({
      status: "ambiguous",
      reason: "provider_outcome_unknown",
    });
  });

  test("allows an explicitly retryable result to be attempted again", () => {
    expect(
      replayResult({
        state: "retryable",
        response_json: JSON.stringify({ status: "retryable" }),
      }),
    ).toBeUndefined();
  });
});
