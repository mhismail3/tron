import { chmod, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import { admitBrowserToolReference } from "../display/browser-tool-reference.js";
import { BrowserLiveViewRegistry } from "../display/browser-live-view.js";
import { RuntimeRegistry } from "./runtime-registry.js";

const installedFork = process.env.TRON_P99_17_BROWSER_FORK_COPY;
const installedForkSource = "git:github.com/fitchmultz/pi-agent-browser-native@d6cde09af8d7757bbfba5a4ffaf83381bb392683";
const registries: RuntimeRegistry[] = [];
const roots: string[] = [];
const oldPath = process.env.PATH;

afterEach(async () => {
  await Promise.all(registries.splice(0).map((registry) => registry.dispose().catch(() => {})));
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
  if (oldPath === undefined) delete process.env.PATH;
  else process.env.PATH = oldPath;
});

async function waitUntil(predicate: () => boolean, timeoutMs = 8_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error("condition timed out");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

function toolResult(slot: Awaited<ReturnType<RuntimeRegistry["create"]>>, toolCallId: string): any {
  return slot.snapshot().transcript.find((item) =>
    item.kind === "message" && item.role === "toolResult" && item.toolCallId === toolCallId);
}

describe("installed agent-browser fork receipts", () => {
  it.skipIf(!installedFork)("registers direct and parent-sealed nested live views, reloads the parent receipt, and clears aborted stash", async () => {
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
    const fakeExecutable = `#!/bin/sh\nif [ "$1" = "--version" ]; then\n  printf '%s\\n' 'agent-browser 0.33.2'\nelse\n  printf '%s\\n' '${envelope}'\nfi\n`;
    const fakePath = join(fakeBin, "agent-browser");
    await writeFile(fakePath, fakeExecutable, { mode: 0o755 });
    await chmod(fakePath, 0o755);
    process.env.PATH = `${fakeBin}:${oldPath ?? "/usr/bin:/bin"}`;
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({
      sessionDir,
      packages: [installedForkSource],
      defaultTools: ["+codemode", "+agent_browser"],
    }));
    const sdkUrl = import.meta.resolve("@earendil-works/pi-coding-agent");
    await writeFile(join(extensions, "codemode.ts"), `import { createCodemodeExtension } from ${JSON.stringify(sdkUrl)}; export default createCodemodeExtension({ mode: "on" });\n`);

    const faux = fauxProvider({ provider: "tron-browser-fork-receipts", tokensPerSecond: 10_000 });
    faux.setResponses([
      fauxAssistantMessage([fauxToolCall("agent_browser", { args: ["open", "https://example.test/"], sessionMode: "fresh" }, { id: "browser-direct" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("direct complete"),
      fauxAssistantMessage([fauxToolCall("codemode", { code: `await tools.agent_browser({ args: ["open", "https://example.test/nested"], sessionMode: "fresh" }); return "nested complete";` }, { id: "browser-nested-parent" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("nested complete"),
      fauxAssistantMessage([fauxToolCall("codemode", { code: `await tools.agent_browser({ args: ["open", "https://example.test/aborted"], sessionMode: "fresh" }); await new Promise(() => {}); return "unreachable";` }, { id: "browser-aborted-parent" })], { stopReason: "toolUse" }),
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
    const createRegistry = () => new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, modelRuntimeFactory, trust,
      browserLiveViews: views, broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    const registry = createRegistry();
    registries.push(registry);
    await registry.initialize();
    await registry.initializeBlobStorage();
    let slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);

    await slot.prompt("run direct browser");
    await waitUntil(() => toolResult(slot, "browser-direct") !== undefined && !slot.isBusy);
    const direct = toolResult(slot, "browser-direct");
    expect(direct?.details).toMatchObject({ browserLiveView: { schema: "tron.browser-live-view.v1" }, tronBrowserReference: { toolCallId: "browser-direct" } });
    expect(admitBrowserToolReference("agent_browser", "browser-direct", direct.details, slot.id))
      .toMatchObject({ descriptor: direct.details.browserLiveView, automatic: true });
    expect(views.describe(slot.id, direct.details.browserLiveView.viewId, direct.details.browserLiveView.generation)).toEqual(direct.details.browserLiveView);

    await slot.prompt("run nested browser");
    await waitUntil(() => toolResult(slot, "browser-nested-parent") !== undefined && !slot.isBusy);
    const nestedParent = toolResult(slot, "browser-nested-parent");
    const nested = nestedParent?.details?.tronNested?.browserLiveViews?.[0];
    expect(nestedParent).toMatchObject({ details: { tronNested: { complete: true, browserLiveViews: [{ toolCallId: expect.stringContaining("browser-nested-parent/") }] } } });
    expect(nested?.receipt?.toolCallId).toBe("browser-nested-parent");
    expect(admitBrowserToolReference("agent_browser", "browser-nested-parent", { tronBrowserReference: nested?.receipt }, slot.id))
      .toMatchObject({ descriptor: nested?.descriptor, automatic: true });
    expect(views.describe(slot.id, nested.descriptor.viewId, nested.descriptor.generation)).toEqual(nested.descriptor);

    await registry.dispose();
    registries.splice(registries.indexOf(registry), 1);
    const reopened = createRegistry();
    registries.push(reopened);
    await reopened.initialize();
    await waitUntil(() => (reopened as unknown as { sessionCatalog: { hasCompleteCut(): boolean } }).sessionCatalog.hasCompleteCut());
    await reopened.catalog("all");
    slot = await reopened.acquire(slot.id);
    const coldParent = toolResult(slot, "browser-nested-parent");
    expect(coldParent).toMatchObject({ details: { tronNested: { complete: true, browserLiveViews: [{ receipt: { toolCallId: "browser-nested-parent" } }] } } });
    expect(slot.snapshot().toolExecutions).toEqual([]);

    const abortedPrompt = slot.prompt("abort nested browser parent");
    await waitUntil(() => slot.snapshot().toolExecutions.some((execution) =>
      execution.toolCallId === "browser-aborted-parent" && execution.nestedCalls?.calls.some((call) => call.toolName === "agent_browser")));
    const abortOperation = slot.snapshot().operation?.id;
    expect(abortOperation).toBeDefined();
    await slot.abort("codemode", abortOperation);
    await abortedPrompt;
    await reopened.dispose();
    registries.splice(registries.indexOf(reopened), 1);

    const afterAbort = createRegistry();
    registries.push(afterAbort);
    await afterAbort.initialize();
    await waitUntil(() => (afterAbort as unknown as { sessionCatalog: { hasCompleteCut(): boolean } }).sessionCatalog.hasCompleteCut());
    await afterAbort.catalog("all");
    slot = await afterAbort.acquire(slot.id);
    await slot.prompt("later unrelated parent");
    await waitUntil(() => toolResult(slot, "browser-later-parent") !== undefined && !slot.isBusy);
    const laterParent = toolResult(slot, "browser-later-parent");
    expect(laterParent).toBeDefined();
    expect((laterParent?.details as Record<string, unknown> | undefined)?.tronNested).toBeUndefined();
    expect(slot.snapshot().transcript.filter((item) => item.kind === "message" && item.role === "toolResult" && item.toolCallId === "browser-later-parent")).toHaveLength(1);

    const artifactPath = join(process.cwd(), "test-results", "pi-sdk-099-browser-fork.json");
    await mkdir(dirname(artifactPath), { recursive: true });
    await writeFile(artifactPath, `${JSON.stringify({
      package: { version: "0.4.1", source: installedForkSource, runtime: "read-only copy" },
      fakeNativeEnvelope: { schema: binding.schema, state: binding.state, owned: binding.owned, session: binding.session, endpoint: "loopback-only" },
      proof: {
        direct: { toolCallId: direct.toolCallId, registered: true, receiptAuthorized: true },
        nested: { parentToolCallId: "browser-nested-parent", nestedToolCallId: nested.toolCallId, receiptResealedForParent: true, coldReload: "preserved" },
        abort: { parentToolCallId: "browser-aborted-parent", runtimeDisposed: true, laterParentHasNoReceipt: true },
      },
    }, null, 2)}\n`);
  });
});
