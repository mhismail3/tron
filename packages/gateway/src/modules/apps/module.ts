import type { ModuleDescriptor } from "../../kernel/host/module-host.js";
import type { DisplayOwner } from "../../display/display-modules.js";
import { readSwiftDisplaySource } from "./swift-app-display.js";
import { digest } from "./swift-app-format.js";
import { readIOSBuildsFeed } from "./ios-builds-feed.js";
import type { JsonValue } from "../../protocol/types.js";
import { integer, rejectUnknownFields, string } from "../../util/validation.js";
import { workspaceModule } from "../../workspace/workspace-module.js";
import { SWIFT_APPS_CAPABILITY, SwiftAppStore, admitSwiftAppId, type SwiftAppCommit } from "./swift-app-store.js";
import { createTronSwiftAppExtension } from "./tron-swift-app-extension.js";

/** Installed Swift apps (docs/swift-apps.md): the store over the internal
 * workspace, the `swift_app` tool for each ordinary runtime, the `apps.*` RPCs
 * and `swift-apps.v1`. */
export function createAppsModule(display: () => DisplayOwner): ModuleDescriptor { return {
  name: "tron-swift-apps",
  purpose: "Installs the user's single-file SwiftUI apps and reads or seeds their stored data.",
  tools: ["swift_app"],
  commands: [],
  dependsOn: [workspaceModule],
  start: (host) => {
    const workspace = host.contract(workspaceModule);
    // The only writer of `state/apps/`, shared by the tool and the RPCs.
    const store = new SwiftAppStore(workspace, display);
    return {
      extension: (session) => createTronSwiftAppExtension({ store, artifacts: display().artifacts, cwd: () => session.cwd(), sessionId: () => session.sessionId(), internalFilesRoot: () => workspace.filesRoot() }),
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
          const snapshot = await store.open(admitSwiftAppId(params.appId));
          if (snapshot.app.version === 1) return snapshot as unknown as JsonValue;
          const feeds = snapshot.app.feeds.includes("ios-builds") ? { "ios-builds": await readIOSBuildsFeed(host.tronHome) } : {};
          return { ...snapshot, feeds } as unknown as JsonValue;
        } },
        "apps.review": { kind: "read", handle: async (params) => {
          rejectUnknownFields(params, ["sessionId", "artifactId"], "apps.review");
          const sessionId = string(params.sessionId, "sessionId", { max: 256 });
          const artifactId = string(params.artifactId, "artifactId", { max: 256 });
          const source = await readSwiftDisplaySource(await display().acquireArtifact(sessionId, artifactId));
          return { ...await store.review({ sessionId, artifactId }, digest(source)), reference: { sessionId, artifactId } } as unknown as JsonValue;
        } },
        "apps.install": { kind: "mutation", handle: async (params, context) => {
          rejectUnknownFields(params, ["commandId", "sessionId", "artifactId", "offerId", "expectedRevision", "expectedSourceSha256", "expectedInstanceId", "upgradeToV2"], "apps.install");
          const sessionId = string(params.sessionId, "sessionId", { max: 256 });
          const artifactId = string(params.artifactId, "artifactId", { max: 256 });
          const source = await readSwiftDisplaySource(await display().acquireArtifact(sessionId, artifactId));
          return await store.installOffer({ offerId: params.offerId, reference: { sessionId, artifactId }, sourceSha256: digest(source), expectedRevision: params.expectedRevision,
            expectedSourceSha256: params.expectedSourceSha256, expectedInstanceId: params.expectedInstanceId, upgradeToV2: params.upgradeToV2 },
          { kind: "device", id: context.identity }) as unknown as JsonValue;
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
          rejectUnknownFields(params, ["commandId", "appId", "expectedInstanceId"], "apps.remove");
          return await store.remove(admitSwiftAppId(params.appId), params.expectedInstanceId) as unknown as JsonValue;
        } },
        "apps.commit": { kind: "mutation", handle: async (params) => {
          rejectUnknownFields(params, ["commandId", "appId", "expectedRevision", "expectedSourceRevision", "expectedInstanceId", "set", "remove"], "apps.commit");
          return await store.commit({
            appId: admitSwiftAppId(params.appId),
            expectedRevision: integer(params.expectedRevision, "expectedRevision", 0, Number.MAX_SAFE_INTEGER),
            ...(params.expectedSourceRevision === undefined ? {}
              : { expectedSourceRevision: integer(params.expectedSourceRevision, "expectedSourceRevision", 1, Number.MAX_SAFE_INTEGER) }),
            ...(params.expectedInstanceId === undefined ? {} : { expectedInstanceId: params.expectedInstanceId as string }),
            set: (params.set ?? []) as SwiftAppCommit["set"],
            remove: (params.remove ?? []) as string[],
          }) as unknown as JsonValue;
        } },
      },
    };
  },
}; }
