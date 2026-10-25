import type { ModuleDescriptor } from "../kernel/host/module-host.js";
import { TronWorkspace } from "./tron-workspace.js";

/** The internal workspace as a module contract (k0-kernel.md §6): this module
 * constructs the one `TronWorkspace` of a Gateway, and peers read it through
 * `dependsOn`. The kernel drives the same instance's critical initialize/dispose
 * through its resourceRoot policy, not best-effort lifecycle observers. */
export const workspaceModule: ModuleDescriptor<TronWorkspace> = {
  name: "tron-workspace",
  purpose: "Owns Tron's durable internal workspace for the capabilities that keep state in it.",
  tools: [],
  commands: [],
  start: (host) => {
    const workspace = new TronWorkspace(host.tronHome, {
      unavailable: cause => host.log.log("warning", "Tron internal workspace is unavailable", {
        event: "workspace.unavailable", source: "workspace", cause,
      }),
    });
    return { contract: workspace, hooks: { resourceRoot: () => workspace } };
  },
};
