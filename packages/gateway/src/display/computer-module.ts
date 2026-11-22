import type { ModuleDescriptor } from "../kernel/host/module-host.js";
import type { ConsoleGate } from "../machine/console-probe.js";
import { createTronComputerExtension } from "./tron-computer-extension.js";

export function createComputerModule(gate: ConsoleGate): ModuleDescriptor {
  return {
    name: "tron-computer",
    purpose: "Lets the agent inspect and operate the Mac desktop.",
    tools: ["computer"],
    commands: [],
    start: () => ({
      extension: (session) => (process.platform === "darwin"
        ? createTronComputerExtension({ sessionId: () => session.sessionId(), delegatedTask: () => session.delegatedTask(), gate })
        : undefined),
    }),
  };
}
