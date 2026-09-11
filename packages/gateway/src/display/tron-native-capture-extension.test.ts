import { afterEach, describe, expect, it, vi } from "vitest";
import { BrowserLiveViewRegistry } from "./browser-live-view.js";
import { createTronNativeCaptureExtension } from "./tron-native-capture-extension.js";
import { createTronDisplayExtension } from "./tron-display-extension.js";
import { admitDisplayProjection } from "./display-contract.js";

const registries: BrowserLiveViewRegistry[] = [];
afterEach(async () => { for (const views of registries.splice(0)) { views.dispose(); await views.joinRetirements(); } });
function fixture() {
  const client = { catalog: async () => [{ handle: "exact-window", kind: "window", title: "Fixture", applicationName: "Fixture", width: 1000, height: 800 }],
    start: vi.fn(async () => {}), pull: vi.fn(async () => undefined), suspend: vi.fn(async () => ({ status: "joined" as const })), close: vi.fn(async () => ({ status: "joined" as const })) };
  const views = new BrowserLiveViewRegistry(undefined, async () => client); registries.push(views); views.beginSessionLoad("session");
  const tools: Record<string, any> = {};
  const api = { registerTool(tool: any) { tools[tool.name] = tool; } } as any;
  createTronNativeCaptureExtension({ sessionId: () => "session", views })(api);
  createTronDisplayExtension({ sessionId: () => "session", cwd: () => "/fixture", artifacts: {} as never, liveViews: views })(api);
  return { tools, views, client };
}

describe("native selection → canonical display", () => {
  it("exposes only an opaque source until display creates a native projection, without starting capture", async () => {
    const f = fixture();
    await f.tools.native_capture.execute("catalog", { action: "catalog" });
    const chosen = await f.tools.native_capture.execute("select", { action: "view", handle: "exact-window" });
    expect(chosen.details.display).toBeUndefined(); expect(chosen.details.source.kind).toBe("native_live");
    const shown = await f.tools.display.execute("display", { title: "Mac window", altText: "Fixture window", source: chosen.details.source });
    expect(shown.details.display.kind).toBe("native_live");
    expect(shown.details.display.presentation.requestedSurface).toBe("floating");
    expect(admitDisplayProjection("display", shown.details)).toEqual(shown.details.display);
    expect(admitDisplayProjection("native_capture", shown.details)).toBeUndefined();
    expect(admitDisplayProjection("display", { ...shown.details, display: { ...shown.details.display, kind: "browser_live" } })).toBeUndefined();
    expect(f.client.start).not.toHaveBeenCalled(); expect(f.client.pull).not.toHaveBeenCalled();
    await expect(f.tools.display.execute("wrong-kind", { title: "Wrong", altText: "Wrong producer", source: { ...chosen.details.source, kind: "browser_live" } })).rejects.toThrow(/producer kind/);
    await f.tools.native_capture.execute("stop", { action: "stop" });
    await expect(f.tools.display.execute("ended", { title: "Ended", altText: "Ended", source: chosen.details.source })).rejects.toThrow(/no longer available/);
  });
  it("rejects invented handles and handles outside their canonical session/load", async () => {
    const f = fixture();
    await expect(f.tools.native_capture.execute("early", { action: "view", handle: "raw-window-id" })).rejects.toThrow(/List native windows/);
    await f.tools.native_capture.execute("catalog", { action: "catalog" });
    await expect(f.tools.native_capture.execute("invented", { action: "view", handle: "raw-window-id" })).rejects.toThrow(/unavailable/);
    f.views.beginSessionLoad("session");
    await expect(f.tools.native_capture.execute("old", { action: "view", handle: "exact-window" })).rejects.toThrow(/List native windows/);
    expect(f.client.start).not.toHaveBeenCalled();
  });
});
