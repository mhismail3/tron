import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it } from "vitest";
import { once } from "node:events";
import { WebSocketServer } from "ws";
import { waitFor } from "../../../test-support/wait-for.js";
import { ModuleHost } from "../host/module-host.js";
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
  try {
    host = await ModuleHost.start([workspaceModule, createDisplayModule(() => ({ artifacts, liveViews: views }))], {
      tronHome: home, log: { log: () => {} },
    }, []);
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
    expect(policy.observeBrowserResult({ ...input, owner: { ...input.owner, source: "untrusted" } })).toBe(result);
    const observed = policy.observeBrowserResult(input) as { content: unknown[]; details: Record<string, unknown> };
    const reference = admitBrowserToolReference("agent_browser", "call", observed.details, sessionId)!;
    expect(reference).toBeDefined();
    expect(views.describe(sessionId, reference.descriptor.viewId, reference.descriptor.generation)).toEqual(reference.descriptor);
    expect(observed.content).toHaveLength(2);
    expect(policy.display("agent_browser", observed.details, "call", sessionId)).toMatchObject({ kind: "browser_live", liveView: reference.descriptor });
    expect(policy.display("agent_browser", observed.details, "other-call", sessionId)).toBeUndefined();
    expect(policy.display("agent_browser", observed.details, "call", "other-session")).toBeUndefined();
    views.beginSessionLoad(sessionId);
    expect(host.policy("toolResultProjection")!().observeBrowserResult(input)).toBe(result);
    expect(() => views.describe(sessionId, reference.descriptor.viewId, reference.descriptor.generation)).toThrow();
  } finally {
    try { await host?.stop(); } finally {
      views.dispose();
      await rm(home, { recursive: true, force: true });
    }
  }
});

it("K3.toolResultProjection binds Chrome's consent endpoint to a retained browser target and refuses a successor", async () => {
  const home = await mkdtemp(join(tmpdir(), "tron-chrome-attach-"));
  const server = new WebSocketServer({ host: "127.0.0.1", port: 0, path: "/devtools/browser" });
  await once(server, "listening");
  const address = server.address();
  if (typeof address !== "object" || address === null) throw new Error("Fixture did not listen");
  const endpoint = `ws://127.0.0.1:${address.port}/devtools/browser`;
  let target = "original-browser-target";
  let responds = true;
  const commands: string[] = [];
  server.on("connection", socket => socket.on("message", raw => {
    const command = JSON.parse(String(raw));
    commands.push(command.method);
    if (responds && command.method === "Target.getTargetInfo") socket.send(JSON.stringify({ id: command.id,
      ...(command.params?.targetId && command.params.targetId !== target
        ? { error: { code: -32602, message: "No such target" } }
        : { result: { targetInfo: { type: "browser", targetId: target } } }) }));
  }));
  const views = new BrowserLiveViewRegistry();
  let host: ModuleHost | undefined;
  try {
    host = await ModuleHost.start([workspaceModule, createDisplayModule(() => ({ artifacts: new DisplayArtifactStore(home), liveViews: views }))], {
      tronHome: home, log: { log: () => {} },
    }, []);
    const sessionId = "chrome-session";
    const loadToken = views.beginSessionLoad(sessionId);
    const result = { content: [{ type: "text", text: "Attached" }], details: {
      agentBrowserStarted: true, command: "get", subcommand: "cdp-url", exitCode: 0, resultCategory: "success",
      sessionName: "chrome", data: { cdpUrl: endpoint },
    } };
    const policy = host.policy("toolResultProjection")!();
    const input = { owner: { id: "browser", title: "Browser", source: "git:github.com/fitchmultz/pi-agent-browser-native" },
      toolName: "agent_browser", toolCallId: "attach", result, sessionId, runtimeGeneration: "runtime", loadToken };
    const observed = await policy.observeBrowserResult(input) as { details: Record<string, unknown> };
    const reference = admitBrowserToolReference("agent_browser", "attach", observed.details, sessionId);
    expect(reference).toBeDefined();
    const descriptor = reference!.descriptor;
    expect(views.describe(sessionId, descriptor.viewId, descriptor.generation)).toEqual(descriptor);
    expect(commands).toEqual(["Target.getTargetInfo"]);
    expect(server.clients.size).toBe(1);
    const reused = await policy.observeBrowserResult({ ...input, toolCallId: "reuse" }) as { details: Record<string, unknown> };
    expect(admitBrowserToolReference("agent_browser", "reuse", reused.details, sessionId)?.descriptor).toEqual(descriptor);
    expect(server.clients.size).toBe(1);
    for (const socket of server.clients) socket.close();
    await waitFor(() => server.clients.size === 0, "original browser disconnect");
    await waitFor(() => {
      try { views.describe(sessionId, descriptor.viewId, descriptor.generation); return false; } catch { return true; }
    }, "the original view's terminal retirement");
    target = "successor-browser-target";
    expect(() => views.open(sessionId, descriptor.viewId, descriptor.generation, "late-viewer")).toThrow("no longer available");
    const successor = await policy.observeBrowserResult({ ...input, toolCallId: "successor" }) as { details: Record<string, unknown> };
    const next = admitBrowserToolReference("agent_browser", "successor", successor.details, sessionId)!.descriptor;
    expect(next.generation).not.toBe(descriptor.generation);
    expect(next.viewId).not.toBe(descriptor.viewId);
    target = "unrelated-browser-target";
    views.open(sessionId, next.viewId, next.generation, "mismatched-browser-viewer");
    await waitFor(() => {
      try { views.describe(sessionId, next.viewId, next.generation); return false; } catch { return true; }
    }, "capture rejects a different browser before inspecting any page");
    expect(commands.every(method => method === "Target.getTargetInfo")).toBe(true);
    views.beginSessionLoad(sessionId);
    await waitFor(() => server.clients.size === 0, "load retirement closes the browser identity socket");
    expect(await policy.observeBrowserResult(input)).toBe(result);
    responds = false;
    const absent = await policy.observeBrowserResult({ ...input, loadToken: views.beginSessionLoad(sessionId) }) as { details: Record<string, unknown> };
    expect(absent.details.browserLiveViewError).toMatch(/^browser_consent_required:/);
    expect(admitBrowserToolReference("agent_browser", "attach", absent.details, sessionId)).toBeUndefined();
    await waitFor(() => server.clients.size === 0, "a refused browser identity connection closes");
    const loading = policy.observeBrowserResult({ ...input, loadToken: views.beginSessionLoad(sessionId) });
    await waitFor(() => server.clients.size === 1, "the pending identity handshake");
    views.beginSessionLoad(sessionId);
    const cancelled = await loading as { details: Record<string, unknown> };
    expect(cancelled).toBe(result);
    expect(cancelled.details.browserLiveView).toBeUndefined();
    expect(admitBrowserToolReference("agent_browser", "attach", cancelled.details, sessionId)).toBeUndefined();
    await waitFor(() => server.clients.size === 0, "load retirement cancels the pending browser handshake");
  } finally {
    await host?.stop();
    views.dispose();
    for (const socket of server.clients) socket.terminate();
    await new Promise<void>(resolve => server.close(() => resolve()));
    await rm(home, { recursive: true, force: true });
  }
});

it("K3.toolResultProjection leaves browser results unchanged when the optional live-view owner is absent", async () => {
  const home = await mkdtemp(join(tmpdir(), "tron-tool-result-port-"));
  const artifacts = new DisplayArtifactStore(home);
  let host: ModuleHost | undefined;
  try {
    host = await ModuleHost.start([workspaceModule, createDisplayModule(() => ({ artifacts, liveViews: undefined }))], {
      tronHome: home, log: { log: () => {} },
    }, []);
    const result = { content: [{ type: "text", text: "No browser view" }] };
    expect(host.policy("toolResultProjection")!().observeBrowserResult({
      owner: { id: "browser", title: "Browser", source: "git:github.com/fitchmultz/pi-agent-browser-native" },
      toolName: "agent_browser", toolCallId: "call", result, sessionId: "session", runtimeGeneration: "runtime", loadToken: "retired",
    })).toBe(result);
  } finally {
    try { await host?.stop(); } finally {
      await rm(home, { recursive: true, force: true });
    }
  }
});
