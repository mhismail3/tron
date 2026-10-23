import type { SessionLineagePolicy } from "./session-lineage.js";
import type { KernelLifecycleObserver, TaskLedgerPolicy } from "./kernel-lifecycle.js";
import type { Model } from "../pi/ai.js";
import type { ExtensionFactory, ModelRuntime, SettingsManager, SessionBeforeCompactEvent } from "../pi/coding-agent.js";
import type { SettingsToolAccess } from "../settings/tool-contract.js";
import type { JsonValue, TronModuleSummary } from "../../protocol/types.js";
import type { ToolResultProjection } from "../projection/tool-result.js";
import type { RequestPolicyHook } from "./request-policy.js";
import type { InputAdmissionPolicy } from "./input-admission.js";
import { ORDINARY_SESSION_PROFILE, type SessionProfile } from "./session-profile.js";
import type { CanonicalAppendContext, CanonicalAppendPolicy } from "./canonical-append.js";

export type AgentTerminalOutcome = "completed" | "limited" | "failed" | "stopped" | "unknown" | "interrupted";

/** Run-owned facts sampled before the notification module admits an alert. */
export interface RunTerminalInput {
  sessionId: string;
  sourceId: string;
  outcome: AgentTerminalOutcome;
  sessionTitle: string;
  observed: boolean;
  pendingBackgroundWork: number;
  waitingEpisode: boolean;
}

export interface InteractionRequiredInput {
  sessionId: string;
  interactionId: string;
  observed: boolean;
}

/** Run settlement preserves the awaited quiescent cut and synchronous idle notice. */
export interface RunSettledPolicy {
  quiescent(sessionId: string): Promise<void>;
  idle(sessionId: string, by: "user" | "wake"): void;
}

/** Provider operations for owned runtime attachment and a new runtime's saved default. */
export interface ModelRuntimePolicy {
  attach(runtime: ModelRuntime): () => void;
  initialModel(runtime: ModelRuntime, settings: Pick<SettingsManager, "getDefaultProvider" | "getDefaultModel">): Promise<Model<never> | undefined>;
}

/** One log line from a module, in the Gateway logger's shape. */
export interface ModuleLog {
  log(level: "debug" | "info" | "warning" | "error", message: string, metadata?: Record<string, unknown>): void;
}

/** What `start` receives: platform facts and the contracts of the modules this
 * one declares in `dependsOn`. Kernel operations join it as each kernel
 * primitive is extracted (k0-kernel.md §3); nothing module-specific is here. */
export interface GatewayHost {
  tronHome: string;
  log: ModuleLog;
  /** The started contract of a module named in this descriptor's `dependsOn`. */
  contract<C>(module: ModuleDescriptor<C>): C;
}

/** Lifecycle operations used by the context extension, not its concrete owner. */
export interface ContextPolicyLifecycle {
  restore(): void;
  apply(): void;
}

/** Lifecycle operations used by the compaction extension. */
export interface CompactionPolicyLifecycle {
  restore(): void;
  capture(event: SessionBeforeCompactEvent): void;
}

/** Per-runtime facts a module's extension reads at call time. */
export interface SessionContext {
  sessionId(): string;
  cwd(): string;
  modelRuntime: ModelRuntime;
  profile(): SessionProfile;
  /** The chat's title as notifications show it. */
  title(): string;
  /** Whether the user is viewing this chat now. */
  presented(): boolean;
  joinTerminalReceiptWrites(): Promise<void>;
  /** The current session actor and target; installed settings stay late-bound. */
  settings(): SettingsToolAccess | undefined;
  contextPolicy(): ContextPolicyLifecycle | undefined;
  compaction: {
    policy(): CompactionPolicyLifecycle | undefined;
    stopped(event: SessionBeforeCompactEvent): boolean;
    changed(): void;
  };
}

/** One RPC method a module serves, routed before `GatewayService`'s own switch
 * (decision D5). A `read` is disposable and admitted while the Gateway drains; a
 * `mutation` runs once per `commandId` under the transport's command receipt and
 * is refused while draining. `handle` validates its own parameters. */
export interface RpcHandler {
  kind: "read" | "mutation";
  handle(params: Record<string, unknown>): Promise<JsonValue>;
}

/** The K3 hooks and their dispatch kind (k0-kernel.md §2.1). A `policy` hook has
 * one implementer; a second fails at start. `observers` hooks run every
 * implementer in composition order. Each signature is typed by the extraction
 * step that wires its call site. */
export const KERNEL_HOOKS = {
  profileDecision: "policy",
  requestPolicy: "policy",
  inputAdmission: "policy",
  appendGuard: "policy",
  runSettled: "policy",
  sessionLineage: "policy",
  taskLedger: "policy",
  runTerminal: "policy",
  interactionRequired: "policy",
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
export type KernelHooks = { [K in Exclude<HookName, "toolResultProjection" | "runTerminal" | "interactionRequired" | "runSettled" | "requestPolicy" | "appendGuard" | "inputAdmission" | "profileDecision" | "sessionLineage" | "taskLedger" | "kernelLifecycle" | "modelRuntimeInstalled">]: (...args: never[]) => unknown } & {
  modelRuntimeInstalled(): ModelRuntimePolicy;
  toolResultProjection(): ToolResultProjection;
  runSettled(): RunSettledPolicy;
  sessionLineage(): SessionLineagePolicy;
  taskLedger(): TaskLedgerPolicy;
  kernelLifecycle(): KernelLifecycleObserver;
  requestPolicy(): RequestPolicyHook;
  inputAdmission(): InputAdmissionPolicy;
  profileDecision(sessionId: string, cwd: string): string | "unrecorded";
  appendGuard(context: CanonicalAppendContext): CanonicalAppendPolicy;
  /** Resolve optional availability before sampling run-owned facts. */
  runTerminal(): ((input: RunTerminalInput) => Promise<void>) | undefined;
  interactionRequired(): ((input: InteractionRequiredInput) => Promise<void>) | undefined;
};

export interface ModuleInstance<C = void> {
  /** This module's Pi extension for one session runtime, or undefined when it
   * offers none to that runtime. */
  extension?(session: SessionContext): ExtensionFactory | undefined;
  /** Read at every dispatch, never captured. */
  hooks?: Partial<KernelHooks>;
  readonly profiles?: readonly SessionProfile[];
  rpc?: Readonly<Record<string, RpcHandler>>;
  capabilities?: readonly string[];
  contract?: C;
  stop?(): Promise<void>;
}

export interface ModuleDescriptor<C = void> {
  /** The Pi inline extension name, so Pi reports `<inline:name>` (B2). */
  name: string;
  purpose: string;
  tools: readonly string[];
  commands: readonly string[];
  /** Modules whose contracts `start` may read; each starts earlier in the list. */
  dependsOn?: readonly ModuleDescriptor<unknown>[];
  /** Runs once, in composition order. */
  start(host: GatewayHost): ModuleInstance<C> | Promise<ModuleInstance<C>>;
}

interface Started {
  descriptor: ModuleDescriptor<unknown>;
  instance: ModuleInstance<unknown>;
}

/** The started modules of one Gateway (K3): it starts the composition in order,
 * answers contracts, per-runtime extensions, descriptor RPCs, capabilities and
 * hook dispatch, and stops modules in reverse order. */
export class ModuleHost {
  private constructor(private readonly started: readonly Started[]) {}

  static async start(composition: readonly ModuleDescriptor<unknown>[], platform: Omit<GatewayHost, "contract">): Promise<ModuleHost> {
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
      await new ModuleHost(started).stop().catch(() => {});
      throw error;
    }
    return new ModuleHost(started);
  }

  /** Composition errors fail at start, never at the first call. */
  private static admit(started: readonly Started[]): void {
    const methods = new Map<string, string>();
    const policies = new Map<string, string>();
    const profiles = new Set([ORDINARY_SESSION_PROFILE.name, "unrecorded"]);
    for (const { descriptor, instance } of started) {
      for (const profile of instance.profiles ?? []) {
        if (profiles.has(profile.name)) throw new Error(`Profile ${profile.name} is already registered`);
        profiles.add(profile.name);
        Object.freeze(profile.resources);
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

  /** A started module's contract, for composition. */
  contract<C>(module: ModuleDescriptor<C>): C {
    const entry = this.find(module as ModuleDescriptor<unknown>);
    if (!entry || !("contract" in entry.instance)) throw new Error(`Module ${module.name} offers no started contract`);
    return entry.instance.contract as C;
  }

  /** Definitions stay with their started owner; there is no second profile store. */
  profile(name: string): SessionProfile {
    if (name === ORDINARY_SESSION_PROFILE.name) return ORDINARY_SESSION_PROFILE;
    for (const { instance } of this.started) {
      const profile = instance.profiles?.find(candidate => candidate.name === name);
      if (profile) return profile;
    }
    throw new Error(`Profile ${name} is not composed`);
  }

  /** Profile order is explicit; optionality stays with each descriptor. */
  registrations(names: readonly string[], session: SessionContext): { name: string; factory: ExtensionFactory }[] {
    return names.flatMap(name => {
      const factory = this.named(name).instance.extension?.(session);
      return factory ? [{ name, factory }] : [];
    });
  }

  summaries(names: readonly string[]): TronModuleSummary[] {
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

  /** Every module's capabilities, in composition order. */
  capabilities(): string[] {
    return this.started.flatMap(({ instance }) => [...(instance.capabilities ?? [])]);
  }

  /** The one implementer of a policy hook as it stands at this call. */
  policy<K extends PolicyHook>(name: K): KernelHooks[K] | undefined {
    for (const { instance } of this.started) {
      const hook = instance.hooks?.[name];
      if (hook) return hook as KernelHooks[K];
    }
    return undefined;
  }

  /** Every implementer of an observer hook as it stands at this call, in
   * composition order. */
  observers<K extends ObserverHook>(name: K): KernelHooks[K][] {
    return this.started.flatMap(({ instance }) => {
      const hook = instance.hooks?.[name];
      return hook ? [hook as KernelHooks[K]] : [];
    });
  }

  /** Stops every started module in reverse order; one failure does not skip
   * the rest. */
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
