import { env } from "cloudflare:test";
import { afterEach, describe, expect, test, vi } from "vitest";
import { buildApnsPayload, sendToApns } from "../src/apns";
import type { Env } from "../src/contracts";
import { notification } from "./fixtures";

afterEach(() => { vi.unstubAllGlobals(); });

const target = { deviceToken: "00", topic: "com.tron.mobile", environment: "sandbox" as const };

describe("closed APNs payload", () => {
  test("projects one fixed alert without badge, routing, or arbitrary data", () => {
    const payload = JSON.parse(buildApnsPayload(notification));
    expect(payload).toEqual({
      aps: {
        alert: { title: "Tron", body: "Tron needs your input." },
        sound: "default",
        category: "TRON_AGENT_NOTIFICATION",
      },
      tron: { kind: "agent_notification", requestId: "request-identifier-0001" },
    });
    expect(new TextEncoder().encode(JSON.stringify(payload)).byteLength).toBeLessThanOrEqual(4096);
    expect(JSON.stringify(payload)).not.toContain("deviceToken");
  });

  test("bounds provider-token failures without contacting APNs", async () => {
    const providerFetch = vi.fn();
    vi.stubGlobal("fetch", providerFetch);
    const result = await sendToApns(
      { ...(env as unknown as Env), APNS_KEY_P8: "not-a-private-key" },
      notification,
      target,
    );
    expect(result).toEqual({ status: "retryable", reason: "provider_token_error", retryAfterSeconds: 30 });
    expect(providerFetch).not.toHaveBeenCalled();
  });

  test("distinguishes bounded APNs transport failures", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => { throw new Error("provider unavailable"); }));
    expect(await sendToApns(env as unknown as Env, notification, target)).toEqual({
      status: "retryable",
      reason: "apns_transport_error",
      retryAfterSeconds: 30,
    });
  });
});
