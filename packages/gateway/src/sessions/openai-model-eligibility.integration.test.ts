import { mkdtemp, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { createServer, type AddressInfo, type Server } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime, SessionManager } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, type Credential, type CredentialInfo, type CredentialStore } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import { OpenAIModelEligibility } from "../providers/openai-model-eligibility.js";
import { RuntimeRegistry } from "./runtime-registry.js";

class SessionCredentials implements CredentialStore {
  constructor(
    private readonly openai: Credential | undefined = { type: "oauth", access: "session-openai-token", refresh: "refresh", expires: Date.now() + 3_600_000 },
    private readonly codex: Credential | undefined | null = { type: "oauth", access: "session-codex-token", refresh: "refresh", expires: Date.now() + 3_600_000 },
    private readonly anthropic?: Credential,
  ) {}
  async read(providerId: string): Promise<Credential | undefined> {
    if (providerId === "openai") return this.openai;
    if (providerId === "openai-codex") return this.codex ?? undefined;
    if (providerId === "anthropic") return this.anthropic;
    return undefined;
  }
  async list(): Promise<readonly CredentialInfo[]> {
    return [
      ...(this.openai ? [{ providerId: "openai", type: this.openai.type } as const] : []),
      ...(this.codex ? [{ providerId: "openai-codex", type: this.codex.type } as const] : []),
      ...(this.anthropic ? [{ providerId: "anthropic", type: this.anthropic.type } as const] : []),
    ];
  }
  async modify(_providerId: string, fn: (current: Credential | undefined) => Promise<Credential | undefined>) {
    return fn(undefined);
  }
  async delete() {}
}

describe("new-session OpenAI default admission", () => {
  let root = "";
  let registry: RuntimeRegistry | undefined;
  let server: Server | undefined;
  afterEach(async () => {
    await registry?.dispose();
    registry = undefined;
    if (server) await new Promise<void>((resolve, reject) => server!.close(error => error ? reject(error) : resolve()));
    server = undefined;
    vi.unstubAllGlobals();
    if (root) await rm(root, { recursive: true, force: true });
    root = "";
  });

  async function useAccountModels(entries: Array<{ slug: string; visibility: string }>): Promise<void> {
    server = createServer((_request, response) => {
      response.setHeader("content-type", "application/json");
      response.end(JSON.stringify({ models: entries, has_more: false }));
    });
    await new Promise<void>(resolve => server!.listen(0, "127.0.0.1", resolve));
    const endpoint = `http://127.0.0.1:${(server.address() as AddressInfo).port}/v1/models`;
    const originalFetch = globalThis.fetch;
    vi.stubGlobal("fetch", async (input: RequestInfo | URL, init?: RequestInit) => {
      const target = new URL(endpoint);
      target.search = new URL(String(input)).search;
      return originalFetch(target, init);
    });
  }

  async function createRegistry(agentDir: string, credentials: CredentialStore, eligibility?: OpenAIModelEligibility): Promise<void> {
    registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      ...(eligibility ? { openAIModelEligibility: eligibility } : {}),
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false, credentials }),
      trust: new TrustService(agentDir), broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    await registry.initialize();
  }

  it("reopens an existing Codex transcript without changing its model identity", async () => {
    root = await mkdtemp(join(tmpdir(), "tron-openai-existing-session-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const sessionDir = join(agentDir, "sessions", "workspace");
    await Promise.all([mkdir(agentDir, { recursive: true }), mkdir(cwd, { recursive: true }), mkdir(sessionDir, { recursive: true })]);
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ defaultProvider: "openai-codex", defaultModel: "gpt-5.6-sol" }));
    vi.stubGlobal("fetch", vi.fn(async () => { throw new Error("unexpected discovery for a historical session identity check"); }));
    const manager = SessionManager.create(cwd, sessionDir);
    manager.appendMessage(fauxAssistantMessage("historical transcript"));
    manager.appendModelChange("openai-codex", "gpt-5.6-sol");
    const sessionPath = manager.getSessionFile()!;
    const modelChanges = (value: string) => value.split("\n").filter(Boolean).map(line => JSON.parse(line) as { type?: string }).filter(entry => entry.type === "model_change");
    const before = modelChanges(await readFile(sessionPath, "utf8"));
    registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false, credentials: new SessionCredentials() }),
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    await registry.initialize();
    await (registry as unknown as { sessionCatalog: { whenPublished(): Promise<void> } }).sessionCatalog.whenPublished();
    const slot = await registry.acquire(manager.getSessionId());
    expect(slot.snapshot().model).toEqual({ provider: "openai-codex", id: "gpt-5.6-sol" });
    expect(modelChanges(await readFile(sessionPath, "utf8"))).toEqual(before);
  });

  it("does not use a saved Codex default while usage is lent, without rewriting settings or breaking creation", async () => {
    root = await mkdtemp(join(tmpdir(), "tron-openai-new-session-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir, { recursive: true }), mkdir(cwd, { recursive: true })]);
    const settingsPath = join(agentDir, "settings.json");
    const savedSettings = JSON.stringify({ defaultProvider: "openai-codex", defaultModel: "gpt-5.6-sol" });
    await writeFile(settingsPath, savedSettings);
    server = createServer((_request, response) => {
      response.setHeader("content-type", "application/json");
      response.end(JSON.stringify({ models: [{ slug: "gpt-5.5", visibility: "list" }, { slug: "gpt-5.6-sol", visibility: "list" }], has_more: false }));
    });
    await new Promise<void>(resolve => server!.listen(0, "127.0.0.1", resolve));
    const endpoint = `http://127.0.0.1:${(server.address() as AddressInfo).port}/v1/models`;
    const originalFetch = globalThis.fetch;
    vi.stubGlobal("fetch", async (input: RequestInfo | URL, init?: RequestInit) => {
      const request = new URL(String(input));
      const target = new URL(endpoint);
      target.search = request.search;
      return originalFetch(target, init);
    });

    registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false, credentials: new SessionCredentials() }),
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = slot.snapshot().model;
    expect(model).toEqual({ provider: "openai", id: "gpt-5.5" });
    const availableOpenAI = slot.modelRuntime.getAvailableSnapshot().filter(available => available.provider === "openai").map(available => available.id);
    expect(availableOpenAI).toEqual(["gpt-5.5", "gpt-5.6-sol"]);
    const session = (slot as unknown as { runtime: { session: { cycleModel(direction: "forward"): Promise<{ model: { provider: string; id: string } } | undefined> } } }).runtime.session;
    const cycled = await session.cycleModel("forward");
    expect(cycled?.model.provider).toBe("openai");
    expect(availableOpenAI).toContain(cycled?.model.id);
    expect(cycled?.model.id).not.toBe("gpt-4");
    expect(await readFile(settingsPath, "utf8")).toBe(savedSettings);
  });

  it("refreshes an OAuth catalog before a no-default session resolves its first model", async () => {
    root = await mkdtemp(join(tmpdir(), "tron-openai-no-default-oauth-"));
    const agentDir = join(root, "agent"); const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir, { recursive: true }), mkdir(cwd, { recursive: true })]);
    await useAccountModels([{ slug: "gpt-5.5", visibility: "list" }]);
    await createRegistry(agentDir, new SessionCredentials(undefined, null));
    const slot = await registry!.create(cwd);
    expect(slot.snapshot().model).toEqual({ provider: "openai", id: "gpt-5.5" });
  });

  it("keeps API-key OpenAI and an unrelated provider available for a no-default session", async () => {
    root = await mkdtemp(join(tmpdir(), "tron-openai-no-default-api-key-"));
    const agentDir = join(root, "agent"); const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir, { recursive: true }), mkdir(cwd, { recursive: true })]);
    const credentials = new SessionCredentials({ type: "api_key", key: "api-key-fixture" }, null, { type: "api_key", key: "anthropic-fixture" });
    const discoveryFetch = vi.fn(async () => { throw new Error("API-key account must not be discovered"); });
    await createRegistry(agentDir, credentials, new OpenAIModelEligibility({ fetch: discoveryFetch as typeof fetch }));
    const slot = await registry!.create(cwd);
    const available = slot.modelRuntime.getAvailableSnapshot();
    expect(available.some(model => model.provider === "openai")).toBe(true);
    expect(available.some(model => model.provider === "anthropic")).toBe(true);
    expect(slot.snapshot().model).not.toEqual({ provider: "unknown", id: "unknown" });
    expect(discoveryFetch).not.toHaveBeenCalled();
    expect(server).toBeUndefined();
  });

  it("fails a saved ineligible default only when no fallback exists and publishes no partial session", async () => {
    root = await mkdtemp(join(tmpdir(), "tron-openai-no-fallback-"));
    const agentDir = join(root, "agent"); const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir, { recursive: true }), mkdir(cwd, { recursive: true })]);
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ defaultProvider: "openai", defaultModel: "gpt-4" }));
    await useAccountModels([]);
    await createRegistry(agentDir, new SessionCredentials(undefined, null));
    await expect(registry!.create(cwd)).rejects.toMatchObject({
      code: "invalid_request",
      message: expect.stringContaining("saved default model is no longer available"),
    });
    expect((await registry!.catalog()).sessions).toEqual([]);
    const sessionDirectory = join(agentDir, "sessions", "workspace");
    const files = await readdir(sessionDirectory).catch(() => [] as string[]);
    expect(files.filter(file => file.endsWith(".jsonl"))).toEqual([]);
  });

  it("matches Pi's no-available-model behavior when a new account lists no eligible model", async () => {
    root = await mkdtemp(join(tmpdir(), "tron-openai-no-model-control-"));
    const agentDir = join(root, "agent"); const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir, { recursive: true }), mkdir(cwd, { recursive: true })]);
    await useAccountModels([]);
    await createRegistry(agentDir, new SessionCredentials(undefined, null));
    const slot = await registry!.create(cwd);
    expect(slot.snapshot().model).toEqual({ provider: "unknown", id: "unknown" });
  });
});
