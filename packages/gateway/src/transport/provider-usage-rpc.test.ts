import { describe, expect, it, vi } from "vitest";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "./gateway-service.js";

const client: ClientContext = {
  id: "phone", identity: "device:phone", isLocal: false, signal: undefined,
  beginSynchronization: () => "sync", establishSynchronization: () => {}, completeSynchronization: () => {},
  setPresentationVisibility: () => ({ visible: true, revision: 1 }), unsubscribe: () => false,
  attachTerminal: () => {}, detachTerminal: () => {}, ownsTerminal: () => false,
  isSubscribed: () => true, isRevoked: () => false, revokeDevice: () => {},
};

describe("provider.usage RPC", () => {
  it("advertises the additive capability and passes the selected runtime", async () => {
    const read = vi.fn(async (_runtime: unknown, providerId?: string) => ({ providers: [{ providerId: providerId ?? "openrouter", status: "available", source: "fixture", scope: "key", updatedAt: null, retryAt: null, stale: false, message: null, windows: [], balances: [] }] }));
    const runtime = {};
    const service = new GatewayService({
      config: { machineId: "machine", machineName: "Mac", tronHome: "/tmp/tron-usage-rpc" },
      modelRuntime: runtime,
      sessions: { isAdministrativeDrainStarted: false },
      providerUsage: { read },
      globalProviderResources: { withStableSnapshot: (operation: () => Promise<unknown>) => operation() },
    } as unknown as GatewayServiceDependencies);
    expect((service.info() as { capabilities: string[] }).capabilities).toContain("provider-usage.v1");
    await expect(service.invoke(client, "provider.usage", { providerId: "openrouter" })).resolves.toMatchObject({ providers: [{ providerId: "openrouter" }] });
    expect(read).toHaveBeenCalledWith(runtime, "openrouter", undefined);
  });

  it("rejects unknown fields and requires an open session for session-scoped reads", async () => {
    const read = vi.fn(async () => ({ providers: [] }));
    const service = new GatewayService({ modelRuntime: {}, providerUsage: { read }, sessions: { isAdministrativeDrainStarted: false } } as unknown as GatewayServiceDependencies);
    await expect(service.invoke(client, "provider.usage", { unexpected: true })).rejects.toMatchObject({ code: "invalid_request" });
    await expect(service.invoke({ ...client, isSubscribed: () => false }, "provider.usage", { sessionId: "closed" })).rejects.toMatchObject({ code: "invalid_request" });
    expect(read).not.toHaveBeenCalled();
  });
});

describe("provider.list usage support", () => {
  const goModels = [
    { provider: "opencode-go", id: "a", api: "anthropic-messages", baseUrl: "https://opencode.ai/zen/go" },
    { provider: "opencode-go", id: "b", api: "openai-completions", baseUrl: "https://opencode.ai/zen/go/v1" },
    { provider: "opencode-go", id: "c", api: "openai-responses", baseUrl: "https://opencode.ai/zen/go/v1" },
  ];
  const anthropicModels = [
    { provider: "anthropic", id: "claude-opus-5-5", api: "cortexkit-anthropic-messages", baseUrl: "https://api.anthropic.com" },
  ];
  const ollamaModels = [
    { provider: "ollama", id: "llama3", api: "openai-completions", baseUrl: "http://127.0.0.1:11434/v1" },
  ];
  const openaiModels = [{ provider: "openai", id: "gpt-test", api: "openai-responses", baseUrl: "https://api.openai.com/v1" }];
  const codexModels = [{ provider: "openai-codex", id: "gpt-codex-test", api: "openai-codex-responses", baseUrl: "https://chatgpt.com/backend-api" }];
  let anthropicOAuth = true;
  let openaiOAuth = false;
  const runtime = {
    getProviders: () => [
      { id: "opencode-go", name: "OpenCode Go", auth: { apiKey: {} }, baseUrl: undefined, getModels: () => goModels },
      { id: "anthropic", name: "Anthropic (CortexKit)", auth: { apiKey: {}, oauth: {} }, baseUrl: undefined, getModels: () => anthropicModels },
      { id: "ollama", name: "Ollama", auth: { apiKey: {} }, baseUrl: undefined, getModels: () => ollamaModels },
      { id: "openai", name: "OpenAI", auth: { apiKey: { login: () => {} }, oauth: {} }, baseUrl: undefined, getModels: () => openaiModels },
      { id: "openai-codex", name: "OpenAI Codex (legacy)", auth: { oauth: {} }, baseUrl: undefined, getModels: () => codexModels },
    ],
    getModels: (id: string) => id === "opencode-go" ? goModels : id === "anthropic" ? anthropicModels : id === "ollama" ? ollamaModels : id === "openai" ? openaiModels : id === "openai-codex" ? codexModels : [],
    getProvider: (id: string) => ({ id, baseUrl: undefined, auth: { apiKey: {}, oauth: id === "anthropic" || id === "openai" || id === "openai-codex" ? {} : undefined } }),
    isUsingOAuth: (id: string) => (id === "anthropic" && anthropicOAuth) || (id === "openai" && openaiOAuth) || id === "openai-codex",
    hasConfiguredAuth: () => true,
    checkAuth: async () => ({ source: "stored" }),
    listCredentials: async () => [{ providerId: "opencode-go", type: "api_key" }, { providerId: "anthropic", type: "oauth" }],
  };

  it("marks only first-party composed providers as usage-supported", async () => {
    const service = new GatewayService({
      modelRuntime: runtime,
      sessions: { isAdministrativeDrainStarted: false },
      globalProviderResources: { withStableSnapshot: (read: () => Promise<unknown>) => read() },
    } as unknown as GatewayServiceDependencies);
    const result = await service.invoke(client, "provider.list", {}) as { providers: Array<{ id: string; usageSupported: boolean; localOnly: boolean }> };
    expect(result.providers).toEqual([
      expect.objectContaining({ id: "opencode-go", usageSupported: true, localOnly: false }),
      expect.objectContaining({ id: "anthropic", usageSupported: true, localOnly: false, credentialType: "oauth" }),
      // Loopback-only models are unmetered, so the row is local rather than usage-backed.
      expect.objectContaining({ id: "ollama", usageSupported: false, localOnly: true }),
      expect.objectContaining({ id: "openai", name: "OpenAI", usageSupported: false, authMethods: ["api_key", "oauth"] }),
      expect.objectContaining({ id: "openai-codex", name: "OpenAI Codex (legacy)", authMethods: ["oauth"] }),
    ]);
    anthropicOAuth = false;
    openaiOAuth = false;
    const apiKeyResult = await service.invoke(client, "provider.list", {}) as { providers: Array<{ id: string; usageSupported: boolean }> };
    expect(apiKeyResult.providers.find((provider) => provider.id === "anthropic")).toMatchObject({ usageSupported: false });
  });

  it("names the provider that presents the Codex login's usage only while OpenAI uses ChatGPT OAuth", async () => {
    // Clients hide a lender row whose usage another configured row presents; an
    // API-key or absent OpenAI login must leave the Codex row as it is.
    const service = new GatewayService({
      modelRuntime: runtime,
      sessions: { isAdministrativeDrainStarted: false },
      globalProviderResources: { withStableSnapshot: (read: () => Promise<unknown>) => read() },
    } as unknown as GatewayServiceDependencies);
    const lentTo = async () => {
      const result = await service.invoke(client, "provider.list", {}) as { providers: Array<{ id: string; usageSupported: boolean; usageLentTo: string | null }> };
      return Object.fromEntries(result.providers.map((provider) => [provider.id, [provider.usageSupported, provider.usageLentTo]]));
    };
    openaiOAuth = false;
    expect(await lentTo()).toMatchObject({ openai: [false, null], "openai-codex": [true, null] });
    openaiOAuth = true;
    expect(await lentTo()).toMatchObject({ openai: [true, null], "openai-codex": [true, "openai"], anthropic: [expect.any(Boolean), null] });
    openaiOAuth = false;
  });
});
