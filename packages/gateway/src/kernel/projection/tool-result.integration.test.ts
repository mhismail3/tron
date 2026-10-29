import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, inject, it } from "vitest";
import { directoryPublisher } from "../../machine/directory-publication.js";
import type { ResourceRoot } from "../resources/resource-root.js";
import { ModuleHost } from "../host/module-host.js";
import { createAppsModule } from "../../modules/apps/module.js";
import { workspaceModule } from "../../workspace/workspace-module.js";
import { createDisplayModule } from "../../display/display-modules.js";
import { DisplayArtifactStore } from "../../display/display-artifact-store.js";
import { BrowserLiveViewRegistry } from "../../display/browser-live-view.js";
import { admitBrowserToolReference } from "../../display/browser-tool-reference.js";

it("K3.toolResultProjection keeps provenance, exact call/session receipts and load retirement at the real module boundary", async () => {
  const home = await mkdtemp(join(tmpdir(), "tron-tool-result-port-"));
  const views = new BrowserLiveViewRegistry();
  const artifacts = new DisplayArtifactStore(home);
  let host: ModuleHost | undefined;
  let workspace: ResourceRoot | undefined;
  try {
    const apps = createAppsModule(directoryPublisher(inject("nativePublicationBinary")));
    host = await ModuleHost.start([workspaceModule, apps, createDisplayModule(() => ({ artifacts, liveViews: views }), apps)], {
      tronHome: home, log: { log: () => {} },
    }, []);
    workspace = host.policy("resourceRoot")!();
    await workspace.initialize();
    const sessionId = "session";
    const loadToken = views.beginSessionLoad(sessionId);
    const result = {
      content: [{ type: "text", text: "Browser ready" }],
      details: { agentBrowserStarted: true, command: "get", subcommand: "cdp-url", exitCode: 0, resultCategory: "success",
        sessionName: "browser", data: { cdpUrl: "ws://127.0.0.1:43127/devtools/browser/12345678-1234-1234-1234-123456789abc" } },
    };
    const input = {
      owner: { id: "browser-owner", title: "Browser", source: "git:github.com/fitchmultz/pi-agent-browser-native" },
      toolName: "agent_browser", toolCallId: "call", result, sessionId, runtimeGeneration: "runtime", loadToken,
    };
    const policy = host.policy("toolResultProjection")!();
    expect(await policy.observeBrowserResult({ ...input, owner: { ...input.owner, source: "untrusted" } })).toBe(result);
    const observed = await policy.observeBrowserResult(input) as { content: unknown[]; details: Record<string, unknown> };
    const reference = admitBrowserToolReference("agent_browser", "call", observed.details, sessionId)!;
    expect(reference).toBeDefined();
    expect(views.describe(sessionId, reference.descriptor.viewId, reference.descriptor.generation)).toEqual(reference.descriptor);
    expect(observed.content).toHaveLength(2);
    expect(policy.display("agent_browser", observed.details, "call", sessionId)).toMatchObject({ kind: "browser_live", liveView: reference.descriptor });
    expect(policy.display("agent_browser", observed.details, "other-call", sessionId)).toBeUndefined();
    expect(policy.display("agent_browser", observed.details, "call", "other-session")).toBeUndefined();
    views.beginSessionLoad(sessionId);
    expect(await host.policy("toolResultProjection")!().observeBrowserResult(input)).toBe(result);
    expect(() => views.describe(sessionId, reference.descriptor.viewId, reference.descriptor.generation)).toThrow();
  } finally {
    try { await host?.stop(); } finally {
      try { await workspace?.dispose(); } finally {
        views.dispose();
        await rm(home, { recursive: true, force: true });
      }
    }
  }
});

it("K3.toolResultProjection leaves browser results unchanged when the optional live-view owner is absent", async () => {
  const home = await mkdtemp(join(tmpdir(), "tron-tool-result-port-"));
  const artifacts = new DisplayArtifactStore(home);
  let host: ModuleHost | undefined;
  let workspace: ResourceRoot | undefined;
  try {
    const apps = createAppsModule(directoryPublisher(inject("nativePublicationBinary")));
    host = await ModuleHost.start([workspaceModule, apps, createDisplayModule(() => ({ artifacts, liveViews: undefined }), apps)], {
      tronHome: home, log: { log: () => {} },
    }, []);
    workspace = host.policy("resourceRoot")!();
    await workspace.initialize();
    const result = { content: [{ type: "text", text: "No browser view" }] };
    expect(await host.policy("toolResultProjection")!().observeBrowserResult({
      owner: { id: "browser", title: "Browser", source: "git:github.com/fitchmultz/pi-agent-browser-native" },
      toolName: "agent_browser", toolCallId: "call", result, sessionId: "session", runtimeGeneration: "runtime", loadToken: "retired",
    })).toBe(result);
  } finally {
    try { await host?.stop(); } finally {
      try { await workspace?.dispose(); } finally {
        await rm(home, { recursive: true, force: true });
      }
    }
  }
});
