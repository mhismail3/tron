import type { ModuleDescriptor } from "../kernel/host/module-host.js";
import { TronWorkspace } from "./tron-workspace.js";

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
