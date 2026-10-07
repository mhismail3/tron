import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime, SessionManager } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, type Credential, type CredentialInfo, type CredentialStore } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import { RuntimeRegistry } from "./runtime-registry.js";

class SessionCredentials implements CredentialStore {
  async read(providerId: string): Promise<Credential | undefined> {
    if (providerId === "openai") return { type: "oauth", access: "session-openai-token", refresh: "refresh", expires: Date.now() + 3_600_000 };
    if (providerId === "openai-codex") return { type: "oauth", access: "session-codex-token", refresh: "refresh", expires: Date.now() + 3_600_000 };
    if (providerId === "anthropic") return { type: "api_key", key: "session-anthropic-key" };
    return undefined;
  }
  async list(): Promise<readonly CredentialInfo[]> {
    return [
      { providerId: "openai", type: "oauth" },
      { providerId: "openai-codex", type: "oauth" },
      { providerId: "anthropic", type: "api_key" },
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
  afterEach(async () => {
    await registry?.dispose();
    registry = undefined;
    vi.unstubAllGlobals();
    if (root) await rm(root, { recursive: true, force: true });
    root = "";
  });

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
    vi.stubGlobal("fetch", vi.fn(async () => { throw new Error("unexpected live fetch in the initial snapshot test"); }));

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
    expect(model.provider).not.toBe("openai-codex");
    expect(model.provider).not.toBe("openai");
    expect(slot.modelRuntime.getAvailableSnapshot().some(available => available.provider === model.provider && available.id === model.id)).toBe(true);
    expect(await readFile(settingsPath, "utf8")).toBe(savedSettings);
  });
});
