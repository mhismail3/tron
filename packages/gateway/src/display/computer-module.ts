import type { ModuleDescriptor } from "../kernel/host/module-host.js";
import { createTronComputerExtension } from "./tron-computer-extension.js";

/** Native operations stay unavailable on hosts without the Mac driver. */
export const computerModule: ModuleDescriptor = {
  name: "tron-computer",
  purpose: "Lets the agent inspect and operate the Mac desktop.",
  tools: ["computer"],
  commands: [],
  start: () => ({
    extension: (session) => (process.platform === "darwin"
      ? createTronComputerExtension({ sessionId: () => session.sessionId() })
      : undefined),
  }),
};
