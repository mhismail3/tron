import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { CommandReceiptStore } from "./command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "./gateway-service.js";

const client = {
  id: "phone", identity: "device:context-test", isLocal: false,
  isSubscribed: (sessionId: string) => sessionId === "owned",
  isRevoked: () => false,
  revokeDevice: () => {},
} as ClientContext;

describe("context window transport", () => {
  const roots: string[] = [];
  afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });

  it("requires the exact open subscription and preserves command receipt idempotency", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-context-rpc-"));
    roots.push(root);
    const setContextWindow = vi.fn(async () => {});
    const acquire = vi.fn(async () => ({ setContextWindow }));
    const isSubscribed = vi.fn((_client: string, id: string) => id === "owned");
    const service = new GatewayService({ receipts: new CommandReceiptStore(root), sessions: { isSubscribed, acquire } } as unknown as GatewayServiceDependencies);
    const params = { sessionId: "owned", provider: "openai-codex", modelId: "gpt-6-astra", contextWindow: 1_050_000, expectedRevision: 7, expectedRuntimeGeneration: "generation-1", commandId: "context-change-1" };
    await Promise.all([service.invoke(client, "session.setContextWindow", params), service.invoke(client, "session.setContextWindow", params)]);
    expect(setContextWindow).toHaveBeenCalledExactlyOnceWith("openai-codex", "gpt-6-astra", 1_050_000, 7, "generation-1");
    await service.invoke(client, "session.setContextWindow", { ...params, contextWindow: null, commandId: "context-reset-1" });
    expect(setContextWindow).toHaveBeenLastCalledWith("openai-codex", "gpt-6-astra", null, 7, "generation-1");
    await expect(service.invoke(client, "session.setContextWindow", { ...params, sessionId: "unopened", commandId: "context-change-2" })).rejects.toMatchObject({ code: "invalid_request" });
    expect(acquire).toHaveBeenCalledTimes(2);
    for (const expectedRevision of [undefined, -1, 1.5, "7"]) {
      await expect(service.invoke(client, "session.setContextWindow", { ...params, expectedRevision, commandId: `bad-revision-${expectedRevision}` })).rejects.toMatchObject({ code: "invalid_request" });
    }
    await expect(service.invoke(client, "session.setContextWindow", { ...params, expectedRuntimeGeneration: undefined, commandId: "missing-generation" })).rejects.toMatchObject({ code: "invalid_request" });
    expect(setContextWindow).toHaveBeenCalledTimes(2);
    await expect(service.invoke(client, "session.setContextWindow", { ...params, commandId: undefined })).rejects.toMatchObject({ code: "invalid_request" });
  });

  it("projects supported capacity separately without changing catalog contextWindow", async () => {
    const model = { provider: "openai-codex", id: "gpt-6-astra", api: "openai-codex-responses", baseUrl: "https://chatgpt.com/backend-api", name: "Astra",
      contextWindow: 272_000, maxTokens: 128_000, reasoning: true, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } };
    const service = new GatewayService({
      config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome: "/tmp/tron-context-catalog" },
      modelRuntime: { getModels: () => [model], getAvailable: async () => [model] },
      globalProviderResources: { withStableSnapshot: async operation => operation() }, sessions: {},
    } as unknown as GatewayServiceDependencies);
    expect((service.info() as { capabilities: string[] }).capabilities).toContain("context-window.v1");
    await expect(service.invoke(client, "model.list", {})).resolves.toMatchObject({ models: [{
      contextWindow: 272_000, maxTokens: 128_000, contextWindowLimits: { minimum: 37_408, maximum: 1_050_000, default: 272_000 },
    }] });
  });

  it("publishes the SDK's Opus 5.5 capacity through model.list", async () => {
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    const service = new GatewayService({
      modelRuntime: runtime,
      globalProviderResources: { withStableSnapshot: async operation => operation() },
    } as unknown as GatewayServiceDependencies);
    const result = await service.invoke(client, "model.list", {}) as { models: Array<Record<string, unknown>> };
    expect(result.models.find(model => model.provider === "anthropic" && model.id === "claude-opus-5-5"))
      .toMatchObject({ contextWindow: 1_000_000, maxTokens: 128_000 });
  });

  it("admits project catalog validation only for a subscribed session in the requested cwd", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-context-project-rpc-"));
    roots.push(root);
    const update = vi.fn(async () => ({}));
    const runtime = {};
    const service = new GatewayService({
      receipts: new CommandReceiptStore(root), broadcast: () => {},
      settings: { update }, trust: { requireResolved: async (cwd: string) => ({ cwd, trusted: true }) },
      sessions: { isSubscribed: () => true, acquire: async () => ({ cwd: "/tmp/context-project", modelRuntime: runtime }) },
    } as unknown as GatewayServiceDependencies);
    const params = { commandId: "project-context-1", scope: "project", sessionId: "session", cwd: "/tmp/context-project", patch: { modelContextWindows: { "project/model": 100_000 } } };
    await service.invoke({ ...client, isSubscribed: () => true }, "settings.update", params);
    expect(update).toHaveBeenCalledWith(params.patch, { cwd: params.cwd, scope: "project", projectTrusted: true, modelRuntime: runtime });
    await expect(service.invoke({ ...client, isSubscribed: () => true }, "settings.update", { ...params, cwd: "/tmp/different-project", commandId: "project-context-2" })).rejects.toMatchObject({ code: "conflict" });
    expect(update).toHaveBeenCalledOnce();
  });
});
