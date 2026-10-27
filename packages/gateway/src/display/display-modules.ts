import type { ModuleDescriptor } from "../kernel/host/module-host.js";
import type { DisplayArtifactStore } from "./display-artifact-store.js";
import type { BrowserLiveViewRegistry } from "./browser-live-view.js";
import type { BlobByteRange } from "../sessions/blob-store.js";
import { GatewayError } from "../errors.js";
import { abortableRead } from "../util/abortable-read.js";
import { RequestSpanLane } from "../util/request-span.js";
import { workspaceModule } from "../workspace/workspace-module.js";
import { createTronDisplayExtension } from "./tron-display-extension.js";
import { admitToolDisplayProjection, displayReferences } from "./display-contract.js";
import { observeTrustedAgentBrowserResult } from "./browser-live-view-adapter.js";
import type { ToolReferences, ToolResultProjection } from "../kernel/projection/tool-result.js";
import { createTronNativeCaptureExtension } from "./tron-native-capture-extension.js";

type DisplayRuntime = { readonly disposed: boolean; toolResultReferences(): ToolReferences };

/** Native session facts, never a second catalog, deletion flag or runtime owner. */
interface DisplaySessions {
  acquire(sessionID: string): Promise<DisplayRuntime>;
  liveRuntime(sessionID: string): DisplayRuntime | undefined;
  isDeletingSession(sessionID: string): boolean;
  sessionIDsForStorageMaintenance(): Promise<ReadonlySet<string>>;
}

/** Display owns resource authorization and lifetime; the kernel owns native sessions
 * and the exact-leaf projection cut. Physical store writes keep their own durability lane. */
export class DisplayOwner {
  // Keep the diagnosing signal stable while ownership moves out of Registry.
  private readonly lane = new RequestSpanLane("registry.display-lane");

  constructor(
    readonly artifacts: DisplayArtifactStore,
    readonly liveViews: BrowserLiveViewRegistry | undefined,
    private readonly sessions: () => DisplaySessions,
  ) {}

  async maintainArtifacts(): Promise<void> {
    await this.artifacts.maintain(() => this.sessions().sessionIDsForStorageMaintenance());
  }

  async removeArtifacts(sessionID: string): Promise<void> {
    await this.lane.run(() => this.artifacts.removeSession(sessionID));
  }

  artifactIDs(runtime: DisplayRuntime): string[] {
    return [...runtime.toolResultReferences().artifacts];
  }

  referencesArtifact(runtime: DisplayRuntime, artifactID: string): boolean {
    return runtime.toolResultReferences().artifacts.includes(artifactID);
  }

  referencesLiveView(runtime: DisplayRuntime, viewId: string, generation: string): boolean {
    return runtime.toolResultReferences().liveViews.has(`${viewId}\0${generation}`);
  }

  async grantReferences(previousId: string, nextId: string, runtime: DisplayRuntime): Promise<void> {
    // Publish inherited owner links before identity commit; retention never grants
    // read authority by itself, and arbitrary transcript data cannot repair a link.
    for (const artifactID of this.artifactIDs(runtime)) {
      await this.artifacts.grant(artifactID, nextId, previousId);
    }
  }

  private async authorizeArtifact(sessionID: string, artifactID: string): Promise<boolean> {
    if (!this.artifacts.hasOwner(artifactID, sessionID)) return false;
    const runtime = await this.sessions().acquire(sessionID);
    return this.referencesArtifact(runtime, artifactID);
  }

  authorizeLiveView(sessionID: string, viewId: string, generation: string): boolean {
    const sessions = this.sessions();
    if (sessions.isDeletingSession(sessionID)) return false;
    const runtime = sessions.liveRuntime(sessionID);
    return runtime !== undefined && !runtime.disposed && this.referencesLiveView(runtime, viewId, generation);
  }

  async acquireArtifact(
    sessionID: string,
    artifactID: string,
    requestedRange?: BlobByteRange,
    signal?: AbortSignal,
  ) {
    return abortableRead(signal, () => this.lane.run(async () => {
      if (this.sessions().isDeletingSession(sessionID)
        || !await this.authorizeArtifact(sessionID, artifactID)) {
        throw new GatewayError("not_found", "Display artifact is unavailable");
      }
      signal?.throwIfAborted();
      return this.artifacts.acquire(artifactID, sessionID, requestedRange);
    }, signal), lease => lease.release());
  }
}

export function createDisplayModule(services: () => DisplayOwner): ModuleDescriptor {
  return {
    name: "tron-display", purpose: "Shows documents, images and live views in the app.",
    tools: ["display"], commands: [], dependsOn: [workspaceModule],
    start: host => {
      const workspace = host.contract(workspaceModule);
      const projection: ToolResultProjection = {
        display: admitToolDisplayProjection, references: displayReferences,
        initializeStorage: () => services().artifacts.initialize(),
        reconcile: (entries, sessionId) => services().artifacts.reconcileSession(sessionId,
          new Set(displayReferences(entries, sessionId).artifacts)),
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

export function createNativeCaptureModule(services: () => DisplayOwner): ModuleDescriptor {
  return {
    name: "tron-native-capture", purpose: "Captures live views from connected devices.",
    tools: ["native_capture"], commands: [],
    start: () => ({ extension: session => {
      const views = services().liveViews;
      return views ? createTronNativeCaptureExtension({ sessionId: session.sessionId, views }) : undefined;
    } }),
  };
}
