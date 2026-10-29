import type { AppReference } from "./apps-reference.js";
import type { SwiftAppStateSnapshot } from "./app-data-store.js";
import type { AppArtifact, AppPermissions, ReadyAppEntry } from "./apps-folder-format.js";
import type { readIOSBuildsFeed } from "./ios-builds-feed.js";

/** Closed wire projection. Only Swift has executable source/state; media bytes
 * are read from the index-owned lease, never converted into JSON UTF-8 text. */
export type AppOpenProjection =
  | { kind: "permissionRequired"; row: ReadyAppEntry["row"]; permissions: AppPermissions; token: string }
  | { kind: "swift"; row: ReadyAppEntry["row"]; source: string; permissions: AppPermissions;
      state: SwiftAppStateSnapshot; feeds: Partial<Record<"ios-builds", Awaited<ReturnType<typeof readIOSBuildsFeed>>>>; grantRevision: string | null }
  | { kind: "reference"; row: ReadyAppEntry["row"]; reference: AppReference }
  | { kind: "artifact"; row: ReadyAppEntry["row"]; artifact: AppArtifact };
