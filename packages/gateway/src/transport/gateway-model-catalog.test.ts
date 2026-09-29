import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { CommandReceiptStore } from "./command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "./gateway-service.js";

const client = {
  id: "phone", identity: "device:model-catalog-test", isLocal: false,
  isSubscribed: () => false, isRevoked: () => false, revokeDevice: () => {},
} as unknown as ClientContext;

// Failure modes guarded here: the shared picker's Recent rail reads
// `model.recent` as one global preference list, and the Latest rail sorts on the
// optional `releaseDate` the catalog projects. A provider/id that has no
// snapshot entry must omit the field rather than invent a date. The release-date
// integration also guards refresh result/event behavior, restart persistence,
// refresh failure isolation and the no-network model.list boundary. Rail cards show
// input/output prices; a model whose SDK price is unset (all zero) must omit
// `cost` rather than advertise itself as free, and cache rates stay private.
describe("model catalog transport", () => {
  let root = "";
  afterEach(async () => {
    vi.unstubAllGlobals();
    if (root) await rm(root, { recursive: true, force: true });
    root = "";
  });
  const dated = { provider: "anthropic", id: "claude-fable-5", api: "anthropic-messages", baseUrl: "https://api.anthropic.com", name: "Claude Fable 5",
    contextWindow: 200_000, maxTokens: 32_000, reasoning: true, input: ["text"], cost: { input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5 } };
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
      globalProviderResources: { withStableSnapshot: async (operation: () => Promise<unknown>) => operation() },
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

  it("refreshes release dates, broadcasts catalog changes, persists them, and isolates fetch failure", async () => {
    root = await mkdtemp(join(tmpdir(), "gateway-model-catalog-"));
    const broadcast = vi.fn();
    const fetcher = vi.fn(async () => new Response(JSON.stringify({ anthropic: { models: { "claude-sonnet-5-5": { release_date: "2026-09-28" } } } }), { status: 200 }));
    vi.stubGlobal("fetch", fetcher);
    const newlyReleased = { ...dated, id: "claude-sonnet-5-5" };
    const runtime = {
      getModels: () => [newlyReleased], getAvailable: async () => [newlyReleased],
      getProviders: () => [{ id: "anthropic" }],
      refresh: async () => ({ aborted: false, errors: new Map() }),
    };
    const dependencies = {
      config: { tronHome: root, machineId: "machine", machineGroupID: "group", machineName: "Mac" },
      modelRuntime: runtime,
      globalProviderResources: { withStableSnapshot: async (operation: () => Promise<unknown>) => operation() },
      sessions: { recentModelUsage: () => usage }, receipts: new CommandReceiptStore(root), broadcast,
    } as unknown as GatewayServiceDependencies;
    const gateway = new GatewayService(dependencies);
    const before = await gateway.invoke(client, "model.list", {}) as { models: Array<Record<string, unknown>> };
    expect("releaseDate" in before.models[0]).toBe(false);
    expect(fetcher).not.toHaveBeenCalled();
    const refresh = await gateway.invoke(client, "models.refresh", { commandId: "catalog-refresh-001", force: true }) as Record<string, unknown>;
    expect(refresh.releaseDates).toEqual({ updated: expect.any(Number) });
    expect(broadcast).toHaveBeenCalledWith("models.catalogChanged", {});
    const after = await gateway.invoke(client, "model.list", {}) as { models: Array<Record<string, unknown>> };
    expect(after.models[0].releaseDate).toBe("2026-09-28");
    gateway.dispose();

    const restored = new GatewayService(dependencies);
    vi.stubGlobal("fetch", vi.fn(async () => { throw new Error("network down"); }));
    const persisted = await restored.invoke(client, "model.list", {}) as { models: Array<Record<string, unknown>> };
    expect(persisted.models[0].releaseDate).toBe("2026-09-28");
    const failed = await restored.invoke(client, "models.refresh", { commandId: "catalog-refresh-002", force: true }) as Record<string, unknown>;
    expect(failed.aborted).toBe(false);
    expect(failed.releaseDates).toMatchObject({ updated: 0, error: expect.any(String) });
    restored.dispose();
  });

  it("projects input/output prices only for priced models", async () => {
    const result = await service().invoke(client, "model.list", {}) as { models: Array<Record<string, unknown>> };
    expect(result.models.find((model) => model.id === "claude-fable-5")!.cost).toEqual({ input: 10, output: 50 });
    expect("cost" in result.models.find((model) => model.id === "local-model")!).toBe(false);
  });
});
