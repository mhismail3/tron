import type { ModuleDescriptor } from "../kernel/host/module-host.js";
import { createTronAskUserExtension } from "./tron-ask-user-extension.js";

/** The decision tool has no Gateway-wide service or per-runtime state. */
export const askUserModule: ModuleDescriptor = {
  name: "tron-ask-user",
  purpose: "Lets the agent ask you one bounded decision question.",
  tools: ["ask_user"],
  commands: [],
  start: () => ({ extension: () => createTronAskUserExtension() }),
};
