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
import { createTronHomeExtension } from "../home/tron-home-extension.js";
import { homeResearchTools, type HomeResearchTransport } from "../home/home-research-tools.js";
import type { SessionSearchRequest, SessionSearchResponse } from "../sessions/session-search-contract.js";
import type { HomeMemoryToolAccess } from "../home/home-memory.js";
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
  /** Whether the user is currently viewing this session's chat. */
  isSessionPresented: () => boolean;
  contextPolicy: () => SessionContextWindowPolicy | undefined;
  compactionPolicy: () => CompactionOperationPolicy | undefined;
  compactionStopped: (event: SessionBeforeCompactEvent) => boolean;
  compactionChanged: () => void;
  joinTerminalReceiptWrites: () => Promise<void>;
  knowledge?: KnowledgeService;
  jev?: JevDecisionClient;
  connections?: ConnectionOwner;
  browserLiveViews?: BrowserLiveViewRegistry;
  notifications?: NotificationService;
  scheduleToolOperations?: ScheduleToolOperations;
  machineId?: string;
  /** Tron Home's memory for one session id, or undefined for every session that
   * is not the enabled Home. Read at every tool call, never cached. Requiring it
   * here is what keeps the wiring honest: the only Home runtime is built by a
   * slot that answers this. */
  homeMemoryTools: (sessionId: string) => HomeMemoryToolAccess | undefined;
  homeTask: (sessionId: string, request: import("../home/tron-home-extension.js").HomeTaskToolRequest) => Promise<unknown>;
  homeDelegate: (sessionId: string, request: import("../home/home-task-dispatcher.js").HomeTaskDispatchRequest) => Promise<import("../home/home-task-dispatcher.js").HomeTaskHandle>;
  /** Session search for Home's research tools, late-bound: the service is
   * installed after the registry exists, and may be absent on this Gateway. */
  sessionSearch: () => ((request: SessionSearchRequest, signal?: AbortSignal) => Promise<SessionSearchResponse>) | undefined;
  /** True only for a directory covered by an explicit recorded trust decision
   * (`savedDecision === true`); the "always" default never counts. Home's
   * `read_file` is limited to what the maintainer deliberately trusted. */
  explicitlyTrustedDirectory: (path: string) => Promise<boolean>;
  /** Transport injection for Home's web tools, the same seam capture's fetch
   * exposes (`SourceCaptureOptions`); production omits it. */
  homeWebTransport?: HomeResearchTransport;
}

/** One built-in Tron extension. `name` is the runtime-registered inline name, so
 * Pi reports its resources with `<inline:name>` as the source. */
export interface TronModule {
  name: string;
  /** One-line purpose for Settings. */
  purpose: string;
  /** Tool names the factory registers when its owners are present. */
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
    name: "tron-invocation-settlement",
    purpose: "Keeps each chat's completion receipts in order before the next message",
    tools: [],
    commands: [],
    factory: (host) => (pi) => {
      // Pi awaits these public hooks before the next run/input can append.
      // Join receipt I/O only: attention must not hold up accepted continuations.
      pi.on("turn_start", async () => {
        await host.joinTerminalReceiptWrites();
      });
      pi.on("message_end", async (event) => {
        if (event.message.role === "user") await host.joinTerminalReceiptWrites();
      });
    },
  },
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
        observed: () => host.isSessionPresented(),
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

/** The existing Tron modules a Home runtime keeps, in definition order. Home's
 * curation excludes Pi built-ins (codemode, tool-search, MCP) and the modules
 * whose work belongs to an ordinary project session. */
export const HOME_MODULE_NAMES: readonly string[] = [
  "tron-context-window",
  "tron-compaction-policy",
  "tron-ask-user",
  "tron-display",
  "tron-notify",
];

/** The one module only a Home runtime loads. It is not part of `TRON_MODULES`
 * because `modules.list` reports what every session registers, and an ordinary
 * session never loads it. */
export const TRON_HOME_MODULE: TronModule = {
  name: "tron-home",
  purpose: "Adds Home's operating context, registers Home's memory tools and keeps Home out of prompt-cache warming.",
  tools: ["zoom", "date", "memory_search", "delegate", "task", "profile"],
  commands: [],
  factory: (host) => createTronHomeExtension(() => host.homeMemoryTools(host.sessionId()),
    request => host.homeDelegate(host.sessionId(), request),
    request => host.homeTask(host.sessionId(), request),
    () => host.knowledge),
};

/** The one research module only a Home runtime loads (#724): read-only web
 * search and fetch, session search, Knowledge lookup, and trusted-project file
 * reading. Like `TRON_HOME_MODULE` it is not part of `TRON_MODULES`, because an
 * ordinary session never loads it. All five tools are always registered — the
 * tool list heads every cached prefix — and each resolves its owner per call. */
const TRON_HOME_RESEARCH_MODULE: TronModule = {
  name: "tron-home-research",
  purpose: "Adds Home's read-only research tools: web search and fetch, session search, Knowledge lookup and trusted-project file reading.",
  tools: ["web_search", "web_fetch", "session_search", "knowledge", "read_file"],
  commands: [],
  factory: (host) => (pi) => {
    const tools = homeResearchTools({
      knowledge: () => host.knowledge,
      sessionSearch: () => host.sessionSearch(),
      explicitlyTrustedDirectory: (path) => host.explicitlyTrustedDirectory(path),
      ...(host.homeWebTransport ? { transport: host.homeWebTransport } : {}),
    });
    for (const tool of tools) pi.registerTool(tool);
  },
};

/** The executable tool ceiling for a Home runtime, passed to the SDK as its
 * registration allowlist. MCP is excluded structurally: no MCP extension is
 * loaded for Home, so no `mcp__*` tool can exist to be kept by a future
 * allowlist semantic. */
export const HOME_TOOL_NAMES: readonly string[] = [
  "ask_user", "display", "notify", "zoom", "date", "memory_search", "delegate", "task", "profile",
  "web_search", "web_fetch", "session_search", "knowledge", "read_file",
];

/** The curated Home profile: the kept Tron modules plus tron-home, and nothing
 * else. Availability stays host-owned exactly as for an ordinary session. */
export function homeModuleFactories(host: TronModuleHost): TronModuleRegistration[] {
  const registrations: TronModuleRegistration[] = [];
  for (const tronModule of TRON_MODULES) {
    if (!HOME_MODULE_NAMES.includes(tronModule.name)) continue;
    const factory = tronModule.factory(host);
    if (factory) registrations.push({ name: tronModule.name, factory });
  }
  for (const homeModule of [TRON_HOME_MODULE, TRON_HOME_RESEARCH_MODULE]) {
    const factory = homeModule.factory(host);
    if (factory) registrations.push({ name: homeModule.name, factory });
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
