import { TEST_SETTINGS_SCHEMA } from "./settings-schema.js";
import { DisplayArtifactStore } from "../src/display/display-artifact-store.js";
import { DisplayOwner } from "../src/display/display-modules.js";
import type { BrowserLiveViewRegistry } from "../src/display/browser-live-view.js";
import { ModelQueueOwner, modelQueueProjectionPath, type ModelQueueOptions } from "../src/providers/model-queue.js";
import { ProviderUsageOwner } from "../src/providers/provider-usage.js";
import type { RecentModelStore } from "../src/providers/recent-models.js";
import { RuntimeRegistry } from "../src/kernel/session/runtime-registry.js";
import type { ModelRuntime } from "../src/kernel/pi/coding-agent.js";
import { createProviderModelRuntime } from "../src/providers/provider-runtime.js";
import { OpenAIModelEligibility, sessionRuntimeView } from "../src/providers/openai-model-eligibility.js";
import { applyHomeCacheRetention } from "../src/modules/home/home-request-policy.js";
import { startGatewayModules, type ModuleOwners } from "../src/main/modules.js";
import type { SessionSearchService } from "../src/sessions/session-search-service.js";
import type { HomeComposition } from "../src/modules/home/home-module.js";
import type { HomeOwner } from "../src/modules/home/home-owner.js";

type RegistryOptions = Omit<ConstructorParameters<typeof RuntimeRegistry>[0], "modules" | "createModelRuntime" | "settingsSchema" | "homeTaskDiagnostic">;
/** Home's composition inputs a test may supply; the rest are the registry's own. */
type HomeTestOptions = Omit<HomeComposition, "tronHome" | "agentDir" | "trust" | "machineId" | "homeTaskDiagnostic" | "modelQueue" | "runtime" | "settings" | "knowledge" | "modelRuntime"> & {
  homeTaskDiagnostic?: NonNullable<HomeComposition["homeTaskDiagnostic"]>;
};

const projects = new WeakMap<object, import("../src/modules/projects/project-lifecycle.js").ProjectLifecycle>();
export function projectsOwnerOf(registry: object) { return projects.get(registry); }

const homes = new WeakMap<RuntimeRegistry, () => HomeOwner>();
const recents = new WeakMap<RuntimeRegistry, RecentModelStore>();
const queues = new WeakMap<RuntimeRegistry, ModelQueueOwner>();
const displays = new WeakMap<RuntimeRegistry, DisplayOwner>();

export function displayOwnerOf(registry: RuntimeRegistry): DisplayOwner {
  const owner = displays.get(registry);
  if (!owner) throw new Error("This registry was not built by createTestRegistry");
  return owner;
}

export function displayStoreOf(registry: RuntimeRegistry): DisplayArtifactStore {
  const owner = displays.get(registry);
  if (!owner) throw new Error("This registry was not built by createTestRegistry");
  return owner.artifacts;
}

export function queueOwnerOf(registry: RuntimeRegistry): ModelQueueOwner | undefined {
  return queues.get(registry);
}

export function recentModelsOf(registry: RuntimeRegistry): RecentModelStore {
  const owner = recents.get(registry);
  if (!owner) throw new Error("This registry was not built by createTestRegistry");
  return owner;
}

/** The Home owner the composition built for this registry. */
export function homeOwnerOf(registry: RuntimeRegistry): HomeOwner {
  const home = homes.get(registry);
  if (!home) throw new Error("This registry was not built by createTestRegistry");
  return home();
}

/** One real registry fixture: the production composition, then the real registry.
 * Options remain the boundary's own inputs; no production overrides or test hooks. */
export async function createTestRegistry(options: RegistryOptions & HomeTestOptions & { projectOptions?: ConstructorParameters<typeof import("../src/modules/projects/project-lifecycle.js").ProjectLifecycle>[2] } & Omit<ModuleOwners, "registry" | "sessionSearch" | "home" | "openAIModelEligibility" | "display"> & { browserLiveViews?: BrowserLiveViewRegistry; providerUsage?: ModelQueueOptions["usage"]; modelQueueDiagnostic?: ModelQueueOptions["log"]; modelRuntimeFactory?: () => Promise<ModelRuntime>; openAIModelEligibility?: OpenAIModelEligibility; knowledge?: HomeComposition["knowledge"]; sessionSearch?: () => SessionSearchService | undefined; settings?: HomeComposition["settings"] }): Promise<RuntimeRegistry> {
  const { projectOptions, notifications, knowledge = () => undefined, settings = () => undefined, browserLiveViews, providerUsage, modelQueueDiagnostic, connections, scheduleToolOperations, sessionSearch, recentModelsChanged, modelRuntimeFactory, openAIModelEligibility = new OpenAIModelEligibility(), homeDiagnostic, homeMemoryDiagnostic, homeRequestDiagnostic, homeMemorySummarizer, homeWebTransport, triggerSources, monitor, ...registryOptions } = options;
  const modelQueue = options.gatewayModelRuntime ? new ModelQueueOwner({
    runtime: options.gatewayModelRuntime,
    usage: providerUsage ?? new ProviderUsageOwner(),
    queue: role => registry.modelQueueOf(role),
    projectionPath: modelQueueProjectionPath(options.tronHome),
    ...(modelQueueDiagnostic ? { log: modelQueueDiagnostic } : {}),
  }) : undefined;
  const display = new DisplayOwner(new DisplayArtifactStore(options.tronHome), browserLiveViews, () => registry);
  const home: HomeComposition = {
    modelQueue, modelRuntime: registryOptions.gatewayModelRuntime,
    settings,
    knowledge,
    runtime: async () => ({
      runtime: applyHomeCacheRetention(sessionRuntimeView(registryOptions.gatewayModelRuntime ?? await createProviderModelRuntime(options.agentDir, modelRuntimeFactory))),
      ownership: registryOptions.gatewayModelRuntime ? "borrowed" : "owned",
    }),
    tronHome: options.tronHome, agentDir: options.agentDir, trust: options.trust, notifications, machineId: options.machineId,
    ...(triggerSources ? { triggerSources } : {}),
    ...(monitor ? { monitor } : {}),
    homeTaskDiagnostic: options.homeTaskDiagnostic, homeDiagnostic, homeMemoryDiagnostic, homeRequestDiagnostic, homeMemorySummarizer, homeWebTransport,
  };
  const { modules, home: owner, projects: projectOwner, recentModels } = await startGatewayModules({ tronHome: options.tronHome, log: { log: () => {} } },
    () => ({ registry, home, display, openAIModelEligibility, connections, scheduleToolOperations, recentModelsChanged, persistenceDiagnostic: options.persistenceDiagnostic, sessionSearch: sessionSearch?.() }), projectOptions);
  const registry: RuntimeRegistry = new RuntimeRegistry({ ...registryOptions, modules, settingsSchema: TEST_SETTINGS_SCHEMA,
    beforeSessionRekey: async (previousId, nextId, runtime) => {
      await display.grantReferences(previousId, nextId, runtime);
      await registryOptions.beforeSessionRekey?.(previousId, nextId, runtime);
    },
    createModelRuntime: () => createProviderModelRuntime(options.agentDir, modelRuntimeFactory) });
  projects.set(registry, projectOwner);
  displays.set(registry, display);
  if (modelQueue) queues.set(registry, modelQueue);
  homes.set(registry, owner);
  recents.set(registry, recentModels);
  return registry;
}
