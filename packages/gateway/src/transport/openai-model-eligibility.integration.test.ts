import { createServer, type AddressInfo, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import type { Credential, CredentialInfo, CredentialStore } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { installOpenAIModelEligibility, openAIModelEligibility } from "../providers/openai-model-eligibility.js";
import { SettingsService } from "../admin/settings-service.js";
import { GatewayError } from "../errors.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "./gateway-service.js";

const client = { id: "openai-catalog", identity: "device:openai-catalog", isLocal: false, isSubscribed: () => false, isRevoked: () => false, revokeDevice: () => {} } as unknown as ClientContext;
const models = [
  { slug: "gpt-5.5", visibility: "list", display_name: "GPT 5.5" },
  { slug: "gpt-4", visibility: "hidden", display_name: "Hidden GPT-4" },
  { slug: "gpt-5.6-sol", visibility: "list", display_name: "GPT 5.6 Sol" },
  { slug: "account-only-unknown", visibility: "list", display_name: "Unknown" },
];

class Credentials implements CredentialStore {
  codex: Credential | undefined = { type: "oauth", access: "legacy-test-token", refresh: "refresh", expires: Date.now() + 3_600_000 };
  constructor(public openai: Credential | undefined) {}
  async read(providerId: string) {
    return providerId === "openai" ? this.openai : providerId === "openai-codex" ? this.codex : undefined;
  }
  async list(): Promise<readonly CredentialInfo[]> {
    return [
      ...(this.openai ? [{ providerId: "openai", type: this.openai.type } as const] : []),
      ...(this.codex ? [{ providerId: "openai-codex", type: this.codex.type } as const] : []),
    ];
  }
  async modify(providerId: string, fn: (current: Credential | undefined) => Promise<Credential | undefined>) {
    if (providerId === "openai") return fn(this.openai);
    if (providerId === "openai-codex") return fn(this.codex);
    return undefined;
  }
  async delete() {}
}

async function fakeModelsServer(respond: (request: IncomingMessage, response: ServerResponse) => void | Promise<void>) {
  const requests: Array<{ authorization: string | undefined; url: string | undefined; status?: number }> = [];
  const server: Server = createServer((request, response) => {
    const record = { authorization: request.headers.authorization, url: request.url } as { authorization: string | undefined; url: string | undefined; status?: number };
    requests.push(record);
    response.on("finish", () => { record.status = response.statusCode; });
    void respond(request, response);
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address() as AddressInfo;
  return {
    url: `http://127.0.0.1:${address.port}/v1/models`,
    requests,
    close: () => new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve())),
  };
}

function json(response: ServerResponse, body: unknown, status = 200): void {
  response.statusCode = status;
  response.setHeader("content-type", "application/json");
  response.end(JSON.stringify(body));
}

describe("OpenAI model eligibility through Gateway and SDK runtime", () => {
  let runtime: ModelRuntime | undefined;
  let root = "";
  let server: Awaited<ReturnType<typeof fakeModelsServer>> | undefined;
  const services: GatewayService[] = [];
  let upstreamUrls: string[] = [];
  afterEach(async () => {
    for (const service of services.splice(0)) service.dispose();
    runtime = undefined;
    if (root) await rm(root, { recursive: true, force: true });
    root = "";
    if (server) await server.close();
    server = undefined;
    upstreamUrls = [];
  });

  async function harness(credential: Credential | undefined, options: { now?: () => number; modelsPath?: string | null; configureModels?: (root: string) => Promise<string>; sessions?: unknown; providerUsage?: unknown } = {}) {
    root = await mkdtemp(join(tmpdir(), "gateway-openai-eligibility-"));
    const credentials = new Credentials(credential);
    const modelsPath = options.configureModels ? await options.configureModels(root) : options.modelsPath ?? null;
    runtime = await ModelRuntime.create({
      modelsPath,
      refreshOnCreate: true,
      allowModelNetwork: false,
      credentials,
    });
    installOpenAIModelEligibility(runtime, {
      now: options.now,
      fetch: async (input, init) => {
        upstreamUrls.push(String(input));
        const target = new URL(server!.url);
        target.search = new URL(String(input)).search;
        return fetch(target, init);
      },
    });
    const service = new GatewayService({
      config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome: root },
      modelRuntime: runtime,
      globalProviderResources: { withStableSnapshot: async (operation: () => Promise<unknown>) => operation() },
      sessions: options.sessions ?? { recentModelUsage: () => [] },
      ...(options.providerUsage ? { providerUsage: options.providerUsage } : {}),
      receipts: { execute: async (_identity: string, _method: string, _commandId: string, operation: () => Promise<unknown>) => operation(), status: async () => undefined },
    } as unknown as GatewayServiceDependencies);
    services.push(service);
    return { runtime, credentials, service };
  }

  async function catalog(service: GatewayService) {
    const result: Array<{ provider: string; id: string; name: string; available: boolean }> = [];
    let cursor: string | undefined;
    do {
      const page = await service.invoke(client, "model.list", { ...(cursor ? { cursor } : {}), limit: 500 }) as {
        models: Array<{ provider: string; id: string; name: string; available: boolean }>;
        nextCursor?: string;
      };
      result.push(...page.models);
      cursor = page.nextCursor;
    } while (cursor);
    return result;
  }

  it("offers only registered account-visible OpenAI slugs and preserves account order", async () => {
    root = await mkdtemp(join(tmpdir(), "gateway-openai-eligibility-"));
    server = await fakeModelsServer((_request, response) => json(response, { models, has_more: false }));
    runtime = await ModelRuntime.create({
      modelsPath: null,
      refreshOnCreate: true,
      allowModelNetwork: false,
      credentials: new Credentials({ type: "oauth", access: "safe-test-token", refresh: "refresh", expires: Date.now() + 3_600_000 }),
    });
    installOpenAIModelEligibility(runtime, { fetch: async (input, init) => {
      upstreamUrls.push(String(input));
      return fetch(server!.url, init);
    } });
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
    expect(server.requests.at(-1)?.authorization).toBe("Bearer safe-test-token");
    expect(upstreamUrls.every(raw => {
      const url = new URL(raw);
      return url.origin === "https://api.openai.com" && url.pathname === "/v1/models";
    })).toBe(true);
    expect(JSON.stringify(catalog)).not.toContain("safe-test-token");
    service.dispose();
  });

  it("fails closed, retains only the same account after refresh failure, and applies additions and withdrawals at TTL", async () => {
    let now = 10_000;
    let status = 500;
    let visible = ["gpt-5.5"];
    server = await fakeModelsServer((_request, response) => json(response, status === 200
      ? { models: visible.map(slug => ({ slug, visibility: "list" })), has_more: false }
      : { error: "unavailable" }, status));
    const { service } = await harness({ type: "oauth", access: "account-a", refresh: "refresh", expires: Date.now() + 3_600_000 }, { now: () => now });
    const openAIChoices = async () => (await catalog(service)).filter(model => model.provider === "openai" && model.available).map(model => model.id);

    expect(await openAIChoices()).toEqual([]);
    expect(server.requests).toHaveLength(1);
    status = 200;
    now += 60_001;
    expect(server.requests.every(request => request.authorization === "Bearer account-a")).toBe(true);
    expect(await openAIChoices(), JSON.stringify(server.requests)).toEqual(["gpt-5.5"]);
    status = 500;
    now += 60_001;
    expect(await openAIChoices()).toEqual(["gpt-5.5"]);
    status = 200;
    visible = ["gpt-5.2-chat-latest"];
    now += 60_001;
    expect(await openAIChoices()).toEqual(["gpt-5.2-chat-latest"]);
  });

  it("concatenates account pagination in order and fails closed on a repeated cursor", async () => {
    let invalid = false;
    server = await fakeModelsServer((request, response) => {
      const after = new URL(request.url ?? "/", "http://local").searchParams.get("after");
      if (!after) return json(response, { models: [{ slug: "gpt-5.6-sol", visibility: "list" }], has_more: true, last_id: "page-1" });
      return json(response, invalid
        ? { models: [{ slug: "gpt-5.5", visibility: "list" }], has_more: true, last_id: "page-1" }
        : { models: [{ slug: "gpt-5.5", visibility: "list" }], has_more: false });
    });
    let now = 0;
    const { service, credentials } = await harness({ type: "oauth", access: "pagination-account", refresh: "refresh", expires: Date.now() + 3_600_000 }, { now: () => now });
    const listed = async () => (await catalog(service)).filter(model => model.provider === "openai" && model.available).map(model => model.id);
    expect(await listed()).toEqual(["gpt-5.6-sol", "gpt-5.5"]);
    expect(server.requests.map(request => request.url)).toEqual(["/v1/models", "/v1/models?after=page-1"]);
    invalid = true;
    credentials.openai = { type: "oauth", access: "invalid-pagination-account", refresh: "refresh-b", expires: Date.now() + 3_600_000 };
    now = 60_001;
    expect(await listed()).toEqual([]);
    expect(server.requests.filter(request => request.authorization === "Bearer invalid-pagination-account")).toHaveLength(2);
  });

  it("does not publish a delayed account-A result after account B becomes current", async () => {
    let releaseA!: () => void;
    let startedA!: () => void;
    const aStarted = new Promise<void>(resolve => { startedA = resolve; });
    const aResponse = new Promise<void>(resolve => { releaseA = resolve; });
    server = await fakeModelsServer(async (request, response) => {
      if (request.headers.authorization === "Bearer account-a") {
        startedA();
        await aResponse;
        return json(response, { models: [{ slug: "gpt-5.5", visibility: "list" }], has_more: false });
      }
      return json(response, { models: [{ slug: "gpt-5.6-sol", visibility: "list" }], has_more: false });
    });
    const { service, credentials, runtime } = await harness({ type: "oauth", access: "account-a", refresh: "refresh", expires: Date.now() + 3_600_000 });
    const policy = openAIModelEligibility(runtime)!;
    const oldRead = policy.refresh();
    await aStarted;
    credentials.openai = { type: "oauth", access: "account-b", refresh: "refresh-b", expires: Date.now() + 3_600_000 };
    expect((await catalog(service)).filter(model => model.provider === "openai" && model.available).map(model => model.id)).toEqual(["gpt-5.6-sol"]);
    releaseA();
    await oldRead;
    expect(policy.isEligible({ provider: "openai", id: "gpt-5.5" })).toBe(false);
    expect(policy.isEligible({ provider: "openai", id: "gpt-5.6-sol" })).toBe(true);
    expect((await catalog(service)).filter(model => model.provider === "openai" && model.available).map(model => model.id)).toEqual(["gpt-5.6-sol"]);
  });

  it("leaves API-key OpenAI availability unchanged without discovery", async () => {
    server = await fakeModelsServer((_request, response) => json(response, { models: [], has_more: false }));
    const { service } = await harness({ type: "api_key", key: "api-key-test" });
    const apiKeyCatalog = await catalog(service);
    expect(apiKeyCatalog.filter(model => model.provider === "openai" && model.available).length).toBeGreaterThan(1);
    expect(server.requests).toHaveLength(0);
  });

  it("keeps sole legacy Codex models available without OpenAI discovery", async () => {
    server = await fakeModelsServer((_request, response) => json(response, { models: [], has_more: false }));
    const { service } = await harness(undefined);
    const legacy = await catalog(service);
    expect(legacy.filter(model => model.provider === "openai-codex" && model.available).length).toBeGreaterThan(0);
    expect(server.requests).toHaveLength(0);
  });

  it("rejects hidden model selections and default writes without mutating the existing session model", async () => {
    let slot: { modelRuntime: ModelRuntime; setModel: ReturnType<typeof vi.fn>; snapshot: () => { model: { provider: string; id: string } } } | undefined;
    const sessions = { recentModelUsage: () => [], acquire: async () => slot };
    server = await fakeModelsServer((_request, response) => json(response, { models, has_more: false }));
    const { runtime, service } = await harness({ type: "oauth", access: "choice-account", refresh: "refresh", expires: Date.now() + 3_600_000 }, { sessions });
    slot = { modelRuntime: runtime, setModel: vi.fn(async () => 2), snapshot: () => ({ model: { provider: "openai-codex", id: "gpt-5.6-sol" } }) };
    const subscribedClient = { ...client, isSubscribed: () => true };
    await expect(service.invoke(subscribedClient, "session.setModel", {
      commandId: "hidden-model-choice", sessionId: "historical-session", expectedRuntimeGeneration: "generation",
      expectedModel: { provider: "openai-codex", id: "gpt-5.6-sol" }, provider: "openai", modelId: "gpt-4",
    })).rejects.toBeInstanceOf(GatewayError);
    expect(slot.setModel).not.toHaveBeenCalled();
    expect(slot.snapshot().model).toEqual({ provider: "openai-codex", id: "gpt-5.6-sol" });

    const providerList = await service.invoke(client, "provider.list", {}) as { providers: Array<{ id: string; usageLentTo: string | null }> };
    expect(providerList.providers.find(provider => provider.id === "openai-codex")?.usageLentTo).toBe("openai");
    await expect(service.invoke(subscribedClient, "session.setModel", {
      commandId: "lent-codex-choice", sessionId: "historical-session", expectedRuntimeGeneration: "generation",
      expectedModel: { provider: "openai-codex", id: "gpt-5.6-sol" }, provider: "openai-codex", modelId: runtime.getModels("openai-codex")[0]!.id,
    })).rejects.toMatchObject({ code: "invalid_request" });
    expect(slot.setModel).not.toHaveBeenCalled();

    const settings = new SettingsService(root, runtime);
    await expect(settings.update({ defaultModel: { provider: "openai", id: "gpt-4" } }, {
      cwd: root, scope: "global", projectTrusted: false,
    })).rejects.toMatchObject({ code: "invalid_request" });
  });

  it("keeps usage lending visible and provider counts aligned with actual choices", async () => {
    server = await fakeModelsServer((_request, response) => json(response, { models, has_more: false }));
    const readUsage = vi.fn(async (runtime: ModelRuntime, providerId: string) => ({ providers: [{
      providerId, source: "openai-codex.wham", scope: "account", status: "available", updatedAt: null, retryAt: null,
      stale: false, message: null, windows: [{ id: "primary", label: "Primary", usedPercent: 25 }], balances: [],
    }] }));
    const providerUsage = { read: readUsage };
    const { runtime, service } = await harness({ type: "oauth", access: "openai-plan-token", refresh: "refresh", expires: Date.now() + 3_600_000 }, { providerUsage });
    const providerResult = await service.invoke(client, "provider.list", {}) as { providers: Array<{ id: string; modelCount: number; usageLentTo: string | null }> };
    const openai = providerResult.providers.find(provider => provider.id === "openai");
    const codex = providerResult.providers.find(provider => provider.id === "openai-codex");
    expect(openai?.modelCount).toBe(2);
    expect(codex?.usageLentTo).toBe("openai");
    expect(codex?.modelCount).toBe(0);
    const usage = await service.invoke(client, "provider.usage", { providerId: "openai" }) as { providers: Array<{ providerId: string; source: string | null; status: string }> };
    expect(usage.providers).toMatchObject([{ providerId: "openai", source: "openai-codex.wham", status: "available", windows: [{ id: "primary", usedPercent: 25 }] }]);
    expect(readUsage).toHaveBeenCalledWith(runtime, "openai", undefined);
    expect(runtime.getModels("openai-codex").length).toBeGreaterThan(0);
  });

  it("never sends OAuth tokens for a custom OpenAI endpoint", async () => {
    server = await fakeModelsServer((_request, response) => json(response, { models, has_more: false }));
    const { service } = await harness({ type: "oauth", access: "custom-endpoint-token", refresh: "refresh", expires: Date.now() + 3_600_000 }, {
      configureModels: async directory => {
        const path = join(directory, "models.json");
        await writeFile(path, JSON.stringify({ providers: {
          openai: { baseUrl: "https://proxy.example/v1", api: "openai-responses", models: [] },
        } }));
        return path;
      },
    });
    await catalog(service);
    expect(server.requests).toHaveLength(0);
    expect(upstreamUrls).toEqual([]);
  });

});
