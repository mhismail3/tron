import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import type { Credential, CredentialInfo, CredentialStore } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../transport/gateway-service.js";
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
    service = new GatewayService({
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
});
