import { describe, expect, it, vi } from "vitest";
import { ProviderUsageOwner } from "./provider-usage.js";

const model = (provider: string, baseUrl: string, api = "openai-completions") => ({ provider, id: "fixture", api, baseUrl });
function runtime(provider: string, baseUrl: string, auth: unknown = { auth: { apiKey: "fixture-secret" } }, api = "openai-completions") {
  return { getModels: () => [model(provider, baseUrl, api)], getAuth: vi.fn(async () => auth), getProvider: () => undefined, hasConfiguredAuth: () => auth !== null } as any;
}
function shapedRuntime(provider: string, shapes: Array<{ api: string; baseUrl: string }>, auth: unknown = { auth: { apiKey: "fixture-secret" } }) {
  return {
    getModels: () => shapes.map((shape, index) => ({ provider, id: `fixture-${index}`, api: shape.api, baseUrl: shape.baseUrl })),
    getAuth: vi.fn(async () => auth),
    getProvider: () => undefined,
    hasConfiguredAuth: () => auth !== null,
  } as any;
}
const openCodeGoShapes = [
  { api: "anthropic-messages", baseUrl: "https://opencode.ai/zen/go" },
  { api: "openai-completions", baseUrl: "https://opencode.ai/zen/go/v1" },
  { api: "openai-responses", baseUrl: "https://opencode.ai/zen/go/v1" },
];
function response(body: unknown, status = 200, headers: Record<string, string> = {}) {
  return new Response(typeof body === "string" ? body : JSON.stringify(body), { status, headers });
}
async function waitFor(condition: () => boolean): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (condition()) return;
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
  throw new Error("fixture condition was not reached");
}

describe("provider usage owner", () => {
  it("queries exact first-party OpenRouter config and projects capped key spend", async () => {
    let now = 1_700_000_000_000;
    const fetch = vi.fn(async (url: string, init?: RequestInit) => {
      expect(url).toBe("https://openrouter.ai/api/v1/key");
      expect(init?.redirect).toBe("error");
      expect((init?.headers as Record<string, string>).Authorization).toBe("Bearer fixture-secret");
      return response({ data: { limit: 10, limit_remaining: 3, usage_daily: 999 } });
    });
    const owner = new ProviderUsageOwner({ fetch, now: () => now });
    const fixture = runtime("openrouter", "https://openrouter.ai/api/v1");
    const result = await owner.read(fixture, "openrouter");
    expect(result.providers[0]).toMatchObject({ status: "available", scope: "key", source: "openrouter.key" });
    expect(result.providers[0]!.windows[0]).toMatchObject({ limit: 10, remaining: 3, used: 7, usedPercent: 70 });
    now += 1_000;
    await owner.read(fixture, "openrouter");
    expect(fetch).toHaveBeenCalledTimes(1);
  });

  it("projects native Codex, Kimi, and Z.ai usage shapes without upstream text", async () => {
    const fixtures = [
      {
        id: "openai-codex", base: "https://chatgpt.com/backend-api", api: "openai-codex-responses",
        auth: { auth: { headers: { Authorization: "Bearer fixture-token", "chatgpt-account-id": "fixture-account" } } },
        body: { rate_limit: { primary_window: { used_percent: 12.5, reset_at: "2026-01-02T05:00:00Z", limit_window_seconds: 18_000 }, secondary_window: { used_percent: 63, reset_at: "2026-01-09T00:00:00Z", limit_window_seconds: 604_800 } } },
      },
      {
        id: "kimi-coding", base: "https://api.kimi.com/coding", api: "anthropic-messages",
        auth: { auth: { apiKey: "fixture-kimi" } },
        body: { usage: { limit: 100, used: 25, remaining: 75, window: { duration: 7, timeUnit: "day" }, detail: { resetTime: "2026-01-09T00:00:00Z" } } },
      },
      {
        id: "zai", base: "https://api.z.ai/api/coding/paas/v4", api: "openai-completions",
        auth: { auth: { apiKey: "fixture-zai" } },
        body: { data: { limits: [{ name: "Tokens", percentage: 17, currentValue: 17, limit: 100, remaining: 83, unit: "requests", resetAt: "2026-01-02T05:00:00Z" }] } },
      },
    ] as const;
    for (const fixture of fixtures) {
      const fetch = vi.fn(async () => response(fixture.body));
      const owner = new ProviderUsageOwner({ fetch });
      const result = await owner.read(runtime(fixture.id, fixture.base, fixture.auth, fixture.api), fixture.id);
      const snapshot = result.providers[0]!;
      expect(snapshot).toMatchObject({ providerId: fixture.id, status: "available" });
      expect(snapshot.windows.length).toBeGreaterThan(0);
      expect(snapshot.windows.some((item) => item.usedPercent !== null)).toBe(true);
      expect(fetch).toHaveBeenCalledTimes(1);
    }
  });

  it("projects OpenCode Go account windows across every first-party model shape", async () => {
    const fetch = vi.fn(async (url: string, init?: RequestInit) => {
      expect(url).toBe("https://opencode.ai/zen/go/v1/usage");
      expect(init?.redirect).toBe("error");
      expect((init?.headers as Record<string, string>).Authorization).toBe("Bearer fixture-secret");
      return response({ usage: {
        rolling: { status: "ok", percent: 12.5, resetsAt: "2026-09-18T12:58:26.147Z" },
        weekly: { status: "ok", percent: 34, resetsAt: "2026-09-21T00:00:00.147Z" },
        monthly: { status: "rate-limited", percent: 100, resetsAt: "2026-09-18T21:13:14.147Z" },
      } });
    });
    const owner = new ProviderUsageOwner({ fetch });
    const result = await owner.read(shapedRuntime("opencode-go", openCodeGoShapes), "opencode-go");
    const snapshot = result.providers[0]!;
    expect(snapshot).toMatchObject({ providerId: "opencode-go", status: "available", scope: "account", source: "opencode-go.usage" });
    // The endpoint reports percents and resets only; amounts stay absent rather than invented.
    expect(snapshot.windows.map((item) => [item.id, item.usedPercent, item.windowSeconds, item.used, item.limit])).toEqual([
      ["rolling", 12.5, 18_000, null, null],
      ["weekly", 34, 604_800, null, null],
      ["monthly", 100, 2_592_000, null, null],
    ]);
    expect(fetch).toHaveBeenCalledTimes(1);
  });

  it("reports an OpenCode Go entitlement 403 as unsupported but still fences a rejected key", async () => {
    const notSubscribed = vi.fn(async () => response({ type: "error", error: { type: "EntitlementError", message: "OpenCode Go subscription required." } }, 403));
    const notSubscribedResult = await new ProviderUsageOwner({ fetch: notSubscribed, now: () => 1_700_000_000_000 }).read(shapedRuntime("opencode-go", openCodeGoShapes), "opencode-go");
    expect(notSubscribedResult.providers[0]).toMatchObject({ status: "unsupported", stale: false, windows: [], message: "This account has no OpenCode Go subscription" });

    const rejected = vi.fn(async () => response({ type: "error", error: { type: "AuthError", message: "Unauthorized" } }, 401));
    const rejectedResult = await new ProviderUsageOwner({ fetch: rejected }).read(shapedRuntime("opencode-go", openCodeGoShapes), "opencode-go");
    expect(rejectedResult.providers[0]).toMatchObject({ status: "authentication_required", windows: [] });
  });

  it("leaves OpenCode Go unsupported when its models resolve to another host", async () => {
    const fetch = vi.fn(async () => response({ usage: {} }));
    const owner = new ProviderUsageOwner({ fetch });
    const remapped = await owner.read(shapedRuntime("opencode-go", [{ api: "openai-completions", baseUrl: "https://proxy.example/v1" }]), "opencode-go");
    expect(remapped.providers[0]).toMatchObject({ status: "unsupported", windows: [] });
    const unexpectedApi = await owner.read(shapedRuntime("opencode-go", [{ api: "google-generative-ai", baseUrl: "https://opencode.ai/zen/go/v1" }]), "opencode-go");
    expect(unexpectedApi.providers[0]).toMatchObject({ status: "unsupported", windows: [] });
    expect(fetch).not.toHaveBeenCalled();
  });

  it("includes OpenCode Go in a global configured read without querying unrelated providers", async () => {
    const fetch = vi.fn(async (url: string) => {
      expect(url).toBe("https://opencode.ai/zen/go/v1/usage");
      return response({ usage: {
        rolling: { status: "ok", percent: 0, resetsAt: "2026-09-18T12:58:26.147Z" },
        weekly: { status: "ok", percent: 0, resetsAt: "2026-09-21T00:00:00.147Z" },
        monthly: { status: "ok", percent: 0, resetsAt: "2026-09-18T21:13:14.147Z" },
      } });
    });
    const result = await new ProviderUsageOwner({ fetch }).read(shapedRuntime("opencode-go", openCodeGoShapes));
    expect(result.providers.map((snapshot) => snapshot.providerId)).toEqual(["opencode-go"]);
    expect(fetch).toHaveBeenCalledTimes(1);
  });

  it("does not query overridden providers and lists only supported configured providers", async () => {
    const fetch = vi.fn(async () => response({ limit: 1, limit_remaining: 1 }));
    const owner = new ProviderUsageOwner({ fetch });
    const custom = await owner.read(runtime("openrouter", "https://proxy.example/v1"));
    expect(custom.providers).toEqual([]);
    expect(fetch).not.toHaveBeenCalled();
    const exact = await owner.read(runtime("openrouter", "https://openrouter.ai/api/v1"));
    expect(exact.providers).toHaveLength(1);
  });

  it("returns bounded ordinary statuses for missing auth and rate limits", async () => {
    const fetch = vi.fn(async () => response({}, 429, { "retry-after": "999999" }));
    const owner = new ProviderUsageOwner({ fetch, now: () => 1_700_000_000_000 });
    const missing = await owner.read(runtime("openrouter", "https://openrouter.ai/api/v1", null), "openrouter");
    expect(missing.providers[0]!.status).toBe("unconfigured");
    const limited = await owner.read(runtime("openrouter", "https://openrouter.ai/api/v1"), "openrouter");
    expect(limited.providers[0]).toMatchObject({ status: "rate_limited", retryAt: expect.any(String), stale: false });
    expect(fetch).toHaveBeenCalledTimes(1);
  });

  it("keeps raw credentials out of projections and rejects oversized bodies", async () => {
    const fetch = vi.fn(async () => response("x".repeat(512 * 1024 + 1)));
    const owner = new ProviderUsageOwner({ fetch });
    const result = await owner.read(runtime("openrouter", "https://openrouter.ai/api/v1"), "openrouter");
    expect(result.providers[0]).toMatchObject({ status: "unavailable", message: "Provider usage response was too large" });
    expect(JSON.stringify(result)).not.toContain("fixture-secret");
  });

  it("rejects null and malformed usage payloads with a retry fence", async () => {
    const fetch = vi.fn(async () => response(null));
    const owner = new ProviderUsageOwner({ fetch, now: () => 1_700_000_000_000 });
    const result = await owner.read(runtime("openrouter", "https://openrouter.ai/api/v1"), "openrouter");
    expect(result.providers[0]).toMatchObject({ status: "unavailable", message: "Provider usage response was malformed", retryAt: expect.any(String) });
  });

  it("coalesces reads without letting one cancelled waiter abort the shared request", async () => {
    let release!: () => void;
    const fetch = vi.fn(() => new Promise<Response>((resolve) => { release = () => resolve(response({ limit: 2, limit_remaining: 1 })); }));
    const owner = new ProviderUsageOwner({ fetch });
    const fixture = runtime("openrouter", "https://openrouter.ai/api/v1");
    const cancelled = new AbortController();
    const first = owner.read(fixture, "openrouter", cancelled.signal);
    const second = owner.read(fixture, "openrouter");
    await waitFor(() => fetch.mock.calls.length === 1);
    expect(fetch).toHaveBeenCalledTimes(1);
    cancelled.abort();
    await expect(first).rejects.toMatchObject({ name: "AbortError" });
    release();
    await expect(second).resolves.toMatchObject({ providers: [{ status: "available" }] });
    expect(fetch).toHaveBeenCalledTimes(1);
  });

  it("fences an account switch that occurs while the provider socket is pending", async () => {
    let release!: () => void;
    const fetch = vi.fn(() => new Promise<Response>((resolve) => { release = () => resolve(response({ limit: 2, limit_remaining: 1 })); }));
    const fixture = runtime("openrouter", "https://openrouter.ai/api/v1");
    fixture.getAuth.mockResolvedValueOnce({ auth: { apiKey: "old-account" } }).mockResolvedValue({ auth: { apiKey: "new-account" } });
    const owner = new ProviderUsageOwner({ fetch });
    const pending = owner.read(fixture, "openrouter");
    await waitFor(() => typeof release === "function");
    release();
    const observed = await pending;
    expect(observed).toMatchObject({ providers: [{ status: "unavailable", stale: false, windows: [], message: "Provider usage changed while the request was in flight" }] });
    expect(JSON.stringify(observed)).not.toContain("old-account");
  });

  it("does not publish cached windows after logout invalidates the auth identity", async () => {
    const fetch = vi.fn(async () => response({ data: { limit: 10, limit_remaining: 3 } }));
    const owner = new ProviderUsageOwner({ fetch });
    const fixture = runtime("openrouter", "https://openrouter.ai/api/v1");
    await expect(owner.read(fixture, "openrouter")).resolves.toMatchObject({ providers: [{ status: "available" }] });
    fixture.getAuth.mockResolvedValue(undefined);
    await expect(owner.read(fixture, "openrouter")).resolves.toMatchObject({ providers: [{ status: "unconfigured", windows: [], stale: false }] });
    expect(fetch).toHaveBeenCalledTimes(1);
  });

  it("revalidates the complete provider binding before dispatching a credential", async () => {
    let releaseAuth!: (value: unknown) => void;
    let baseUrl = "https://openrouter.ai/api/v1";
    const auth = new Promise((resolve) => { releaseAuth = resolve; });
    const fetch = vi.fn(async () => response({ data: { limit: 1, limit_remaining: 1 } }));
    const fixture = {
      getModels: () => [model("openrouter", "https://openrouter.ai/api/v1")],
      getAuth: vi.fn(() => auth),
      getProvider: () => ({ baseUrl, auth: {} }),
      hasConfiguredAuth: () => true,
    } as any;
    const owner = new ProviderUsageOwner({ fetch });
    const pending = owner.read(fixture, "openrouter");
    baseUrl = "https://proxy.example/v1";
    releaseAuth({ auth: { apiKey: "fixture-key" } });
    await expect(pending).resolves.toMatchObject({ providers: [{ status: "unsupported", windows: [] }] });
    expect(fetch).not.toHaveBeenCalled();
  });

  it("normalizes zero limits and exposes a cached-success rate-limit status", async () => {
    const zeroShapes = [
      { id: "kimi-coding", base: "https://api.kimi.com/coding", api: "anthropic-messages", body: { usage: { used: 0, limit: 0, remaining: 0 } } },
      { id: "zai", base: "https://api.z.ai/api/coding/paas/v4", api: "openai-completions", body: { data: { limits: [{ name: "Quota", currentValue: 0, limit: 0, remaining: 0 }] } } },
    ] as const;
    for (const fixture of zeroShapes) {
      const fetch = vi.fn(async () => response(fixture.body));
      const owner = new ProviderUsageOwner({ fetch });
      const result = await owner.read(runtime(fixture.id, fixture.base, undefined, fixture.api), fixture.id);
      expect(result.providers[0]!.status).toBe("available");
      expect(result.providers[0]!.windows[0]!.limit).toBeNull();
    }

    let now = 1_700_000_000_000;
    const fetch = vi.fn()
      .mockResolvedValueOnce(response({ data: { limit: 10, limit_remaining: 3 } }))
      .mockResolvedValueOnce(response({}, 429, { "retry-after": "60" }));
    const owner = new ProviderUsageOwner({ fetch, now: () => now });
    const fixture = runtime("openrouter", "https://openrouter.ai/api/v1");
    await owner.read(fixture, "openrouter");
    now += 60_001;
    const limited = await owner.read(fixture, "openrouter");
    expect(limited.providers[0]).toMatchObject({ status: "rate_limited", stale: true, retryAt: expect.any(String) });
    expect(limited.providers[0]!.windows[0]!.used).toBe(7);
  });

  it("retains physical read admission after cancelled waiters until the shared fetch settles", async () => {
    let release!: () => void;
    const fetch = vi.fn(() => new Promise<Response>((resolve) => { release = () => resolve(response({ limit: 2, limit_remaining: 1 })); }));
    const owner = new ProviderUsageOwner({ fetch });
    const fixture = runtime("openrouter", "https://openrouter.ai/api/v1");
    const controllers = Array.from({ length: 16 }, () => new AbortController());
    const reads = controllers.map((controller) => owner.read(fixture, "openrouter", controller.signal));
    await waitFor(() => typeof release === "function");
    controllers.forEach((controller) => controller.abort());
    await expect(owner.read(fixture, "openrouter")).resolves.toMatchObject({ providers: [{ status: "unavailable", message: "Provider usage is busy" }] });
    release();
    await Promise.all(reads.map((read) => read.catch(() => undefined)));
    expect(fetch).toHaveBeenCalledTimes(1);
  });
});
