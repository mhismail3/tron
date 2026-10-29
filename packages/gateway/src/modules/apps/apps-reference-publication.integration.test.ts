import { mkdir, mkdtemp, readFile, readdir, realpath, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall, type TranscriptContext } from "@earendil-works/pi-ai";
import { afterEach, expect, it } from "vitest";
import { createTestRegistry, displayOwnerOf } from "../../../test-support/gateway-registry.js";
import { admitBrowserToolReference, sealBrowserToolReference } from "../../display/browser-tool-reference.js";
import { BrowserLiveViewRegistry } from "../../display/browser-live-view.js";
import type { NativeLiveClient } from "../../display/native-live-view.js";
import { TrustService } from "../../kernel/resources/trust-service.js";
import { GatewayService, type GatewayServiceDependencies } from "../../transport/gateway-service.js";
import { CommandReceiptStore } from "../../transport/command-receipts.js";
import { waitFor } from "../../../test-support/wait-for.js";

const cleanup: Array<() => Promise<void>> = [];
afterEach(async () => { for (const close of cleanup.splice(0).reverse()) await close(); });
async function fixture(existingRoot?: string, views?: BrowserLiveViewRegistry, tools: string[] = []) {
  const root = existingRoot ?? await realpath(await mkdtemp(join(tmpdir(), "tron-app-display-"))), home = join(root, "tron"), agentDir = join(root, "agent");
  if (!existingRoot) cleanup.push(() => rm(root, { recursive: true, force: true })); await mkdir(agentDir, { recursive: true });
  await mkdir(join(home, "workspace/files/apps"), { recursive: true, mode: 0o700 });
  if (tools.length) await writeFile(join(agentDir, "settings.json"), JSON.stringify({ defaultTools: tools }));
  const trust = new TrustService(agentDir), faux = fauxProvider({ provider: "folder-display", tokensPerSecond: 100_000 });
  const registry = await createTestRegistry({ agentDir, tronHome: home, trust,
    ...(views ? { browserLiveViews: views } : {}), modelRuntimeFactory: async () => { const runtime = await ModelRuntime.create({ authPath: join(agentDir, "auth.json"), modelsPath: null, refreshOnCreate: false, allowModelNetwork: false }); runtime.registerNativeProvider(faux.provider); return runtime; },
    broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {} });
  cleanup.push(() => registry.dispose()); await registry.initialize(); await registry.initializeBlobStorage();
  const service = new GatewayService({ display: displayOwnerOf(registry), sessions: registry, modules: registry.moduleHost,
    config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome: home, agentDir }, receipts: new CommandReceiptStore(home), broadcast: () => {},
    globalProviderResources: { withStableSnapshot: async (run: () => Promise<unknown>) => run(), requestReload: () => {} },
  } as unknown as GatewayServiceDependencies);
  const rpc = (method: string, params: Record<string, unknown> = {}) => service.invoke({ id: "phone", identity: "device:fixture", isLocal: false } as never, method, params) as Promise<any>;
  const display = async (cwd: string, source: Record<string, string> | ((id: string) => Promise<Record<string, string>>), title = "Fixture", nested = false, browser = false) => {
    await trust.set(cwd, true);
    let result: any;
    const slot = await registry.create(cwd), model = faux.getModel(); await slot.setModel(model.provider, model.id);
    const selected = typeof source === "function" ? await source(slot.id) : source;
    faux.setResponses([fauxAssistantMessage([fauxToolCall(nested ? "codemode" : browser ? "agent_browser" : "display", nested ? { code: "return await tools.agent_browser({});" } : browser ? {} : { title, altText: "Fixture artifact", source: selected }, { id: "show-file" })], { stopReason: "toolUse" }),
      (context: TranscriptContext) => { result = context.messages.findLast(message => message.role === "toolResult"); return fauxAssistantMessage("Done"); }]);
    await slot.prompt("Display the requested fixture.");
    await waitFor(() => result && !slot.isBusy ? true : undefined, "display turn settles");
    return { result, slot };
  };
  return { root, home, registry, rpc, display, apps: join(home, "workspace/files/apps") };
}

it("persists a public URL app reference across canonical history reload without fetching or recreating membership", async () => {
  const f = await fixture(), cwd = join(f.root, "project"); await mkdir(cwd);
  const shown = await f.display(cwd, { kind: "public_url", url: "https://example.com/report", media: "webpage" });
  expect(shown.result.isError).not.toBe(true);
  const row = (await f.rpc("apps.catalog")).rows[0]; expect(row.kind).toBe("link");
  expect(shown.result.details.display.app).toEqual({ id: row.id, contentRevision: row.contentRevision });
  const consent = await f.rpc("apps.open", { id: row.id, expectedContentRevision: row.contentRevision });
  expect(consent.kind).toBe("permissionRequired"); expect(consent.permissions.network).toEqual(["https://example.com"]);
  await f.rpc("apps.permissions.grant", { commandId: "link-consent", token: consent.token });
  const opened = await f.rpc("apps.open", { id: row.id, expectedContentRevision: row.contentRevision });
  expect(opened.reference).toEqual({ kind: "url", media: "webpage", url: "https://example.com/report" });
  await f.registry.dispose(); const restarted = await fixture(f.root), slot = await restarted.registry.acquire(shown.slot.id);
  expect(slot.snapshot().transcript.some(item => item.kind === "message" && item.display?.app?.id === row.id)).toBe(true);
  expect((await restarted.rpc("apps.catalog")).rows.map((entry: any) => entry.id)).toEqual([row.id]);
});

it("keeps a long display title intact while materializing bounded app metadata", async () => {
 const f = await fixture(), cwd = join(f.root, "project"), title = "Report 🧭 ".repeat(12); await mkdir(cwd); await writeFile(join(cwd, "note.txt"), "note");
 const shown = await f.display(cwd, { kind: "path", path: "note.txt" }, title);
 expect(shown.result.isError).not.toBe(true); expect(shown.result.details.display.title).toBe(title);
 const row = (await f.rpc("apps.catalog")).rows[0]; expect(Buffer.byteLength(row.title)).toBeLessThanOrEqual(80);
});
it("copies a displayed app.json as payload rather than replacing generated metadata", async () => {
 const f = await fixture(), cwd = join(f.root, "project"), content = JSON.stringify({ arbitrary: "payload" }); await mkdir(cwd); await writeFile(join(cwd, "app.json"), content);
 const shown = await f.display(cwd, { kind: "path", path: "app.json" }); expect(shown.result.isError).not.toBe(true);
 const row = (await f.rpc("apps.catalog")).rows[0], folder = join(f.apps, row.id), manifest = JSON.parse(await readFile(join(folder, "app.json"), "utf8"));
 expect(manifest.entry).not.toBe("app.json"); expect(await readFile(join(folder, manifest.entry), "utf8")).toBe(content);
});
it("materializes a self-contained HTML display as an inert document without executable access", async () => {
 const f = await fixture(), cwd = join(f.root, "project"), content = "<!doctype html><html><body><p>Report</p></body></html>"; await mkdir(cwd); await writeFile(join(cwd, "report.html"), content);
 const shown = await f.display(cwd, { kind: "path", path: "report.html" }); expect(shown.result.isError).not.toBe(true);
 const row = (await f.rpc("apps.catalog")).rows[0], opened = await f.rpc("apps.open", { id: row.id, expectedContentRevision: row.contentRevision });
 expect(opened.kind).toBe("artifact"); expect(opened.artifact.media).toBe("html");
});

it("opens only the original active live owner and never restarts an ended reference", async () => {
 let starts = 0;
 const client = { catalog: async () => [{ handle: "returned-handle", kind: "window", title: "Fixture", applicationName: "Fixture", width: 800, height: 600 }], close: async () => ({}), start: async () => { starts++; throw new Error("Viewing was not requested"); } } as unknown as NativeLiveClient;
 const views = new BrowserLiveViewRegistry(undefined, async () => client); cleanup.push(async () => { views.dispose(); await views.joinRetirements(); });
 const f = await fixture(undefined, views), cwd = join(f.root, "project"); await mkdir(cwd);
 const shown = await f.display(cwd, async sessionId => {
   const catalog = await views.catalogNative(sessionId), view = await views.registerNative(sessionId, catalog[0]!.handle);
   return { kind: "native_live", viewId: view.viewId, generation: view.generation };
 });
 expect(shown.result.isError).not.toBe(true);
 const row = (await f.rpc("apps.catalog")).rows[0], opened = await f.rpc("apps.open", { id: row.id, expectedContentRevision: row.contentRevision });
 expect(opened.reference).toMatchObject({ kind: "live", sessionId: shown.slot.id, liveView: { schema: "tron.native-live-view.v1" } });
 await views.stopNative(shown.slot.id);
 await expect(f.rpc("apps.open", { id: row.id, expectedContentRevision: row.contentRevision })).rejects.toMatchObject({ code: "not_found" });
 expect(starts).toBe(0); expect((await f.rpc("apps.catalog")).rows).toHaveLength(1);
});

it("keeps a displayed Swift source snapshot inert rather than promoting it to an executable app", async () => {
 const f = await fixture(), cwd = join(f.root, "project"); await mkdir(cwd);
 await writeFile(join(cwd, "Example.swift"), 'import SwiftUI\nText("Read only")');
 await f.display(cwd, { kind: "path", path: "Example.swift" });
 const row = (await f.rpc("apps.catalog")).rows[0]; expect(row.kind).toBe("document");
 const opened = await f.rpc("apps.open", { id: row.id, expectedContentRevision: row.contentRevision });
 expect(opened.kind).toBe("artifact");
 expect(await readFile(join(f.apps, row.id, opened.artifact.entry), "utf8")).toBe('import SwiftUI\nText("Read only")');
});

it.each(["Large.swift", "entry.link.json", "entry.live.json"])("copies ordinary displayed %s without applying executable or reference-descriptor semantics", async name => {
 const f = await fixture(), cwd = join(f.root, "project"); await mkdir(cwd);
 const text = name.endsWith(".swift") ? "//" + "x".repeat(399_998) : '{"ordinary":"JSON payload"}';
 await writeFile(join(cwd, name), text);
 const shown = await f.display(cwd, { kind: "path", path: name }); expect(shown.result.isError, JSON.stringify(shown.result)).not.toBe(true);
 const row = (await f.rpc("apps.catalog")).rows[0]; expect(row.kind).toBe("document");
 const opened = await f.rpc("apps.open", { id: row.id, expectedContentRevision: row.contentRevision }); expect(opened.kind).toBe("artifact");
 expect(await readFile(join(f.apps, row.id, opened.artifact.entry), "utf8")).toBe(text);
});

it("keeps the materialized app binding in parent-bound nested browser receipts and refuses tampering", async () => {
 const f = await fixture(undefined, undefined, ["+codemode"]), cwd = join(f.root, "project"), extensions = join(cwd, ".pi/extensions"); await mkdir(extensions, { recursive: true });
 const sdk = import.meta.resolve("@earendil-works/pi-coding-agent"), receiptFile = join(cwd, "receipt.json");
 await writeFile(join(extensions, "codemode.ts"), `import { createCodemodeExtension } from ${JSON.stringify(sdk)}; export default createCodemodeExtension({ mode: "on" });`);
 await writeFile(join(extensions, "browser.ts"), `import { readFile } from "node:fs/promises"; export default function(pi) { pi.registerTool({name: "agent_browser", label:"Fixture browser", description:"Returns an admitted opaque reference", parameters:{type:"object",properties:{}}, execute: async() => ({content:[{type:"text",text:"view"}],details:JSON.parse(await readFile(${JSON.stringify(receiptFile)}, "utf8"))}) }); }`);
 // Seed the provider's actual wire receipt outside the project's independent module loader.
 const shown = await f.display(cwd, async sessionID => {
   const descriptor = { schema: "tron.browser-live-view.v1" as const, viewId: "opaque-view", generation: "opaque-generation", title: "Fixture browser", fallbackText: "Ended" };
   await writeFile(receiptFile, JSON.stringify({ tronBrowserReference: sealBrowserToolReference(sessionID, "show-file/1", descriptor, true) }));
   return {};
 }, "Nested", true); expect(shown.result.isError, JSON.stringify(shown.result)).not.toBe(true);
 expect(shown.result.details.tronNested, JSON.stringify(shown.result)).toBeDefined();
 const row = (await f.rpc("apps.catalog")).rows[0], receipt = shown.result.details.tronNested.browserLiveViews[0].receipt;
 const reference = admitBrowserToolReference("agent_browser", "show-file", { tronBrowserReference: receipt }, shown.slot.id);
 expect(reference?.app).toEqual({ id: row.id, contentRevision: row.contentRevision });
 const changed = { ...receipt, app: { ...receipt.app, id: "different" } };
 expect(admitBrowserToolReference("agent_browser", "show-file", { tronBrowserReference: changed }, shown.slot.id)).toBeUndefined();
});

it("retains a browser app link across a real process restart without retaining live authority", async () => {
 const f = await fixture(undefined, undefined, ["+agent_browser"]), cwd = join(f.root, "project"), extensions = join(cwd, ".pi/extensions");
 await mkdir(extensions, { recursive: true }); const receiptFile = join(cwd, "receipt.json");
 await writeFile(join(extensions, "browser.ts"), `import { readFile } from "node:fs/promises"; export default function(pi) { pi.registerTool({name:"agent_browser",label:"Fixture browser",description:"Returns an opaque reference",parameters:{type:"object",properties:{}},execute:async()=>({content:[{type:"text",text:"view"}],details:JSON.parse(await readFile(${JSON.stringify(receiptFile)},"utf8"))})}); }`);
 const shown = await f.display(cwd, async sessionID => {
   const descriptor = { schema: "tron.browser-live-view.v1" as const, viewId: "old-view", generation: "old-generation", title: "Retained browser", fallbackText: "Ended" };
   await writeFile(receiptFile, JSON.stringify({ tronBrowserReference: sealBrowserToolReference(sessionID, "show-file", descriptor, true) })); return {};
 }, "Browser", false, true);
 expect(shown.result.isError, JSON.stringify(shown.result)).not.toBe(true);
 const row = (await f.rpc("apps.catalog")).rows[0]; expect(row).toBeDefined(); await f.registry.dispose();
 await writeFile(join(f.root, "package.json"), JSON.stringify({ type: "module" }));
 const child = join(f.root, "cold.ts"), registryURL = new URL("../../../test-support/gateway-registry.ts", import.meta.url).href;
 await writeFile(child, `import {createTestRegistry} from ${JSON.stringify(registryURL)};
import {ModelRuntime} from ${JSON.stringify(import.meta.resolve("@earendil-works/pi-coding-agent"))};
import {fauxProvider} from ${JSON.stringify(import.meta.resolve("@earendil-works/pi-ai"))};
import {join} from "node:path";
import {TrustService} from ${JSON.stringify(new URL("../../kernel/resources/trust-service.ts", import.meta.url).href)};
const agentDir=${JSON.stringify(join(f.root, "agent"))}; const faux=fauxProvider({provider:"folder-display"});
const registry=await createTestRegistry({agentDir,trust:new TrustService(agentDir),tronHome:${JSON.stringify(f.home)},modelRuntimeFactory:async()=>{const runtime=await ModelRuntime.create({authPath:join(agentDir,"auth.json"),modelsPath:null,refreshOnCreate:false,allowModelNetwork:false});runtime.registerNativeProvider(faux.provider);return runtime;},broadcast:()=>{},sessionSummaryChanged:()=>{},sessionListChanged:()=>{}});
try {await registry.initialize();await registry.initializeBlobStorage();await registry.catalog("all");const slot=await registry.acquire(${JSON.stringify(shown.slot.id)});const message=slot.snapshot().transcript.find(x=>x.kind==="message"&&x.role==="toolResult"&&x.toolCallId==="show-file");const policy=registry.moduleHost.policy("toolResultProjection")();console.log(JSON.stringify({app:message.details.tronBrowserReference.app,display:policy.display("agent_browser",message.details,"show-file",slot.id),liveViews:[...policy.references(slot.searchCanonicalCut().entries,slot.id).liveViews]}));} finally {await registry.dispose();}`);
 const { stdout } = await promisify(execFile)(process.execPath, ["--experimental-transform-types", "--import", new URL("../../../test-support/apps-crash-preload.mjs", import.meta.url).href, child], { cwd: process.cwd() });
 const cold = JSON.parse(stdout.trim());
 expect(cold.app).toEqual({ id: row.id, contentRevision: row.contentRevision });
 // Stored metadata is not a live projection. The paired inert UI is a separate consumer.
 expect(cold.display).toBeUndefined();
 expect(cold.liveViews).toEqual([]);
 expect((await readdir(f.apps))).toContain(row.id);
});
