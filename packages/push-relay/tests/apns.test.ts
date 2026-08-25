import { env } from "cloudflare:test";
import { afterEach, describe, expect, test, vi } from "vitest";
import { buildApnsPayload, sendToApns } from "../src/apns";
import type { Env } from "../src/contracts";
import { notification } from "./fixtures";

afterEach(() => { vi.unstubAllGlobals(); vi.useRealTimers(); });

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

  test("provider-token cache identity includes private-key contents", async () => {
    const providerFetch = vi.fn(async () => new Response(null, { status: 200 }));
    vi.stubGlobal("fetch", providerFetch);
    const provider = { ...(env as unknown as Env), APNS_TEAM_ID: "CACHE_TEAM", APNS_KEY_ID: "CACHE_KEY" };
    expect((await sendToApns(provider, notification, target)).status).toBe("accepted_by_apns");
    expect(await sendToApns({ ...provider, APNS_KEY_P8: "x".repeat(provider.APNS_KEY_P8.length) }, notification, target)).toEqual({
      status: "retryable",
      reason: "provider_token_error",
      retryAfterSeconds: 30,
    });
    expect(providerFetch).toHaveBeenCalledTimes(1);
  });

  test.each(["InvalidProviderToken", "ExpiredProviderToken"])("clears cached provider token after APNs %s", async (reason) => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-08-25T00:00:00.000Z"));
    const authorizations: string[] = [];
    const providerFetch = vi.fn(async (_url: string | URL | Request, init?: RequestInit) => {
      authorizations.push(new Headers(init?.headers).get("authorization") ?? "");
      return authorizations.length === 1
        ? new Response(JSON.stringify({ reason }), { status: 403 })
        : new Response(null, { status: 200 });
    });
    vi.stubGlobal("fetch", providerFetch);
    const provider = { ...(env as unknown as Env), APNS_TEAM_ID: `AUTH_${reason}`, APNS_KEY_ID: "AUTH_KEY" };
    expect(await sendToApns(provider, notification, target)).toEqual({ status: "retryable", reason, retryAfterSeconds: 1 });
    vi.setSystemTime(new Date("2026-08-25T00:00:01.000Z"));
    expect((await sendToApns(provider, notification, target)).status).toBe("accepted_by_apns");
    expect(authorizations).toHaveLength(2);
    expect(authorizations[1]).not.toBe(authorizations[0]);
  });
});
