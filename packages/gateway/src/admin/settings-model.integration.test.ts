import { execFileSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { ModelRuntime, SettingsManager } from "@earendil-works/pi-coding-agent";
import { fauxProvider } from "@earendil-works/pi-ai";
import { getSupportedThinkingLevels } from "@earendil-works/pi-ai";
import { afterAll, afterEach, describe, expect, it } from "vitest";
import { TrustService } from "./trust-service.js";
import { SettingsChangePath, SettingsModel } from "./settings-model.js";
import { SettingsChangeRecord, type ChangeEntry } from "./settings-record.js";
import { SettingsApprovals } from "./settings-approvals.js";
import { KEYS } from "./settings-schema.js";
import type { Resolution, ResolvedKey, SettingsTarget } from "./settings-resolver.js";
import { UPDATE_TRON_NOTE, type PresentedKey, type PresentedResolution } from "./settings-presentation.js";
import { CONTROLS } from "./settings-types.js";
import { contextWindowLimits } from "../providers/context-window-policy.js";
import { RuntimeRegistry } from "../sessions/runtime-registry.js";
import { CommandReceiptStore } from "../transport/command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../transport/gateway-service.js";

/**
 * settings.resolve at its real boundaries (docs/settings-model.md F1, F4):
 * the Gateway RPC over real stores, a real RuntimeRegistry chat, pi's own
 * SettingsManager as the oracle and a real git linked worktree. The resolved
 * report, including fallback after the store values are removed, is retained.
 */
const ARTIFACT = join(dirname(new URL(import.meta.url).pathname), "../../test-results/settings-resolve.json");
const RENDERER_ARTIFACT = join(dirname(new URL(import.meta.url).pathname), "../../test-results/settings-renderer.integration.json");
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
  const faux = fauxProvider({
    provider: "tron-settings-model", tokensPerSecond: 10_000,
    models: [{ id: "reasoner", reasoning: true, contextWindow: 200_000 }, { id: "plain", reasoning: false }],
  });
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
  const settingsChanges = new SettingsChangePath(settingsModel, new SettingsChangeRecord(tronHome), new SettingsApprovals(tronHome), {
    setTrust: async (project, decision) => trust.setAndApply(project, decision,
      async inspection => { await registry.reloadProject(inspection.projectDir, inspection.effectiveDecision === true, false); },
      async inspection => { await registry.commitProjectReload(inspection.projectDir); }),
  }, agentDir);
  const service = new GatewayService({
    config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome, agentDir },
    modelRuntime, trust, settingsModel, settingsChanges, sessions: registry, receipts: new CommandReceiptStore(tronHome),
    broadcast: () => {}, globalProviderResources: { withStableSnapshot: async (operation: () => Promise<unknown>) => operation(), requestReload: () => {} },
  } as unknown as GatewayServiceDependencies);
  return { root, tronHome, agentDir, project, trust, registry, service, settingsModel, settingsChanges, model, modelKey, faux };
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
  it("declares no Project or Chat layer for a key the pinned pi reads only from the agent directory", async () => {
    // The pinned pi's own settings reference marks its agent-directory-only keys;
    // a pi upgrade that adds or moves one fails here rather than drifting silently.
    const reference = await readFile(join(dirname(fileURLToPath(import.meta.resolve("@earendil-works/pi-coding-agent"))), "..", "docs", "settings.md"), "utf8");
    const agentDirOnly = reference.split("\n").flatMap(line => {
      const match = /^\| `([^`]+)` \|/u.exec(line);
      return match && /Can only be set in agent-directory settings|Global setting only/u.test(line) ? [match[1]!] : [];
    });
    expect(agentDirOnly).toEqual(expect.arrayContaining(["cacheWarming", "defaultProjectTrust", "httpProxy"]));
    // pi honours that: a trusted project's values for these keys are ignored.
    const root = await mkdtemp(join(tmpdir(), "tron-settings-agent-dir-only-"));
    try {
      const agentDir = join(root, "agent");
      const project = join(root, "project");
      await mkdir(agentDir, { recursive: true });
      await mkdir(join(project, ".pi"), { recursive: true });
      await writeFile(join(agentDir, "settings.json"), JSON.stringify({ cacheWarming: "off", defaultProjectTrust: "never", httpProxy: "http://mac.invalid" }));
      await writeFile(join(project, ".pi", "settings.json"), JSON.stringify({ cacheWarming: "idle", defaultProjectTrust: "always", httpProxy: "http://project.invalid" }));
      const pi = SettingsManager.create(project, agentDir, { projectTrusted: true });
      expect([pi.getCacheWarmingMode(), pi.getDefaultProjectTrust(), pi.getGlobalSettings().httpProxy]).toEqual(["off", "never", "http://mac.invalid"]);
    } finally { await rm(root, { recursive: true, force: true }); }
    // Every schema binding that a Project or Chat layer writes to a pi path.
    const violations = KEYS.flatMap(key => (["project", "chat"] as const).flatMap(layer => {
      const binding = key.layers[layer];
      const paths = binding?.store === "pi" ? [binding.path, ...(binding.qualified ? [binding.qualified] : [])]
        : binding?.store === "chat-settings" ? [binding.path] : [];
      return paths.map(path => path.join(".")).filter(path => agentDirOnly.some(only => path === only || path.startsWith(`${only}.`)))
        .map(path => `${key.id} declares ${layer} at ${path}`);
    }));
    expect(violations).toEqual([]);
  });
  it("changes bounded Home profile fields through the canonical change path and reads them from profile.json", async () => {
    const f = await fixture();
    const target = { kind: "home" };
    const response = await f.service.invoke(subscribed(), "settings.change", {
      commandId: "home-profile-worker-thinking", target,
      changes: [{ key: "model.thinking[role=worker]", layer: "profile", op: "set", value: "high" }],
    }) as { status: string };
    expect(response.status).toBe("applied");
    const profile = JSON.parse(await readFile(join(f.tronHome, "gateway", "home", "profile.json"), "utf8"));
    expect(profile).toEqual({ thinking: { worker: "high" } });
    const resolution = await f.service.invoke(subscribed(), "settings.resolve", { target }) as Resolution;
    expect(row(resolution, "model.thinking[role=worker]")).toMatchObject({ value: "high", layer: "profile" });

    await expect(f.service.invoke(subscribed(), "settings.change", {
      commandId: "home-profile-invalid-thinking", target,
      changes: [{ key: "model.thinking[role=worker]", layer: "profile", op: "set", value: "unbounded" }],
    })).rejects.toThrow();
    expect(JSON.parse(await readFile(join(f.tronHome, "gateway", "home", "profile.json"), "utf8"))).toEqual(profile);

    await writeFile(join(f.tronHome, "gateway", "home", "profile.json"), JSON.stringify({ thinking: { worker: "unbounded" } }));
    await expect(f.service.invoke(subscribed(), "settings.resolve", { target })).rejects.toThrow("Home profile value for model.thinking[role=worker] is invalid");
    await writeFile(join(f.tronHome, "gateway", "home", "profile.json"), JSON.stringify({ oversized: "x".repeat(256 * 1024) }));
    await expect(f.service.invoke(subscribed(), "settings.resolve", { target })).rejects.toThrow("Home profile exceeds its 262144-byte limit");
  });
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

    // Removing stored values must reveal the SDK defaults at the real read
    // boundary, not merely make two declaration tables agree.
    await writeFile(join(agentDir, "settings.json"), "{}");
    const defaults = await resolve({ kind: "mac" });
    const piDefaults = piEffective(SettingsManager.create(project, agentDir, { projectTrusted: false }), model);
    for (const [key, expected] of Object.entries(piDefaults)) {
      if (expected !== undefined) expect(row(defaults, key), key).toMatchObject({ value: expected, layer: "builtin" });
    }
    await mkdir(dirname(ARTIFACT), { recursive: true });
    await writeFile(ARTIFACT, `${JSON.stringify({ untrusted, trusted, mac, session, home, defaults }, null, 2)}\n`);
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

describe("settings renderer contract", () => {
  const transcript: Array<{ case: string; response: unknown }> = [];
  afterAll(async () => {
    await mkdir(dirname(RENDERER_ARTIFACT), { recursive: true });
    await writeFile(RENDERER_ARTIFACT, `${JSON.stringify(transcript, null, 2)}\n`);
  });

  let command = 0;
  const commandId = () => `settings-renderer-${String(++command).padStart(4, "0")}`;
  const macTarget: SettingsTarget = { kind: "mac" };
  type Fixture = Awaited<ReturnType<typeof fixture>>;
  type Options = { key: string; source: string; dependsOn: string[]; options: Array<{ value: unknown; label: string; detail?: string; disabledReason?: string }>; range?: unknown; nextCursor?: string };

  /** The presented resolution for a target, with the renderer the client names (if any). */
  const resolveWith = (f: Fixture, target: Record<string, unknown>, renderer?: Record<string, unknown>) =>
    f.service.invoke(subscribed(), "settings.resolve", { target, ...(renderer ? { renderer } : {}) }) as unknown as Promise<PresentedResolution>;
  const presentedRow = (resolution: PresentedResolution, key: string, qualifiers?: Record<string, string>): PresentedKey =>
    row(resolution, key, qualifiers) as PresentedKey;
  const section = (resolution: PresentedResolution, id: string) => {
    const found = resolution.sections.find(candidate => candidate.id === id);
    if (!found) throw new Error(`section ${id} was not presented`);
    return found;
  };
  /** A maintainer's change through the RPC: the iPhone's own tap, as the Mac target. */
  const maintainerChange = (f: Fixture, changes: unknown[], dryRun = false) =>
    f.service.invoke(subscribed(), "settings.change", { commandId: commandId(), target: macTarget, changes, ...(dryRun ? { dryRun: true } : {}) }) as
      Promise<{ dryRun?: true; status: string; tier: string; changes: Array<Record<string, unknown>> }>;
  const options = (f: Fixture, request: Record<string, unknown>, target: Record<string, unknown> = macTarget) =>
    f.service.invoke(subscribed(), "settings.options", { target, ...request }) as Promise<Options>;

  it("negotiates each key's control with the client, and shows every key read-only with its display when no renderer is named", async () => {
    const f = await fixture();
    const everything = await resolveWith(f, macTarget, { version: 1, controls: [...CONTROLS] });
    expect(everything.renderer).toEqual({ version: 1 });
    expect(presentedRow(everything, "model.thinking[role=chat]", { model: f.modelKey }).presentation).toMatchObject({
      control: "choice", valueKind: "orderedChoice", options: expect.arrayContaining([{ value: "high", label: "High" }]),
    });
    expect(presentedRow(everything, "run.retry.maxRetries").presentation).toMatchObject({
      control: "number", importance: "essential", label: "Retries", range: { min: 0, max: 20, unit: "retries" },
    });
    expect(presentedRow(everything, "run.retry.maxRetries").presentation.note).toBeUndefined();
    // One meaning per name (#760, doc 7.9 D2/D3): no two served keys share a label,
    // so "Thinking", "Worker thinking" and "Summary thinking", and "Trust for this
    // project" and the default trust policy, stay distinct controls.
    const labelOwners = new Map<string, Set<string>>();
    for (const row of everything.keys) labelOwners.set(row.presentation.label, (labelOwners.get(row.presentation.label) ?? new Set()).add(row.key));
    expect([...labelOwners].filter(([, owners]) => owners.size > 1)).toEqual([]);
    expect([...labelOwners.keys()].filter(label => /thinking|trust/iu.test(label)).sort().length).toBeGreaterThanOrEqual(4);

    // The new iPhone primitives persist through the same real change path. A
    // secret is writable but never comes back as an editable/readable value.
    await maintainerChange(f, [
      { key: "sources.skills", layer: "mac", op: "set", value: ["beta", "gamma"] },
      { key: "run.httpProxy", layer: "mac", op: "set", value: "http://replacement.invalid:8080" },
    ]);
    const edited = await resolveWith(f, macTarget, { version: 1, controls: [...CONTROLS] });
    expect(presentedRow(edited, "sources.skills")).toMatchObject({ value: ["beta", "gamma"], presentation: { control: "list", valueKind: "stringList" } });
    expect(presentedRow(edited, "run.httpProxy").presentation).toMatchObject({ control: "secret", redacted: true });
    expect(presentedRow(edited, "run.httpProxy").value).toBeNull();
    expect(JSON.stringify(edited)).not.toContain("replacement.invalid");
    const history = await f.service.invoke(subscribed(), "settings.history", {});
    expect(JSON.stringify(history)).not.toContain("replacement.invalid");
    transcript.push({ case: "secret and ordered list after changes", response: { list: presentedRow(edited, "sources.skills"), secret: presentedRow(edited, "run.httpProxy") } });

    // A client that speaks only toggles: a choice with no fallback, and a catalog whose fallback is read-only.
    const toggles = await resolveWith(f, macTarget, { version: 1, controls: ["hologram", "toggle"] });
    expect(presentedRow(toggles, "model.thinking[role=chat]", { model: f.modelKey }).presentation).toMatchObject({ control: "readOnly", note: UPDATE_TRON_NOTE });
    expect(presentedRow(toggles, "model.ref[role=chat]").presentation).toMatchObject({ control: "readOnly", note: UPDATE_TRON_NOTE });
    expect(presentedRow(toggles, "context.compaction.enabled").presentation).toMatchObject({ control: "toggle" });
    expect(presentedRow(toggles, "context.compaction.enabled").presentation.note).toBeUndefined();
    transcript.push({ case: "negotiation: every control, toggles only", response: { all: presentedRow(everything, "run.retry.maxRetries"), toggles: presentedRow(toggles, "model.ref[role=chat]") } });

    // No renderer: every editable key is read-only with the note, and every key still carries its display.
    const declared = new Map(KEYS.map(key => [key.id, key.control]));
    const plain = await resolveWith(f, macTarget);
    expect(plain.renderer).toEqual({ version: 1 });
    for (const key of plain.keys) {
      expect(typeof key.display, key.key).toBe("string");
      const note = declared.get(key.key) === "readOnly" ? undefined : UPDATE_TRON_NOTE;
      expect(key.presentation, key.key).toMatchObject({ control: "readOnly", ...(note ? { note } : {}) });
      expect(key.presentation.note, key.key).toBe(note);
    }
    expect(presentedRow(plain, "run.retry.maxRetries")).toMatchObject({ display: "5 retries", presentation: { control: "readOnly", note: UPDATE_TRON_NOTE } });

    // Unknown renderer fields are refused; the version must be a positive integer.
    await expect(f.service.invoke(subscribed(), "settings.resolve", { target: macTarget, renderer: { version: 1, controls: [], extra: true } }))
      .rejects.toMatchObject({ code: "invalid_request" });
    await expect(f.service.invoke(subscribed(), "settings.resolve", { target: macTarget, renderer: { version: 0, controls: [] } }))
      .rejects.toMatchObject({ code: "invalid_request" });
  });

  it("serves each section's essential values, overrides, pending approvals and recent agent changes", async () => {
    const f = await fixture();
    const before = await resolveWith(f, macTarget, { version: 1, controls: [...CONTROLS] });
    const model = section(before, "model");
    expect(model).toMatchObject({ title: "Model", order: 10 });
    expect(model.summary.essential.map(entry => entry.key)).toEqual(["model.ref[role=chat]", "model.thinking[role=chat]", "model.contextWindow"]);
    expect(model.summary.essential[1]).toMatchObject({ qualifiers: { role: "chat", model: f.modelKey }, label: "Thinking", display: expect.any(String) });
    // A section the target has no key in is not presented at all.
    expect(before.sections.map(entry => entry.id)).not.toContain("accounts");

    // A maintainer's own Mac-layer change is an override, named by its layer; it is not an agent change.
    const tapped = await maintainerChange(f, [{ key: "run.retry.maxRetries", layer: "mac", op: "set", value: 6, expected: 5 }]);
    expect(tapped.status).toBe("applied");
    const afterTap = await resolveWith(f, macTarget, { version: 1, controls: [...CONTROLS] });
    expect(section(afterTap, "run").summary.overrides).toContainEqual({
      key: "run.retry.maxRetries", label: "Retries", display: "6 retries", layer: "mac", layerLabel: "Mac",
    });
    expect(section(afterTap, "run").summary.recent).toEqual([]);

    // A quiet change by a chat's agent, with its reason, is recent.
    await f.settingsChanges.change(macTarget, [{ key: "run.retry.maxRetries", layer: "mac", op: "set", value: 7, expected: 6 }],
      { actor: { kind: "agent", id: "chat-1", sessionId: "chat-1" }, reason: "The provider is flaky today" });
    const afterAgent = await resolveWith(f, macTarget, { version: 1, controls: [...CONTROLS] });
    const run = section(afterAgent, "run");
    expect(run.summary.recent).toEqual([{
      changeId: expect.any(String), key: "run.retry.maxRetries", label: "Retries", actor: "A chat's agent",
      reason: "The provider is flaky today", at: expect.any(String),
    }]);
    expect(run.summary.moreRecent).toBe(0);
    expect(run.summary.overrides).toContainEqual(expect.objectContaining({ key: "run.retry.maxRetries", display: "7 retries", layerLabel: "Mac" }));
    transcript.push({ case: "section summary: run", response: run });

    // An approve-tier request by Home is held: pending in its section, for this target only.
    const held = await f.settingsChanges.change(macTarget, [{ key: "permissions.projectTrust", qualifiers: { project: join(f.root, "other") }, layer: "mac", op: "set", value: true }],
      { actor: { kind: "home", id: "home" }, reason: "The maintainer asked me to work there" });
    expect(held).toMatchObject({ status: "pending", tier: "approve" });
    const withPending = await resolveWith(f, macTarget, { version: 1, controls: [...CONTROLS] });
    expect(section(withPending, "permissions").summary.pending).toEqual([{
      requestId: held.approval!.requestId, requester: "Home", labels: ["Trust for this project"],
    }]);
    const otherTarget = await resolveWith(f, { kind: "project", cwd: f.project });
    expect(section(otherTarget, "permissions").summary.pending).toEqual([]);
    transcript.push({ case: "section summary: permissions pending", response: section(withPending, "permissions") });
  });

  it("covers only the named keys when a keys filter is given", async () => {
    const f = await fixture();
    const filtered = await f.service.invoke(subscribed(), "settings.resolve", { target: macTarget, keys: ["run.retry.maxRetries"], renderer: { version: 1, controls: ["number"] } }) as unknown as PresentedResolution;
    expect(filtered.keys.map(key => key.key)).toEqual(["run.retry.maxRetries"]);
    expect(filtered.sections.map(entry => entry.id)).toEqual(["run"]);
    expect(section(filtered, "run").summary.essential).toEqual([{ key: "run.retry.maxRetries", label: "Retries", display: "5 retries" }]);
  });

  it("serves option lists that follow the target's model, page catalogs, and refuse keys with no options", async () => {
    const f = await fixture();
    const reasoner = f.settingsModel.modelRuntime.getModel(f.model.provider, f.model.id)!;
    const plain = f.settingsModel.modelRuntime.getModel(f.model.provider, "plain")!;
    const plainKey = `${plain.provider}/${plain.id}`;

    // Thinking levels: the target's chat model's own levels, labelled as the schema labels them.
    const levels = await options(f, { key: "model.thinking[role=chat]" });
    expect(levels).toMatchObject({ source: "catalog.thinkingLevels", dependsOn: ["model.ref[role=chat]"] });
    expect(levels.options.map(option => option.value)).toEqual(getSupportedThinkingLevels(reasoner));
    expect(levels.options).toContainEqual({ value: "high", label: "High" });

    // A named model is followed instead: a model without reasoning offers no thinking level.
    const followed = await options(f, { key: "model.thinking[role=chat]", qualifiers: { model: plainKey } });
    expect(followed.options).toEqual([]);
    // Switching the chat model re-requests: the same key now follows the new chat model.
    await maintainerChange(f, [{ key: "model.ref[role=chat]", layer: "mac", op: "set", value: { provider: plain.provider, id: plain.id } }]);
    expect((await options(f, { key: "model.thinking[role=chat]" })).options).toEqual([]);
    expect((await options(f, { key: "model.thinking[role=chat]", qualifiers: { model: f.modelKey } })).options.length).toBeGreaterThan(0);

    // The context window range is the bounds settings.change validates against.
    const window = await options(f, { key: "model.contextWindow", qualifiers: { model: f.modelKey } });
    expect(window).toMatchObject({ source: "catalog.contextWindow", options: [], range: { min: contextWindowLimits(reasoner)!.minimum, max: 200_000, unit: "tokens" } });
    const tooLarge = await maintainerChange(f, [{ key: "model.contextWindow", qualifiers: { model: f.modelKey }, layer: "mac", op: "set", value: 200_001 }], true);
    expect(tooLarge.changes[0]).toMatchObject({ status: "failed", error: { code: "invalid_request", message: expect.stringContaining("Context window must be") } });

    // Models: a provider query narrows the catalog to the faux provider, and pages by an opaque cursor.
    const all = await options(f, { key: "model.ref[role=chat]", query: f.model.provider, limit: 200 });
    expect(all.options.map(option => option.value)).toEqual(expect.arrayContaining([{ provider: f.model.provider, id: "plain" }, { provider: f.model.provider, id: f.model.id }]));
    expect(all.options.every(option => option.detail === f.model.provider)).toBe(true);
    const firstPage = await options(f, { key: "model.ref[role=chat]", query: f.model.provider, limit: 1 });
    expect(firstPage.options).toEqual([all.options[0]]);
    expect(firstPage.nextCursor).toBe("1");
    const secondPage = await options(f, { key: "model.ref[role=chat]", query: f.model.provider.toUpperCase(), limit: 1, cursor: firstPage.nextCursor });
    expect(secondPage.options).toEqual([all.options[1]]);
    expect(secondPage.nextCursor).toBeUndefined();
    expect((await options(f, { key: "model.ref[role=chat]", query: "no-such-model-anywhere" })).options).toEqual([]);

    // A static choice: its declared options, in declared order.
    const transport = await options(f, { key: "run.transport" });
    expect(transport).toMatchObject({ source: "static", dependsOn: [], options: [
      { value: "auto", label: "Automatic" }, { value: "sse", label: "SSE" }, { value: "websocket", label: "WebSocket" }, { value: "websocket-cached", label: "WebSocket (cached)" },
    ] });

    // Refused: an unknown key, a key with neither options nor a source, and a malformed cursor.
    await expect(options(f, { key: "no.such.key" })).rejects.toMatchObject({ code: "invalid_request" });
    await expect(options(f, { key: "run.retry.maxRetries" })).rejects.toMatchObject({ code: "invalid_request" });
    await expect(options(f, { key: "model.ref[role=chat]", cursor: "not-a-cursor" })).rejects.toMatchObject({ code: "invalid_request" });
    transcript.push({ case: "options", response: { levels, followed, window, firstPage, transport } });
  });

  it("refuses an out-of-range value in a dry run, names the error, and changes nothing", async () => {
    const f = await fixture();
    const settingsFile = join(f.agentDir, "settings.json");
    const beforeFile = await readFile(settingsFile, "utf8");
    const dryRun = await maintainerChange(f, [{ key: "run.retry.maxRetries", layer: "mac", op: "set", value: 99 }], true);
    expect(dryRun).toMatchObject({ dryRun: true, changes: [{ key: "run.retry.maxRetries", layer: "mac", status: "failed",
      error: { code: "invalid_request", message: expect.stringContaining("run.retry.maxRetries must be an integer from 0 through 20") } }] });
    expect(await readFile(settingsFile, "utf8")).toBe(beforeFile);
    const history = await f.service.invoke(subscribed(), "settings.history", { limit: 50 }) as unknown as { entries: ChangeEntry[] };
    expect(history.entries).toEqual([]);
    transcript.push({ case: "dry run refused", response: dryRun });
  });
});
