import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { ModelRuntime, SettingsManager, createAgentSessionServices } from "@earendil-works/pi-coding-agent";
import type { JsonValue } from "../protocol/types.js";
import { AuthBroker } from "./auth-broker.js";
import { waitFor } from "../../test-support/wait-for.js";
import { GlobalProviderResources } from "./global-provider-resources.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../transport/gateway-service.js";

const roots: string[] = [];
const client: ClientContext = {
  id: "dashboard", identity: "device:dashboard", isLocal: false, signal: undefined,
  beginSynchronization: () => "sync", establishSynchronization: () => {}, completeSynchronization: () => {},
  setPresentationVisibility: () => ({ visible: true, revision: 1 }), unsubscribe: () => false,
  attachTerminal: () => {}, detachTerminal: () => {}, ownsTerminal: () => false,
  isSubscribed: () => true, isRevoked: () => false, revokeDevice: () => {},
};
afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "tron-global-provider-"));
  roots.push(root);
  const agentDir = join(root, "agent");
  const extensionPath = join(root, "provider.ts");
  await mkdir(agentDir, { recursive: true });
  const runtime = await ModelRuntime.create({
    authPath: join(agentDir, "auth.json"),
    modelsPath: null,
    refreshOnCreate: false,
  });
  const events: Array<{ topic: string; payload: JsonValue }> = [];
  const broker = new AuthBroker(runtime, (_client, topic, payload) => {
    events.push({ topic, payload });
  });
  /** Waits for the recorded events to satisfy the predicate; the shared hang
   * bound names it when they never do. */
  const waitForAuthEvent = (predicate: () => boolean): Promise<void> =>
    waitFor(predicate, "the global provider auth event");
  const log = vi.fn();
  const broadcast = vi.fn();
  const createResources = () => GlobalProviderResources.create({
    cwd: homedir(),
    agentDir,
    modelRuntime: runtime,
    auth: broker,
    log,
    broadcast,
  });
  return { root, agentDir, extensionPath, runtime, events, broker, log, broadcast, createResources, waitForAuthEvent };
}

function providerExtension(providerId: string, waitForPrompt = false, probeRuntime = false): string {
  const login = probeRuntime
    ? `async login() { let refresh; try { pi.getAllTools(); refresh = "active"; } catch (error) { refresh = error.message; } return { refresh, access: "fixture-access", expires: Date.now() + 60000 }; }`
    : waitForPrompt
      ? `async login(callbacks) { const code = await callbacks.onPrompt({ message: "Fixture authorization code" }); return { refresh: "fixture-refresh-" + code, access: "fixture-access-" + code, expires: Date.now() + 60000 }; }`
      : `async login() { return { refresh: "fixture-refresh", access: "fixture-access", expires: Date.now() + 60000 }; }`;
  return `export default (pi) => pi.registerProvider(${JSON.stringify(providerId)}, {
    name: "Global fixture",
    api: "openai-completions",
    baseUrl: "https://example.invalid/v1",
    models: [{ id: "fixture-model", name: "Fixture model", api: "openai-completions", reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 4096, maxTokens: 1024 }],
    oauth: {
      ${login},
      async refreshToken(credentials) { return credentials; },
      getApiKey(credentials) { return credentials.access; }
    }
  });\n`;
}

async function configure(agentDir: string, extensions: string[]): Promise<void> {
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({ extensions }, null, 2));
}

/** Event-loop turns are what settle a queued catalog read: every pending
 * continuation and I/O callback runs before each `setImmediate` callback, and no
 * wall-clock wait is involved. A read that is not fenced on the refresh mutex
 * resolves inside these turns, which is what the assertions below detect. */
async function settleScheduledWork(): Promise<void> {
  for (let turn = 0; turn < 32; turn += 1) {
    await Promise.resolve();
    await new Promise<void>((resolve) => setImmediate(resolve));
  }
}

describe("global provider resources", () => {
  it("replays global virtual-model registrations into the administrative catalog", async () => {
    // Guard the global/session-free boundary: virtual registrations were queued by
    // extension loading but never replayed, so model.list omitted a selectable router.
    const f = await fixture();
    await writeFile(f.extensionPath, `export default (pi) => {
      pi.registerProvider("virtual-physical", {
        name: "Virtual fixture", api: "openai-completions", baseUrl: "https://example.invalid/v1",
        models: [{ id: "physical", name: "Physical", api: "openai-completions", reasoning: false, input: ["text"], cost: { input: 1, output: 2, cacheRead: 0, cacheWrite: 0 }, contextWindow: 8192, maxTokens: 1024 }]
      });
      pi.registerVirtualModel({ provider: "virtual-physical", id: "router", name: "Router", contextWindow: 4096, route: () => ({ model: pi.modelRegistry.find("virtual-physical", "physical"), thinkingLevel: "off" }) });
    };`);
    await configure(f.agentDir, [f.extensionPath]);
    const resources = await f.createResources();
    const gateway = new GatewayService({ modelRuntime: f.runtime, sessions: { isAdministrativeDrainStarted: false }, globalProviderResources: resources } as unknown as GatewayServiceDependencies);
    const result = await gateway.invoke(client, "model.list", { limit: 200 }) as { models: Array<Record<string, unknown>>; nextCursor?: string };
    const models = [...result.models];
    let cursor = result.nextCursor;
    while (cursor && !models.some(({ id }) => id === "router")) {
      const page = await gateway.invoke(client, "model.list", { limit: 200, cursor }) as typeof result;
      models.push(...page.models);
      cursor = page.nextCursor;
    }
    expect(models.find(({ id }) => id === "router")).toMatchObject({
      provider: "virtual-physical", virtual: true, contextWindow: 4096,
    });
    expect(f.runtime.getModels().some(({ id }) => id === "router")).toBe(true);
  });

  it("registers CortexKit-style image and classifier overrides without exposing them in the chat picker", async () => {
    const f = await fixture();
    const resources = await f.createResources();
    await f.runtime.setRuntimeApiKey("typesafe", "fixture-only-typesafe-key");
    const gateway = new GatewayService({ modelRuntime: f.runtime, sessions: { isAdministrativeDrainStarted: false }, globalProviderResources: resources } as unknown as GatewayServiceDependencies);

    await expect(gateway.invoke(client, "provider.list", {})).resolves.toMatchObject({
      providers: expect.arrayContaining([
        expect.objectContaining({ id: "typesafe", configured: true, modelCount: 0 }),
      ]),
    });
    const result = await gateway.invoke(client, "model.list", {}) as { models: Array<Record<string, unknown>> };
    expect(result.models.some(model => model.provider === "cortexkit")).toBe(false);
  });

  it("refreshes pi.dev typed catalogs into models-store.json and reloads the chat overlay", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-pi-catalog-"));
    roots.push(root);
    const modelsStorePath = join(root, "models-store.json");
    const fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = new URL(String(input));
      expect(url.pathname).toBe("/api/models/providers/openai");
      expect(url.searchParams.get("types")).toBe("chat,image,classifier");
      return new Response(JSON.stringify({ models: [
        { type: "chat", id: "catalog-chat", name: "Catalog chat", api: "openai-completions", reasoning: false, input: ["text"], contextWindow: 8192, maxTokens: 1024, cost: { input: 0, output: 0 } },
        { type: "image", id: "catalog-image", name: "Catalog image", api: "openai-images", input: ["text"], output: ["image"], cost: { input: 0, output: 0 } },
        { type: "classifier", id: "catalog-classifier", name: "Catalog classifier", api: "typesafe-system-one", input: ["text"], contextWindow: 8192, cost: { input: 0.042, output: 0 } },
      ] }), { status: 200, headers: { "last-modified": new Date("2030-09-29T00:00:00Z").toUTCString(), etag: '"typed-catalog"' } });
    });
    vi.stubGlobal("fetch", fetch);
    const runtime = await ModelRuntime.create({ modelsPath: join(root, "models.json"), modelsStorePath, catalogBaseUrl: "https://pi.invalid", refreshOnCreate: false });
    await runtime.setRuntimeApiKey("openai", "fixture-only-key");
    await runtime.refresh({ providers: ["openai"], force: true, allowNetwork: true });
    expect(fetch).toHaveBeenCalledTimes(1);
    const chat = runtime.getModels().filter(model => model.provider === "openai");
    expect(chat.map(model => model.id)).toContain("catalog-chat");
    expect(chat.some(model => model.id === "catalog-image" || model.id === "catalog-classifier")).toBe(false);
    const stored = JSON.parse(await (await import("node:fs/promises")).readFile(modelsStorePath, "utf8")) as Record<string, { models: Array<{ type?: string; id: string }> }>;
    expect(stored.openai?.models.map(model => model.type)).toEqual(["chat", "image", "classifier"]);
    const reloaded = await ModelRuntime.create({ modelsPath: join(root, "models.json"), modelsStorePath, catalogBaseUrl: "https://pi.invalid", refreshOnCreate: false });
    await reloaded.refresh({ providers: ["openai"], allowNetwork: false });
    expect(reloaded.getModels().filter(model => model.provider === "openai").map(model => model.id)).toContain("catalog-chat");
    expect(fetch).toHaveBeenCalledTimes(1);
  });

  it("loads user extensions for global catalog and OAuth before any session exists", async () => {
    const f = await fixture();
    await writeFile(f.extensionPath, providerExtension("global-fixture"));
    await configure(f.agentDir, [f.extensionPath]);
    const resources = await f.createResources();
    f.broadcast.mockClear();

    expect(f.runtime.getProvider("global-fixture")?.name).toBe("Global fixture");
    expect(f.runtime.getModels()).toEqual(expect.arrayContaining([
      expect.objectContaining({ provider: "global-fixture", id: "fixture-model" }),
    ]));
    const dashboard = new GatewayService({
      modelRuntime: f.runtime,
      sessions: { isAdministrativeDrainStarted: false },
      globalProviderResources: resources,
    } as unknown as GatewayServiceDependencies);
    await expect(dashboard.invoke(client, "provider.list", {})).resolves.toMatchObject({
      providers: expect.arrayContaining([expect.objectContaining({ id: "global-fixture", modelCount: 1 })]),
    });
    const operationId = f.broker.start("dashboard", "global-fixture", "oauth", f.runtime, "dashboard-device", "login-1", "global").operationId;
    await f.waitForAuthEvent(() => f.events.some((event) => event.topic === "auth.completed"));
    expect(f.runtime.isUsingOAuth("global-fixture")).toBe(true);
    expect(f.events).toContainEqual(expect.objectContaining({
      topic: "auth.completed",
      payload: expect.objectContaining({ operationId, providerId: "global-fixture", success: true }),
    }));
    expect(resources).toBeDefined();
  });

  it("reconciles global package/settings changes but never imports project-only providers", async () => {
    const f = await fixture();
    const globalExtension = join(f.root, "global.ts");
    const secondGlobalExtension = join(f.root, "second-global.ts");
    const projectExtension = join(f.root, "project.ts");
    const projectDir = join(f.root, "project");
    await mkdir(join(projectDir, ".pi"), { recursive: true });
    await writeFile(globalExtension, providerExtension("global-fixture"));
    await writeFile(secondGlobalExtension, providerExtension("second-global-fixture"));
    await writeFile(projectExtension, providerExtension("project-fixture"));
    await configure(f.agentDir, [globalExtension]);
    await writeFile(join(projectDir, ".pi", "settings.json"), JSON.stringify({ extensions: [projectExtension] }));
    const resources = await f.createResources();
    f.broadcast.mockClear();

    expect(f.runtime.getProvider("global-fixture")).toBeDefined();
    expect(f.runtime.getProvider("project-fixture")).toBeUndefined();
    const projectRuntime = await ModelRuntime.create({ authPath: join(f.agentDir, "auth.json"), modelsPath: null, refreshOnCreate: false });
    const projectServices = await createAgentSessionServices({
      cwd: projectDir,
      agentDir: f.agentDir,
      modelRuntime: projectRuntime,
      settingsManager: SettingsManager.create(projectDir, f.agentDir, { projectTrusted: true }),
    });
    expect(projectRuntime.getProvider("project-fixture")).toBeDefined();
    expect(f.runtime.getProvider("project-fixture")).toBeUndefined();
    expect(projectServices.cwd).toBe(projectDir);

    const refreshed = new Promise<void>((resolve) => f.broadcast.mockImplementationOnce(resolve));
    await writeFile(join(f.agentDir, "settings.json"), JSON.stringify({ extensions: [globalExtension, secondGlobalExtension] }));
    resources.requestReload();
    await refreshed;
    expect(f.runtime.getProvider("second-global-fixture")).toBeDefined();
    expect(f.runtime.getProvider("project-fixture")).toBeUndefined();
    expect(f.broadcast).toHaveBeenCalledTimes(1);

    const removed = new Promise<void>((resolve) => f.broadcast.mockImplementationOnce(resolve));
    await writeFile(join(f.agentDir, "settings.json"), JSON.stringify({ extensions: [] }));
    resources.requestReload();
    await removed;
    expect(f.runtime.getProvider("global-fixture")).toBeUndefined();
    expect(f.runtime.getProvider("project-fixture")).toBeUndefined();
  });

  it("loads providers from ordered global package resources and removes them when the package is removed", async () => {
    const f = await fixture();
    const packageDir = join(f.agentDir, "fixture-provider-package");
    await mkdir(packageDir, { recursive: true });
    await writeFile(join(packageDir, "package.json"), JSON.stringify({
      name: "fixture-provider-package", version: "1.0.0", pi: { extensions: ["provider.ts"] },
    }));
    await writeFile(join(packageDir, "provider.ts"), providerExtension("packaged-provider"));
    await writeFile(join(f.agentDir, "settings.json"), JSON.stringify({ packages: ["./fixture-provider-package"] }));
    const resources = await f.createResources();
    expect(f.runtime.getProvider("packaged-provider")).toBeDefined();

    const refreshed = new Promise<void>((resolve) => f.broadcast.mockImplementationOnce(resolve));
    await writeFile(join(f.agentDir, "settings.json"), JSON.stringify({ packages: [] }));
    resources.requestReload();
    await refreshed;
    expect(f.runtime.getProvider("packaged-provider")).toBeUndefined();
  });

  it("restores a built-in provider after removing its global extension layer", async () => {
    const f = await fixture();
    await writeFile(f.extensionPath, providerExtension("openai"));
    await configure(f.agentDir, [f.extensionPath]);
    const resources = await f.createResources();
    expect(f.runtime.getProvider("openai")).toBeDefined();
    expect(f.runtime.getProvider("openai")?.getModels()).toEqual(expect.arrayContaining([
      expect.objectContaining({ id: "fixture-model" }),
    ]));

    const refreshed = new Promise<void>((resolve) => f.broadcast.mockImplementationOnce(resolve));
    await configure(f.agentDir, []);
    resources.requestReload();
    await refreshed;
    expect(f.runtime.getProvider("openai")).toBeDefined();
    expect(f.runtime.getProvider("openai")?.getModels()).not.toEqual(expect.arrayContaining([
      expect.objectContaining({ id: "fixture-model" }),
    ]));
  });

  it("replays duplicate provider contributions in SDK order and removes omitted fields with their owner", async () => {
    const f = await fixture();
    const first = join(f.root, "first.ts");
    const second = join(f.root, "second.ts");
    await writeFile(first, providerExtension("shared-provider")
      .replace('name: "Global fixture"', 'name: "First contributor"')
      .replace("https://example.invalid/v1", "https://first.invalid/v1"));
    await writeFile(second, providerExtension("shared-provider")
      .replace('name: "Global fixture",\n    api:', 'api:')
      .replace("https://example.invalid/v1", "https://second.invalid/v1"));
    await configure(f.agentDir, [first, second]);
    const resources = await f.createResources();
    const providerName = () => f.runtime.getProvider("shared-provider")?.name;
    const modelBaseUrl = () => f.runtime.getModels().find(({ provider }) => provider === "shared-provider")?.baseUrl;
    expect(providerName()).toBe("First contributor");
    expect(modelBaseUrl()).toBe("https://second.invalid/v1");

    const reload = async (paths: string[]) => {
      const refreshed = new Promise<void>((resolve) => f.broadcast.mockImplementationOnce(resolve));
      await configure(f.agentDir, paths);
      resources.requestReload();
      await refreshed;
    };
    await reload([first]);
    expect(providerName()).toBe("First contributor");
    expect(modelBaseUrl()).toBe("https://first.invalid/v1");

    await reload([second]);
    expect(providerName()).not.toBe("First contributor");
    expect(modelBaseUrl()).toBe("https://second.invalid/v1");

    await reload([second, first]);
    expect(providerName()).toBe("First contributor");
    expect(modelBaseUrl()).toBe("https://first.invalid/v1");
  });

  it("retains the actual runtime of a provider whose replacement registration fails", async () => {
    const f = await fixture();
    await writeFile(f.extensionPath, providerExtension("retained-provider", false, true));
    await configure(f.agentDir, [f.extensionPath]);
    const resources = await f.createResources();

    const refreshed = new Promise<void>((resolve) => f.broadcast.mockImplementationOnce(resolve));
    const invalidRegistration = providerExtension("retained-provider", false, true)
      .replaceAll('api: "openai-completions",', "");
    await writeFile(f.extensionPath, invalidRegistration);
    resources.requestReload();
    await refreshed;

    const provider = f.runtime.getProvider("retained-provider");
    expect(provider).toBeDefined();
    const credential = await provider!.auth.oauth!.login({
      signal: new AbortController().signal,
      prompt: async () => "",
      notify: () => {},
    });
    expect(credential.refresh).toContain("Extension runtime not initialized");
    expect(credential.refresh).not.toContain("Global provider extension resources were reloaded");
  });

  it("holds global provider catalog reads until an asynchronous resource refresh commits", async () => {
    const f = await fixture();
    const initial = join(f.root, "initial.ts");
    const added = join(f.root, "added.ts");
    await writeFile(initial, providerExtension("initial-provider"));
    await writeFile(added, providerExtension("added-provider"));
    await configure(f.agentDir, [initial]);
    const resources = await f.createResources();
    f.broadcast.mockClear();
    const dashboard = new GatewayService({
      modelRuntime: f.runtime,
      sessions: { isAdministrativeDrainStarted: false },
      globalProviderResources: resources,
    } as unknown as GatewayServiceDependencies);

    let releaseRefresh!: () => void;
    let refreshEntered!: () => void;
    let refreshCalls = 0;
    const entered = new Promise<void>((resolve) => { refreshEntered = resolve; });
    const blockedRefresh = new Promise<void>((resolve) => { releaseRefresh = resolve; });
    const originalRefresh = f.runtime.refresh.bind(f.runtime);
    f.runtime.refresh = async (options) => {
      refreshCalls += 1;
      refreshEntered();
      await blockedRefresh;
      return originalRefresh(options);
    };
    await writeFile(join(f.agentDir, "settings.json"), JSON.stringify({ extensions: [initial, added] }));
    const refreshed = new Promise<void>((resolve) => f.broadcast.mockImplementationOnce(resolve));
    resources.requestReload();
    await entered;

    let catalogResolved = false;
    const catalogPromise = dashboard.invoke(client, "provider.list", {}).then((result) => {
      catalogResolved = true;
      return result as { providers: Array<{ id: string }> };
    });
    let modelsResolved = false;
    const modelsPromise = dashboard.invoke(client, "model.list", {}).then((result) => {
      modelsResolved = true;
      return result as { models: Array<{ provider: string }> };
    });
    await settleScheduledWork();
    expect(refreshCalls).toBeGreaterThan(0);
    expect(catalogResolved).toBe(false);
    expect(modelsResolved).toBe(false);

    releaseRefresh();
    await refreshed;
    const catalog = await catalogPromise;
    let models = await modelsPromise;
    const modelProviders = new Set(models.models.map(({ provider }) => provider));
    while (models.nextCursor) {
      models = await dashboard.invoke(client, "model.list", { cursor: models.nextCursor }) as typeof models;
      for (const { provider } of models.models) modelProviders.add(provider);
    }
    expect(catalog.providers.map(({ id }) => id)).toContain("added-provider");
    expect(modelProviders).toContain("added-provider");
  });

  it("defers global resource replacement until the exact global login settles", async () => {
    const f = await fixture();
    await writeFile(f.extensionPath, providerExtension("global-fixture", true));
    await configure(f.agentDir, [f.extensionPath]);
    const resources = await f.createResources();
    f.broadcast.mockClear();
    const operationId = f.broker.start("dashboard", "global-fixture", "oauth", f.runtime, "dashboard-device", "login-1", "global").operationId;
    await f.waitForAuthEvent(() => f.events.some((event) => event.topic === "auth.prompt"));
    const refreshed = new Promise<void>((resolve) => f.broadcast.mockImplementationOnce(resolve));
    await writeFile(join(f.agentDir, "settings.json"), JSON.stringify({ extensions: [] }));
    resources.requestReload();
    expect(f.broadcast).not.toHaveBeenCalled();
    expect(f.runtime.getProvider("global-fixture")).toBeDefined();
    const prompt = f.events.find((event) => event.topic === "auth.prompt")!.payload as Record<string, JsonValue>;
    f.broker.respond("dashboard-device", operationId, prompt.promptId as string, "fixture-code");
    await f.waitForAuthEvent(() => f.events.some((event) => event.topic === "auth.completed"));
    await refreshed;
    expect(f.events).toContainEqual(expect.objectContaining({ topic: "auth.completed", payload: expect.objectContaining({ operationId, success: true }) }));
    expect(f.runtime.getProvider("global-fixture")).toBeUndefined();
  });

  it("retains valid provider registrations when another extension fails to load", async () => {
    const f = await fixture();
    const valid = join(f.root, "valid.ts");
    const broken = join(f.root, "formerly-valid.ts");
    await writeFile(valid, providerExtension("valid-provider"));
    await writeFile(broken, providerExtension("retained-provider"));
    await configure(f.agentDir, [valid, broken]);
    const resources = await f.createResources();
    f.broadcast.mockClear();

    const refreshed = new Promise<void>((resolve) => f.broadcast.mockImplementationOnce(resolve));
    await writeFile(broken, "export default (pi) => { this is not valid javascript");
    resources.requestReload();
    await refreshed;
    expect(f.runtime.getProvider("valid-provider")).toBeDefined();
    expect(f.runtime.getProvider("retained-provider")).toBeDefined();
    expect(f.log).toHaveBeenCalledWith("error", expect.stringContaining("formerly-valid.ts"));
  });
});
