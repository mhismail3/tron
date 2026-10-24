import { GatewayError } from "../../errors.js";
import { createQueueSummarizer } from "../../episodic/episodic-compactor.js";
import type { ModelQueueOwner } from "../../providers/model-queue.js";
import { homeSessionProfile, type HomeSessionProfileServices } from "./home-session-profile.js";
import type { GatewayHost, ModuleDescriptor, RunSettledPolicy, SessionContext } from "../../kernel/host/module-host.js";
import { createTronHomeExtension } from "./tron-home-extension.js";
import { homeResearchTools, type HomeResearchTransport } from "./home-research-tools.js";
import type { HomeMemoryToolAccess } from "./home-memory.js";
import { HomeProfileItems, type HomeProfileChangeAccess } from "./home-profile.js";
import type { SettingsChangePath } from "../../kernel/settings/settings-change.js";
import { HomeOwner, type HomeOwnerOptions } from "./home-owner.js";
import { homeAppendGuardHook, type HomeAppendGuardServices } from "./home-append-guard.js";
import type { HomeDiagnostic } from "./home-diagnostic.js";
import { HomeRequestPolicyError } from "./home-request-policy.js";
import type { RequestPolicyHook } from "../../kernel/host/request-policy.js";
import type { InputAdmissionPolicy } from "../../kernel/host/input-admission.js";
import type { SessionLineagePolicy } from "../../kernel/host/session-lineage.js";
import type { KernelLifecycleObserver, TaskLedgerPolicy } from "../../kernel/host/kernel-lifecycle.js";
import { assertChapterWritable } from "./home-chapter-state.js";
import { homeOpenRefusal } from "./home-session-recovery.js";
import { homeInputAdmission } from "./home-input-admission.js";
import { dispatchWithWorkerChoice, type HomeWorkerChoicePort } from "./home-task-worker-choice.js";
import type { TrustService } from "../../admin/trust-service.js";
import type { HomeTaskDiagnostic, HomeTaskDispatchRequest, HomeTaskHandle } from "./home-task-dispatcher.js";
import { readHomeSessionEntry, type HomeSessionReader } from "./home-session-read.js";
import type { HomeMemoryDiagnostic } from "./home-memory.js";
import type { HomeRequestRecord } from "./home-request-policy.js";
import type { NotificationService } from "../../notifications/notification-service.js";
import type { EpisodicSummarizer } from "../../episodic/episodic-contract.js";
import type { RuntimeRegistry } from "../../sessions/runtime-registry.js";
import type { TronWorkspace } from "../../workspace/tron-workspace.js";
import { workspaceModule } from "../../workspace/workspace-module.js";
import type { KnowledgeService } from "../../knowledge/knowledge-service.js";
import type { SessionSearchRequest, SessionSearchResponse } from "../../sessions/session-search-contract.js";

export interface HomeModuleServices {
  runSettled: RunSettledPolicy;
  lineage: SessionLineagePolicy;
  lifecycle: KernelLifecycleObserver;
  taskLedger: TaskLedgerPolicy;
  requestPolicy: RequestPolicyHook;
  inputAdmission: InputAdmissionPolicy;
  profile: HomeSessionProfileServices;
  appendGuard: HomeAppendGuardServices;
  memory(sessionId: string): HomeMemoryToolAccess | undefined;
  delegate(sessionId: string, request: HomeTaskDispatchRequest, signal?: AbortSignal): Promise<HomeTaskHandle>;
  task(sessionId: string, request: unknown): Promise<unknown>;
  profileChanges(session: SessionContext): HomeProfileChangeAccess | undefined;
  knowledge: KnowledgeService | undefined;
  search(): ((request: SessionSearchRequest, signal?: AbortSignal) => Promise<SessionSearchResponse>) | undefined;
  read: HomeSessionReader;
  explicitlyTrustedDirectory(path: string): Promise<boolean>;
  transport?: HomeResearchTransport;
}

/** The composition's Home inputs: platform owners and log sinks, never the registry. */
export interface HomeComposition {
  runtime: HomeSessionProfileServices["runtime"];
  tronHome: string;
  agentDir: string;
  trust: TrustService;
  notifications?: NotificationService | undefined;
  machineId?: string | undefined;
  homeDiagnostic?: HomeDiagnostic | undefined;
  homeMemoryDiagnostic?: ((record: HomeMemoryDiagnostic) => void) | undefined;
  homeRequestDiagnostic?: ((record: HomeRequestRecord) => void) | undefined;
  homeTaskDiagnostic?: ((record: HomeTaskDiagnostic) => void) | undefined;
  modelQueue?: ModelQueueOwner | undefined;
  /** Home memory's compactor calls; production omits it and uses the background model queue. */
  homeMemorySummarizer?: (() => EpisodicSummarizer) | undefined;
  /** Transport injection for Home's web research tools; production uses the pinned DNS-safe transport. */
  homeWebTransport?: HomeResearchTransport | undefined;
}

/** The registry's generic operations and reads Home is built over (k0-kernel.md §5). */
export interface HomeKernelPorts extends Pick<HomeOwnerOptions, "sessions" | "runtimes" | "taskSessions" | "memoryModels" | "knowledge"> {
  readSearchCut: Pick<RuntimeRegistry, "readSearchCut">["readSearchCut"];
  changes(): SettingsChangePath | undefined;
  workerChoice: Omit<HomeWorkerChoicePort, "availability">;
}

/** Home's one owner, built on first use over the composition and the registry's ports. */
export function homeOwnerFactory(workspace: TronWorkspace, inputs: () => HomeComposition, kernel: () => HomeKernelPorts): () => HomeOwner {
  let owner: HomeOwner | undefined;
  return () => {
    if (owner) return owner;
    const composition = inputs();
    const ports = kernel();
    owner = new HomeOwner({
      tronHome: composition.tronHome, agentDir: composition.agentDir, trust: composition.trust,
      sessions: ports.sessions, runtimes: ports.runtimes,
      ...(composition.homeDiagnostic ? { diagnostic: composition.homeDiagnostic } : {}),
      workspace, memoryModels: ports.memoryModels,
      memorySummarizer: composition.homeMemorySummarizer ?? (() => {
        const queue = composition.modelQueue;
        if (!queue) throw new GatewayError("unsupported", "Home memory needs the Gateway model runtime");
        return createQueueSummarizer({ complete: async (role, request, signal) =>
          queue.complete(role, request, signal, await ports.memoryModels()) });
      }),
      ...(composition.homeMemoryDiagnostic ? { memoryDiagnostic: composition.homeMemoryDiagnostic } : {}),
      ...(composition.homeRequestDiagnostic ? { requestDiagnostic: composition.homeRequestDiagnostic } : {}),
      taskSessions: ports.taskSessions,
      ...(composition.notifications ? { notifications: composition.notifications } : {}),
      ...(composition.machineId ? { machineId: composition.machineId } : {}),
      ...(composition.homeTaskDiagnostic ? { taskDiagnostic: composition.homeTaskDiagnostic } : {}),
      knowledge: ports.knowledge,
    });
    return owner;
  };
}

/** Home owns its extension closures; the registry supplies only generic operations. */
export function homeModuleServices(owner: HomeOwner, platform: HomeComposition, ports: HomeKernelPorts): Omit<HomeModuleServices, "search"> {
  const workerChoice: HomeWorkerChoicePort = { ...ports.workerChoice,
    availability: (role, signal, queue) => platform.modelQueue?.availability(role, signal, queue),
  };
  return {
    knowledge: ports.knowledge(), read: (request, signal) => readHomeSessionEntry(ports, owner, request, signal),
    delegate: (sessionId, request, signal) => dispatchWithWorkerChoice(owner, workerChoice, sessionId, request, signal),
    inputAdmission: homeInputAdmission(owner, platform.homeTaskDiagnostic),
    lifecycle: {
      // The designation is read before any runtime is built.
      initialize: () => owner.initialize(),
      started: () => owner.resources.start(),
      closing: () => owner.resources.close(),
      dispose: () => owner.dispose(),
    },
    taskLedger: {
      validateMarker: (sessionId, marker) => owner.validateTaskMarker(sessionId, marker),
      settingsTarget: (sessionId, taskId, purpose) => owner.taskSettingsTarget(sessionId, taskId, purpose),
    },
    lineage: {
      state: sessionId => {
        const { homeId, ...state } = owner.chapterStateFor(sessionId);
        return homeId === undefined ? state : { ...state, lineageId: homeId };
      },
      openRefusal: (sessionId, path) => homeOpenRefusal(sessionId, path, owner.chapterStateFor(sessionId)),
      assertWritable: sessionId => assertChapterWritable(owner.chapterStateFor(sessionId)),
      publicationUncertain: () => owner.publicationUncertain,
    },
    profile: {
      decision: (sessionId, cwd) => owner.profileFor(sessionId, cwd), runtime: platform.runtime,
    },
    appendGuard: {
      state: sessionId => owner.chapterStateFor(sessionId),
      admission: (sessionId, metrics) => owner.assertChapterAdmission(sessionId, metrics),
      committed: sessionId => owner.noteEntriesCommitted(sessionId),
      diagnostic: record => platform.homeDiagnostic?.(record),
    },
    requestPolicy: {
      forSession: sessionId => owner.requestPolicyFor(sessionId),
      isRefusal: (error): error is Error => error instanceof HomeRequestPolicyError,
    },
    runSettled: {
      quiescent: sessionId => owner.chapterQuiescent(sessionId),
      idle: (sessionId, by) => { owner.noteHomeIdle(sessionId, by); owner.resources.idle(sessionId); },
    },
    memory: sessionId => owner.memoryToolsFor(sessionId),
    task: (sessionId, request) => owner.taskTool(sessionId, request),
    profileChanges: session => homeProfileChanges(session, ports.changes(), ports.knowledge),
    explicitlyTrustedDirectory: async path => {
      try { return (await platform.trust.inspect(path)).savedDecision === true; } catch { return false; }
    },
    ...(platform.homeWebTransport ? { transport: platform.homeWebTransport } : {}),
  };
}

/** Home's profile tool resolves the current change path and actor on each call. */
export function homeProfileChanges(session: SessionContext, changes: SettingsChangePath | undefined, knowledge: HomeKernelPorts["knowledge"]): HomeProfileChangeAccess | undefined {
  if (!changes || !session.profile().profileChanges) return undefined;
  return { change: (ops, input) => new HomeProfileItems(knowledge).change(changes, ops, {
    actor: { kind: "home", id: session.sessionId(), sessionId: session.sessionId(), toolCallId: input.toolCallId },
    author: input.author, commandId: input.commandId, web: input.web, ...(input.reason ? { reason: input.reason } : {}),
  }) };
}

/** What Home's two modules read per runtime: the composition's inputs, the
 * registry's generic ports and the search owner, resolved at each call. */
export interface HomeModuleOwners {
  composition: HomeComposition;
  kernel(): HomeKernelPorts;
  search: HomeModuleServices["search"];
}

/** Home's module and its research module over one owner, which the composition
 * reads through `owner` (transport, recovery, notifications). */
export function createHomeModules(owners: () => HomeModuleOwners): { home: ModuleDescriptor; research: ModuleDescriptor; owner: () => HomeOwner } {
  let owner: (() => HomeOwner) | undefined;
  const homeOwner = () => {
    if (!owner) throw new Error("Tron Home has not started");
    return owner();
  };
  const services = (): HomeModuleServices => {
    const current = owners();
    return { ...homeModuleServices(homeOwner(), current.composition, current.kernel()), search: current.search };
  };
  return { owner: homeOwner, research: createHomeResearchModule(services), home: createHomeModule(services, host => {
    owner = homeOwnerFactory(host.contract(workspaceModule), () => owners().composition, () => owners().kernel());
  }) };
}

function createHomeModule(services: () => HomeModuleServices, started: (host: GatewayHost) => void): ModuleDescriptor {
  return {
    name: "tron-home",
    purpose: "Adds Home's operating context, registers Home's memory tools and keeps Home out of prompt-cache warming.",
    tools: ["zoom", "date", "memory_search", "delegate", "task", "profile"], commands: [], dependsOn: [workspaceModule],
    start: host => { started(host); return { profiles: [homeSessionProfile(() => services().profile)], hooks: {
      profileDecision: (sessionId, cwd) => { const name = services().profile.decision(sessionId, cwd); return name === "unnamed" ? "unrecorded" : name; },
      runSettled: () => services().runSettled, sessionLineage: () => services().lineage, kernelLifecycle: () => services().lifecycle, taskLedger: () => services().taskLedger, requestPolicy: () => services().requestPolicy,
      inputAdmission: () => services().inputAdmission, appendGuard: homeAppendGuardHook(() => services().appendGuard) }, extension: session => {
      const owners = services();
      return createTronHomeExtension(() => owners.memory(session.sessionId()),
        (request, signal) => owners.delegate(session.sessionId(), request, signal),
        request => owners.task(session.sessionId(), request),
        () => owners.knowledge, () => owners.profileChanges(session));
    } }; },
  };
}

function createHomeResearchModule(services: () => HomeModuleServices): ModuleDescriptor {
  return {
    name: "tron-home-research",
    purpose: "Adds Home's read-only research tools: web search and fetch, session search and cited-entry reading, Knowledge lookup and trusted-project file reading.",
    tools: ["web_search", "web_fetch", "session_search", "session_read", "knowledge", "read_file"], commands: [],
    start: () => ({ extension: () => {
      const owners = services();
      return pi => {
        const tools = homeResearchTools({
          knowledge: () => owners.knowledge, sessionSearch: owners.search, sessionRead: owners.read,
          explicitlyTrustedDirectory: owners.explicitlyTrustedDirectory,
          ...(owners.transport ? { transport: owners.transport } : {}),
        });
        for (const tool of tools) pi.registerTool(tool);
      };
    } }),
  };
}
