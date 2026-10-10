import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { vi } from "vitest";
import { TrustService } from "../src/admin/trust-service.js";
import { NotificationService } from "../src/notifications/notification-service.js";
import { NotificationGrantStore } from "../src/notifications/grant-store.js";
import type { PushRelayClient } from "../src/notifications/relay-client.js";
import { RuntimeRegistry } from "../src/sessions/runtime-registry.js";
import { ManagedSubagents } from "../src/sessions/managed-subagents.js";
import { delegatedArtifactRoot } from "../src/sessions/delegated-provider.js";

// Registered runtime roots of the current test file. Each file's afterEach calls
// disposeFixtures(), so a fixture is retired with the file that created it.
const fixtures: Array<{ registry: RuntimeRegistry; root: string }> = [];
/** Retires every fixture and restores the environment the fixtures stubbed (TMPDIR
 * points into a fixture root). Every fixture is attempted and the environment is
 * restored even when one disposal fails, so a failed teardown is reported against
 * its own test instead of pointing the next fixture at a deleted directory. */
export async function disposeFixtures(): Promise<void> {
  const failures: unknown[] = [];
  try {
    for (const fixture of fixtures.splice(0)) {
      try {
        await fixture.registry.dispose();
        await fixture.registry.administrativeWorkRegistry.waitUntilSettled();
        await rm(fixture.root, { recursive: true, force: true });
      } catch (error) { failures.push(error); }
    }
  } finally {
    vi.unstubAllEnvs();
  }
  if (failures.length) throw failures[0];
}

// A same-named user package. The producer gate admits a provider only by managed
// identity, so this version string never changes what the gate decides.
const UNMANAGED_PROVIDER_VERSION = "0.76.1-tron.4";

export async function fixture(unmanagedProvider = false, codemode = false, contextWindow?: number, managed = false) {
  const root = await mkdtemp(join(tmpdir(), "tron-task-dispatch-"));
  const agentDir = join(root, "agent");
  const cwd = join(root, "project");
  const tronHome = join(root, "tron");
  await mkdir(agentDir); await mkdir(cwd);
  // jiti transpiles pi and managed extensions into os.tmpdir(). Keep that cache in this
  // fixture's root so disposal removes it instead of leaking into the host's temp.
  const temporary = join(root, "tmp");
  await mkdir(temporary);
  vi.stubEnv("TMPDIR", temporary);
  // Pacing 0 streams by microtask. A timer per chunk waits at least 1 ms in Node, so a
  // 64 KB tool call alone took about 5 s here.
  const faux = fauxProvider({ provider: "tron-task-faux", tokensPerSecond: 0, ...(contextWindow ? { models: [{ id: "bounded", contextWindow, maxTokens: 1024 }] } : {}) });
  const model = faux.getModel();
  const settings: Record<string, unknown> = { sessionDir: join(root, "sessions"), defaultProvider: model.provider, defaultModel: model.id };
  if (contextWindow) settings.compaction = { enabled: false, reserveTokens: 1024, keepRecentTokens: 0 };
  if (codemode) {
    settings.defaultTools = ["+codemode"];
    const extensionDir = join(cwd, ".pi", "extensions");
    await mkdir(extensionDir, { recursive: true });
    await writeFile(join(extensionDir, "codemode.ts"), `import { createCodemodeExtension } from ${JSON.stringify(import.meta.resolve("@earendil-works/pi-coding-agent"))}; export default createCodemodeExtension({ mode: "on" });`);
  }
  if (unmanagedProvider) {
    const packageRoot = join(agentDir, "npm/node_modules/pi-subagents");
    await mkdir(packageRoot, { recursive: true });
    await writeFile(join(packageRoot, "package.json"), JSON.stringify({ name: "pi-subagents", version: UNMANAGED_PROVIDER_VERSION, pi: { extensions: ["index.ts"] } }));
    await writeFile(join(packageRoot, "index.ts"), `import { writeFileSync } from 'node:fs'; export default function(pi) {
      pi.registerTool({name:'subagent',label:'Subagent',description:'Test producer boundary',parameters:{type:'object',properties:{}},
        execute:async (_id,input) => { writeFileSync(${JSON.stringify(join(cwd, "subagent-effect.json"))}, JSON.stringify(input)); return {content:[{type:'text',text:'producer admitted'}]}; }});
      pi.registerTool({name:'bg_wait',label:'Background Wait',description:'Test versioned wait boundary',parameters:{type:'object',properties:{}},
        execute:async (_id,input) => {
          writeFileSync(${JSON.stringify(join(cwd, "wait-effect.json"))}, JSON.stringify(input));
          return {content:[{type:'text',text:'wait finished'}]}; }});
    }`);
    settings.packages = [`npm:pi-subagents@${UNMANAGED_PROVIDER_VERSION}`];
  }
  await writeFile(join(agentDir, "settings.json"), JSON.stringify(settings));
  const trust = new TrustService(agentDir);
  await trust.set(cwd, true);
  const signals: Array<Record<string, unknown>> = [];
  const notifications: Array<Record<string, unknown>> = [];
  if (managed) {
    vi.stubEnv("PI_CODING_AGENT_DIR", agentDir);
    vi.stubEnv("PI_SUBAGENTS_TEMP_ROOT", delegatedArtifactRoot(tronHome));
  }
  const managedSubagents = managed ? ManagedSubagents.activateForStartup(tronHome) : undefined;
  // Fixture runtimes never idle-evict; an omitted idle lifetime would make the cutoff NaN.
  const pushStore = new NotificationGrantStore(join(root, "notifications"));
  await pushStore.initialize();
  // No relay: admission validates and records nothing is sent off the Mac.
  const pushAdmission = new NotificationService(pushStore, { available: false, relayOrigin: "https://push.invalid" } as unknown as PushRelayClient);
  const createRegistry = () => new RuntimeRegistry({ agentDir, tronHome, trust, machineId: "machine-task-test", idleRuntimeMs: Infinity, ...(managedSubagents ? { managedSubagents } : {}),
    modelRuntimeFactory: async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider); return runtime;
    },
    broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    notifications: { enqueue: async (input: Parameters<NotificationService["enqueue"]>[0]) => {
      // The real admission (identity, route and bounds) runs before a push is
      // recorded: a fake that accepts anything hid a route every real push refused.
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
    homeMemorySummarizer: () => ({ summarizer: async () => fauxAssistantMessage("bounded summary") }),
  });
  const registry = createRegistry();
  const owned = { registry, root };
  fixtures.push(owned);
  await bringUpToReadiness(registry);
  await registry.recoverHomeTasks();
  const home = await registry.homeOwner().designate({ model: { provider: model.provider, id: model.id } }, () => model);
  // Readiness only: task recovery runs after listen, as in gateway-main.
  const restartToReadiness = async () => {
    await owned.registry.dispose();
    await owned.registry.administrativeWorkRegistry.waitUntilSettled();
    owned.registry = createRegistry();
    await bringUpToReadiness(owned.registry);
    return owned.registry;
  };
  return { root, registry, faux, cwd, tronHome, home, signals, notifications, agentDir, trust, restartToReadiness,
    restart: async () => {
      const cold = await restartToReadiness();
      await cold.recoverHomeTasks();
      return cold;
    } };
}

async function bringUpToReadiness(registry: RuntimeRegistry): Promise<void> {
  await registry.initialize();
  await (registry as any).sessionCatalog.whenPublished();
}

export const reportCall = (id = "report-one", text = "Verified result") => fauxToolCall("report", { resultId: id, outcome: "final", text, evidence: ["focused check passed"] }, { id: `call-${id}` });
export async function dispatch(f: Awaited<ReturnType<typeof fixture>>, taskId = "task-one") {
  return f.registry.homeOwner().dispatchTask(f.home.sessionId, { taskId, intent: "Finite work", target: f.cwd });
}
