import { createTestRegistry } from "../../../test-support/gateway-registry.js";
import { chmod, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { execFile, execFileSync, spawn } from "node:child_process";
import WebSocket from "ws";
import { promisify } from "node:util";
import { once } from "node:events";
import { createServer } from "node:http";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
import { dirname, join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { TrustService } from "../../kernel/resources/trust-service.js";
import { admitBrowserToolReference } from "../../display/browser-tool-reference.js";
import { BrowserLiveViewRegistry } from "../../display/browser-live-view.js";
import { RuntimeRegistry } from "../../kernel/session/runtime-registry.js";
import { awaitsWithin, HOOK_HANG_BOUND_MS, waitFor } from "../../../test-support/wait-for.js";

const require = createRequire(import.meta.url);
const installedFork = dirname(require.resolve("pi-agent-browser-native/package.json"));
const engineRoot = dirname(require.resolve("agent-browser/package.json", { paths: [installedFork] }));
const executable = join(engineRoot, "bin", "agent-browser.js");
const installedForkSource = "git:github.com/fitchmultz/pi-agent-browser-native@6346982c0fec9e00b9f3ef6997cfb2d6f6893c6d";
const registries: RuntimeRegistry[] = [];
const roots: string[] = [];
const browserCleanups: Array<() => void> = [];
const oldPath = process.env.PATH;

afterEach(async () => {
  const failures: unknown[] = [];
  try {
    for (const registry of registries.splice(0)) {
      try { await registry.dispose(); } catch (error) { failures.push(error); }
    }
    for (const cleanup of browserCleanups.splice(0)) {
      try { cleanup(); } catch (error) { failures.push(error); }
    }
    if (!failures.length) {
      for (const root of roots.splice(0)) {
        try { await rm(root, { recursive: true, force: true }); } catch (error) { failures.push(error); }
      }
    }
  } finally {
    if (oldPath === undefined) delete process.env.PATH;
    else process.env.PATH = oldPath;
  }
  if (failures.length) throw new AggregateError(failures, "Browser receipt fixture cleanup failed");
});

function toolResult(slot: Awaited<ReturnType<RuntimeRegistry["create"]>>, toolCallId: string): any {
  return slot.snapshot().transcript.find((item) =>
    item.kind === "message" && item.role === "toolResult" && item.toolCallId === toolCallId);
}

function closeNative(agentDir: string, sockets: string | undefined): void {
  if (!sockets) return;
  let names: string[];
  try { names = readdirSync(sockets); } catch (error) {
    if (error instanceof Error && "code" in error && error.code === "ENOENT") return;
    throw error;
  }
  for (const name of names.filter(name => name.endsWith(".pid"))) {
    execFileSync(executable, ["--session", name.slice(0,-4), "close"], {
      env: {...process.env, HOME:join(agentDir,"browser","home"), AGENT_BROWSER_SOCKET_DIR:sockets, PI_AGENT_BROWSER_SOCKET_DIR:sockets},
      timeout:15000, stdio:"pipe",
    });
  }
}

describe("packaged agent-browser receipts", () => {
  describe("packaged owned-browser qualification", { concurrent: false }, () => {
    let root: string, agentDir: string, cwd: string, control: string, base: string, endpoint: string;
    let sockets: string;
    let registry: RuntimeRegistry, slot: Awaited<ReturnType<RuntimeRegistry["create"]>>;
    let cli: (...args: string[]) => Promise<any>, step: (id:string,args:string[],fresh?:boolean)=>Promise<any>;
    let call: (id:string,name:string,params:Record<string,unknown>)=>Promise<any>;
    let createRegistry: ()=>Promise<RuntimeRegistry>;
    let model: ReturnType<ReturnType<typeof fauxProvider>["getModel"]>;
    const cookie=randomUUID(), receipts:string[]=[], timing:number[]=[];
    let site: ReturnType<typeof createServer>;
    beforeAll(async () => {
    root = await mkdtemp("/tmp/ob-");
    agentDir = join(root,"agent"); cwd = join(root,"workspace"); control = join(root,"control");
    await Promise.all([mkdir(agentDir),mkdir(cwd),mkdir(control)]);
    cli = async (...args: string[]) => {
      const result=await promisify(execFile)(executable, ["--json","--session","control",...args], {
        env:{...process.env,AGENT_BROWSER_SOCKET_DIR:control,PI_AGENT_BROWSER_SOCKET_DIR:control},timeout:15000,
      });
      const value=JSON.parse(result.stdout);
      expect(value.success).toBe(true);
      return value.data;
    };
    site=createServer((request,response)=>{
      const url=new URL(request.url!, "http://127.0.0.1");
      if(url.pathname==="/login"){response.setHeader("Set-Cookie",`fixture=${cookie}; HttpOnly; Path=/`);response.end("<title>login granted</title>");return;}
      if(url.pathname!=="/protected"){response.writeHead(404);response.end();return;}
      if(request.headers.cookie!==`fixture=${cookie}`){response.writeHead(401);response.end("<title>NOT AUTHENTICATED</title>");return;}
      const nonce=url.searchParams.get("nonce")!; receipts.push(nonce);response.end(`<title>AUTH ${nonce}</title>`);
    });
    site.listen(0,"127.0.0.1"); await once(site,"listening");
    const address=site.address(); if(!address || typeof address==="string")throw new Error("No fixture address");
    base=`http://127.0.0.1:${address.port}`;
    const faux=fauxProvider({provider:"tron-owned-browser",tokensPerSecond:10000});
    await writeFile(join(agentDir,"settings.json"),JSON.stringify({defaultTools:["+agent_browser","+agent_browser_electron"]}));
    const trust=new TrustService(agentDir);await trust.set(cwd,true);
    createRegistry=async()=>{
      const registry=await createTestRegistry({agentDir,tronHome:join(root,"tron"),trust,idleRuntimeMs:60000,
        modelRuntimeFactory:async()=>{const runtime=await ModelRuntime.create({modelsPath:null,refreshOnCreate:false});runtime.registerNativeProvider(faux.provider);return runtime;},
        broadcast:()=>{},sessionSummaryChanged:()=>{},sessionListChanged:()=>{}});
      await registry.initialize();await registry.initializeBlobStorage();return registry;
    };
    registry=await createRegistry();
    slot=await registry.create(cwd);model=faux.getModel();await slot.setModel(model.provider,model.id);
    call=async(id,name,params)=>{
      faux.setResponses([fauxAssistantMessage([fauxToolCall(name,params,{id})],{stopReason:"toolUse"}),fauxAssistantMessage("done")]);
      await slot.prompt("Operate only on the isolated fixture");
      await waitFor(()=>!slot.isBusy && toolResult(slot,id)!==undefined, id);
      return toolResult(slot,id);
    };
    step=(id,args,fresh=false)=>call(id,"agent_browser",{args,...(fresh?{sessionMode:"fresh"}:{})});
      await cli("--profile",join(root,"unrecorded-profile"),"open","about:blank");
      const unowned=(await cli("get","cdp-url")).cdpUrl;
      const refusal=await step("unowned",["connect",unowned],true);
      expect(refusal).toMatchObject({isError:true});
      expect(JSON.stringify(refusal)).toContain("recorded Tron-owned launch");
      expect(refusal.details.agentBrowserStarted).not.toBe(true);
      expect((await cli("get","cdp-url")).cdpUrl).toBe(unowned);
      expect(await step("login",["open",base+"/login"])).toMatchObject({isError:false});
      const opened=await step("endpoint",["get","cdp-url"]);
      expect(opened).toMatchObject({isError:false});
      endpoint=opened.details.data.cdpUrl;
      sockets=opened.details.managedSessionSocketDir;
      expect(typeof sockets).toBe("string");
    });
    it.each([0,5,10,15])("admits five owned authenticated attaches starting at %i", async first => {
      for(let i=first;i<first+5;i++){
        const started=performance.now();
        expect(await step("attach-"+i,["connect",endpoint],true)).toMatchObject({isError:false});
        timing.push(performance.now()-started);
        const nonce=randomUUID();
        expect(await step("protected-"+i,["open",base+"/protected?nonce="+nonce])).toMatchObject({isError:false});
        expect(JSON.stringify(await step("title-"+i,["get","title"]))).toContain("AUTH "+nonce);
        expect(receipts.at(-1)).toBe(nonce);
        expect(await step("detach-"+i,["close"])).toMatchObject({isError:false});
      }
    });
    it("retains authentication through a native and Gateway runtime restart", async () => {
      closeNative(agentDir,sockets);
      expect((await readdir(sockets)).filter(name=>name.endsWith(".pid"))).toEqual([]);
      await registry.dispose();
      registry=await createRegistry();slot=await registry.create(cwd);await slot.setModel(model.provider,model.id);
      const nonce=randomUUID();
      expect(await step("restart",["open",base+"/protected?nonce="+nonce])).toMatchObject({isError:false});
      expect(JSON.stringify(await step("restart-title",["get","title"]))).toContain("AUTH "+nonce);
      expect(timing.every(ms=>ms<2000)).toBe(true);
      expect(receipts).toHaveLength(21);
      expect(receipts.at(-1)).toBe(nonce);
      await mkdir(join(process.cwd(),"test-results"),{recursive:true});
      await writeFile(join(process.cwd(),"test-results/2556-packaged-owned-browser.json"),JSON.stringify({package:JSON.parse(await readFile(join(installedFork,"package.json"),"utf8")).version,unownedRefused:true,ownedAttaches:20,timing,protectedReceipts:21,authenticatedRestart:true},null,2));
    });
    it("records an isolated external Chrome producer before generic connect and cleans its retired profile", async () => {
      const prepared=await step("producer-prepare",["owned-launch","prepare"]);
      expect(prepared).toMatchObject({isError:false});
      const {launchId,profile,args}=prepared.details.data;
      const chrome=process.env.AGENT_BROWSER_EXECUTABLE_PATH;
      if(!chrome) throw new Error("Chrome for Testing is required");
      const child=spawn(chrome,["--headless=new","--password-store=basic","--use-mock-keychain",...args,"about:blank"],{stdio:"ignore"});
      const exited=once(child,"exit");
      let endpoint:string|undefined;
      try {
        await waitFor(async()=>{try{return (await readFile(join(profile,"DevToolsActivePort"),"utf8")).includes("/devtools/browser/");}catch{return false;}},"owned external Chrome endpoint");
        const [port,path]=(await readFile(join(profile,"DevToolsActivePort"),"utf8")).trim().split("\n");
        endpoint=`ws://127.0.0.1:${port}${path}`;
        expect(await step("producer-live-cleanup",["owned-launch","cleanup",launchId])).toMatchObject({isError:true});
        expect(await step("producer-record",["owned-launch","record",launchId,String(child.pid)])).toMatchObject({isError:false,details:{data:{endpoint}}});
        expect(await step("producer-connect",["connect",`http://127.0.0.1:${port}`],true)).toMatchObject({isError:false});
        expect(await step("producer-verify",["get","url"])).toMatchObject({isError:false});
        expect(await step("producer-read",["get","cdp-url"])).toMatchObject({isError:false,details:{data:{cdpUrl:endpoint}}});
        expect(await step("producer-detach",["close"])).toMatchObject({isError:false});
      } finally {
        try {
          if(child.exitCode===null && endpoint){const socket=new WebSocket(endpoint);try {await awaitsWithin(once(socket,"open"),"producer cleanup connection",HOOK_HANG_BOUND_MS);socket.send(JSON.stringify({id:1,method:"Browser.close"}));await awaitsWithin(exited,"producer graceful exit",HOOK_HANG_BOUND_MS);} finally {socket.terminate();}}
        } finally {
          if(child.exitCode===null){if(!child.pid || child.pid<=1) throw new Error("Producer cleanup has no owned child PID; profile retained");child.kill("SIGTERM");await awaitsWithin(exited,"owned producer child exit",HOOK_HANG_BOUND_MS);}
        }
      }
      expect(await step("producer-cleanup",["owned-launch","cleanup",launchId])).toMatchObject({isError:false,details:{data:{cleaned:true}}});
      await expect(readFile(join(profile,"DevToolsActivePort"))).rejects.toMatchObject({code:"ENOENT"});
    });
    it("hands a native Electron launch fixture to the recorded-owner engine without touching an installed app", async () => {
      const appPath=join(root,"OwnedFixture.app"), contents=join(appPath,"Contents");
      await Promise.all(["MacOS","Frameworks/Electron Framework.framework","Resources/app"].map(path=>mkdir(join(contents,path),{recursive:true})));
      const chrome=process.env.AGENT_BROWSER_EXECUTABLE_PATH;
      if(!chrome) throw new Error("Chrome for Testing is required");
      const launcher=join(contents,"MacOS","OwnedFixture");
      const execute=`exec ${JSON.stringify(chrome)} --headless=new --password-store=basic --use-mock-keychain "$@"\n`;
      await writeFile(launcher,`#!/bin/sh\nfor arg do shift; case "$arg" in --tron-owned-launch=*) ;; *) set -- "$@" "$arg" ;; esac; done\n${execute}`,{mode:0o755});
      await writeFile(join(contents,"Resources/app/package.json"),JSON.stringify({name:"owned-fixture",main:"index.js"}));
      try {
        const stripped=await call("electron-stripped-nonce","agent_browser_electron",{action:"launch",appPath,handoff:"connect"});
        expect(stripped).toMatchObject({isError:true});
        expect(JSON.stringify(stripped)).toContain("owned_launch_required");
        await writeFile(launcher,`#!/bin/sh\n${execute}`,{mode:0o755});
        const launched=await call("electron-launch","agent_browser_electron",{action:"launch",appPath,handoff:"connect"});
        expect(launched).toMatchObject({isError:false});
        expect(await step("electron-verify",["get","url"])).toMatchObject({isError:false});
        expect(await step("electron-endpoint",["get","cdp-url"])).toMatchObject({isError:false});
      } finally {
        expect(await call("electron-cleanup","agent_browser_electron",{action:"cleanup",all:true})).toMatchObject({isError:false});
      }
    });
    afterAll(async () => {
      const failures: unknown[]=[];
      for(const cleanup of [()=>registry?.dispose(),()=>closeNative(agentDir,sockets),()=>cli("close"),()=>{site.closeAllConnections();return new Promise<void>(resolve=>site.close(()=>resolve()));}]){
        try {await cleanup();} catch(error) {failures.push(error);}
      }
      if(failures.length) throw new AggregateError(failures,`Browser qualification cleanup failed; retained ${root}`);
      await rm(root,{recursive:true,force:true});
    });
  });
  it("registers direct and parent-sealed packaged native views, reloads the parent receipt, and clears aborted stash", async () => {
    const forkStat = await readFile(join(installedFork, "package.json"), "utf8");
    expect(JSON.parse(forkStat)).toMatchObject({ name: "pi-agent-browser-native", version: "0.9.19-tron.1" });
    const root = await mkdtemp("/tmp/nb-");
    roots.push(root);
    const agentDir = join(root, "agent");
    const sessionDir = join(root, "sessions");
    const cwd = join(root, "workspace");
    const extensions = join(cwd, ".pi", "extensions");
    const fakeBin = join(root, "fake-bin");
    await Promise.all([mkdir(agentDir), mkdir(sessionDir), mkdir(extensions, {recursive:true}), mkdir(fakeBin)]);
    const callsPath = join(root, "cli-calls.jsonl");
    const fakeExecutable = `#!${process.execPath}\nrequire("node:fs").appendFileSync(${JSON.stringify(callsPath)}, "unexpected PATH engine execution"); process.exit(1);\n`;
    let sockets: string | undefined;
    browserCleanups.push(() => closeNative(agentDir,sockets));
    const fakePath = join(fakeBin, "agent-browser");
    await writeFile(fakePath, fakeExecutable, { mode: 0o755 });
    await chmod(fakePath, 0o755);
    process.env.PATH = `${fakeBin}:${oldPath ?? "/usr/bin:/bin"}`;
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({
      sessionDir,
      packages: [installedForkSource],
      defaultTools: ["+codemode", "+agent_browser", "+receipt_gate"],
    }));
    const sdkUrl = import.meta.resolve("@earendil-works/pi-coding-agent");
    await writeFile(join(extensions, "codemode.ts"), `import { createCodemodeExtension } from ${JSON.stringify(sdkUrl)}; export default createCodemodeExtension({ mode: "on" });\n`);

    await writeFile(join(extensions, "receipt-gate.ts"), `export default pi => pi.registerTool({
      name: "receipt_gate", label: "Receipt gate", description: "Hold the fixture parent for cancellation",
      parameters: { type: "object", properties: {} },
      execute: async (_id, _args, signal) => {
        await new Promise((resolve, reject) => {
          if (signal.aborted) reject(signal.reason);
          else signal.addEventListener("abort", () => reject(signal.reason), { once: true });
        });
        return { content: [{ type: "text", text: "unreachable" }] };
      }
    });\n`);
    const faux = fauxProvider({ provider: "tron-browser-fork-receipts", tokensPerSecond: 10_000 });
    faux.setResponses([
      fauxAssistantMessage([fauxToolCall("agent_browser", { args: ["connect", "ws://127.0.0.1:9/devtools/browser/12345678-1234-1234-1234-123456789abc"], sessionMode: "fresh" }, { id: "browser-forged" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("forged complete"),
      fauxAssistantMessage([fauxToolCall("agent_browser", { args: ["open", "about:blank"], sessionMode: "fresh" }, { id: "browser-open" })], { stopReason: "toolUse" }),
      fauxAssistantMessage([fauxToolCall("agent_browser", { args: ["get", "cdp-url"] }, { id: "browser-direct" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("direct complete"),
      fauxAssistantMessage([fauxToolCall("codemode", { code: `await tools.agent_browser({ args: ["open", "about:blank"], sessionMode: "fresh" }); await tools.agent_browser({ args: ["get", "cdp-url"] }); return "nested complete";` }, { id: "browser-nested-parent" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("nested complete"),
      fauxAssistantMessage([fauxToolCall("codemode", { code: `await tools.agent_browser({ args: ["open", "about:blank"], sessionMode: "fresh" }); await tools.agent_browser({ args: ["get", "cdp-url"] }); await tools.receipt_gate({}); return "unreachable";` }, { id: "browser-aborted-parent" })], { stopReason: "toolUse" }),
      fauxAssistantMessage([fauxToolCall("codemode", { code: `return "later parent has no nested browser";` }, { id: "browser-later-parent" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("later complete"),
    ]);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const views = new BrowserLiveViewRegistry();
    const modelRuntimeFactory = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const createRegistry = async () => await createTestRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, modelRuntimeFactory, trust,
      browserLiveViews: views, broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    const registry = await createRegistry();
    registries.push(registry);
    await registry.initialize();
    await registry.initializeBlobStorage();
    let slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const browserExtensions=slot.runtime.session.resourceLoader.getExtensions().extensions.filter(extension=>extension.tools.has("agent_browser"));
    expect(browserExtensions).toHaveLength(1);
    expect(browserExtensions[0]!.path).toBe("builtin:agent-browser");
    expect(browserExtensions[0]!.sourceInfo.baseDir).toBeUndefined();

    await slot.prompt("reject a forged raw lifecycle binding");
    await waitFor(() => toolResult(slot, "browser-forged") !== undefined && !slot.isBusy, "the forged browser result");
    expect(toolResult(slot, "browser-forged")).toMatchObject({ isError: true });
    expect(toolResult(slot, "browser-forged").details.agentBrowserStarted).not.toBe(true);
    expect(toolResult(slot, "browser-forged").details.browserLiveView).toBeUndefined();
    expect(toolResult(slot, "browser-forged").details.tronBrowserReference).toBeUndefined();

    await slot.prompt("run direct browser");
    await waitFor(() => toolResult(slot, "browser-direct") !== undefined && !slot.isBusy, "the direct browser tool result and an idle slot");
    const direct = toolResult(slot, "browser-direct");
    sockets=direct.details.managedSessionSocketDir;
    expect(typeof sockets).toBe("string");
    let frameBytes=0;
    expect(direct?.details).toMatchObject({ browserLiveView: { schema: "tron.browser-live-view.v1" }, tronBrowserReference: { toolCallId: "browser-direct" } });
    expect(admitBrowserToolReference("agent_browser", "browser-direct", direct.details, slot.id))
      .toMatchObject({ descriptor: direct.details.browserLiveView, automatic: true });
    expect(views.describe(slot.id, direct.details.browserLiveView.viewId, direct.details.browserLiveView.generation)).toEqual(direct.details.browserLiveView);
    {
      const descriptor = direct.details.browserLiveView;
      const viewer = views.open(slot.id, descriptor.viewId, descriptor.generation, "fixture-viewer");
      try {
        const frame = await waitFor(() => {
          const delivery = views.acquireFrame(slot.id, descriptor.viewId, descriptor.generation, viewer.leaseId, "fixture-viewer", () => {});
          delivery.release();
          return "sequence" in delivery.frame ? delivery.frame : undefined;
        }, "a real frame from the admitted native browser");
        expect(frame.data.length).toBeGreaterThan(0);
        frameBytes=frame.data.length;
      } finally { views.close(viewer.leaseId); }
    }

    await slot.prompt("run nested browser");
    await waitFor(() => toolResult(slot, "browser-nested-parent") !== undefined && !slot.isBusy, "the nested browser parent's result and an idle slot");
    const nestedParent = toolResult(slot, "browser-nested-parent");
    const nested = nestedParent?.details?.tronNested?.browserLiveViews?.[0];
    expect(nestedParent).toMatchObject({ details: { tronNested: { complete: true, browserLiveViews: [{ toolCallId: expect.stringContaining("browser-nested-parent/") }] } } });
    expect(nested?.receipt?.toolCallId).toBe("browser-nested-parent");
    expect(admitBrowserToolReference("agent_browser", "browser-nested-parent", { tronBrowserReference: nested?.receipt }, slot.id))
      .toMatchObject({ descriptor: nested?.descriptor, automatic: true });
    expect(views.describe(slot.id, nested.descriptor.viewId, nested.descriptor.generation)).toEqual(nested.descriptor);

    await registry.dispose();
    registries.splice(registries.indexOf(registry), 1);
    const reopened = await createRegistry();
    registries.push(reopened);
    await reopened.initialize();
    await waitFor(() => (reopened as unknown as { sessionCatalog: { hasCompleteCut(): boolean } }).sessionCatalog.hasCompleteCut(), "the catalog's complete cut");
    await reopened.catalog("all");
    slot = await reopened.acquire(slot.id);
    const coldParent = toolResult(slot, "browser-nested-parent");
    expect(coldParent).toMatchObject({ details: { tronNested: { complete: true, browserLiveViews: [{ receipt: { toolCallId: "browser-nested-parent" } }] } } });
    expect(slot.snapshot().toolExecutions).toEqual([]);

    const abortedPrompt = slot.prompt("abort nested browser parent");
    await waitFor(() => slot.snapshot().toolExecutions.some((execution) =>
      execution.toolCallId === "browser-aborted-parent"
      && execution.nestedCalls?.calls.filter(call => call.toolName === "agent_browser" && call.status === "completed").length === 2
      && execution.nestedCalls.calls.some(call => call.toolName === "receipt_gate" && call.status === "running")), "the real nested host gate after both browser calls");
    const abortOperation = slot.snapshot().operation?.id;
    expect(abortOperation).toBeDefined();
    await slot.abort("codemode", abortOperation);
    await abortedPrompt;
    await reopened.dispose();
    registries.splice(registries.indexOf(reopened), 1);

    const afterAbort = await createRegistry();
    registries.push(afterAbort);
    await afterAbort.initialize();
    await waitFor(() => (afterAbort as unknown as { sessionCatalog: { hasCompleteCut(): boolean } }).sessionCatalog.hasCompleteCut(), "the catalog's complete cut after the abort");
    await afterAbort.catalog("all");
    slot = await afterAbort.acquire(slot.id);
    await slot.prompt("later unrelated parent");
    await waitFor(() => toolResult(slot, "browser-later-parent") !== undefined && !slot.isBusy, "the later browser parent's result and an idle slot");
    const laterParent = toolResult(slot, "browser-later-parent");
    expect(laterParent).toBeDefined();
    expect((laterParent?.details as Record<string, unknown> | undefined)?.tronNested).toBeUndefined();
    expect(slot.snapshot().transcript.filter((item) => item.kind === "message" && item.role === "toolResult" && item.toolCallId === "browser-later-parent")).toHaveLength(1);

    await expect(readFile(callsPath, "utf8")).rejects.toMatchObject({ code: "ENOENT" });
    const artifactPath = join(process.cwd(), "test-results", "pi-sdk-099-browser-fork-native.json");
    await mkdir(dirname(artifactPath), { recursive: true });
    await writeFile(artifactPath, `${JSON.stringify({
      package: { version: JSON.parse(forkStat).version, source: browserExtensions[0]!.path, runtime: "pinned file artifact" },
      cli: { mode: "native", forgedRawLifecycleRejected: toolResult(slot,"browser-forged")?.isError===true, nativeFrameObserved: frameBytes>0, frameBytes },
      proof: {
        direct: { toolCallId: direct.toolCallId, registered: true, receiptAuthorized: true },
        nested: { parentToolCallId: "browser-nested-parent", nestedToolCallId: nested.toolCallId, receiptResealedForParent: true, coldReload: "preserved" },
        abort: { parentToolCallId: "browser-aborted-parent", runtimeDisposed: true, laterParentHasNoReceipt: true },
      },
    }, null, 2)}\n`);
  });
});
