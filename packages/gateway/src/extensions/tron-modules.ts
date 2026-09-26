import type { ExtensionFactory, SessionBeforeCompactEvent } from "@earendil-works/pi-coding-agent";
import type { TronModuleSummary } from "../protocol/types.js";
import { compactionPolicyExtension, type CompactionOperationPolicy } from "../runtime/compaction-policy.js";
import { contextWindowExtension, type SessionContextWindowPolicy } from "../providers/context-window-policy.js";
import { createTronCoreExtension } from "../workspace/tron-core-extension.js";
import { createTronAskUserExtension } from "./tron-ask-user-extension.js";
import { createTronDisplayExtension } from "../display/tron-display-extension.js";
import { createTronNativeCaptureExtension } from "../display/tron-native-capture-extension.js";
import { createTronComputerExtension } from "../display/tron-computer-extension.js";
import { createTronScheduleExtension, type ScheduleToolOperations } from "../automations/tron-schedule-extension.js";
import { createTronNotifyExtension } from "../notifications/tron-notify-extension.js";
import type { DisplayArtifactStore } from "../display/display-artifact-store.js";
import type { BrowserLiveViewRegistry } from "../display/browser-live-view.js";
import type { TronWorkspace } from "../workspace/tron-workspace.js";
import type { KnowledgeService } from "../knowledge/knowledge-service.js";
import type { JevDecisionClient } from "../knowledge/jev-client.js";
import type { ConnectionOwner } from "../integrations/connection-owner.js";
import type { NotificationService } from "../notifications/notification-service.js";

/** What one session runtime offers Tron's built-in extensions. Every field is
 * owned by the session runtime; a module's factory closes over this host rather
 * than reaching into the slot. */
export interface TronModuleHost {
  sessionId: () => string;
  cwd: () => string;
  workspace: TronWorkspace;
  displayArtifacts: DisplayArtifactStore;
  notificationTitle: () => string;
  contextPolicy: () => SessionContextWindowPolicy | undefined;
  compactionPolicy: () => CompactionOperationPolicy | undefined;
  compactionStopped: (event: SessionBeforeCompactEvent) => boolean;
  compactionChanged: () => void;
  knowledge?: KnowledgeService;
  jev?: JevDecisionClient;
  connections?: ConnectionOwner;
  browserLiveViews?: BrowserLiveViewRegistry;
  notifications?: NotificationService;
  scheduleToolOperations?: ScheduleToolOperations;
  machineId?: string;
}

/** One built-in Tron extension. `name` is the runtime-registered inline name, so
 * Pi reports its resources with `<inline:name>` as the source. */
export interface TronModule {
  name: string;
  /** One-line purpose for Settings. */
  purpose: string;
  /** Tool names the factory registers when its owners are present, proven
   * against the factory by `tron-modules.test.ts`. */
  tools: readonly string[];
  /** Command names the factory registers; no Tron module registers one today. */
  commands: readonly string[];
  /** Builds this module's factory for one session host, or undefined when the
   * host cannot offer it. */
  factory: (host: TronModuleHost) => ExtensionFactory | undefined;
}

export interface TronModuleRegistration {
  name: string;
  factory: ExtensionFactory;
}

/** The one definition of Tron's built-in extensions. RuntimeSlot registers
 * exactly this list for each session and `modules.list` reports it, so Settings
 * and sessions cannot drift. */
export const TRON_MODULES: readonly TronModule[] = [
  {
    name: "tron-context-window",
    purpose: "Keeps the session's model context window applied as the model changes.",
    tools: [],
    commands: [],
    factory: (host) => contextWindowExtension(() => host.contextPolicy()),
  },
  {
    name: "tron-compaction-policy",
    purpose: "Applies Tron's compaction policy and cancels the compaction a stop aborted.",
    tools: [],
    commands: [],
    factory: (host) => compactionPolicyExtension(
      () => host.compactionPolicy(),
      (event) => host.compactionStopped(event),
      () => host.compactionChanged(),
    ),
  },
  {
    name: "tron-core",
    purpose: "Adds Tron's operating context and the knowledge, connections and Jev tools.",
    tools: ["knowledge", "connections", "jev"],
    commands: [],
    factory: (host) => createTronCoreExtension(host.workspace, host.knowledge, host.jev, host.connections),
  },
  {
    name: "tron-ask-user",
    purpose: "Lets the agent ask you one bounded decision question.",
    tools: ["ask_user"],
    commands: [],
    factory: () => createTronAskUserExtension(),
  },
  {
    name: "tron-display",
    purpose: "Shows documents, images and live views in the app.",
    tools: ["display"],
    commands: [],
    factory: (host) => createTronDisplayExtension({
      sessionId: () => host.sessionId(),
      cwd: () => host.cwd(),
      artifacts: host.displayArtifacts,
      ...(host.browserLiveViews ? { liveViews: host.browserLiveViews } : {}),
      internalFilesRoot: () => host.workspace.filesRoot(),
    }),
  },
  {
    name: "tron-native-capture",
    purpose: "Captures live views from connected devices.",
    tools: ["native_capture"],
    commands: [],
    factory: (host) => (host.browserLiveViews
      ? createTronNativeCaptureExtension({ sessionId: () => host.sessionId(), views: host.browserLiveViews })
      : undefined),
  },
  {
    name: "tron-computer",
    purpose: "Lets the agent inspect and operate the Mac desktop.",
    tools: ["computer"],
    commands: [],
    factory: (host) => (process.platform === "darwin"
      ? createTronComputerExtension({ sessionId: () => host.sessionId() })
      : undefined),
  },
  {
    name: "tron-schedule",
    purpose: "Creates and manages durable reminders and automations.",
    tools: ["schedule"],
    commands: [],
    factory: (host) => (host.scheduleToolOperations
      ? createTronScheduleExtension({ sessionId: () => host.sessionId(), operations: host.scheduleToolOperations })
      : undefined),
  },
  {
    name: "tron-notify",
    purpose: "Sends notifications to your Tron iPhones.",
    tools: ["notify"],
    commands: [],
    factory: (host) => {
      const notifications = host.notifications;
      if (!notifications) return undefined;
      return createTronNotifyExtension({
        sessionId: () => host.sessionId(),
        sessionTitle: () => host.notificationTitle(),
        ...(host.machineId ? { machineId: host.machineId } : {}),
        enqueue: (input) => notifications.enqueue(input),
      });
    },
  },
];

/** The ordered inline registrations for one session. Availability stays with the
 * module definition, so a host-owned owner is the only reason a module is absent. */
export function tronModuleFactories(host: TronModuleHost): TronModuleRegistration[] {
  const registrations: TronModuleRegistration[] = [];
  for (const tronModule of TRON_MODULES) {
    const factory = tronModule.factory(host);
    if (factory) registrations.push({ name: tronModule.name, factory });
  }
  return registrations;
}

export const MODULES_CAPABILITY = "modules.v1";

/** The `modules.list` module rows, taken from the same definition RuntimeSlot
 * registers so Settings cannot report a module a session does not load. */
export function tronModuleSummaries(): TronModuleSummary[] {
  return TRON_MODULES.map((tronModule) => ({
    name: tronModule.name,
    purpose: tronModule.purpose,
    tools: [...tronModule.tools],
    commands: [...tronModule.commands],
  }));
}
