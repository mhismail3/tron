import { createServer, type AddressInfo, type Server } from "node:http";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import type { Credential, CredentialInfo, CredentialStore } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { installOpenAIModelEligibility } from "../providers/openai-model-eligibility.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "./gateway-service.js";

const client = { id: "openai-catalog", identity: "device:openai-catalog", isLocal: false, isSubscribed: () => false, isRevoked: () => false, revokeDevice: () => {} } as unknown as ClientContext;
const models = [
  { slug: "gpt-5.5", visibility: "list", display_name: "GPT 5.5" },
  { slug: "gpt-4", visibility: "hidden", display_name: "Hidden GPT-4" },
  { slug: "gpt-5.6-sol", visibility: "list", display_name: "GPT 5.6 Sol" },
  { slug: "account-only-unknown", visibility: "list", display_name: "Unknown" },
];

class Credentials implements CredentialStore {
  constructor(private readonly value: Credential) {}
  async read(providerId: string) {
    if (providerId === "openai") return this.value;
    if (providerId === "openai-codex") return { type: "oauth", access: "legacy-test-token", refresh: "refresh", expires: Date.now() + 3_600_000 };
    return undefined;
  }
  async list(): Promise<readonly CredentialInfo[]> {
    return [{ providerId: "openai", type: this.value.type }, { providerId: "openai-codex", type: "oauth" }];
  }
  async modify(providerId: string, fn: (current: Credential | undefined) => Promise<Credential | undefined>) {
    return fn(providerId === "openai" ? this.value : undefined);
  }
  async delete() {}
}

async function fakeModelsServer(body: unknown) {
  let server: Server;
  let requestAuthorization: string | undefined;
  server = createServer((request, response) => {
    requestAuthorization = request.headers.authorization;
    response.setHeader("content-type", "application/json");
    response.end(JSON.stringify(body));
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address() as AddressInfo;
  return {
    url: `http://127.0.0.1:${address.port}/v1/models`,
    authorization: () => requestAuthorization,
    close: () => new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve())),
  };
}

describe("OpenAI model eligibility through Gateway and SDK runtime", () => {
  let runtime: ModelRuntime | undefined;
  let root = "";
  let server: Awaited<ReturnType<typeof fakeModelsServer>> | undefined;
  afterEach(async () => {
    runtime = undefined;
    if (root) await rm(root, { recursive: true, force: true });
    root = "";
    if (server) await server.close();
    server = undefined;
  });

  it("offers only registered account-visible OpenAI slugs and preserves account order", async () => {
    root = await mkdtemp(join(tmpdir(), "gateway-openai-eligibility-"));
    server = await fakeModelsServer({ models, has_more: false });
    runtime = await ModelRuntime.create({
      modelsPath: null,
      refreshOnCreate: true,
      allowModelNetwork: false,
      credentials: new Credentials({ type: "oauth", access: "safe-test-token", refresh: "refresh", expires: Date.now() + 3_600_000 }),
    });
    installOpenAIModelEligibility(runtime, { fetch: async (_input, init) => fetch(server!.url, init) });
    const service = new GatewayService({
      config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome: root },
      modelRuntime: runtime,
      globalProviderResources: { withStableSnapshot: async (operation: () => Promise<unknown>) => operation() },
      sessions: { recentModelUsage: () => [] },
    } as unknown as GatewayServiceDependencies);

    const catalog: Array<{ provider: string; id: string; name: string; available: boolean }> = [];
    let cursor: string | undefined;
    do {
      const page = await service.invoke(client, "model.list", { ...(cursor ? { cursor } : {}), limit: 500 }) as {
        models: Array<{ provider: string; id: string; name: string; available: boolean }>;
        nextCursor?: string;
      };
      catalog.push(...page.models);
      cursor = page.nextCursor;
    } while (cursor);
    const offered = catalog.filter(model => model.available).map(model => `${model.provider}/${model.id}`);
    expect(offered).toEqual(["openai/gpt-5.5", "openai/gpt-5.6-sol"]);
    expect(catalog.find(model => model.provider === "openai" && model.id === "gpt-5.5")?.name).toBe("GPT 5.5");
    expect(catalog.find(model => model.provider === "openai" && model.id === "gpt-5.2-chat-latest")?.available).toBe(false);
    expect(catalog.find(model => model.provider === "openai" && model.id === "gpt-realtime-2.1")?.available).toBe(false);
    expect(server.authorization()).toBe("Bearer safe-test-token");
    expect(JSON.stringify(catalog)).not.toContain("safe-test-token");
    service.dispose();
  });

});
