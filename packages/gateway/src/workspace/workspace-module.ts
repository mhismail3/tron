import type { ModuleDescriptor } from "../kernel/host/module-host.js";
import { TronWorkspace } from "./tron-workspace.js";

/** The internal workspace as a module contract (k0-kernel.md §6): this module
 * constructs the one `TronWorkspace` of a Gateway, and peers read it through
 * `dependsOn`. The registry still drives its initialize/dispose order around
 * Home until Home leaves the registry (E7). */
export const workspaceModule: ModuleDescriptor<TronWorkspace> = {
  name: "tron-workspace",
  purpose: "Owns Tron's durable internal workspace for the capabilities that keep state in it.",
  tools: [],
  commands: [],
  start: (host) => ({
    contract: new TronWorkspace(host.tronHome, {
      unavailable: cause => host.log.log("warning", "Tron internal workspace is unavailable", {
        event: "workspace.unavailable", source: "workspace", cause,
      }),
    }),
  }),
};
