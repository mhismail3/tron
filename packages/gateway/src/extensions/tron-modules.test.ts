import { describe, expect, it } from "vitest";
import type { NotificationService } from "../notifications/notification-service.js";
import type { DisplayArtifactStore } from "../display/display-artifact-store.js";
import type { BrowserLiveViewRegistry } from "../display/browser-live-view.js";
import type { TronWorkspace } from "../workspace/tron-workspace.js";
import type { KnowledgeService } from "../knowledge/knowledge-service.js";
import type { JevDecisionClient } from "../knowledge/jev-client.js";
import type { ConnectionOwner } from "../integrations/connection-owner.js";
import type { ScheduleToolOperations } from "../automations/tron-schedule-extension.js";
import { HOME_TOOL_NAMES, TRON_HOME_MODULE, TRON_MODULES, tronModuleFactories, type TronModuleHost } from "./tron-modules.js";

/** Records what one factory run registers without a session or a live runtime. */
function registrationSurface() {
  const tools: string[] = [];
  const commands: string[] = [];
  const events: string[] = [];
  const pi = {
    registerTool: (tool: { name: string }) => { tools.push(tool.name); },
    registerCommand: (command: { name: string }) => { commands.push(command.name); },
    on: (event: string) => { events.push(event); },
    getActiveTools: () => [],
  };
  return { tools, commands, events, pi };
}

function tronModuleHost(options: { optionalOwners?: boolean } = {}): TronModuleHost {
  const optionalOwners = options.optionalOwners ?? true;
  return {
    sessionId: () => "session-a",
    cwd: () => "/workspace",
    workspace: { describe: async () => ({}), filesRoot: () => "/tron/workspace/files" } as unknown as TronWorkspace,
    displayArtifacts: {} as DisplayArtifactStore,
    notificationTitle: () => "Session",
    isSessionPresented: () => false,
    contextPolicy: () => undefined,
    compactionPolicy: () => undefined,
    compactionStopped: () => false,
    compactionChanged: () => {},
    knowledge: {} as KnowledgeService,
    jev: {} as JevDecisionClient,
    connections: {} as ConnectionOwner,
    ...(optionalOwners ? {
      browserLiveViews: {} as BrowserLiveViewRegistry,
      notifications: { enqueue: async () => "queued" } as unknown as NotificationService,
      scheduleToolOperations: {} as ScheduleToolOperations,
      machineId: "machine-a",
    } : {}),
    homeMemoryTools: () => undefined,
  };
}

describe("Tron module definition", () => {
  it("registers exactly the declared tool and command names for every module", () => {
    const host = tronModuleHost();
    for (const tronModule of TRON_MODULES) {
      const factory = tronModule.factory(host);
      expect(factory, tronModule.name).toBeTypeOf("function");
      const surface = registrationSurface();
      factory!(surface.pi as never);
      // Registration order is not part of the contract; the exact set is.
      expect({ name: tronModule.name, tools: [...surface.tools].sort(), commands: [...surface.commands].sort() })
        .toEqual({ name: tronModule.name, tools: [...tronModule.tools].sort(), commands: [...tronModule.commands].sort() });
    }
  });

  it("declares exactly the tools the Home-only module registers", () => {
    // `TRON_HOME_MODULE` is not in `TRON_MODULES`: only a Home runtime loads it.
    // Its declared tools are still a promise, and this is where it is kept. A
    // session that is not the enabled Home gets no memory from the accessor, so
    // the tools are registered and answer a typed unavailable result.
    const factory = TRON_HOME_MODULE.factory(tronModuleHost());
    expect(factory).toBeTypeOf("function");
    const surface = registrationSurface();
    factory!(surface.pi as never);
    expect([...surface.tools].sort()).toEqual([...TRON_HOME_MODULE.tools].sort());
    // Every registered name must be inside the executable allowlist, or the
    // registration is a tool Home can never call.
    for (const name of surface.tools) expect(HOME_TOOL_NAMES).toContain(name);
  });

  it("keeps declared names unique and non-empty so a registration cannot silently collide", () => {
    const names = TRON_MODULES.map((tronModule) => tronModule.name);
    expect(new Set(names).size).toBe(names.length);
    for (const tronModule of TRON_MODULES) {
      expect(tronModule.name.trim().length, tronModule.name).toBeGreaterThan(0);
      expect(tronModule.purpose.trim().length, tronModule.name).toBeGreaterThan(0);
    }
  });

  it("registers every definition entry in definition order when the host offers its owners", () => {
    expect(tronModuleFactories(tronModuleHost()).map((registration) => registration.name))
      .toEqual(TRON_MODULES.map((tronModule) => tronModule.name));
    expect(tronModuleFactories(tronModuleHost()).length).toBe(TRON_MODULES.length);
  });

  it("drops exactly the modules whose session owners are absent", () => {
    const names = tronModuleFactories(tronModuleHost({ optionalOwners: false })).map((registration) => registration.name);
    const dropped = TRON_MODULES.map((tronModule) => tronModule.name).filter((name) => !names.includes(name));
    // tron-computer is macOS-only; every other conditional module follows its owner.
    expect(dropped).toEqual([
      ...(process.platform === "darwin" ? [] : ["tron-computer"]),
      "tron-native-capture",
      "tron-schedule",
      "tron-notify",
    ]);
  });
});
