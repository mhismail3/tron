import type { ExtensionAdmission } from "./extension-registration.js";
import type { SessionLineagePolicy } from "./session-lineage.js";
import type { ResourceRoot, TronWorkspaceDescriptor } from "../resources/resource-root.js";
import type { KernelLifecycleObserver, TaskLedgerPolicy } from "./kernel-lifecycle.js";
import type { Model } from "../pi/ai.js";
import type { AgentSession, ExtensionFactory, ModelRuntime, SessionEntry, SettingsManager, SessionBeforeCompactEvent } from "../pi/coding-agent.js";
import type { FixedSetting, SettingsToolAccess } from "../settings/tool-contract.js";
import type { ContextWindowPolicy, ModelRef, JsonValue, TronModuleSummary } from "../../protocol/types.js";
import type { ToolResultProjection } from "../projection/tool-result.js";
import type { RequestPolicyHook } from "./request-policy.js";
import type { InputAdmissionPolicy } from "./input-admission.js";
import { ORDINARY_SESSION_PROFILE, type SessionProfile } from "./session-profile.js";
import type { CanonicalAppendContext, CanonicalAppendPolicy } from "./canonical-append.js";

export type AgentTerminalOutcome = "completed" | "limited" | "failed" | "stopped" | "unknown" | "interrupted";

export interface RunTerminalInput {
  sessionId: string;
  sourceId: string;
  outcome: AgentTerminalOutcome;
  sessionTitle: string;
  observed: boolean;
  pendingBackgroundWork: number;
  waitingEpisode: boolean;
}

export interface SessionNotificationOperations {
  rekeySession(previousId: string, nextId: string): Promise<boolean>;
  markSessionInboxRead(sessionId: string): Promise<void>;
}

export interface InteractionRequiredInput {
  sessionId: string;
  interactionId: string;
  observed: boolean;
}

export interface RunSettledPolicy {
  quiescent(sessionId: string): Promise<void>;
  idle(sessionId: string, by: "user" | "wake"): void;
}

export interface ModelRuntimePolicy {
  attach(runtime: ModelRuntime): () => void;
  initialModel(runtime: ModelRuntime, settings: Pick<SettingsManager, "getDefaultProvider" | "getDefaultModel">): Promise<Model<never> | undefined>;
  contextPolicy(session: AgentSession): ContextPolicy;
  modelChoice(entries: readonly SessionEntry[], afterIndex: number): ModelRef | undefined;
  extensions(session: SessionContext,
    requireChildren: ((sessionId: string, extensions: readonly { id: string; path: string }[]) => Promise<{ dispose(): void }>) | undefined,
  ): readonly { name: string; factory: ExtensionFactory }[];
}

export interface ModuleLog {
  log(level: "debug" | "info" | "warning" | "error", message: string, metadata?: Record<string, unknown>): void;
}

export interface GatewayHost {
  tronHome: string;
  log: ModuleLog;
  contract<C>(module: ModuleDescriptor<C>): C;
}

export interface ContextPolicy {
  restore(): void;
  apply(): void;
  snapshot(): ContextWindowPolicy | undefined;
  set(model: ModelRef, raw: unknown): void;
}

export interface CompactionPolicyLifecycle {
  restore(): void;
  capture(event: SessionBeforeCompactEvent): void;
}

export interface SessionContext {
  sessionId(): string;
  cwd(): string;
  modelRuntime: ModelRuntime;
  fixedSettings(): Readonly<Record<string, FixedSetting>>;
  delegatedWorker(): boolean;
  requireChildExtensions?(sessionId: string, extensions: readonly { id: string; path: string }[]): Promise<{ dispose(): void }>;

  profile(): SessionProfile;
  title(): string;
  presented(): boolean;
  joinTerminalReceiptWrites(): Promise<void>;
  settings(): SettingsToolAccess | undefined;
  requestChange: import("./native-change.js").NativeChangeRequest;
  contextPolicy(): ContextPolicy | undefined;
  compaction: {
    policy(): CompactionPolicyLifecycle | undefined;
    stopped(event: SessionBeforeCompactEvent): boolean;
    changed(): void;
  };
}

interface RpcContext {
  readonly identity: string;
  readonly isLocal: boolean;
  readonly signal?: AbortSignal;
}
export interface RpcHandler {
  kind: "read" | "mutation";
  handle(params: Record<string, unknown>, context: RpcContext): Promise<JsonValue>;
}

const KERNEL_HOOKS = {
  profileDecision: "policy",
  resourceRoot: "policy",
  extensionAdmission: "policy",
  operatingContext: "policy",
  requestPolicy: "policy",
  inputAdmission: "policy",
  appendGuard: "policy",
  runSettled: "policy",
  sessionLineage: "policy",
  taskLedger: "policy",
  runTerminal: "policy",
  interactionRequired: "policy",
  sessionNotifications: "policy",
  toolResultProjection: "policy",
  modelRuntimeInstalled: "policy",
  modelUsed: "policy",
  sessionRemoval: "observers",
  sessionRetired: "observers",
  kernelLifecycle: "observers",
} as const;

export type HookName = keyof typeof KERNEL_HOOKS;
type PolicyHook = { [K in HookName]: typeof KERNEL_HOOKS[K] extends "policy" ? K : never }[HookName];
type ObserverHook = Exclude<HookName, PolicyHook>;
export type KernelHooks = { [K in Exclude<HookName, "extensionAdmission" | "resourceRoot" | "operatingContext" | "toolResultProjection" | "runTerminal" | "interactionRequired" | "sessionNotifications" | "runSettled" | "requestPolicy" | "appendGuard" | "inputAdmission" | "profileDecision" | "sessionLineage" | "taskLedger" | "kernelLifecycle" | "modelRuntimeInstalled" | "modelUsed" | "sessionRetired">]: (...args: never[]) => unknown } & {
  extensionAdmission: ExtensionAdmission;
  resourceRoot(): ResourceRoot;
  operatingContext(workspace: TronWorkspaceDescriptor, cwd: string, tools: readonly string[]): string;
  modelRuntimeInstalled(): ModelRuntimePolicy;
  modelUsed(sessionId: string, model: { provider: string; id: string }): void;
  sessionRetired(sessionId: string): void;
  toolResultProjection(): ToolResultProjection;
  runSettled(): RunSettledPolicy;
  sessionLineage(): SessionLineagePolicy;
  taskLedger(): TaskLedgerPolicy;
  kernelLifecycle(): KernelLifecycleObserver;
  requestPolicy(): RequestPolicyHook;
  inputAdmission(): InputAdmissionPolicy;
  profileDecision(sessionId: string, cwd: string): string | "unrecorded";
  appendGuard(context: CanonicalAppendContext): CanonicalAppendPolicy;
  runTerminal(): ((input: RunTerminalInput) => Promise<void>) | undefined;
  interactionRequired(): ((input: InteractionRequiredInput) => Promise<void>) | undefined;
  sessionNotifications(): SessionNotificationOperations | undefined;
};

export interface ModuleInstance<C = void> {
  extension?(session: SessionContext): ExtensionFactory | undefined;
  hooks?: Partial<KernelHooks>;
  readonly profiles?: readonly SessionProfile[];
  rpc?: Readonly<Record<string, RpcHandler>>;
  capabilities?: readonly string[];
  contract?: C;
  stop?(): Promise<void>;
}

export interface ModuleDescriptor<C = void> {
  name: string;
  purpose: string;
  tools: readonly string[];
  commands: readonly string[];
  dependsOn?: readonly ModuleDescriptor<unknown>[];
  start(host: GatewayHost): ModuleInstance<C> | Promise<ModuleInstance<C>>;
}

interface Started {
  descriptor: ModuleDescriptor<unknown>;
  instance: ModuleInstance<unknown>;
}

export class ModuleHost {
  private constructor(private readonly started: readonly Started[], readonly runtimeOrder: readonly string[]) {}

  static async start(composition: readonly ModuleDescriptor<unknown>[], platform: Omit<GatewayHost, "contract">,
    runtimeOrder: readonly string[]): Promise<ModuleHost> {
    const started: Started[] = [];
    const startedContract = (module: ModuleDescriptor<unknown>, reader: string): unknown => {
      const entry = started.find(candidate => candidate.descriptor === module);
      if (!entry) throw new Error(`Module ${module.name} is not started before ${reader}`);
      if (!("contract" in entry.instance)) throw new Error(`Module ${module.name} offers no contract`);
      return entry.instance.contract;
    };
    try {
      for (const descriptor of composition) {
        if (started.some(entry => entry.descriptor.name === descriptor.name)) throw new Error(`Module ${descriptor.name} is composed twice`);
        const host: GatewayHost = {
          ...platform,
          contract: <C>(module: ModuleDescriptor<C>): C => {
            if (!descriptor.dependsOn?.includes(module as ModuleDescriptor<unknown>)) {
              throw new Error(`Module ${descriptor.name} does not declare ${module.name} in dependsOn`);
            }
            return startedContract(module as ModuleDescriptor<unknown>, descriptor.name) as C;
          },
        };
        started.push({ descriptor, instance: await descriptor.start(host) });
      }
      ModuleHost.admit(started);
    } catch (error) {
      await new ModuleHost(started, runtimeOrder).stop().catch(() => {});
      throw error;
    }
    return new ModuleHost(started, runtimeOrder);
  }

  private static admit(started: readonly Started[]): void {
    const methods = new Map<string, string>();
    const policies = new Map<string, string>();
    const profiles = new Set([ORDINARY_SESSION_PROFILE.name, "unrecorded"]);
    for (const { descriptor, instance } of started) {
      for (const profile of instance.profiles ?? []) {
        if (profiles.has(profile.name)) throw new Error(`Profile ${profile.name} is already registered`);
        profiles.add(profile.name);
        Object.freeze(profile.resources);
        if (profile.modelSelection) Object.freeze(profile.modelSelection);
        if (profile.tools) Object.freeze(profile.tools);
        if (Array.isArray(profile.extensions)) Object.freeze(profile.extensions);
        Object.freeze(profile);
      }
      for (const method of Object.keys(instance.rpc ?? {})) {
        const owner = methods.get(method);
        if (owner) throw new Error(`RPC ${method} is served by both ${owner} and ${descriptor.name}`);
        methods.set(method, descriptor.name);
      }
      for (const name of Object.keys(instance.hooks ?? {})) {
        if (!Object.hasOwn(KERNEL_HOOKS, name)) throw new Error(`Module ${descriptor.name} implements unknown hook ${name}`);
        if (KERNEL_HOOKS[name as HookName] !== "policy") continue;
        const owner = policies.get(name);
        if (owner) throw new Error(`Policy hook ${name} is implemented by both ${owner} and ${descriptor.name}`);
        policies.set(name, descriptor.name);
      }
    }
  }

  contract<C>(module: ModuleDescriptor<C>): C {
    const entry = this.find(module as ModuleDescriptor<unknown>);
    if (!entry || !("contract" in entry.instance)) throw new Error(`Module ${module.name} offers no started contract`);
    return entry.instance.contract as C;
  }

  profile(name: string): SessionProfile {
    if (name === ORDINARY_SESSION_PROFILE.name) return ORDINARY_SESSION_PROFILE;
    for (const { instance } of this.started) {
      const profile = instance.profiles?.find(candidate => candidate.name === name);
      if (profile) return profile;
    }
    throw new Error(`Profile ${name} is not composed`);
  }

  registrations(names: readonly string[], session: SessionContext): { name: string; factory: ExtensionFactory }[] {
    return names.flatMap(name => {
      const factory = this.named(name).instance.extension?.(session);
      return factory ? [{ name, factory }] : [];
    });
  }

  summaries(names: readonly string[] = this.started.map(entry => entry.descriptor.name)): TronModuleSummary[] {
    return names.map(name => {
      const { descriptor } = this.named(name);
      return { name, purpose: descriptor.purpose, tools: [...descriptor.tools], commands: [...descriptor.commands] };
    });
  }

  private named(name: string): Started {
    const entry = this.started.find(candidate => candidate.descriptor.name === name);
    if (!entry) throw new Error(`Module ${name} is not composed`);
    return entry;
  }

  rpc(method: string): RpcHandler | undefined {
    for (const { instance } of this.started) {
      const handler = instance.rpc && Object.hasOwn(instance.rpc, method) ? instance.rpc[method] : undefined;
      if (handler) return handler;
    }
    return undefined;
  }

  capabilities(): string[] {
    return this.started.flatMap(({ instance }) => [...(instance.capabilities ?? [])]);
  }

  policy<K extends PolicyHook>(name: K): KernelHooks[K] | undefined {
    for (const { instance } of this.started) {
      const hook = instance.hooks?.[name];
      if (hook) return hook as KernelHooks[K];
    }
    return undefined;
  }

  observers<K extends ObserverHook>(name: K): KernelHooks[K][] {
    return this.started.flatMap(({ instance }) => {
      const hook = instance.hooks?.[name];
      return hook ? [hook as KernelHooks[K]] : [];
    });
  }

  async stop(): Promise<void> {
    const failures: unknown[] = [];
    for (const { instance } of [...this.started].reverse()) {
      try { await instance.stop?.(); } catch (error) { failures.push(error); }
    }
    if (failures.length > 0) throw new AggregateError(failures, "One or more modules failed to stop");
  }

  private find(module: ModuleDescriptor<unknown>): Started | undefined {
    return this.started.find(entry => entry.descriptor === module);
  }
}
