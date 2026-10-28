import type { ModuleDescriptor } from "../../kernel/host/module-host.js";
import type { JsonValue } from "../../protocol/types.js";
import { integer, rejectUnknownFields } from "../../util/validation.js";
import { workspaceModule } from "../../workspace/workspace-module.js";
import { SWIFT_APPS_CAPABILITY, SwiftAppStore, admitSwiftAppId, type SwiftAppCommit } from "./swift-app-store.js";
import { createTronSwiftAppExtension } from "./tron-swift-app-extension.js";

/** Installed Swift apps (docs/swift-apps.md): the store over the internal
 * workspace, the `swift_app` tool for each ordinary runtime, the `apps.*` RPCs
 * and `swift-apps.v1`. */
export const appsModule: ModuleDescriptor = {
  name: "tron-swift-apps",
  purpose: "Installs the user's single-file SwiftUI apps and reads or seeds their stored data.",
  tools: ["swift_app"],
  commands: [],
  dependsOn: [workspaceModule],
  start: (host) => {
    const workspace = host.contract(workspaceModule);
    // The only writer of `state/apps/`, shared by the tool and the RPCs.
    const store = new SwiftAppStore(workspace);
    return {
      extension: (session) => createTronSwiftAppExtension({ store, cwd: () => session.cwd(), internalFilesRoot: () => workspace.filesRoot() }),
      capabilities: [SWIFT_APPS_CAPABILITY],
      rpc: {
        "apps.list": { kind: "read", handle: async (params) => {
          rejectUnknownFields(params, [], "apps.list");
          return { apps: await store.list() } as unknown as JsonValue;
        } },
        // Source and state are exact data the runner executes and restores, so
        // they skip safeJson's presentation clipping; the store bounds them.
        "apps.get": { kind: "read", handle: async (params) => {
          rejectUnknownFields(params, ["appId"], "apps.get");
          return await store.get(admitSwiftAppId(params.appId)) as unknown as JsonValue;
        } },
        "apps.open": { kind: "read", handle: async (params) => {
          rejectUnknownFields(params, ["appId"], "apps.open");
          return await store.open(admitSwiftAppId(params.appId)) as unknown as JsonValue;
        } },
        "apps.state": { kind: "read", handle: async (params) => {
          rejectUnknownFields(params, ["appId"], "apps.state");
          return await store.state(admitSwiftAppId(params.appId)) as unknown as JsonValue;
        } },
        // Phone-side management. Each is a receipt-backed mutation; replay returns
        // the original result, including a remove after the app is already gone.
        "apps.rename": { kind: "mutation", handle: async (params) => {
          rejectUnknownFields(params, ["commandId", "appId", "name"], "apps.rename");
          return await store.rename(admitSwiftAppId(params.appId), params.name) as unknown as JsonValue;
        } },
        "apps.reset": { kind: "mutation", handle: async (params) => {
          rejectUnknownFields(params, ["commandId", "appId", "expectedRevision"], "apps.reset");
          return await store.resetState(admitSwiftAppId(params.appId),
            integer(params.expectedRevision, "expectedRevision", 0, Number.MAX_SAFE_INTEGER)) as unknown as JsonValue;
        } },
        "apps.remove": { kind: "mutation", handle: async (params) => {
          rejectUnknownFields(params, ["commandId", "appId"], "apps.remove");
          return await store.remove(admitSwiftAppId(params.appId)) as unknown as JsonValue;
        } },
        "apps.commit": { kind: "mutation", handle: async (params) => {
          rejectUnknownFields(params, ["commandId", "appId", "expectedRevision", "expectedSourceRevision", "set", "remove"], "apps.commit");
          return await store.commit({
            appId: admitSwiftAppId(params.appId),
            expectedRevision: integer(params.expectedRevision, "expectedRevision", 0, Number.MAX_SAFE_INTEGER),
            ...(params.expectedSourceRevision === undefined ? {}
              : { expectedSourceRevision: integer(params.expectedSourceRevision, "expectedSourceRevision", 1, Number.MAX_SAFE_INTEGER) }),
            set: (params.set ?? []) as SwiftAppCommit["set"],
            remove: (params.remove ?? []) as string[],
          }) as unknown as JsonValue;
        } },
      },
    };
  },
};
