import type { ModuleDescriptor } from "../../kernel/host/module-host.js";
import type { JsonValue } from "../../protocol/types.js";
import { integer, rejectUnknownFields, string } from "../../util/validation.js";
import { workspaceModule } from "../../workspace/workspace-module.js";
import { AppsFolderStore } from "./apps-folder-store.js";
import { createAppDataExtension } from "./app-data-extension.js";
import type { AppDataCommit } from "./app-data-store.js";

/** Files are the only membership authority. No offer or install admission. */
export function createAppsModule(): ModuleDescriptor<AppsFolderStore> { return {
  name: "tron-swift-apps",
  purpose: "Indexes folder-backed apps and artifacts; owns scoped access and saved data.",
  tools: ["app_data"], commands: [], dependsOn: [workspaceModule],
  start: host => {
    const store = new AppsFolderStore(host.contract(workspaceModule), host.tronHome);
    const id = (params: Record<string, unknown>) => string(params.id, "id", { max: 80 });
    const revision = (params: Record<string, unknown>) => string(params.expectedContentRevision, "expectedContentRevision", { max: 64 });
    return {
      contract: store,
      hooks: { kernelLifecycle: () => ({ initialize: async () => {},
        started: () => { void store.index.recoverPublications().catch(() => host.log.log("warning", "Apps staging recovery unavailable")); },
        closing: () => store.index.stopPublications(), dispose: () => store.dispose() }) },
      extension: () => createAppDataExtension(store),
      stop: () => store.dispose(),
      capabilities: ["apps-folder.v1"],
      rpc: {
        "apps.catalog": { kind: "read", handle: async params => {
          rejectUnknownFields(params, ["cursor", "limit"], "apps.catalog");
          return await store.index.catalog(params.cursor === undefined ? undefined : string(params.cursor, "cursor", { max: 1024 }),
            params.limit === undefined ? 50 : integer(params.limit, "limit", 1, 50)) as unknown as JsonValue;
        } },
        "apps.open": { kind: "read", handle: async (params, context) => {
          rejectUnknownFields(params, ["id", "expectedContentRevision"], "apps.open");
          return await store.open(id(params), revision(params), context.identity) as unknown as JsonValue;
        } },
        "apps.permissions.grant": { kind: "mutation", handle: async (params, context) => {
          rejectUnknownFields(params, ["commandId", "token"], "apps.permissions.grant");
          return await store.grant(string(params.token, "token", { max: 4096 }), context.identity) as unknown as JsonValue;
        } },
        "apps.permissions.revoke": { kind: "mutation", handle: async params => {
          rejectUnknownFields(params, ["commandId", "id"], "apps.permissions.revoke");
          return await store.revoke(id(params)) as unknown as JsonValue;
        } },
        "apps.deleteFiles": { kind: "mutation", handle: async params => {
          rejectUnknownFields(params, ["commandId", "rowKey", "expectedContentRevision"], "apps.deleteFiles");
          return await store.deleteFiles(string(params.rowKey, "rowKey", { max: 64 }), revision(params)) as unknown as JsonValue;
        } },
        "apps.state": { kind: "read", handle: async params => {
          rejectUnknownFields(params, ["id"], "apps.state");
          return await store.managedState(id(params)) as unknown as JsonValue;
        } },
        "apps.reset": { kind: "mutation", handle: async params => {
          rejectUnknownFields(params, ["commandId", "id", "expectedRevision", "confirmed"], "apps.reset");
          return await store.clearData(id(params), integer(params.expectedRevision, "expectedRevision", 0, Number.MAX_SAFE_INTEGER), params.confirmed) as unknown as JsonValue;
        } },
        "apps.commit": { kind: "mutation", handle: async params => {
          rejectUnknownFields(params, ["commandId", "id", "expectedContentRevision", "grantRevision", "expectedRevision", "set", "remove"], "apps.commit");
          return await store.commit({ appId: id(params), expectedContentRevision: revision(params),
            grantRevision: string(params.grantRevision, "grantRevision", { max: 64 }),
            expectedRevision: integer(params.expectedRevision, "expectedRevision", 0, Number.MAX_SAFE_INTEGER),
            set: (params.set ?? []) as AppDataCommit["set"], remove: (params.remove ?? []) as string[] }) as unknown as JsonValue;
        } },
      },
    };
  },
}; }
