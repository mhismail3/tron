import { createTestRegistry } from "../../../test-support/gateway-registry.js";
import { chmod, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { execFile, execFileSync } from "node:child_process";
import { promisify } from "node:util";
import { once } from "node:events";
import { createServer } from "node:http";
import { WebSocket, WebSocketServer } from "ws";
import { dirname, join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { TrustService } from "../../kernel/resources/trust-service.js";
import { admitBrowserToolReference } from "../../display/browser-tool-reference.js";
import { BrowserLiveViewRegistry } from "../../display/browser-live-view.js";
import { RuntimeRegistry } from "../../kernel/session/runtime-registry.js";
import { waitFor } from "../../../test-support/wait-for.js";

const installedFork = process.env.TRON_P99_17_BROWSER_FORK_COPY;
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
    for (const root of roots.splice(0)) {
      try { await rm(root, { recursive: true, force: true }); } catch (error) { failures.push(error); }
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

describe("installed agent-browser fork receipts", () => {
  it.skipIf(!installedFork)("attaches the pinned tool to Chrome's fixed consent endpoint, reuses it for DOM work, and seals a restart-fenced live view", async () => {
    if (!installedFork) throw new Error("The pinned browser fork fixture is required");
    const root = await mkdtemp(join(tmpdir(), "chrome-"));
    roots.push(root);
    const socketDir = join(root, "sockets");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const cache = join(agentDir, "git/github.com/fitchmultz/pi-agent-browser-native");
    await Promise.all([mkdir(socketDir), mkdir(cwd), mkdir(dirname(cache), { recursive: true })]);
    await symlink(installedFork, cache, "dir");
    const executable = execFileSync("/usr/bin/which", ["agent-browser"], { encoding: "utf8" }).trim();
    const cli = async (...args: string[]) => {
      const result = await promisify(execFile)(executable, ["--json", "--session", "o", ...args], {
        encoding: "utf8", env: { ...process.env, AGENT_BROWSER_SOCKET_DIR: socketDir }, timeout: 15_000,
      });
      const envelope = JSON.parse(result.stdout);
      expect(envelope.success).toBe(true);
      return envelope.data;
    };
    browserCleanups.push(() => execFileSync(executable, ["--session", "o", "close"], {
      env: { ...process.env, AGENT_BROWSER_SOCKET_DIR: socketDir }, timeout: 15_000, stdio: "pipe",
    }));
    const site = createServer((_request, response) => response.end("<!doctype html><title>Consented attach fixture</title><button>Local fixture only</button>"));
    site.listen(0, "127.0.0.1");
    await once(site, "listening");
    const siteAddress = site.address();
    if (!siteAddress || typeof siteAddress === "string") throw new Error("No fixture site address");
    const url = `http://127.0.0.1:${siteAddress.port}/`;
    const proxy = new WebSocketServer({ host: "127.0.0.1", port: 0, path: "/devtools/browser" });
    await once(proxy, "listening");
    const proxyAddress = proxy.address();
    if (typeof proxyAddress === "string" || !proxyAddress) throw new Error("No fixture proxy address");
    const endpoint = `ws://127.0.0.1:${proxyAddress.port}/devtools/browser`;
    const upstreams = new Set<WebSocket>();
    const views = new BrowserLiveViewRegistry();
    let registry: RuntimeRegistry | undefined;
    try {
      await cli("open", url);
      const upstreamEndpoint = (await cli("get", "cdp-url")).cdpUrl;
      expect(upstreamEndpoint).toMatch(/^ws:\/\/127\.0\.0\.1:/);
      proxy.on("connection", downstream => {
        const upstream = new WebSocket(upstreamEndpoint);
        upstreams.add(upstream);
        const pending: Array<{ data: Buffer; binary: boolean }> = [];
        downstream.on("message", (data, binary) => {
          if (upstream.readyState === WebSocket.OPEN) upstream.send(data, { binary });
          else pending.push({ data: Buffer.from(data as Buffer), binary });
        });
        upstream.on("open", () => { for (const { data, binary } of pending) upstream.send(data, { binary }); pending.length = 0; });
        upstream.on("message", (data, binary) => { if (downstream.readyState === WebSocket.OPEN) downstream.send(data, { binary }); });
        downstream.on("close", () => upstream.terminate());
        upstream.on("close", () => { upstreams.delete(upstream); downstream.terminate(); });
        upstream.on("error", () => downstream.terminate());
        downstream.on("error", () => upstream.terminate());
      });
      await writeFile(join(agentDir, "settings.json"), JSON.stringify({ sessionDir: join(root, "sessions"), packages: [installedForkSource], defaultTools: ["+agent_browser"] }));
      const faux = fauxProvider({ provider: "tron-chrome-attach", tokensPerSecond: 10_000 });
      faux.setResponses([
        fauxAssistantMessage([fauxToolCall("agent_browser", { args: ["connect", endpoint], sessionMode: "fresh" }, { id: "attach" })], { stopReason: "toolUse" }),
        fauxAssistantMessage([fauxToolCall("agent_browser", { args: ["tab", "new", url] }, { id: "fixture-open" })], { stopReason: "toolUse" }),
        fauxAssistantMessage([fauxToolCall("agent_browser", { args: ["get", "title"] }, { id: "fixture-title" })], { stopReason: "toolUse" }),
        fauxAssistantMessage([fauxToolCall("agent_browser", { args: ["get", "cdp-url"] }, { id: "fixture-view" })], { stopReason: "toolUse" }),
        fauxAssistantMessage([fauxToolCall("agent_browser", { args: ["tab", "close"] }, { id: "fixture-close" })], { stopReason: "toolUse" }),
        fauxAssistantMessage("complete"),
      ]);
      const trust = new TrustService(agentDir);
      await trust.set(cwd, true);
      registry = await createTestRegistry({ agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
        modelRuntimeFactory: async () => {
          const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
          runtime.registerNativeProvider(faux.provider);
          return runtime;
        }, browserLiveViews: views, broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
      });
      registries.push(registry);
      await registry.initialize();
      await registry.initializeBlobStorage();
      const slot = await registry.create(cwd);
      const model = faux.getModel();
      await slot.setModel(model.provider, model.id);
      await slot.prompt("Attach to the isolated local Chrome fixture, open and read only the fixture tab, then close it");
      await waitFor(() => !slot.isBusy && toolResult(slot, "fixture-close") !== undefined, "real attached browser task completion");
      for (const id of ["attach", "fixture-open", "fixture-title", "fixture-view", "fixture-close"]) {
        expect(toolResult(slot, id), id).toMatchObject({ isError: false });
      }
      expect(JSON.stringify(toolResult(slot, "fixture-title"))).toContain("Consented attach fixture");
      const observed = toolResult(slot, "fixture-view");
      const reference = admitBrowserToolReference("agent_browser", "fixture-view", observed.details, slot.id);
      expect(reference).toBeDefined();
      const descriptor = reference!.descriptor;
      expect(views.describe(slot.id, descriptor.viewId, descriptor.generation)).toEqual(descriptor);
      const viewer = views.open(slot.id, descriptor.viewId, descriptor.generation, "attached-viewer");
      try {
        const frame = await waitFor(() => {
          const delivery = views.acquireFrame(slot.id, descriptor.viewId, descriptor.generation, viewer.leaseId, "attached-viewer", () => {});
          delivery.release();
          return "sequence" in delivery.frame ? delivery.frame : undefined;
        }, "a real frame from the identity-pinned Chrome endpoint");
        expect(frame.data.length).toBeGreaterThan(0);
      } finally { views.close(viewer.leaseId); }
      await cli("close");
      await waitFor(() => {
        try { views.describe(slot.id, descriptor.viewId, descriptor.generation); return false; } catch { return true; }
      }, "Chrome exit retires its exact live view");
      expect(() => views.open(slot.id, descriptor.viewId, descriptor.generation, "late-viewer")).toThrow();
    } finally {
      if (registry) { await registry.dispose(); registries.splice(registries.indexOf(registry), 1); }
      views.dispose();
      for (const socket of proxy.clients) socket.terminate();
      for (const socket of upstreams) socket.terminate();
      await new Promise<void>(resolve => proxy.close(() => resolve()));
      site.closeAllConnections();
      await new Promise<void>(resolve => site.close(() => resolve()));
    }
  });
  it.skipIf(!installedFork).each(["envelope", "native"] as const)("registers direct and parent-sealed nested live views, reloads the parent receipt, and clears aborted stash (%s CLI)", async mode => {
    if (!installedFork) throw new Error("TRON_P99_17_BROWSER_FORK_COPY must point at the read-only installed fork copy");
    const forkStat = await readFile(join(installedFork, "package.json"), "utf8");
    expect(JSON.parse(forkStat)).toMatchObject({ name: "pi-agent-browser-native", version: "0.9.19" });

    const root = await mkdtemp(join(tmpdir(), "tron-pi-sdk-099-browser-fork-"));
    roots.push(root);
    const agentDir = join(root, "agent");
    const sessionDir = join(root, "sessions");
    const cwd = join(root, "workspace");
    const packageCachePath = join(agentDir, "git", "github.com", "fitchmultz", "pi-agent-browser-native");
    const extensions = join(cwd, ".pi", "extensions");
    const fakeBin = join(root, "fake-bin");
    await Promise.all([
      mkdir(agentDir, { recursive: true }), mkdir(sessionDir, { recursive: true }),
      mkdir(dirname(packageCachePath), { recursive: true }), mkdir(cwd, { recursive: true }), mkdir(extensions, { recursive: true }), mkdir(fakeBin),
    ]);
    await symlink(installedFork, packageCachePath, "dir");
    const binding = {
      schema: "agent-browser.browser-binding.v1",
      state: "active",
      owned: true,
      cdpUrl: "ws://127.0.0.1:43127/devtools/browser/12345678-1234-1234-1234-123456789abc",
      session: "s1",
    };
    const envelope = JSON.stringify({ success: true, data: {
      active: false,
      url: "https://example.test/",
      lifecycle: { browserBinding: binding },
    } });
    const nativeExecutable = mode === "native" ? execFileSync("/usr/bin/which", ["agent-browser"], { encoding: "utf8" }).trim() : undefined;
    const callsPath = join(root, "cli-calls.jsonl");
    const fakeExecutable = `#!${process.execPath}\nconst fs = require("node:fs"), cp = require("node:child_process");
const args = process.argv.slice(2);
fs.appendFileSync(${JSON.stringify(callsPath)}, JSON.stringify({ args, socketDir: process.env.AGENT_BROWSER_SOCKET_DIR }) + "\\n");
if (args.includes("--version") && ${JSON.stringify(mode)} === "envelope") { console.log("agent-browser 0.42.0"); process.exit(0); }
if (args.includes("https://forged.invalid/") || ${JSON.stringify(mode)} === "envelope") {
  const data = args.includes("cdp-url") ? { cdpUrl: ${JSON.stringify(binding.cdpUrl)} } : ${envelope}.data;
  console.log(JSON.stringify({ success: true, data }));
} else {
  const result = cp.spawnSync(${JSON.stringify(nativeExecutable)}, args, { stdio: "inherit" });
  if (result.error) throw result.error;
  process.exit(result.status ?? 1);
}\n`;
    if (nativeExecutable) browserCleanups.push(() => {
      const calls = readFileSync(callsPath, "utf8").trim().split("\n").map(line => JSON.parse(line) as { args: string[]; socketDir: string });
      const identities = new Map<string, { flags: string[]; socketDir: string }>();
      for (const { args, socketDir } of calls) {
        if (!args.includes("open") || args.includes("https://forged.invalid/")) continue;
        const flags = ["--namespace", "--session"].flatMap(flag => {
          const index = args.indexOf(flag);
          return index < 0 ? [] : [flag, args[index + 1]!];
        });
        if (flags.includes("--session")) identities.set(JSON.stringify(flags), { flags, socketDir });
      }
      const failures: unknown[] = [];
      for (const { flags, socketDir } of identities.values()) {
        try {
          execFileSync(nativeExecutable, [...flags, "close"], {
            timeout: 15_000, stdio: "pipe", env: { ...process.env, AGENT_BROWSER_SOCKET_DIR: socketDir },
          });
        } catch (error) { failures.push(error); }
      }
      if (failures.length) throw new AggregateError(failures, "Owned browser sessions failed to close");
    });
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
      fauxAssistantMessage([fauxToolCall("agent_browser", { args: ["open", "https://forged.invalid/"], sessionMode: "fresh" }, { id: "browser-forged" })], { stopReason: "toolUse" }),
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

    await slot.prompt("reject a forged raw lifecycle binding");
    await waitFor(() => toolResult(slot, "browser-forged") !== undefined && !slot.isBusy, "the forged browser result");
    expect(toolResult(slot, "browser-forged").details.browserLiveView).toBeUndefined();
    expect(toolResult(slot, "browser-forged").details.tronBrowserReference).toBeUndefined();

    await slot.prompt("run direct browser");
    await waitFor(() => toolResult(slot, "browser-direct") !== undefined && !slot.isBusy, "the direct browser tool result and an idle slot");
    const direct = toolResult(slot, "browser-direct");
    expect(direct?.details).toMatchObject({ browserLiveView: { schema: "tron.browser-live-view.v1" }, tronBrowserReference: { toolCallId: "browser-direct" } });
    expect(admitBrowserToolReference("agent_browser", "browser-direct", direct.details, slot.id))
      .toMatchObject({ descriptor: direct.details.browserLiveView, automatic: true });
    expect(views.describe(slot.id, direct.details.browserLiveView.viewId, direct.details.browserLiveView.generation)).toEqual(direct.details.browserLiveView);
    if (mode === "native") {
      const descriptor = direct.details.browserLiveView;
      const viewer = views.open(slot.id, descriptor.viewId, descriptor.generation, "fixture-viewer");
      try {
        const frame = await waitFor(() => {
          const delivery = views.acquireFrame(slot.id, descriptor.viewId, descriptor.generation, viewer.leaseId, "fixture-viewer", () => {});
          delivery.release();
          return "sequence" in delivery.frame ? delivery.frame : undefined;
        }, "a real frame from the admitted native browser");
        expect(frame.data.length).toBeGreaterThan(0);
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

    const artifactPath = join(process.cwd(), "test-results", `pi-sdk-099-browser-fork-${mode}.json`);
    await mkdir(dirname(artifactPath), { recursive: true });
    await writeFile(artifactPath, `${JSON.stringify({
      package: { version: "0.9.19", source: installedForkSource, runtime: "read-only copy" },
      cli: { mode, forgedRawLifecycleRejected: true, nativeFrameObserved: mode === "native" },
      fakeNativeEnvelope: { schema: binding.schema, state: binding.state, owned: binding.owned, session: binding.session, endpoint: "loopback-only" },
      proof: {
        direct: { toolCallId: direct.toolCallId, registered: true, receiptAuthorized: true },
        nested: { parentToolCallId: "browser-nested-parent", nestedToolCallId: nested.toolCallId, receiptResealedForParent: true, coldReload: "preserved" },
        abort: { parentToolCallId: "browser-aborted-parent", runtimeDisposed: true, laterParentHasNoReceipt: true },
      },
    }, null, 2)}\n`);
  });
});
