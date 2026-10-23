import type { ModuleDescriptor } from "../kernel/host/module-host.js";
import type { DisplayArtifactStore } from "./display-artifact-store.js";
import type { BrowserLiveViewRegistry } from "./browser-live-view.js";
import { workspaceModule } from "../workspace/workspace-module.js";
import { createTronDisplayExtension } from "./tron-display-extension.js";
import { admitToolDisplayProjection, displayReferences } from "./display-contract.js";
import { observeTrustedAgentBrowserResult } from "./browser-live-view-adapter.js";
import type { ToolResultProjection } from "../kernel/projection/tool-result.js";
import { createTronNativeCaptureExtension } from "./tron-native-capture-extension.js";

export interface DisplayModuleServices { artifacts: DisplayArtifactStore; liveViews: BrowserLiveViewRegistry | undefined }

export function createDisplayModule(services: () => DisplayModuleServices): ModuleDescriptor {
  return {
    name: "tron-display", purpose: "Shows documents, images and live views in the app.",
    tools: ["display"], commands: [], dependsOn: [workspaceModule],
    start: host => {
      const workspace = host.contract(workspaceModule);
      const projection: ToolResultProjection = {
        display: admitToolDisplayProjection, references: displayReferences,
        beginBrowserLoad: (sessionId, runtimeGeneration) => {
          const views = services().liveViews;
          return views ? { sessionId, runtimeGeneration, loadToken: views.beginSessionLoad(sessionId),
            observeResult: input => projection.observeBrowserResult(input) } : undefined;
        },
        observeBrowserResult: input => {
          const views = services().liveViews;
          return views ? observeTrustedAgentBrowserResult({ ...input, views }) : input.result;
        },
      };
      return { hooks: {
        toolResultProjection: () => projection, sessionRetired: sessionId => services().liveViews?.retireSession(sessionId),
      }, extension: session => {
        const owners = services();
        return createTronDisplayExtension({
          sessionId: session.sessionId, cwd: session.cwd, artifacts: owners.artifacts,
          ...(owners.liveViews ? { liveViews: owners.liveViews } : {}),
          internalFilesRoot: () => workspace.filesRoot(),
        });
      } };
    },
  };
}

export function createNativeCaptureModule(services: () => DisplayModuleServices): ModuleDescriptor {
  return {
    name: "tron-native-capture", purpose: "Captures live views from connected devices.",
    tools: ["native_capture"], commands: [],
    start: () => ({ extension: session => {
      const views = services().liveViews;
      return views ? createTronNativeCaptureExtension({ sessionId: session.sessionId, views }) : undefined;
    } }),
  };
}
