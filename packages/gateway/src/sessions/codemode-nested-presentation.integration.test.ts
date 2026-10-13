import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { BrowserLiveViewRegistry } from "../display/browser-live-view.js";
import type { NativeLiveClient, NativeLiveClientFactory } from "../display/native-live-view.js";
import { TrustService } from "../admin/trust-service.js";
import { RuntimeRegistry } from "./runtime-registry.js";
import { waitFor } from "../../test-support/wait-for.js";

const driver = vi.hoisted(() => ({ active: 0, maximumActive: 0, calls: 0 }));
vi.mock("../machine/cua-client.js", () => ({ CuaComputerClient: class {
  private pending = false;
  constructor(readonly binding: unknown) {}
  invalidateObservation() {}
  async invoke(tool: string) {
    if (this.pending) throw new Error("One computer operation may be pending");
    this.pending = true;
    driver.active += 1;
    driver.maximumActive = Math.max(driver.maximumActive, driver.active);
    driver.calls += 1;
    try {
      await new Promise((resolve) => setTimeout(resolve, 60));
      return { status: "completed", endpointGeneration: "fake-cua", output: { tool } };
    } finally { this.pending = false; driver.active -= 1; }
  }
  async close() {}
} }));

const registries: RuntimeRegistry[] = [];
const roots: string[] = [];
afterEach(async () => {
  await Promise.all(registries.splice(0).map((registry) => registry.dispose().catch(() => {})));
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
  driver.active = 0; driver.maximumActive = 0; driver.calls = 0;
});

describe("codemode nested presentation tools", () => {
  it("serializes nested computer driver calls and keeps native views session-owned under the codemode parent", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-codemode-nested-presentation-"));
    roots.push(root);
    const agentDir = join(root, "agent");
    const sessionDir = join(root, "sessions");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir, { recursive: true }), mkdir(sessionDir, { recursive: true }), mkdir(extensionDir, { recursive: true })]);
    const sdkUrl = import.meta.resolve("@earendil-works/pi-coding-agent");
    const browserReferenceUrl = new URL("../display/browser-tool-reference.ts", import.meta.url).href;
    const browserFixture = `import { sealBrowserToolReference } from ${JSON.stringify(browserReferenceUrl)};
export default function(pi) { pi.registerTool({ name: "agent_browser", label: "Fixture browser", description: "Returns a sealed live view receipt", parameters: { type: "object", properties: {} }, execute: async (id, _args, _signal, _update, ctx) => {
 const descriptor = { schema: "tron.browser-live-view.v1", viewId: "nested-browser-view", generation: "nested-browser-generation", title: "Fixture browser", fallbackText: "Closed" };
 return { content: [{ type: "text", text: "view ready" }], details: { browserLiveView: descriptor, tronBrowserReference: sealBrowserToolReference(ctx.sessionManager.getSessionId(), id, descriptor, true) } };
} }); }`;
    await Promise.all([
      writeFile(join(agentDir, "settings.json"), JSON.stringify({ sessionDir, defaultTools: ["+codemode"] })),
      writeFile(join(extensionDir, "codemode.ts"), `import { createCodemodeExtension } from ${JSON.stringify(sdkUrl)}; export default createCodemodeExtension({ mode: "on" });\n`),
      writeFile(join(extensionDir, "browser-fixture.ts"), browserFixture),
      writeFile(join(cwd, "display.txt"), "Nested codemode display artifact\n"),
    ]);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);

    const nativeBindings: Array<{ canonicalSessionID: string; runtimeLoadID: string }> = [];
    const nativeClient = {
      async catalog() { return [{ handle: "fixture-window", kind: "window", title: "Fixture window", applicationName: "Fixture", width: 800, height: 600 }]; },
      async close() { return {}; },
    } as unknown as NativeLiveClient;
    const views = new BrowserLiveViewRegistry(undefined, (async (binding) => {
      nativeBindings.push(binding);
      return nativeClient;
    }) as NativeLiveClientFactory);
    const faux = fauxProvider({ provider: "tron-codemode-nested-presentation", tokensPerSecond: 10_000 });
    const script = `const results = await Promise.allSettled([\n` +
      `  tools.computer({ tool: "help", arguments: {} }),\n` +
      `  tools.computer({ tool: "help", arguments: {} }),\n` +
      `  tools.display({ title: "Nested artifact", altText: "Nested artifact", source: { kind: "path", path: "display.txt" } }),\n` +
      `  tools.agent_browser({}),\n` +
      `  (async () => { const catalog = JSON.parse(text(await tools.native_capture({ action: "catalog" }))); const source = catalog.sources[0]; const selected = JSON.parse(text(await tools.native_capture({ action: "view", handle: source.handle }))); return await tools.display({ title: "Native view", altText: "Native view", source: selected.source }); })(),\n` +
      `]); return JSON.stringify(results.map((result) => result.status));`;
    faux.setResponses([
      fauxAssistantMessage([fauxToolCall("codemode", { code: script }, { id: "presentation-parent" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("done"),
    ]);
    const modelRuntimeFactory = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const codemodeDiagnostics: Array<Record<string, unknown>> = [];
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, modelRuntimeFactory, trust,
      browserLiveViews: views,
      codemodeDiagnostic: (diagnostic) => codemodeDiagnostics.push(diagnostic),
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    await registry.initializeBlobStorage();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const prompting = slot.prompt("Run nested presentation tools");
    await waitFor(() => slot.snapshot().toolExecutions.some((tool) =>
      tool.toolCallId === "presentation-parent" && (tool.nestedCalls?.calls.length ?? 0) >= 5), "the presentation parent's nested calls");
    const live = slot.snapshot();
    const liveParent = live.toolExecutions.find((tool) => tool.toolCallId === "presentation-parent");
    expect(live.toolExecutions.map((tool) => tool.toolCallId)).toEqual(["presentation-parent"]);
    expect(liveParent?.nestedCalls?.calls.map((call) => call.toolName)).toEqual(expect.arrayContaining([
      "computer", "display", "agent_browser", "native_capture",
    ]));
    await prompting;
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    const settled = slot.snapshot();
    expect(driver.maximumActive).toBe(1);
    expect(driver.calls).toBe(2);
    const parent = settled.transcript.find((item) => item.kind === "message" && item.role === "toolResult" && item.toolCallId === "presentation-parent");
    expect(parent).toMatchObject({ role: "toolResult", nestedCalls: { complete: true }, details: {
      tronNested: { complete: true, display: expect.arrayContaining([expect.objectContaining({ toolName: "display", display: expect.objectContaining({ artifact: expect.objectContaining({ id: expect.any(String) }) }) })]),
        browserLiveViews: [] },
    } });
    expect(parent?.nestedCalls?.calls.map((call) => call.toolName)).toEqual(expect.arrayContaining([
      "computer", "display", "agent_browser", "native_capture",
    ]));
    expect(codemodeDiagnostics).toHaveLength(1);
    expect(codemodeDiagnostics[0]).toMatchObject({
      sessionId: slot.id, outcome: "completed", durationMs: expect.any(Number),
      nestedCallCount: expect.any(Number), complete: true,
    });
    expect(codemodeDiagnostics[0].nestedCallCount).toBeGreaterThanOrEqual(5);
    expect(Object.keys(codemodeDiagnostics[0]).sort()).toEqual(["complete", "durationMs", "nestedCallCount", "outcome", "sessionId"]);
    expect(JSON.stringify(codemodeDiagnostics)).not.toContain(script);
    expect(nativeBindings.length).toBeGreaterThanOrEqual(1);
    expect(nativeBindings.every((binding) => binding.canonicalSessionID === slot.id)).toBe(true);
    await views.catalogNative(slot.id);
    const nativeDescriptor = await views.registerNative(slot.id, "fixture-window");
    const nativeRegistration = [...(views as unknown as { views: Map<string, { registration: { sessionId: string; viewId: string; generation: string } }> }).views.values()]
      .find((view) => view.registration.sessionId === slot.id);
    expect(nativeRegistration).toBeDefined();
    expect(nativeDescriptor.schema).toBe("tron.native-live-view.v1");
    expect(views.describe(slot.id, nativeRegistration!.registration.viewId, nativeRegistration!.registration.generation).schema)
      .toBe("tron.native-live-view.v1");
    expect(() => views.describe("different-session", nativeRegistration!.registration.viewId, nativeRegistration!.registration.generation)).toThrow();

    const retainedParent = JSON.parse(JSON.stringify(parent));
    const retainedLive = JSON.parse(JSON.stringify(live));
    await registry.dispose();
    registries.splice(registries.indexOf(registry), 1);
    const reopened = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, modelRuntimeFactory, trust,
      browserLiveViews: views,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(reopened);
    await reopened.initialize();
    await waitFor(() => (reopened as unknown as { sessionCatalog: { hasCompleteCut(): boolean } }).sessionCatalog.hasCompleteCut(), "the catalog's complete cut");
    await reopened.catalog("all");
    const reloadedSlot = await reopened.acquire(slot.id);
    const reloadedParent = reloadedSlot.snapshot().transcript.find((item) =>
      item.kind === "message" && item.role === "toolResult" && item.toolCallId === "presentation-parent");
    expect(reloadedSlot.snapshot().toolExecutions).toEqual([]);
    expect(reloadedParent).toMatchObject({ role: "toolResult", nestedCalls: { complete: true }, details: {
      tronNested: { complete: true, display: expect.arrayContaining([expect.objectContaining({ toolName: "display" })]),
        browserLiveViews: [] },
    } });
    expect(reloadedSlot.snapshot().transcript.filter((item) => item.kind === "message" && item.role === "toolResult"))
      .toHaveLength(1);

    const artifactPath = join(process.cwd(), "test-results", "pi-sdk-099-nested-presentation.json");
    await mkdir(dirname(artifactPath), { recursive: true });
    await writeFile(artifactPath, `${JSON.stringify({ live: retainedLive, parent: retainedParent, reloadedParent, codemodeDiagnostics, computer: { calls: driver.calls, maximumActive: driver.maximumActive }, nativeSession: nativeBindings[0]?.canonicalSessionID }, null, 2)}\n`);
  });
});
