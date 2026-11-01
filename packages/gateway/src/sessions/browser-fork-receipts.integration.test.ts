import { createTestRegistry } from "../../test-support/gateway-registry.js";
import { chmod, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { TrustService } from "../kernel/resources/trust-service.js";
import { admitBrowserToolReference } from "../display/browser-tool-reference.js";
import { BrowserLiveViewRegistry } from "../display/browser-live-view.js";
import { RuntimeRegistry } from "../kernel/session/runtime-registry.js";
import { waitFor } from "../../test-support/wait-for.js";

const installedFork = process.env.TRON_P99_17_BROWSER_FORK_COPY;
const installedForkSource = "git:github.com/fitchmultz/pi-agent-browser-native@d6cde09af8d7757bbfba5a4ffaf83381bb392683";
const registries: RuntimeRegistry[] = [];
const roots: string[] = [];
const browserCleanups: Array<() => void> = [];
const oldPath = process.env.PATH;

afterEach(async () => {
  await Promise.all(registries.splice(0).map((registry) => registry.dispose().catch(() => {})));
  for (const cleanup of browserCleanups.splice(0)) cleanup();
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
  if (oldPath === undefined) delete process.env.PATH;
  else process.env.PATH = oldPath;
});

function toolResult(slot: Awaited<ReturnType<RuntimeRegistry["create"]>>, toolCallId: string): any {
  return slot.snapshot().transcript.find((item) =>
    item.kind === "message" && item.role === "toolResult" && item.toolCallId === toolCallId);
}

describe("installed agent-browser fork receipts", () => {
  it.skipIf(!installedFork).each(["envelope", "native"] as const)("registers direct and parent-sealed nested live views, reloads the parent receipt, and clears aborted stash (%s CLI)", async mode => {
    if (!installedFork) throw new Error("TRON_P99_17_BROWSER_FORK_COPY must point at the read-only installed fork copy");
    const forkStat = await readFile(join(installedFork, "package.json"), "utf8");
    expect(JSON.parse(forkStat)).toMatchObject({ name: "pi-agent-browser-native", version: "0.4.1" });

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
    // Run the real pinned fork in both cases. One case controls CLI envelopes;
    // the other crosses the actual engine boundary. Record only owned session
    // identities so even an assertion failure can close exactly our browsers.
    const fakeExecutable = `#!${process.execPath}\nconst fs = require("node:fs"), cp = require("node:child_process");
const args = process.argv.slice(2);
fs.appendFileSync(${JSON.stringify(callsPath)}, JSON.stringify({ args, socketDir: process.env.AGENT_BROWSER_SOCKET_DIR }) + "\\n");
if (args.includes("--version") && ${JSON.stringify(mode)} === "envelope") { console.log("agent-browser 0.33.2"); process.exit(0); }
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
      for (const { flags, socketDir } of identities.values()) execFileSync(nativeExecutable, [...flags, "close"], {
        timeout: 15_000, stdio: "pipe", env: { ...process.env, AGENT_BROWSER_SOCKET_DIR: socketDir },
      });
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

    // A bare never-settling sandbox Promise is rejected by the SDK, not an
    // abort window. Hold a real nested host tool until the public abort arrives.
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
      package: { version: "0.4.1", source: installedForkSource, runtime: "read-only copy" },
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
