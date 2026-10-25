import type { ModuleDescriptor, SessionContext } from "../kernel/host/module-host.js";
import { createTronHomeExtension } from "./tron-home-extension.js";
import { homeResearchTools, type HomeResearchTransport } from "./home-research-tools.js";
import type { HomeMemoryToolAccess } from "./home-memory.js";
import type { HomeProfileChangeAccess } from "./home-profile-tool.js";
import type { SettingsChangePath } from "../admin/settings-model.js";
import type { HomeOwner } from "./home-owner.js";
import type { TrustService } from "../admin/trust-service.js";
import type { HomeTaskDispatchRequest, HomeTaskHandle } from "./home-task-dispatcher.js";
import type { HomeSessionReader } from "./home-session-read.js";
import type { KnowledgeService } from "../knowledge/knowledge-service.js";
import type { SessionSearchRequest, SessionSearchResponse } from "../sessions/session-search-contract.js";

export interface HomeModuleServices {
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

/** Home owns its extension closures; registry supplies only the kernel-side
 * operations and reads of owners installed after registry construction. */
export function homeModuleServices(owner: HomeOwner,
  platform: { trust: TrustService; homeWebTransport?: HomeResearchTransport },
  ports: Pick<HomeModuleServices, "knowledge" | "search" | "read" | "delegate"> & { changes(): SettingsChangePath | undefined },
): HomeModuleServices {
  return {
    knowledge: ports.knowledge, search: ports.search, read: ports.read, delegate: ports.delegate,
    memory: sessionId => owner.memoryToolsFor(sessionId),
    task: (sessionId, request) => owner.taskTool(sessionId, request),
    profileChanges: session => homeProfileChanges(session, ports.changes()),
    explicitlyTrustedDirectory: async path => {
      try { return (await platform.trust.inspect(path)).savedDecision === true; } catch { return false; }
    },
    ...(platform.homeWebTransport ? { transport: platform.homeWebTransport } : {}),
  };
}

/** Home's profile tool resolves the current change path and actor on each call. */
export function homeProfileChanges(session: SessionContext, changes: SettingsChangePath | undefined): HomeProfileChangeAccess | undefined {
  if (!changes || session.profile() !== "home") return undefined;
  return { change: (ops, input) => changes.changeProfile(ops, {
    actor: { kind: "home", id: session.sessionId(), sessionId: session.sessionId(), toolCallId: input.toolCallId },
    author: input.author, commandId: input.commandId, web: input.web, ...(input.reason ? { reason: input.reason } : {}),
  }) };
}

export function createHomeModule(services: () => HomeModuleServices): ModuleDescriptor {
  return {
    name: "tron-home",
    purpose: "Adds Home's operating context, registers Home's memory tools and keeps Home out of prompt-cache warming.",
    tools: ["zoom", "date", "memory_search", "delegate", "task", "profile"], commands: [],
    start: () => ({ extension: session => {
      const owners = services();
      return createTronHomeExtension(() => owners.memory(session.sessionId()),
        (request, signal) => owners.delegate(session.sessionId(), request, signal),
        request => owners.task(session.sessionId(), request),
        () => owners.knowledge, () => owners.profileChanges(session));
    } }),
  };
}

export function createHomeResearchModule(services: () => HomeModuleServices): ModuleDescriptor {
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
