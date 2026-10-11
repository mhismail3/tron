import { execFileSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { ModelRuntime, SettingsManager } from "@earendil-works/pi-coding-agent";
import { fauxProvider } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { TrustService } from "./trust-service.js";
import { SettingsModel } from "./settings-model.js";
import { KEYS, UNDECLARED_PI_SETTINGS, type KeyDeclaration } from "./settings-schema.js";
import type { Resolution, ResolvedKey } from "./settings-resolver.js";
import { RuntimeRegistry } from "../sessions/runtime-registry.js";
import { CommandReceiptStore } from "../transport/command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../transport/gateway-service.js";

/**
 * settings.resolve at its real boundaries (docs/settings-model.md F1, F4):
 * the Gateway RPC over real stores, a real RuntimeRegistry chat, pi's own
 * SettingsManager as the oracle, a real git linked worktree, and the pinned pi
 * settings reference. The resolved report is retained as an artifact.
 */
const ARTIFACT = join(dirname(new URL(import.meta.url).pathname), "../../test-results/settings-resolve.json");
const roots: string[] = [];
const registries: RuntimeRegistry[] = [];
afterEach(async () => {
  await Promise.all(registries.splice(0).map(registry => registry.dispose().catch(() => {})));
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});

function subscribed(sessionIds: string[] = []): ClientContext {
  return { id: "settings-client", identity: "local", isLocal: true, isSubscribed: (id: string) => sessionIds.includes(id), isRevoked: () => false, revokeDevice: () => {} } as unknown as ClientContext;
}

function row(resolution: Resolution, key: string, qualifiers?: Record<string, string>): ResolvedKey {
  const found = resolution.keys.find(candidate => candidate.key === key
    && (!qualifiers || Object.entries(qualifiers).every(([name, value]) => candidate.qualifiers?.[name as "model"] === value)));
  if (!found) throw new Error(`${key} was not resolved`);
  return found;
}

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "tron-settings-model-"));
  roots.push(root);
  const tronHome = join(root, "tron");
  const agentDir = join(tronHome, "agent");
  const sessionDir = join(root, "sessions");
  const project = join(root, "project");
  await Promise.all([mkdir(agentDir, { recursive: true }), mkdir(sessionDir, { recursive: true }), mkdir(join(project, ".pi"), { recursive: true })]);
  const faux = fauxProvider({ provider: "tron-settings-model", tokensPerSecond: 10_000, models: [{ id: "reasoner", reasoning: true, contextWindow: 200_000 }] });
  const model = faux.getModel();
  const modelKey = `${model.provider}/${model.id}`;
  const runtimeFactory = async () => {
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    return runtime;
  };
  const modelRuntime = await runtimeFactory();
  // Mac layer.
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({
    sessionDir,
    defaultProvider: model.provider,
    defaultModel: model.id,
    defaultThinkingLevel: "high",
    steeringMode: "all",
    retry: { maxRetries: 5 },
    defaultTools: ["read", "bash"],
    compaction: { reserveTokens: 20_000 },
    httpProxy: "http://proxy.invalid:8080",
  }));
  // Project layer, including a key the Project layer may not set.
  await writeFile(join(project, ".pi", "settings.json"), JSON.stringify({
    retry: { maxRetries: 7 },
    transport: "sse",
    defaultTools: ["+write"],
    defaultProjectTrust: "always",
    compaction: { modelOverrides: { [modelKey]: { reserveTokens: 30_000 } } },
  }));
  const trust = new TrustService(agentDir);
  const registry = new RuntimeRegistry({
    agentDir, tronHome, idleRuntimeMs: 60_000, modelRuntimeFactory: runtimeFactory, trust,
    broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
  });
  registries.push(registry);
  await registry.initialize();
  const settingsModel = new SettingsModel({
    agentDir, tronHome, trust, modelRuntime,
    homeMemoryModel: async () => ({ provider: model.provider, id: model.id }),
  });
  const service = new GatewayService({
    config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome, agentDir },
    modelRuntime, trust, settingsModel, sessions: registry, receipts: new CommandReceiptStore(tronHome),
    broadcast: () => {}, globalProviderResources: { withStableSnapshot: async (operation: () => Promise<unknown>) => operation(), requestReload: () => {} },
  } as unknown as GatewayServiceDependencies);
  return { root, tronHome, agentDir, project, trust, registry, service, settingsModel, model, modelKey };
}

/** What pi's own SettingsManager resolves for each key it owns: the oracle. */
function piEffective(manager: SettingsManager, model: { provider: string; id: string }): Record<string, unknown> {
  return {
    "model.thinking[role=chat]": manager.getModelThinkingLevel(model.provider, model.id) ?? manager.getDefaultThinkingLevel(),
    "run.retry.maxRetries": manager.getRetrySettings().maxRetries,
    "run.retry.enabled": manager.getRetrySettings().enabled,
    "run.retry.baseDelayMs": manager.getRetrySettings().baseDelayMs,
    "run.retry.provider.maxRetryDelayMs": manager.getProviderRetrySettings().maxRetryDelayMs,
    "run.transport": manager.getTransport(),
    "run.queue.steeringMode": manager.getSteeringMode(),
    "run.queue.followUpMode": manager.getFollowUpMode(),
    "run.httpIdleTimeoutMs": manager.getHttpIdleTimeoutMs(),
    "run.cacheWarming": manager.getCacheWarmingMode(),
    "tools.active": manager.getDefaultTools(),
    "context.compaction.enabled": manager.getCompactionSettings(model as never).enabled,
    "context.compaction.reserveTokens": manager.getCompactionSettings(model as never).reserveTokens,
    "context.compaction.keepRecentTokens": manager.getCompactionSettings(model as never).keepRecentTokens,
    "context.branchSummary.reserveTokens": manager.getBranchSummarySettings().reserveTokens,
    "context.images.autoResize": manager.getImageAutoResize(),
    "context.images.block": manager.getBlockImages(),
    "permissions.defaultProjectTrust": manager.getDefaultProjectTrust(),
    "setup.installTelemetry": manager.getEnableInstallTelemetry(),
  };
}

describe("settings.resolve", () => {
  it("resolves five uniform layers for every target, shows an untrusted project as not applied, and matches pi and a live chat", async () => {
    const { service, project, registry, model, modelKey, tronHome, agentDir, trust } = await fixture();
    const client = subscribed();
    const resolve = (target: Record<string, unknown>, c = client) => service.invoke(c, "settings.resolve", { target }) as Promise<Resolution>;

    // Untrusted: the project's values are present but not applied (doc 3.5).
    const untrusted = await resolve({ kind: "project", cwd: project });
    const retries = row(untrusted, "run.retry.maxRetries");
    expect(retries).toMatchObject({ value: 5, layer: "mac", applied: false, reason: "untrusted", display: "5 retries" });
    expect(retries.layers.find(layer => layer.layer === "project")).toMatchObject({ value: 7, applied: false, reason: "untrusted" });
    expect(retries.badges).toContainEqual(expect.objectContaining({ kind: "state", label: "Not applied (untrusted)" }));
    // Untrusted equals what pi itself applies without trust.
    const piUntrusted = piEffective(SettingsManager.create(project, agentDir, { projectTrusted: false }), model);
    for (const [key, expected] of Object.entries(piUntrusted)) expect(row(untrusted, key).value, key).toEqual(expected);
    // A Project value for a Mac-only key is a diagnostic, never applied.
    expect(untrusted.diagnostics).toContainEqual({ key: "permissions.defaultProjectTrust", layer: "project", reason: "layer-not-allowed", path: "defaultProjectTrust" });
    expect(row(untrusted, "permissions.defaultProjectTrust").value).toBe("ask");
    // Redacted: shown as set, never the value.
    expect(row(untrusted, "run.httpProxy")).toMatchObject({ display: "Set", layer: "mac" });
    expect(JSON.stringify(untrusted)).not.toContain("proxy.invalid");

    // Trusting flips the project's values to applied with no other change.
    await trust.set(project, true);
    const trusted = await resolve({ kind: "project", cwd: project });
    expect(row(trusted, "run.retry.maxRetries")).toMatchObject({ value: 7, layer: "project", applied: true, display: "7 retries" });
    const strip = (resolution: Resolution) => resolution.keys.filter(key => key.key !== "permissions.projectTrust").map(key => ({
      key: key.key, qualifiers: key.qualifiers,
      layers: key.layers.map(({ applied: _applied, reason: _reason, ...rest }) => rest),
    }));
    expect(strip(trusted)).toEqual(strip(untrusted));
    expect(row(trusted, "permissions.projectTrust")).toMatchObject({ value: true, display: "Trusted", qualifiers: { project: trusted.keys.find(k => k.key === "permissions.projectTrust")!.qualifiers!.project } });

    // Trusted equals pi's merged resolution, including the +name tool modifier
    // and the per-model compaction override that beats the Mac ordinary value.
    const piTrusted = piEffective(SettingsManager.create(project, agentDir, { projectTrusted: true }), model);
    for (const [key, expected] of Object.entries(piTrusted)) {
      const qualifiers = key.startsWith("context.compaction.") && key !== "context.compaction.enabled" ? { model: modelKey } : undefined;
      expect(row(trusted, key, qualifiers).value, key).toEqual(expected);
    }
    expect(row(trusted, "tools.active").value).toEqual(["read", "bash", "write"]);
    expect(row(trusted, "context.compaction.reserveTokens", { model: modelKey })).toMatchObject({ value: 30_000, layer: "project" });

    // Mac target: Mac and Built-in only.
    const mac = await resolve({ kind: "mac" });
    expect(mac.layers).toEqual(["mac", "builtin"]);
    expect(row(mac, "run.retry.maxRetries")).toMatchObject({ value: 5, layer: "mac" });
    expect(row(mac, "run.retry.baseDelayMs")).toMatchObject({ value: 2_000, layer: "builtin" });

    // Session target: a live chat in the project. Its Chat layer is what the
    // runtime actually uses, and a fresh runtime used the resolver's values.
    const slot = await registry.create(project);
    const session = await resolve({ kind: "session", sessionId: slot.id }, subscribed([slot.id]));
    expect(session.layers).toEqual(["chat", "project", "mac", "builtin"]);
    const context = await slot.context() as { activeTools: string[] };
    const snapshot = slot.snapshot();
    expect(row(session, "model.ref[role=chat]")).toMatchObject({ value: { provider: model.provider, id: model.id }, layer: "chat" });
    expect(snapshot.model).toEqual(row(trusted, "model.ref[role=chat]").value);
    expect(row(session, "model.thinking[role=chat]", { model: modelKey }).value).toBe(snapshot.thinkingLevel);
    expect(snapshot.thinkingLevel).toBe(row(trusted, "model.thinking[role=chat]", { model: modelKey }).value);
    expect([...row(session, "tools.active").value as string[]].sort()).toEqual([...context.activeTools].sort());
    for (const tool of row(trusted, "tools.active").value as string[]) expect(context.activeTools).toContain(tool);
    // A Run key with no Chat value follows the project for this chat.
    expect(row(session, "run.retry.maxRetries")).toMatchObject({ value: 7, layer: "project" });
    // Home-only profile keys never appear on an ordinary chat (doc 3.3).
    expect(session.keys.some(key => key.key === "model.ref[role=worker]")).toBe(false);

    // Home profile target: Profile, Mac and Built-in; "same as Home" is built in.
    await mkdir(join(tronHome, "gateway", "home"), { recursive: true });
    await writeFile(join(tronHome, "gateway", "home", "profile.json"), JSON.stringify({ thinking: { worker: "low" } }));
    const home = await resolve({ kind: "home" });
    expect(home.layers).toEqual(["profile", "mac", "builtin"]);
    expect(row(home, "model.ref[role=worker]")).toMatchObject({ value: { sameAs: "home" }, layer: "builtin", display: "Same as Home" });
    expect(row(home, "model.thinking[role=worker]")).toMatchObject({ value: "low", layer: "profile", badges: expect.arrayContaining([{ kind: "layer", label: "Profile: Home" }]) });
    expect(row(home, "model.ref[role=memory]")).toMatchObject({ layer: "profile", value: { provider: model.provider, id: model.id } });

    await mkdir(dirname(ARTIFACT), { recursive: true });
    await writeFile(ARTIFACT, `${JSON.stringify({ untrusted, trusted, mac, session, home }, null, 2)}\n`);
  });

  it("clamps a thinking level the resolved model does not support, with a Clamped badge", async () => {
    const { service, agentDir } = await fixture();
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    const plain = runtime.getModels().find(candidate => !candidate.reasoning);
    if (!plain) throw new Error("the pinned catalog has no non-reasoning model");
    const document = JSON.parse(await readFile(join(agentDir, "settings.json"), "utf8"));
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ ...document, defaultProvider: plain.provider, defaultModel: plain.id }));
    const mac = await service.invoke(subscribed(), "settings.resolve", { target: { kind: "mac" } }) as Resolution;
    const thinking = row(mac, "model.thinking[role=chat]");
    expect(thinking.value).toBe("off");
    expect(thinking.badges).toContainEqual(expect.objectContaining({ kind: "state", label: "Clamped" }));
  });

  it("resolves a linked worktree's own .pi, not the main checkout's", async () => {
    const { root, service, trust } = await fixture();
    const main = join(root, "repo");
    const linked = join(root, "repo-linked");
    await mkdir(join(main, ".pi"), { recursive: true });
    const git = (cwd: string, ...args: string[]) => execFileSync("git", args, { cwd, stdio: "pipe", env: { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1" } });
    git(main, "init", "-q", "-b", "main");
    await writeFile(join(main, ".pi", "settings.json"), JSON.stringify({ retry: { maxRetries: 9 } }));
    git(main, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "add", ".");
    git(main, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "-m", "init");
    git(main, "worktree", "add", "-q", "-b", "linked", linked);
    await writeFile(join(linked, ".pi", "settings.json"), JSON.stringify({ retry: { maxRetries: 2 } }));
    await trust.set(main, true);
    await trust.set(linked, true);
    const resolveFor = async (cwd: string) => row(await service.invoke(subscribed(), "settings.resolve", { target: { kind: "project", cwd } }) as Resolution, "run.retry.maxRetries");
    expect(await resolveFor(linked)).toMatchObject({ value: 2, layer: "project" });
    expect(await resolveFor(main)).toMatchObject({ value: 9, layer: "project" });
  });
});

describe("the schema against the pinned pi settings", () => {
  // The pinned package's own settings reference (resolved like gateway-main resolves its CLI).
  const piRoot = dirname(dirname(fileURLToPath(import.meta.resolve("@earendil-works/pi-coding-agent"))));

  async function piReference() {
    const reference = await readFile(join(piRoot, "docs", "settings.md"), "utf8");
    const rows = [...reference.matchAll(/^\| `([A-Za-z.]+)` \|(.*)$/gmu)];
    return rows.map(([, key, rest]) => ({ key: key!, agentDirOnly: /Can only be set in agent-directory settings|Global setting only/u.test(rest!) }));
  }

  function declaredPaths(keys: readonly KeyDeclaration[]): Map<string, KeyDeclaration> {
    const paths = new Map<string, KeyDeclaration>();
    for (const key of keys) {
      for (const binding of Object.values(key.layers)) {
        if (binding.store === "pi-model-ref") { paths.set("defaultProvider", key); paths.set("defaultModel", key); }
        if (binding.store !== "pi") continue;
        for (const path of [binding.path, binding.qualified ?? []]) {
          const prefix = path.slice(0, path.indexOf("{model}") === -1 ? path.length : path.indexOf("{model}"));
          if (prefix.length) paths.set(prefix.join("."), key);
        }
      }
    }
    return paths;
  }

  /** Every pi key is declared or deliberately undeclared, and pi's agent-dir-only keys allow only the Mac layer. */
  function coverageFailures(keys: readonly KeyDeclaration[], reference: Array<{ key: string; agentDirOnly: boolean }>): string[] {
    const declared = declaredPaths(keys);
    const failures: string[] = [];
    for (const { key, agentDirOnly } of reference) {
      const undeclared = UNDECLARED_PI_SETTINGS.some(name => key === name || key.startsWith(`${name}.`));
      const owner = declared.get(key) ?? [...declared.entries()].find(([path]) => key.startsWith(`${path}.`))?.[1];
      if (!owner && !undeclared) failures.push(`${key} is neither declared nor listed as undeclared`);
      if (owner && agentDirOnly && Object.keys(owner.layers).some(layer => layer !== "mac")) failures.push(`${key} is agent-directory only but ${owner.id} allows ${Object.keys(owner.layers).join(", ")}`);
    }
    return failures;
  }

  it("covers every pi setting and confines agent-directory-only keys to the Mac layer", async () => {
    const reference = await piReference();
    expect(reference.length).toBeGreaterThan(50);
    expect(reference.filter(entry => entry.agentDirOnly).map(entry => entry.key).sort()).toEqual(["cacheWarming", "defaultProjectTrust", "httpProxy"]);
    expect(coverageFailures(KEYS, reference)).toEqual([]);
    // Negative control: declaring an agent-dir-only key at the Project layer fails.
    const mutated = KEYS.map(key => key.id === "run.httpProxy" ? { ...key, layers: { ...key.layers, project: key.layers.mac! } } : key);
    expect(coverageFailures(mutated, reference)).toEqual([expect.stringContaining("httpProxy is agent-directory only")]);
    // A pi key nobody declared fails too.
    expect(coverageFailures(KEYS, [...reference, { key: "futureSetting", agentDirOnly: false }])).toEqual(["futureSetting is neither declared nor listed as undeclared"]);
  });

  it("declares built-in values equal to pi's defaults", () => {
    const manager = SettingsManager.inMemory({});
    const builtins: Record<string, unknown> = {
      "run.retry.maxRetries": manager.getRetrySettings().maxRetries, "run.retry.enabled": manager.getRetrySettings().enabled,
      "run.retry.baseDelayMs": manager.getRetrySettings().baseDelayMs, "run.transport": manager.getTransport(),
      "run.retry.provider.maxRetryDelayMs": manager.getProviderRetrySettings().maxRetryDelayMs,
      "run.queue.steeringMode": manager.getSteeringMode(), "run.queue.followUpMode": manager.getFollowUpMode(),
      "run.httpIdleTimeoutMs": manager.getHttpIdleTimeoutMs(), "run.cacheWarming": manager.getCacheWarmingMode(),
      "context.compaction.enabled": manager.getCompactionSettings().enabled,
      "context.compaction.reserveTokens": manager.getCompactionSettings().reserveTokens,
      "context.compaction.keepRecentTokens": manager.getCompactionSettings().keepRecentTokens,
      "context.branchSummary.reserveTokens": manager.getBranchSummarySettings().reserveTokens,
      "context.images.autoResize": manager.getImageAutoResize(), "context.images.block": manager.getBlockImages(),
      "permissions.defaultProjectTrust": manager.getDefaultProjectTrust(), "setup.installTelemetry": manager.getEnableInstallTelemetry(),
    };
    for (const [id, expected] of Object.entries(builtins)) expect(KEYS.find(key => key.id === id)?.builtin, id).toEqual(expected);
  });
});
