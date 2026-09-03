import { describe, expect, it, vi } from "vitest";
import {
  KIMI_K3_MAX_COMPLETION_TOKENS,
  installKimiK3Policy,
  normalizeKimiK3Payload,
  wrapKimiK3Fetch,
} from "./kimi-k3-policy.js";

describe("Kimi K3 request policy", () => {
  it("uses the documented completion field and caps the TPM reservation", () => {
    expect(normalizeKimiK3Payload({ model: "kimi-k3", max_tokens: 131_072 })).toMatchObject({
      max_completion_tokens: KIMI_K3_MAX_COMPLETION_TOKENS,
    });
    expect(normalizeKimiK3Payload({ max_completion_tokens: 4_096 })).toEqual({ max_completion_tokens: 4_096 });
    expect(normalizeKimiK3Payload({ max_tokens: 1 })).toEqual({ max_completion_tokens: 1 });
  });

  it("translates K3 requests at the runtime boundary without changing other models", async () => {
    let capturedOptions: any;
    const stream = vi.fn((_model: unknown, _context: unknown, options: unknown) => {
      capturedOptions = options;
      return "stream";
    });
    const runtime = { streamSimple: stream } as any;
    installKimiK3Policy(runtime);
    const k3 = { provider: "moonshotai-cn", id: "kimi-k3" };
    expect(runtime.streamSimple(k3, {}, {
      onPayload: async (payload: any) => ({ ...payload, max_tokens: 131_072 }),
    })).toBe("stream");
    expect(await capturedOptions.onPayload({ max_tokens: 131_072 }, k3)).toEqual({
      max_completion_tokens: KIMI_K3_MAX_COMPLETION_TOKENS,
    });

    expect(runtime.streamSimple({ provider: "other", id: "model" }, {}, {})).toBe("stream");
    expect(capturedOptions).toEqual({});
  });

  it("performs one provider-advised retry for max-concurrency responses", async () => {
    const fetch = vi.fn<typeof globalThis.fetch>()
      .mockResolvedValueOnce(new Response(JSON.stringify({
        error: {
          type: "rate_limit_reached_error",
          message: "request reached max organization concurrency: 1, please try again after 0 seconds",
        },
      }), { status: 429 }))
      .mockResolvedValueOnce(new Response("ok", { status: 200 }));
    const response = await wrapKimiK3Fetch(fetch)("https://api.moonshot.cn/v1/chat/completions");
    expect(response.status).toBe(200);
    expect(await response.text()).toBe("ok");
    expect(fetch).toHaveBeenCalledTimes(2);
  });

  it("turns terminal account-limit 429s into non-retryable provider errors", async () => {
    const fetch = vi.fn<typeof globalThis.fetch>(async () => new Response(JSON.stringify({
      error: {
        type: "rate_limit_reached_error",
        message: "request reached organization TPM rate limit, current: 563653, limit: 500000",
      },
    }), { status: 429, headers: { "content-type": "application/json" } }));
    const response = await wrapKimiK3Fetch(fetch)("https://api.moonshot.cn/v1/chat/completions");
    expect(response.status).toBe(400);
    expect(response.headers.get("x-should-retry")).toBe("false");
    const body = await response.json() as { error: { message: string; type: string } };
    expect(body.error.type).toBe("account_limit_reached");
    expect(body.error.message).toContain("TPM");
    expect(body.error.message).not.toMatch(/429|rate.?limit/i);
  });

  it("leaves transient engine overload responses retryable", async () => {
    const response = await wrapKimiK3Fetch(async () => new Response(JSON.stringify({
      error: { type: "engine_overloaded_error", message: "engine overloaded; RPM capacity is busy" },
    }), { status: 429 }))("https://api.moonshot.cn/v1/chat/completions");
    expect(response.status).toBe(429);
    await response.text();
  });

  it("allows concurrent K3 requests when the account permits them", async () => {
    let active = 0;
    let maximumActive = 0;
    const fetch = vi.fn<typeof globalThis.fetch>(async () => {
      active += 1;
      maximumActive = Math.max(maximumActive, active);
      await new Promise((resolve) => setTimeout(resolve, 0));
      active -= 1;
      return new Response("ok", { status: 200 });
    });
    const wrapped = wrapKimiK3Fetch(fetch);
    const [first, second] = await Promise.all([
      wrapped("https://api.moonshot.ai/v1/chat/completions"),
      wrapped("https://api.moonshot.ai/v1/chat/completions"),
    ]);
    await Promise.all([first.text(), second.text()]);
    expect(maximumActive).toBe(2);
    expect(fetch).toHaveBeenCalledTimes(2);
  });
});
