import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import type { Credential, CredentialInfo, CredentialStore } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../transport/gateway-service.js";
import { ModelQueueOwner } from "./model-queue.js";
import { createProviderModelRuntime } from "./provider-runtime.js";
import { ProviderUsageOwner } from "./provider-usage.js";

const client = { id: "provider-usage", identity: "device:provider-usage", isLocal: false, isSubscribed: () => false, isRevoked: () => false, revokeDevice: () => {} } as unknown as ClientContext;
const usageBody = {
  usage: {
    rolling: { status: "ok", percent: 12, resetsAt: "2026-10-15T23:30:33.247Z" },
    weekly: { status: "ok", percent: 34, resetsAt: "2026-10-19T00:00:00.000Z" },
    monthly: { status: "rate-limited", percent: 100, resetsAt: "2026-10-18T21:13:08.000Z" },
  },
};
// Shape of the remote catalog pi.dev served for opencode-go on 2026-10-15:
// every model moved from opencode.ai/zen/go to opencode.ai/inference/go, and a
// google-generative-ai model joined the three existing wire APIs.
const refreshedCatalog = [
  { id: "glm-5.3", api: "openai-completions", baseUrl: "https://opencode.ai/inference/go/v1" },
  { id: "minimax-m3", api: "anthropic-messages", baseUrl: "https://opencode.ai/inference/go" },
  { id: "gpt-6-luna", api: "openai-responses", baseUrl: "https://opencode.ai/inference/go/v1" },
  { id: "gemini-4-argon-contributor", api: "google-generative-ai", baseUrl: "https://opencode.ai/inference/go/v1" },
].map((model) => ({
  ...model, name: model.id, provider: "opencode-go", type: "chat", reasoning: true, input: ["text"],
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 200_000, maxTokens: 32_000,
}));

class OpenCodeGoKey implements CredentialStore {
  private readonly credential: Credential = { type: "api_key", key: "opencode-go-test-key" };
  async read(providerId: string) { return providerId === "opencode-go" ? this.credential : undefined; }
  async list(): Promise<readonly CredentialInfo[]> { return [{ providerId: "opencode-go", type: "api_key" }]; }
  async modify(providerId: string, fn: (current: Credential | undefined) => Promise<Credential | undefined>) {
    return providerId === "opencode-go" ? fn(this.credential) : undefined;
  }
  async delete() {}
}

describe("provider usage across a model catalog refresh", () => {
  let root = "";
  let service: GatewayService | undefined;
  afterEach(async () => {
    service?.dispose();
    service = undefined;
    vi.unstubAllEnvs();
    vi.restoreAllMocks();
    if (root) await rm(root, { recursive: true, force: true });
    root = "";
  });

  it("keeps OpenCode Go usage supported after the catalog moves its models to opencode.ai/inference/go", async () => {
    root = await mkdtemp(join(tmpdir(), "gateway-provider-usage-"));
    vi.stubEnv("PI_OFFLINE", undefined);
    const catalogRequests: string[] = [];
    const realFetch = globalThis.fetch;
    // The runtime and the release-date catalog read upstream through global
    // fetch; answer the pi.dev catalog with the refreshed shape and keep every
    // other upstream offline.
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const url = new URL(input instanceof Request ? input.url : String(input));
      if (url.hostname === "pi.dev") {
        catalogRequests.push(url.pathname);
        if (url.pathname === "/api/models/providers/opencode-go") {
          return new Response(JSON.stringify(refreshedCatalog), {
            headers: { "content-type": "application/json", etag: "\"refreshed\"", "last-modified": new Date().toUTCString() },
          });
        }
        return new Response("not found", { status: 404 });
      }
      if (url.hostname === "127.0.0.1") return realFetch(input, init);
      return new Response("offline", { status: 503 });
    });
    const usageRequests: Array<{ url: string; authorization: string | null }> = [];
    const providerUsage = new ProviderUsageOwner({ fetch: async (input, init) => {
      usageRequests.push({ url: String(input), authorization: new Headers(init?.headers).get("authorization") });
      return new Response(JSON.stringify(usageBody), { headers: { "content-type": "application/json" } });
    } });
    const runtime = await ModelRuntime.create({
      modelsPath: join(root, "agent", "models.json"),
      modelsStorePath: join(root, "agent", "models-store.json"),
      refreshOnCreate: true,
      allowModelNetwork: false,
      credentials: new OpenCodeGoKey(),
    });
    service = new GatewayService({ display: {} as never,
      config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome: root },
      modelRuntime: runtime,
      broadcast: () => {},
      providerUsage,
      globalProviderResources: { withStableSnapshot: async (operation: () => Promise<unknown>) => operation() },
      sessions: { recentModelUsage: () => [] },
      receipts: { execute: async (_identity: string, _method: string, _commandId: string, operation: () => Promise<unknown>) => operation(), status: async () => undefined },
    } as unknown as GatewayServiceDependencies);

    const usageSupported = async () => {
      const list = await service!.invoke(client, "provider.list", {}) as { providers: Array<{ id: string; usageSupported: boolean }> };
      return list.providers.find((provider) => provider.id === "opencode-go")?.usageSupported;
    };
    expect(await usageSupported()).toBe(true);

    // Settings › Providers › Model Catalog › Refresh.
    const refresh = await service.invoke(client, "models.refresh", { commandId: "refresh-catalog", force: true }) as { errors: Record<string, string> };
    expect(catalogRequests).toContain("/api/models/providers/opencode-go");
    expect(refresh.errors["opencode-go"]).toBeUndefined();
    expect(runtime.getModels("opencode-go").map((model) => model.baseUrl)).toContain("https://opencode.ai/inference/go");

    expect(await usageSupported()).toBe(true);
    const usage = await service.invoke(client, "provider.usage", { providerId: "opencode-go" }) as { providers: Array<Record<string, unknown>> };
    expect(usage.providers).toMatchObject([{
      providerId: "opencode-go", status: "available", source: "opencode-go.usage", scope: "account",
      // iOS names each window by its duration and shows every distinct one, so
      // the exhausted monthly limit (#1163) must arrive with its cadence and reset.
      windows: [
        { id: "rolling", label: "5h", usedPercent: 12, windowSeconds: 18_000 },
        { id: "weekly", label: "Weekly", usedPercent: 34, windowSeconds: 604_800 },
        { id: "monthly", label: "Monthly", usedPercent: 100, windowSeconds: 2_592_000, resetsAt: "2026-10-18T21:13:08.000Z" },
      ],
    }]);
    expect(usageRequests).toEqual([{ url: "https://opencode.ai/zen/go/v1/usage", authorization: "Bearer opencode-go-test-key" }]);
  });
  it("classifies OpenCode Go usage refusals by their error type and never lets a refused read skip a queue model", async () => {
    root = await mkdtemp(join(tmpdir(), "gateway-provider-usage-"));
    // Live 2026-10-19 answers of GET /zen/go/v1/usage, plus forbidden shapes that
    // are not an entitlement refusal (an edge/WAF page, another error type).
    const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
    const answers: Record<string, () => Response> = {
      entitlement: () => json(403, { type: "error", error: { type: "EntitlementError", message: "OpenCode Go subscription required." } }),
      forbiddenAuth: () => json(403, { type: "error", error: { type: "AuthError", message: "Unauthorized" } }),
      rejectedKey: () => json(401, { type: "error", error: { type: "AuthError", message: "Unauthorized" } }),
      otherForbidden: () => json(403, { type: "error", error: { type: "RegionError", message: "Not available in this region" } }),
      edgePage: () => new Response("<html><body>Access denied</body></html>", { status: 403, headers: { "content-type": "text/html" } }),
      limited: () => json(429, { type: "error", error: { type: "GoUsageLimitError", message: "Go usage limit exceeded" } }),
      exhausted: () => json(200, usageBody),
    };
    let answer = "entitlement";
    let clock = Date.parse("2026-10-19T06:00:00.000Z");
    const providerUsage = new ProviderUsageOwner({ now: () => clock, fetch: async () => answers[answer]!() });
    const runtime = await ModelRuntime.create({
      modelsPath: join(root, "agent", "models.json"),
      modelsStorePath: join(root, "agent", "models-store.json"),
      refreshOnCreate: false,
      allowModelNetwork: false,
      credentials: new OpenCodeGoKey(),
    });
    const model = `opencode-go/${runtime.getModels("opencode-go")[0]!.id}`;
    const queue = new ModelQueueOwner({ runtime, usage: providerUsage, queue: async () => [model], now: () => clock });
    service = new GatewayService({ display: {} as never,
      config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome: root },
      modelRuntime: runtime,
      broadcast: () => {},
      providerUsage,
      globalProviderResources: { withStableSnapshot: async (operation: () => Promise<unknown>) => operation() },
      sessions: { recentModelUsage: () => [] },
      receipts: { execute: async (_identity: string, _method: string, _commandId: string, operation: () => Promise<unknown>) => operation(), status: async () => undefined },
    } as unknown as GatewayServiceDependencies);

    const observe = async (next: string) => {
      answer = next;
      clock += 31_000; // past the 30 s negative-result retry, so each answer is a fresh read
      const usage = await service!.invoke(client, "provider.usage", { providerId: "opencode-go" }) as { providers: Array<{ status: string; message: string | null }> };
      const { status, message } = usage.providers[0]!;
      const [entry] = (await queue.availability("subagent")).models;
      return { status, message, skipped: entry!.available ? null : entry!.reason };
    };

    const noSubscription = "OpenCode Go reports no active Go subscription for this account";
    expect(await observe("entitlement")).toEqual({ status: "unsupported", message: noSubscription, skipped: null });
    // Only OpenCode's own entitlement refusal states a subscription fact.
    expect(await observe("forbiddenAuth")).toEqual({ status: "authentication_required", message: "Provider authentication was rejected", skipped: null });
    expect(await observe("rejectedKey")).toEqual({ status: "authentication_required", message: "Provider authentication was rejected", skipped: null });
    expect(await observe("otherForbidden")).toEqual({ status: "unavailable", message: "OpenCode Go refused the usage request", skipped: null });
    expect(await observe("edgePage")).toEqual({ status: "unavailable", message: "OpenCode Go refused the usage request", skipped: null });
    expect(await observe("limited")).toEqual({ status: "rate_limited", message: "Provider usage is temporarily rate limited", skipped: null });
    // Quota exhaustion is a readable window at 100%, the one usage state that skips.
    expect(await observe("exhausted")).toEqual({ status: "available", message: null, skipped: "Monthly usage 100%" });
  });

  it("reads Anthropic's account weekly window without an inactive per-model limit and keeps active ones", async () => {
    const oauth: Credential = { type: "oauth", access: "anthropic-test-token", refresh: "refresh", expires: Date.now() + 3_600_000 };
    const credentials: CredentialStore = {
      read: async (providerId) => providerId === "anthropic" ? oauth : undefined,
      list: async () => [{ providerId: "anthropic", type: "oauth" }],
      modify: async (providerId, fn) => providerId === "anthropic" ? fn(oauth) : undefined,
      delete: async () => {},
    };
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: true, allowModelNetwork: false, credentials });
    const weeklyAll = { kind: "weekly_all", group: "weekly", percent: 0, is_active: true, scope: null, resets_at: "2026-11-09T00:00:00Z" };
    const scoped = (name: string, id: string | null, percent: number, active: boolean) =>
      ({ kind: "weekly_scoped", group: "weekly", percent, is_active: active, scope: { model: { display_name: name, id } }, resets_at: "2026-11-09T00:00:00Z" });
    // Live 2026-11 shape of /api/oauth/usage for an Ultra plan: no 5h window,
    // and an inactive "Fable" share beside the account's weekly limit.
    let body: unknown = { five_hour: null, seven_day: { utilization: 0, resets_at: "2026-11-09T00:00:00Z" }, limits: [weeklyAll, scoped("Fable", null, 0, false)] };
    let clock = Date.parse("2026-11-02T12:00:00Z");
    const providerUsage = new ProviderUsageOwner({ now: () => clock, fetch: async () => new Response(JSON.stringify(body), { headers: { "content-type": "application/json" } }) });
    const windows = async () => {
      clock += 3_600_000; // past any cached answer
      const [snapshot] = (await providerUsage.read(runtime, "anthropic")).providers;
      expect(snapshot).toMatchObject({ providerId: "anthropic", status: "available", message: null });
      return snapshot!.windows.map(({ id, label, usedPercent, windowSeconds }) => ({ id, label, usedPercent, windowSeconds }));
    };
    expect(await windows()).toEqual([{ id: "seven-day", label: "Weekly", usedPercent: 0, windowSeconds: 604_800 }]);

    // An active per-model limit still reaches the detail sheet.
    body = { five_hour: { utilization: 12 }, seven_day: { utilization: 30 }, limits: [weeklyAll, scoped("Opus", "claude-opus", 45, true), scoped("Fable", null, 0, false)] };
    expect(await windows()).toEqual([
      { id: "five-hour", label: "5h", usedPercent: 12, windowSeconds: 18_000 },
      { id: "seven-day", label: "Weekly", usedPercent: 30, windowSeconds: 604_800 },
      { id: "weekly-claude-opus", label: "Opus only", usedPercent: 45, windowSeconds: 604_800 },
    ]);
  });

  it("does not infer rejected credentials from an unrelated 403 type containing unauthorized prose", async () => {
    root = await mkdtemp(join(tmpdir(), "gateway-usage-unrelated-403-"));
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false,
      allowModelNetwork: false, credentials: new OpenCodeGoKey() });
    const providerUsage = new ProviderUsageOwner({ fetch: async () => new Response(
      JSON.stringify({ error: { type: "RegionError", message: "Unauthorized region" } }),
      { status: 403, headers: { "content-type": "application/json" } }
    ) });
    service = new GatewayService({ display: {} as never,
      config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome: root },
      modelRuntime: runtime, broadcast: () => {}, providerUsage,
      globalProviderResources: { withStableSnapshot: async (operation: () => Promise<unknown>) => operation() },
      sessions: { recentModelUsage: () => [] },
      receipts: { execute: async (_identity: string, _method: string, _commandId: string, operation: () => Promise<unknown>) => operation(), status: async () => undefined },
    } as unknown as GatewayServiceDependencies);
    expect(await service.invoke(client, "provider.usage", { providerId: "opencode-go" })).toMatchObject({
      providers: [{ status: "unavailable", message: "OpenCode Go refused the usage request" }],
    });
  });
});

/** Pi's auth.json with one Anthropic subscription login (synthetic values), as Pi's OAuth login writes it. */
async function writePiAnthropicLogin(agentDir: string, login: { access: string; refresh: string; expires: number }) {
  await writeFile(join(agentDir, "auth.json"), JSON.stringify({ anthropic: { type: "oauth", ...login } }, null, 2), { mode: 0o600 });
}
function piAnthropicLogin(agentDir: string): Promise<{ type: string; access: string; refresh: string; expires: number }> {
  return readFile(join(agentDir, "auth.json"), "utf8").then((text) => JSON.parse(text).anthropic);
}

describe("Anthropic usage under Pi's built-in OAuth", () => {
  let root = "";
  let service: GatewayService | undefined;
  afterEach(async () => {
    service?.dispose();
    service = undefined;
    vi.restoreAllMocks();
    if (root) await rm(root, { recursive: true, force: true });
    root = "";
  });

  it("reads the usage bearer from Pi's auth.json, lets Pi refresh it once, and never reads retired CortexKit files", async () => {
    root = await mkdtemp(join(tmpdir(), "gateway-anthropic-oauth-usage-"));
    const agentDir = join(root, "agent");
    await mkdir(agentDir, { recursive: true });
    await writePiAnthropicLogin(agentDir, { access: "sk-ant-oat01-first", refresh: "sk-ant-ort01-first", expires: Date.now() + 3_600_000 });
    // Files a CortexKit 1.x/2.x install leaves beside auth.json. Their tokens must never be sent.
    await writeFile(join(agentDir, "anthropic-auth.json"), JSON.stringify({ version: 1, mainAccountId: "main", main: { type: "opencode", provider: "anthropic" }, accounts: [] }));
    await writeFile(join(agentDir, "anthropic-auth-pool.json"), JSON.stringify({ version: 1, mainAccountId: "main", accounts: [{ id: "main", type: "oauth", addedAt: 1 }], claustrum: { mode: "local" } }));
    await writeFile(join(agentDir, "anthropic-auth-pool-state.json"), JSON.stringify({ version: 1,
      accounts: { main: { access: "sk-ant-oat01-retired-pool", refresh: "sk-ant-ort01-retired-pool", expires: Date.now() + 3_600_000 } } }));
    // Pi refreshes through global fetch; the usage owner reads through its own fetch.
    const tokenRequests: Array<Record<string, unknown>> = [];
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const url = String(input instanceof Request ? input.url : input);
      if (url === "https://platform.claude.com/v1/oauth/token") {
        tokenRequests.push(JSON.parse(String(init?.body)) as Record<string, unknown>);
        await new Promise((resolve) => setTimeout(resolve, 20)); // a refresh in flight while the other reader arrives
        return new Response(JSON.stringify({ access_token: "sk-ant-oat01-second", refresh_token: "sk-ant-ort01-second", expires_in: 28_800 }),
          { headers: { "content-type": "application/json" } });
      }
      return new Response("offline", { status: 503 });
    });
    const runtime = await createProviderModelRuntime(agentDir);
    let clock = Date.parse("2026-11-09T12:00:00Z");
    const requests: Array<{ url: string; authorization: string | null; beta: string | null }> = [];
    // Live 2026-11 Ultra shape of /api/oauth/usage.
    const body = { five_hour: null, seven_day: { utilization: 10, resets_at: "2026-11-16T05:00:00Z" }, limits: [], extra_usage: { is_enabled: false } };
    const providerUsage = new ProviderUsageOwner({ now: () => clock, fetch: async (input, init) => {
      const headers = new Headers(init?.headers);
      requests.push({ url: String(input), authorization: headers.get("authorization"), beta: headers.get("anthropic-beta") });
      return new Response(JSON.stringify(body), { headers: { "content-type": "application/json" } });
    } });
    service = new GatewayService({ display: {} as never,
      config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome: root },
      modelRuntime: runtime,
      broadcast: () => {},
      providerUsage,
      globalProviderResources: { withStableSnapshot: async (operation: () => Promise<unknown>) => operation() },
      sessions: { recentModelUsage: () => [] },
      receipts: { execute: async (_identity: string, _method: string, _commandId: string, operation: () => Promise<unknown>) => operation(), status: async () => undefined },
    } as unknown as GatewayServiceDependencies);

    const list = await service.invoke(client, "provider.list", {}) as { providers: Array<{ id: string; name: string; usageSupported: boolean }> };
    expect(list.providers.find((provider) => provider.id === "anthropic")).toMatchObject({ name: "Anthropic", usageSupported: true });
    const usage = async () => {
      clock += 61_000; // past the 60 s usage cache
      return (await service!.invoke(client, "provider.usage", { providerId: "anthropic" }) as { providers: Array<Record<string, unknown>> }).providers[0];
    };
    expect(await usage()).toMatchObject({
      providerId: "anthropic", status: "available", source: "anthropic.oauth-usage", scope: "account",
      windows: [{ id: "seven-day", label: "Weekly", usedPercent: 10, windowSeconds: 604_800 }],
    });
    expect(requests).toEqual([{ url: "https://api.anthropic.com/api/oauth/usage", authorization: "Bearer sk-ant-oat01-first", beta: "oauth-2025-04-20" }]);
    expect(tokenRequests).toEqual([]);

    // Inside Pi's five-minute validity margin: the usage read and a chat request's
    // auth resolve together, and Pi's locked refresh rotates the login exactly once.
    await writePiAnthropicLogin(agentDir, { access: "sk-ant-oat01-first", refresh: "sk-ant-ort01-first", expires: Date.now() + 60_000 });
    requests.length = 0;
    const [snapshot, chat] = await Promise.all([usage(), runtime.getAuth("anthropic")]);
    expect(tokenRequests).toEqual([expect.objectContaining({ grant_type: "refresh_token", refresh_token: "sk-ant-ort01-first" })]);
    expect(chat?.auth.apiKey).toBe("sk-ant-oat01-second");
    expect(snapshot).toMatchObject({ providerId: "anthropic", status: "available" });
    expect(requests.map((request) => request.authorization)).toEqual(["Bearer sk-ant-oat01-second"]);
    expect(await piAnthropicLogin(agentDir)).toMatchObject({ type: "oauth", access: "sk-ant-oat01-second", refresh: "sk-ant-ort01-second" });
  });
});
