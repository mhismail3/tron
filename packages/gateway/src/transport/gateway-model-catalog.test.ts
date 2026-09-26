import { describe, expect, it } from "vitest";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "./gateway-service.js";

const client = {
  id: "phone", identity: "device:model-catalog-test", isLocal: false,
  isSubscribed: () => false, isRevoked: () => false, revokeDevice: () => {},
} as ClientContext;

// Failure modes guarded here: the shared picker's Recent rail reads
// `model.recent` as one global preference list, and the Latest rail sorts on the
// optional `releaseDate` the catalog projects. A provider/id that has no
// snapshot entry must omit the field rather than invent a date.
describe("model catalog transport", () => {
  const dated = { provider: "anthropic", id: "claude-fable-5", api: "anthropic-messages", baseUrl: "https://api.anthropic.com", name: "Claude Fable 5",
    contextWindow: 200_000, maxTokens: 32_000, reasoning: true, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } };
  const undated = { provider: "custom-router", id: "local-model", api: "openai-responses", baseUrl: "http://127.0.0.1", name: "Local Model",
    contextWindow: 8_000, maxTokens: 1_000, reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } };
  const usage = [
    { provider: "anthropic", id: "claude-fable-5", lastUsedAt: "2026-09-25T12:00:00.000Z" },
    { provider: "custom-router", id: "local-model", lastUsedAt: "2026-09-24T12:00:00.000Z" },
  ];

  function service(): GatewayService {
    return new GatewayService({
      config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome: "/tmp/tron-model-catalog" },
      modelRuntime: { getModels: () => [dated, undated], getAvailable: async () => [dated] },
      globalProviderResources: { withStableSnapshot: async operation => operation() },
      sessions: { recentModelUsage: () => usage },
    } as unknown as GatewayServiceDependencies);
  }

  it("serves the newest-first global recency list without a session", async () => {
    await expect(service().invoke(client, "model.recent", {})).resolves.toEqual({ models: usage });
  });

  it("projects release dates only for snapshot-known models", async () => {
    const result = await service().invoke(client, "model.list", {}) as { models: Array<Record<string, unknown>> };
    const datedRow = result.models.find((model) => model.id === "claude-fable-5")!;
    const undatedRow = result.models.find((model) => model.id === "local-model")!;
    expect(datedRow.releaseDate).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    expect("releaseDate" in undatedRow).toBe(false);
  });
});
