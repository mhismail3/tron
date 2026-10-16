import { mkdir, mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
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
import { delegatedArtifactRoot, ensureDelegatedArtifactRoot } from "../src/sessions/delegated-provider.js";
import { MODEL_QUEUE_PROJECTION_ENV } from "../src/providers/model-queue-extension.js";
import { modelQueueProjectionPath } from "../src/providers/model-queue.js";
import type { ProviderUsageOwner } from "../src/providers/provider-usage.js";
import { HOOK_HANG_BOUND_MS, waitFor } from "./wait-for.js";

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

/** Detached async runners outlive the Gateway by design, and one still writes its final
 * status and mission records after the run reads `complete`. Removing the root under it
 * failed teardown with ENOTEMPTY (#950). Every runner the fixture started (each run
 * directory's `status.json` records its pid) must exit before the root goes; one that
 * outlives the bound is killed and fails the test that left it running. */
async function awaitRunnersExited(root: string): Promise<void> {
  const pids = new Map<number, string>();
  const visit = async (directory: string, depth: number): Promise<void> => {
    const entries = await readdir(directory, { withFileTypes: true }).catch(() => []);
    for (const entry of entries) {
      const path = join(directory, entry.name);
      if (entry.isDirectory() && depth < 8) await visit(path, depth + 1);
      else if (entry.name === "status.json") {
        const pid = (JSON.parse(await readFile(path, "utf8").catch(() => "{}")) as { pid?: unknown }).pid;
        // A foreground run executes in this process and records its pid; only detached runners are awaited.
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
    for (const [pid] of outliving) { try { process.kill(pid, "SIGKILL"); } catch { /* exited meanwhile */ } }
    await waitFor(() => outliving.every(([pid]) => !alive(pid)), "killed async runners exit", { boundMs: HOOK_HANG_BOUND_MS });
    throw new Error(`async runners outlived their fixture: ${outliving.map(([pid, dir]) => `${pid} (${dir})`).join(", ")}`, { cause: error });
  }
}

// A same-named user package. The producer gate admits a provider only by managed
// identity, so this version string never changes what the gate decides.
const UNMANAGED_PROVIDER_VERSION = "0.76.1-tron.4";

export const TASK_REASONING_MODEL_ID = "tron-task-reasoning";
export const TASK_VIRTUAL_MODEL_ID = "tron-task-router";

/** `models` is written as the agent directory's models.json before any runtime starts, for a
 * provider the faux one cannot stand in for (a local wire-protocol endpoint). */
export interface FixtureOptions {
  /** Provider usage for the model queues' 95% skip (the transport's owner in production). */
  providerUsage?: Pick<ProviderUsageOwner, "read">;
  /** Run Home memory on the real background-queue summarizer instead of a fixed summary. */
  queueSummarizer?: boolean;
}

export async function fixture(unmanagedProvider = false, codemode = false, contextWindow?: number, managed = false, models?: Record<string, unknown>, options: FixtureOptions = {}) {
  const root = await mkdtemp(join(tmpdir(), "tron-task-dispatch-"));
  const agentDir = join(root, "agent");
  const cwd = join(root, "project");
  const tronHome = join(root, "tron");
  await mkdir(agentDir); await mkdir(cwd);
  if (models) await writeFile(join(agentDir, "models.json"), JSON.stringify(models));
  // jiti transpiles pi and managed extensions into os.tmpdir(). Keep that cache in this
  // fixture's root so disposal removes it instead of leaking into the host's temp.
  const temporary = join(root, "tmp");
  await mkdir(temporary);
  vi.stubEnv("TMPDIR", temporary);
  // Pacing 0 streams by microtask. A timer per chunk waits at least 1 ms in Node, so a
  // 64 KB tool call alone took about 5 s here.
  // The second model is a reasoning model, so a delegation can choose a thinking level
  // it supports (`off` through `high`; the faux definition has no xhigh or max mapping).
  const faux = fauxProvider({ provider: "tron-task-faux", tokensPerSecond: 0, models: [
    contextWindow ? { id: "bounded", contextWindow, maxTokens: 1024 } : { id: "faux-1", name: "Faux Model" },
    { id: TASK_REASONING_MODEL_ID, reasoning: true },
  ] });
  const model = faux.getModel();
  // The Gateway-wide runtime that admits Home's delegate choices (production passes it
  // as `gatewayModelRuntime`). It also holds a virtual router, which must be refused.
  const gateway = await ModelRuntime.create({ modelsPath: join(agentDir, "models.json"), refreshOnCreate: false });
  gateway.registerNativeProvider(faux.provider);
  gateway.registerVirtualModel({ provider: model.provider, id: TASK_VIRTUAL_MODEL_ID, name: "Fixture router",
    route: () => ({ model: gateway.getModel(model.provider, model.id)!, thinkingLevel: "off" }) });
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
    // Managed children read the subagent model queue here, as gateway-main binds it.
    vi.stubEnv(MODEL_QUEUE_PROJECTION_ENV, modelQueueProjectionPath(tronHome));
    // Gateway startup creates the admitted root owner-only (gateway-main.ts); run artifacts under it are read only then.
    await ensureDelegatedArtifactRoot(delegatedArtifactRoot(tronHome));
  }
  const managedSubagents = managed ? ManagedSubagents.activateForStartup(tronHome) : undefined;
  // Fixture runtimes never idle-evict; an omitted idle lifetime would make the cutoff NaN.
  // Every slot event, so a test can assert that a path emits no error event.
  const events: Array<{ topic: string; payload: unknown }> = [];
  const pushStore = new NotificationGrantStore(join(root, "notifications"));
  await pushStore.initialize();
  // No relay: admission validates and records nothing is sent off the Mac.
  const pushAdmission = new NotificationService(pushStore, { available: false, relayOrigin: "https://push.invalid" } as unknown as PushRelayClient);
  const createRegistry = () => new RuntimeRegistry({ agentDir, tronHome, trust, machineId: "machine-task-test", idleRuntimeMs: Infinity, ...(managedSubagents ? { managedSubagents } : {}),
    // Production admits the same artifact root (gateway-main.ts): run status artifacts are read only under it.
    ...(managed ? { delegatedArtifactRoot: delegatedArtifactRoot(tronHome) } : {}),
    gatewayModelRuntime: gateway,
    modelRuntimeFactory: async () => {
      // Every runtime reads the agent directory's models.json, as production does, so a test
      // can register a scripted child model or a local wire-protocol endpoint there.
      const runtime = await ModelRuntime.create({ modelsPath: join(agentDir, "models.json"), refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider); return runtime;
    },
    broadcast: (_sessionId: string, topic: string, payload: unknown) => { events.push({ topic, payload }); }, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
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
    ...(options.queueSummarizer ? {} : { homeMemorySummarizer: () => async () => fauxAssistantMessage("bounded summary") }),
    ...(options.providerUsage ? { providerUsage: options.providerUsage } : {}),
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
  return { root, registry, faux, model, gateway, cwd, tronHome, home, signals, notifications, events, agentDir, trust, restartToReadiness,
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
