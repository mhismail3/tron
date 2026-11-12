import { createTestRegistry, homeOwnerOf } from "./gateway-registry.js";
import { mkdir, mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { vi } from "vitest";
import { TrustService } from "../src/kernel/resources/trust-service.js";
import { NotificationService } from "../src/notifications/notification-service.js";
import { NotificationGrantStore } from "../src/notifications/grant-store.js";
import type { PushRelayClient } from "../src/notifications/relay-client.js";
import { RuntimeRegistry } from "../src/kernel/session/runtime-registry.js";
import { ManagedSubagents } from "../src/kernel/delegation/managed-subagents.js";
import { delegatedArtifactRoot, ensureDelegatedArtifactRoot } from "../src/kernel/delegation/delegated-provider.js";
import { settingsDependencies } from "./settings-dependencies.js";
import type { ProfileStore } from "../src/modules/home/profile-store.js";
import { MODEL_QUEUE_PROJECTION_ENV } from "../src/providers/model-queue-extension.js";
import { modelQueueProjectionPath, type ModelQueueRecord } from "../src/providers/model-queue.js";
import type { ProviderUsageOwner } from "../src/providers/provider-usage.js";
import { HOOK_HANG_BOUND_MS, waitFor } from "./wait-for.js";

const fixtures: Array<{ registry: RuntimeRegistry; root: string }> = [];
export async function disposeFixtures(): Promise<void> {
  const failures: unknown[] = [];
  try {
    for (const fixture of fixtures.splice(0)) {
      try {
        await fixture.registry.dispose();
        await fixture.registry.administrativeWorkRegistry.waitUntilSettled();
        const outlived = await awaitRunnersExited(fixture.root).then(() => undefined, (error: unknown) => error);
        await rm(fixture.root, { recursive: true, force: true });
        if (outlived) throw outlived;
      } catch (error) { failures.push(error); }
    }
  } finally {
    vi.unstubAllEnvs();
  }
  if (failures.length) throw failures[0];
}

async function awaitRunnersExited(root: string): Promise<void> {
  const pids = new Map<number, string>();
  const visit = async (directory: string, depth: number): Promise<void> => {
    const entries = await readdir(directory, { withFileTypes: true }).catch(() => []);
    for (const entry of entries) {
      const path = join(directory, entry.name);
      if (entry.isDirectory() && depth < 8) await visit(path, depth + 1);
      else if (entry.name === "status.json") {
        const pid = (JSON.parse(await readFile(path, "utf8").catch(() => "{}")) as { pid?: unknown }).pid;
        if (Number.isInteger(pid) && pid !== process.pid) pids.set(pid as number, directory);
      }
    }
  };
  await visit(delegatedArtifactRoot(join(root, "tron")), 0);
  const alive = (pid: number) => { try { process.kill(pid, 0); return true; } catch { return false; } };
  try {
    await waitFor(() => [...pids.keys()].every(pid => !alive(pid)), "every async runner the fixture started exits", { boundMs: HOOK_HANG_BOUND_MS });
  } catch (error) {
    const outliving = [...pids].filter(([pid]) => alive(pid));
    for (const [pid] of outliving) { try { process.kill(pid, "SIGKILL"); } catch { } }
    await waitFor(() => outliving.every(([pid]) => !alive(pid)), "killed async runners exit", { boundMs: HOOK_HANG_BOUND_MS });
    throw new Error(`async runners outlived their fixture: ${outliving.map(([pid, dir]) => `${pid} (${dir})`).join(", ")}`, { cause: error });
  }
}

export const TASK_REASONING_MODEL_ID = "tron-task-reasoning";
export const TASK_VIRTUAL_MODEL_ID = "tron-task-router";

export interface FixtureOptions {
  projectOptions?: Parameters<typeof createTestRegistry>[0]["projectOptions"];
  providerUsage?: Pick<ProviderUsageOwner, "read">;
  queueSummarizer?: boolean;
  knowledge?: () => ProfileStore | undefined;
  settingsNow?: Parameters<typeof settingsDependencies>[0]["now"];
  homeDiagnostic?: import("../src/modules/home/home-diagnostic.js").HomeDiagnostic;
}

export async function fixture(unmanagedProvider = false, codemode = false, contextWindow?: number, managed = false, models?: Record<string, unknown>, options: FixtureOptions = {}) {
  const knowledge = options.knowledge ?? (() => undefined);
  const root = await mkdtemp(join(tmpdir(), "tron-task-dispatch-"));
  const agentDir = join(root, "agent");
  const cwd = join(root, "project");
  const tronHome = join(root, "tron");
  await mkdir(agentDir); await mkdir(cwd);
  if (models) await writeFile(join(agentDir, "models.json"), JSON.stringify(models));
  const temporary = join(root, "tmp");
  await mkdir(temporary);
  vi.stubEnv("TMPDIR", temporary);
  const faux = fauxProvider({ provider: "tron-task-faux", tokensPerSecond: 0, models: [
    contextWindow ? { id: "bounded", contextWindow, maxTokens: 1024 } : { id: "faux-1", name: "Faux Model" },
    { id: TASK_REASONING_MODEL_ID, reasoning: true },
  ] });
  const model = faux.getModel();
  const gateway = await ModelRuntime.create({ modelsPath: join(agentDir, "models.json"), refreshOnCreate: false });
  gateway.registerNativeProvider(faux.provider);
  gateway.registerVirtualModel({ provider: model.provider, id: TASK_VIRTUAL_MODEL_ID, name: "Fixture router",
    route: () => ({ model: gateway.getModel(model.provider, model.id)!, thinkingLevel: "off" }) });
  await gateway.refresh({ allowNetwork: false });
  const sdkSettings: Record<string, unknown> = { defaultProvider: model.provider, defaultModel: model.id };
  if (contextWindow) sdkSettings.compaction = { enabled: false, reserveTokens: 1024, keepRecentTokens: 0 };
  if (codemode) {
    sdkSettings.defaultTools = ["+codemode"];
    const extensionDir = join(cwd, ".pi", "extensions");
    await mkdir(extensionDir, { recursive: true });
    await writeFile(join(extensionDir, "codemode.ts"), `import { createCodemodeExtension } from ${JSON.stringify(import.meta.resolve("@earendil-works/pi-coding-agent"))}; export default createCodemodeExtension({ mode: "on" });`);
  }
  if (unmanagedProvider) {
    const extensionRoot = join(agentDir, "extensions");
    await mkdir(extensionRoot, { recursive: true });
    await writeFile(join(extensionRoot, "unmanaged-producer.ts"), `import { writeFileSync } from 'node:fs'; export default function(pi) {
      pi.registerTool({name:'subagent',label:'Subagent',description:'Test producer boundary',parameters:{type:'object',properties:{}},
        execute:async (_id,input) => { writeFileSync(${JSON.stringify(join(cwd, "subagent-effect.json"))}, JSON.stringify(input)); return {content:[{type:'text',text:'producer admitted'}]}; }});
      pi.registerTool({name:'bg_wait',label:'Background Wait',description:'Test versioned wait boundary',parameters:{type:'object',properties:{}},
        execute:async (_id,input) => {
          writeFileSync(${JSON.stringify(join(cwd, "wait-effect.json"))}, JSON.stringify(input));
          return {content:[{type:'text',text:'wait finished'}]}; }});
    }`);
  }
  await writeFile(join(agentDir, "settings.json"), JSON.stringify(sdkSettings));
  const trust = new TrustService(agentDir);
  await trust.set(cwd, true);
  const signals: Array<Record<string, unknown>> = [];
  const notifications: Array<Record<string, unknown>> = [];
  if (managed) {
    vi.stubEnv("PI_CODING_AGENT_DIR", agentDir);
    vi.stubEnv("PI_SUBAGENTS_TEMP_ROOT", delegatedArtifactRoot(tronHome));
    vi.stubEnv(MODEL_QUEUE_PROJECTION_ENV, modelQueueProjectionPath(tronHome));
    await ensureDelegatedArtifactRoot(delegatedArtifactRoot(tronHome));
  }
  const managedSubagents = managed ? ManagedSubagents.activateForStartup(tronHome) : undefined;
  const events: Array<{ topic: string; payload: unknown }> = [];
  const queueDiagnostics: ModelQueueRecord[] = [];
  const pushStore = new NotificationGrantStore(join(root, "notifications"));
  await pushStore.initialize();
  const pushAdmission = new NotificationService(pushStore, { available: false, relayOrigin: "https://push.invalid" } as unknown as PushRelayClient);
  let settings: ReturnType<typeof settingsDependencies> | undefined;
  const createRegistry = async () => await createTestRegistry({ projectOptions: options.projectOptions, knowledge, agentDir, tronHome, trust, machineId: "machine-task-test",
    settings: () => settings ? { model: settings.settingsModel, changes: settings.settingsChanges } : undefined,
    resourceFreshnessDiagnostic: record => signals.push({ outcome: "resources-reload", ...record }),
    homeDiagnostic: record => { signals.push({ ...record }); options.homeDiagnostic?.(record); }, idleRuntimeMs: Infinity, ...(managedSubagents ? { managedSubagents } : {}),
    ...(managed ? { delegatedArtifactRoot: delegatedArtifactRoot(tronHome) } : {}),
    gatewayModelRuntime: gateway,
    modelQueueDiagnostic: record => queueDiagnostics.push(record),
    modelRuntimeFactory: async () => {
      const runtime = await ModelRuntime.create({ modelsPath: join(agentDir, "models.json"), refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      await runtime.refresh({ allowNetwork: false });
      return runtime;
    },
    broadcast: (_sessionId: string, topic: string, payload: unknown) => { events.push({ topic, payload }); }, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    notifications: { enqueue: async (input: Parameters<NotificationService["enqueue"]>[0]) => {
      const status = await pushAdmission.enqueue(input);
      notifications.push(input as unknown as Record<string, unknown>);
      return status;
    },
      suppressAutomatic: async () => "suppressed", markSessionInboxRead: async () => {} } as unknown as NotificationService,
    homeTaskDiagnostic: record => signals.push(record as unknown as Record<string, unknown>),
    homeRequestDiagnostic: record => signals.push(record as unknown as Record<string, unknown>),
    scheduleToolOperations: { execute: async () => {
      await writeFile(join(cwd, "schedule-effect"), "producer called");
      return { message: "schedule read", details: { status: "ok" } };
    } },
    ...(options.queueSummarizer ? {} : { homeMemorySummarizer: () => async () => fauxAssistantMessage("bounded summary") }),
    ...(options.providerUsage ? { providerUsage: options.providerUsage } : {}),
  });
  const registry = await createRegistry();
  settings = settingsDependencies({ agentDir, tronHome, trust, modelRuntime: gateway, sessions: registry, registry,
    home: () => homeOwnerOf(registry), knowledge,
    ...(options.settingsNow ? { now: options.settingsNow } : {}) });
  await settings.settingsChanges.start();
  const owned = { registry, root };
  fixtures.push(owned);
  await bringUpToReadiness(registry);
  await homeOwnerOf(registry).recoverTasks();
  const home = await homeOwnerOf(registry).designate({ model: { provider: model.provider, id: model.id } }, () => model);
  const restartToReadiness = async () => {
    await owned.registry.dispose();
    await owned.registry.administrativeWorkRegistry.waitUntilSettled();
    settings = undefined;
    owned.registry = await createRegistry();
    const restarted = owned.registry;
    settings = settingsDependencies({ agentDir, tronHome, trust, modelRuntime: gateway, sessions: restarted, registry: restarted,
      home: () => homeOwnerOf(restarted), knowledge,
      ...(options.settingsNow ? { now: options.settingsNow } : {}) });
    await settings.settingsChanges.start();
    await bringUpToReadiness(owned.registry);
    return owned.registry;
  };
  return { root, registry, get settings() { return settings!; }, faux, model, gateway, cwd, tronHome, home, signals, notifications, events, queueDiagnostics, agentDir, trust, restartToReadiness,
    restart: async () => {
      const cold = await restartToReadiness();
      await homeOwnerOf(cold).recoverTasks();
      return cold;
    } };
}

async function bringUpToReadiness(registry: RuntimeRegistry): Promise<void> {
  await registry.initialize();
  await (registry as any).sessionCatalog.whenPublished();
}

export const reportCall = (id = "report-one", text = "Verified result") => fauxToolCall("report", { resultId: id, outcome: "final", text, evidence: ["focused check passed"] }, { id: `call-${id}` });
export async function dispatch(f: Awaited<ReturnType<typeof fixture>>, taskId = "task-one") {
  return homeOwnerOf(f.registry).dispatchTask(f.home.sessionId, { taskId, intent: "Finite work", target: f.cwd });
}
