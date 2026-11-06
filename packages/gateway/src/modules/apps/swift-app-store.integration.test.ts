import { displayOwnerOf, createTestRegistry } from "../../../test-support/gateway-registry.js";
/**
 * Installed Swift apps (#1157), end to end through a real RuntimeRegistry and
 * GatewayService: a faux model offers source in an ordinary session, the paired
 * phone explicitly reviews/installs it, and its RPCs (`apps.list/get/state/commit`) read and write
 * the same `state/apps/<id>/` store, across a Gateway restart.
 *
 * Failure modes:
 *  F1 an installed app is missing from apps.list, or apps.get returns a clipped source;
 *  F2 a commit replayed with its commandId applies twice, or a stale revision overwrites;
 *  F3 an over-bound or malformed commit changes state;
 *  F4 reinstalling an app loses its data;
 *  F5 state does not survive a Gateway restart;
 *  F6 remove leaves the app listed or readable, or the tool hides that data was deleted;
 *  F7 the tool reads a source outside its root, through a link, or a non-.swift file;
 *  F8 a vanished state/apps after creation reads as a fresh, empty install.
 *  F9 while the Gateway drains, the phone cannot read its apps, or a commit is admitted.
 *
 * The retained artifact is `test-results/swift-app-store/report.json`.
 */
import { execFileSync } from "node:child_process";
import { constants } from "node:fs";
import { lstat, mkdir, mkdtemp, open, readFile, realpath, rename, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall, type TranscriptContext } from "@earendil-works/pi-ai";
import { afterAll, afterEach, describe, expect, it, vi } from "vitest";
import { waitFor } from "../../../test-support/wait-for.js";
import { TrustService } from "../../kernel/resources/trust-service.js";
import { RuntimeRegistry } from "../../kernel/session/runtime-registry.js";
import { CommandReceiptStore } from "../../transport/command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../../transport/gateway-service.js";
import { SWIFT_APPS_CAPABILITY } from "./swift-app-store.js";

const REPORT_PATH = "test-results/swift-app-store/report.json";
const report: { generatedAt: string; cases: Array<Record<string, unknown>> } = { generatedAt: new Date().toISOString(), cases: [] };
const registries: RuntimeRegistry[] = [];
const roots: string[] = [];
const client = { id: "phone", identity: "device:swift-apps", isLocal: false } as ClientContext;

afterEach(async () => {
  const disposals = await Promise.allSettled(registries.splice(0).map(registry => registry.dispose()));
  const removals = await Promise.allSettled(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
  vi.unstubAllEnvs();
  selectedInstances.clear();
  const failures = [...disposals, ...removals].flatMap(result => result.status === "rejected" ? [result.reason] : []);
  if (failures.length > 0) throw new AggregateError(failures, "swift-app-store fixture teardown failed");
});

afterAll(async () => {
  await mkdir(join(process.cwd(), "test-results", "swift-app-store"), { recursive: true });
  await writeFile(join(process.cwd(), REPORT_PATH), `${JSON.stringify(report, null, 2)}\n`);
});

const selectedInstances = new Map<string, Map<string, string>>();
interface Gateway { registry: RuntimeRegistry; service: GatewayService; instances: Map<string, string> }

async function gateway(root: string, faux: ReturnType<typeof fauxProvider>): Promise<Gateway> {
  const agentDir = join(root, "agent");
  const tronHome = join(root, "tron");
  const registry = await createTestRegistry({
    agentDir, tronHome, idleRuntimeMs: 60_000,
    trust: new TrustService(agentDir),
    modelRuntimeFactory: async () => {
      const runtime = await ModelRuntime.create({ authPath: join(agentDir, "auth.json"), modelsPath: null, refreshOnCreate: false, allowModelNetwork: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    },
    broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
  });
  registries.push(registry);
  await registry.initialize();
  await registry.initializeBlobStorage();
  const service = new GatewayService({ display: displayOwnerOf(registry),
    config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome, agentDir },
    sessions: registry, receipts: new CommandReceiptStore(tronHome), broadcast: () => {},
    globalProviderResources: { withStableSnapshot: async (operation: () => Promise<unknown>) => operation(), requestReload: () => {} },
  } as unknown as GatewayServiceDependencies);
  const instances = selectedInstances.get(root) ?? new Map<string, string>();
  selectedInstances.set(root, instances);
  return { registry, service, instances };
}

async function fixture() {
  const root = await realpath(await mkdtemp(join(tmpdir(), "tron-swift-apps- #%-")));
  roots.push(root);
  const agentDir = join(root, "agent");
  const cwd = join(root, "project");
  await Promise.all([mkdir(agentDir), mkdir(cwd)]);
  vi.stubEnv("PI_CODING_AGENT_DIR", agentDir);
  vi.stubEnv("HOME", root);
  vi.stubEnv("PI_OFFLINE", "1");
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({ retry: { enabled: false }, compaction: { enabled: false, keepRecentTokens: 1 } }));
  const faux = fauxProvider({ provider: "swift-apps-fixture", tokensPerSecond: 100_000 });
  const contexts: TranscriptContext[] = [];
  const first = await gateway(root, faux);
  return { root, cwd, tronHome: join(root, "tron"), faux, contexts, ...first };
}

type Fixture = Awaited<ReturnType<typeof fixture>>;
interface ToolResult { isError: boolean; text: string; details: Record<string, unknown> }

/** Real tool turn, then explicit paired-phone review/install of successful offers.
 * Selected instance identities come from accepted installs, never fresh reads. */
async function agentCalls(f: Fixture, gatewayNow: Gateway, calls: Array<Record<string, unknown>>): Promise<ToolResult[]> {
  const slot = await gatewayNow.registry.create(f.cwd);
  const model = f.faux.getModel();
  await slot.setModel(model.provider, model.id);
  const before = f.contexts.length;
  f.faux.setResponses([
    fauxAssistantMessage(calls.map((args, index) => fauxToolCall("swift_app", args, { id: `call-${index}` })), { stopReason: "toolUse" }),
    (context: TranscriptContext) => { f.contexts.push(context); return fauxAssistantMessage("Done"); },
  ]);
  await slot.prompt("manage apps");
  await waitFor(() => (!slot.isBusy && f.contexts.length > before) || undefined, "the swift_app turn to settle");
  const messages = f.contexts.at(-1)!.messages as unknown as Array<Record<string, unknown>>;
  const results = messages.filter(message => message.role === "toolResult" && message.toolName === "swift_app").map(message => ({
    isError: message.isError === true,
    text: ((message.content as Array<{ text?: string }>)[0]?.text) ?? "",
    details: (message.details ?? {}) as Record<string, unknown>,
  }));
  for (const result of results) {
    const display = result.details.display as { artifact?: { id: string } } | undefined;
    if (result.isError || !display?.artifact) continue;
    const reference = { sessionId: slot.id, artifactId: display.artifact.id };
    const review = await rpc(gatewayNow, "apps.review", reference) as any;
    const installed = await rpc(gatewayNow, "apps.install", { ...reference, commandId: `review-${display.artifact.id}`,
      offerId: review.offer.id, expectedRevision: review.installed?.revision ?? null,
      expectedSourceSha256: review.installed?.sourceSha256 ?? null, expectedInstanceId: review.installed?.instanceId ?? null, upgradeToV2: false }) as any;
    expect(installed.app.version).toBe(2);
    gatewayNow.instances.set(installed.app.id, installed.app.instanceId);
  }
  return results;
}

function selectedRequest(g: Gateway, method: string, params: Record<string, unknown>): Record<string, unknown> {
  const instance = g.instances.get(params.appId as string);
  return instance && ["apps.commit", "apps.remove"].includes(method) && params.expectedInstanceId === undefined
    ? { ...params, expectedInstanceId: instance } : params;
}
async function rpc(g: Gateway, method: string, params: Record<string, unknown> = {}): Promise<Record<string, unknown>> {
  return await g.service.invoke(client, method, selectedRequest(g, method, params)) as Record<string, unknown>;
}

async function rpcError(g: Gateway, method: string, params: Record<string, unknown>): Promise<{ code: string; message: string }> {
  try { await g.service.invoke(client, method, selectedRequest(g, method, params)); } catch (error) {
    return { code: (error as { code?: string }).code ?? "unknown", message: (error as Error).message };
  }
  throw new Error(`${method} unexpectedly succeeded`);
}

/** A realistic app source past safeJson's 100,000-character clip, so a clipped get is visible. */
function bigSource(marker: string): string {
  const rows = Array.from({ length: 5_000 }, (_, index) => `        Text("row ${index} ${marker}")`).join("\n");
  return `import SwiftUI\n\nstruct ContentView: View {\n    var body: some View {\n        List {\n${rows}\n        }\n    }\n}\n// end ${marker}\n`;
}

describe("installed Swift apps through the Gateway", () => {
  it("refuses the retired direct v1 install action without creating an app or an offer", async () => {
    const f = await fixture();
    await writeFile(join(f.cwd, "Retired.swift"), "import SwiftUI\n");
    const [refused] = await agentCalls(f, f, [{ action: "install", appId: "retired", name: "Retired", source: { kind: "path", path: "Retired.swift" } }]);
    expect(refused!.isError).toBe(true);
    expect(refused!.text).toMatch(/install|action|invalid/i);
    expect(await rpc(f, "apps.list")).toEqual({ apps: [] });
    expect(await rpc(f, "apps.pending")).toEqual({ offers: [] });
  }, 60_000);
  it("lets the phone rename, reset and remove an app through idempotent receipts across restart", async () => {
    const f = await fixture();
    const source = 'import SwiftUI\nstruct ContentView: View { @AppStorage("count") var count = 0\n var body: some View { Text("\\(count)") } }';
    await writeFile(join(f.cwd, "Managed.swift"), source);
    const [installed] = await agentCalls(f, f, [{ action: "offer", feeds: [], appId: "managed", name: "Managed", source: { kind: "path", path: "Managed.swift" } }]);
    expect(installed!.isError).toBe(false);
    expect(await rpc(f, "apps.commit", { commandId: "manage-seed-1", appId: "managed", expectedRevision: 0, expectedSourceRevision: 1, set: [{ key: "count", value: 4 }] })).toEqual({ appId: "managed", revision: 1 });

    const rename = { commandId: "manage-rename-1", appId: "managed", name: "Renamed app" };
    const renamed = await rpc(f, "apps.rename", rename) as { app: Record<string, unknown> };
    expect(renamed.app).toMatchObject({ id: "managed", name: "Renamed app", revision: 1 });
    expect(await rpc(f, "apps.rename", rename)).toEqual(renamed);
    expect((await rpcError(f, "apps.rename", { commandId: "manage-rename-2", appId: "managed", name: " " })).code).toBe("invalid_request");
    // A rename keeps the program identity: its source revision fence is unchanged.
    expect(await rpc(f, "apps.commit", { commandId: "manage-after-rename", appId: "managed", expectedRevision: 1, expectedSourceRevision: 1, set: [{ key: "count", value: 5 }] })).toEqual({ appId: "managed", revision: 2 });

    const stale = await rpcError(f, "apps.reset", { commandId: "manage-reset-stale", appId: "managed", expectedRevision: 1 });
    expect(stale.code).toBe("conflict");
    const reset = { commandId: "manage-reset-1", appId: "managed", expectedRevision: 2 };
    expect(await rpc(f, "apps.reset", reset)).toEqual({ appId: "managed", revision: 3 });
    expect(await rpc(f, "apps.reset", reset)).toEqual({ appId: "managed", revision: 3 });
    expect(await rpc(f, "apps.state", { appId: "managed" })).toEqual({ appId: "managed", revision: 3, entries: [] });
    // An open program computed from the previous state cannot overwrite the reset.
    expect((await rpcError(f, "apps.commit", { commandId: "manage-after-reset", appId: "managed", expectedRevision: 2, expectedSourceRevision: 1, set: [{ key: "count", value: 9 }] })).code).toBe("conflict");

    await f.registry.dispose();
    registries.splice(registries.indexOf(f.registry), 1);
    const restarted = await gateway(f.root, f.faux);
    expect(((await rpc(restarted, "apps.get", { appId: "managed" })).app as Record<string, unknown>).name).toBe("Renamed app");
    expect(await rpc(restarted, "apps.reset", reset)).toEqual({ appId: "managed", revision: 3 });
    const remove = { commandId: "manage-remove-1", appId: "managed" };
    expect(await rpc(restarted, "apps.remove", remove)).toEqual({ appId: "managed", removed: true });
    expect(await rpc(restarted, "apps.remove", remove)).toEqual({ appId: "managed", removed: true });
    expect(await rpc(restarted, "apps.list")).toEqual({ apps: [] });
    expect((await rpcError(restarted, "apps.rename", { commandId: "manage-rename-3", appId: "managed", name: "Gone" })).code).toBe("not_found");
    await expect(stat(join(f.tronHome, "workspace", "state", "apps", "managed"))).rejects.toMatchObject({ code: "ENOENT" });
  }, 60_000);

  it("opens one installed snapshot and refuses interpreter writes from replaced source", async () => {
    const f = await fixture();
    const source = 'import SwiftUI\nstruct ContentView: View { var body: some View { Text("First") } }';
    await writeFile(join(f.cwd, "Installed.swift"), source);
    const [installed] = await agentCalls(f, f, [{ action: "offer", feeds: [], appId: "installed", name: "Installed", source: { kind: "path", path: "Installed.swift" } }]);
    expect(installed!.isError).toBe(false);
    const opened = await rpc(f, "apps.open", { appId: "installed" });
    expect(opened).toMatchObject({ app: { id: "installed", revision: 1 }, source, state: { appId: "installed", revision: 0, entries: [] } });
    await writeFile(join(f.cwd, "Installed.swift"), source.replace("First", "Second"));
    const [reinstalled] = await agentCalls(f, f, [{ action: "offer", feeds: [], appId: "installed", name: "Installed", source: { kind: "path", path: "Installed.swift" } }]);
    expect(reinstalled!.isError).toBe(false);
    const stale = await rpcError(f, "apps.commit", { commandId: "source-stale-1", appId: "installed", expectedRevision: 0,
      expectedSourceRevision: 1, set: [{ key: "count", value: 1 }] });
    expect(stale.code).toBe("conflict");
    expect(stale.message).toContain("source is at revision 2");
    expect((await rpc(f, "apps.state", { appId: "installed" })).revision).toBe(0);
    const params = { commandId: "source-current-1", appId: "installed", expectedRevision: 0, expectedSourceRevision: 2, set: [{ key: "count", value: 2 }] };
    expect(await rpc(f, "apps.commit", params)).toEqual({ appId: "installed", revision: 1 });
    expect(await rpc(f, "apps.commit", params)).toEqual({ appId: "installed", revision: 1 });
    expect(await rpc(f, "apps.open", { appId: "installed" })).toMatchObject({ app: { revision: 2 }, source: source.replace("First", "Second"),
      state: { revision: 1, entries: [{ key: "count", value: 2 }] } });
  }, 60_000);

  it("installs from the agent, serves the phone's RPCs, keeps data across reinstall and restart, then removes", async () => {
    const f = await fixture();
    const sourceV1 = bigSource("v1");
    expect(sourceV1.length).toBeGreaterThan(100_000);
    await writeFile(join(f.cwd, "Builds.swift"), sourceV1);

    const info = await rpc(f, "system.info");
    expect(info.capabilities).toContain(SWIFT_APPS_CAPABILITY);
    expect(await rpc(f, "apps.list")).toEqual({ apps: [] });

    // F1: the agent installs; the phone lists and reads the exact source.
    const [installed] = await agentCalls(f, f, [{ action: "offer", feeds: [], appId: "builds", name: "Tron builds", icon: "shippingbox", source: { kind: "path", path: "Builds.swift" } }]);
    expect(installed!.isError).toBe(false);
    expect(installed!.text).toContain("explicit Install App review");
    const listed = (await rpc(f, "apps.list")).apps as Array<Record<string, unknown>>;
    expect(listed.map(app => [app.id, app.name, app.icon, app.revision])).toEqual([["builds", "Tron builds", "shippingbox", 1]]);
    const got = await rpc(f, "apps.get", { appId: "builds" });
    expect(got.source).toBe(sourceV1);
    const directory = join(f.tronHome, "workspace", "state", "apps", "builds");
    expect((await stat(join(directory, "data.sqlite"))).isFile()).toBe(true);
    expect(await readFile(join(directory, "sources", `${(got.app as Record<string, unknown>).sourceSha256}.swift`), "utf8")).toBe(sourceV1);

    // F2: commits are revisioned and receipt-idempotent.
    expect(await rpc(f, "apps.state", { appId: "builds" })).toEqual({ appId: "builds", revision: 0, entries: [] });
    const commit = { commandId: "commit-0001", appId: "builds", expectedRevision: 0, set: [{ key: "filter", value: "Optimized" }, { key: "starred", value: ["f95544a20", { pinned: true, count: 2 }] }] };
    expect(await rpc(f, "apps.commit", commit)).toEqual({ appId: "builds", revision: 1 });
    expect(await rpc(f, "apps.commit", commit)).toEqual({ appId: "builds", revision: 1 });
    const stale = await rpcError(f, "apps.commit", { ...commit, commandId: "commit-0002", set: [{ key: "filter", value: "All" }] });
    expect(stale.code).toBe("conflict");
    expect(stale.message).toContain("revision 1, not 0");

    // F3: over-bound or malformed commits change nothing.
    const refusals = await Promise.all([
      rpcError(f, "apps.commit", { commandId: "commit-0003", appId: "builds", expectedRevision: 1, set: [{ key: "big", value: "x".repeat(300_000) }] }),
      rpcError(f, "apps.commit", { commandId: "commit-0004", appId: "builds", expectedRevision: 1, set: [], remove: [] }),
      rpcError(f, "apps.commit", { commandId: "commit-0005", appId: "builds", expectedRevision: 1, set: [{ key: "a", value: 1 }], remove: ["a"] }),
      rpcError(f, "apps.commit", { commandId: "commit-0006", appId: "../escape", expectedRevision: 1, set: [{ key: "a", value: 1 }] }),
      rpcError(f, "apps.commit", { commandId: "commit-0007", appId: "builds", expectedRevision: 1, set: Array.from({ length: 300 }, (_, index) => ({ key: `k${index}`, value: index })) }),
    ]);
    expect(refusals.map(refusal => refusal.code)).toEqual(["invalid_request", "invalid_request", "invalid_request", "invalid_request", "invalid_request"]);
    const overflow = Array.from({ length: 3 }, (_, index) => ({ key: `chunk${index}`, value: "y".repeat(200_000) }));
    expect((await rpcError(f, "apps.commit", { commandId: "commit-0008", appId: "builds", expectedRevision: 1, set: overflow })).code).toBe("conflict");
    const afterRefusals = await rpc(f, "apps.state", { appId: "builds" });
    expect(afterRefusals).toEqual({ appId: "builds", revision: 1, entries: [
      { key: "filter", value: "Optimized" }, { key: "starred", value: ["f95544a20", { pinned: true, count: 2 }] },
    ] });

    // F4 + agent seeding: reinstall from internal files keeps data; the agent commits too.
    const files = join(f.tronHome, "workspace", "files", "apps");
    await mkdir(files, { recursive: true });
    const sourceV2 = "import SwiftUI\nstruct ContentView: View { var body: some View { Text(\"v2\") } }\n";
    await writeFile(join(files, "Builds.swift"), sourceV2);
    const [reinstalled, seeded, read] = await agentCalls(f, f, [
      { action: "offer", feeds: [], appId: "builds", name: "Builds", source: { kind: "internal_file", path: "apps/Builds.swift" } },
      { action: "commit", appId: "builds", expectedRevision: 1, set: [{ key: "seen", value: 3 }], remove: ["filter"] },
      { action: "state", appId: "builds" },
    ]);
    expect([reinstalled!.isError, seeded!.isError, read!.isError]).toEqual([false, false, false]);
    expect(reinstalled!.text).toContain("explicit Install App review");
    expect(read!.details).toEqual({ appId: "builds", revision: 2, entries: [
      { key: "seen", value: 3 }, { key: "starred", value: ["f95544a20", { pinned: true, count: 2 }] },
    ] });
    expect(((await rpc(f, "apps.get", { appId: "builds" })).app as Record<string, unknown>)).toMatchObject({ name: "Builds", revision: 2 });

    // F5: a restarted Gateway reads the same apps and state.
    await f.registry.dispose();
    registries.splice(registries.indexOf(f.registry), 1);
    const restarted = await gateway(f.root, f.faux);
    expect((await rpc(restarted, "apps.get", { appId: "builds" })).source).toBe(sourceV2);
    expect((await rpc(restarted, "apps.state", { appId: "builds" })).revision).toBe(2);

    // F6: removal is explicit about deleting data, and the app is gone everywhere.
    const [removed] = await agentCalls(f, restarted, [{ action: "remove", appId: "builds", expectedInstanceId: restarted.instances.get("builds") }]);
    expect(removed!.isError).toBe(false);
    expect(removed!.text).toBe("Removed builds: its source and all of its stored data were deleted.");
    expect(await rpc(restarted, "apps.list")).toEqual({ apps: [] });
    expect((await rpcError(restarted, "apps.get", { appId: "builds" })).code).toBe("not_found");
    expect((await rpcError(restarted, "apps.state", { appId: "builds" })).code).toBe("not_found");
    await expect(stat(directory)).rejects.toMatchObject({ code: "ENOENT" });

    report.cases.push({ name: "install-rpc-commit-reinstall-restart-remove", sourceBytes: sourceV1.length, stateRevision: 2, refusals: refusals.map(refusal => refusal.message) });
  }, 60_000);

  describe.each(["missing", "uninitialized", "linked", "newer"] as const)("an installed app's %s database", damage => {
    it.each(["state", "commit", "reinstall"] as const)("refuses %s without recreating state or publishing source", async operation => {
      const f = await fixture();
      await writeFile(join(f.cwd, "App.swift"), "import SwiftUI\n// original\n");
      const install = { action: "offer", feeds: [], appId: "kept", name: "Kept", source: { kind: "path", path: "App.swift" } };
      expect((await agentCalls(f, f, [install]))[0]!.isError).toBe(false);
      expect(await rpc(f, "apps.commit", { commandId: "seed-state", appId: "kept", expectedRevision: 0, set: [{ key: "kept", value: 42 }] })).toEqual({ appId: "kept", revision: 1 });
      const directory = join(f.tronHome, "workspace", "state", "apps", "kept");
      const before = await rpc(f, "apps.get", { appId: "kept" });
      const database = join(directory, "data.sqlite");
      const originalBytes = await readFile(database);
      const linked = join(f.root, "Other.sqlite");
      if (damage === "newer") {
        const future = new DatabaseSync(database);
        try { future.exec("PRAGMA journal_mode = WAL; PRAGMA user_version = 2;"); } finally { future.close(); }
      } else if (damage === "linked") {
        await rename(database, linked);
        await symlink(linked, database);
      } else {
        await rm(database);
        if (damage === "uninitialized") new DatabaseSync(database).close();
      }
      const bytes = damage === "missing" ? undefined : await readFile(database);
      await writeFile(join(f.cwd, "App.swift"), "import SwiftUI\n// replacement\n");

      if (operation === "reinstall") {
        await expect(agentCalls(f, f, [install])).rejects.toThrow(/state|schema/i);
      } else {
        // Revision zero must not become valid again after the original data vanished.
        const params = operation === "state" ? { appId: "kept" } : {
          commandId: "after-loss", appId: "kept", expectedRevision: damage === "linked" ? 1 : 0, set: [{ key: "replacement", value: true }],
        };
        expect((await rpcError(f, `apps.${operation}`, params)).code).toBe("conflict");
      }
      expect(await rpc(f, "apps.get", { appId: "kept" })).toEqual(before);
      if (bytes) expect(await readFile(database)).toEqual(bytes);
      else await expect(stat(database)).rejects.toMatchObject({ code: "ENOENT" });
      if (damage === "linked") expect((await lstat(database)).isSymbolicLink()).toBe(true);
      await rm(database, { force: true });
      await writeFile(database, originalBytes);
      expect(await rpc(f, "apps.state", { appId: "kept" })).toEqual({ appId: "kept", revision: 1, entries: [{ key: "kept", value: 42 }] });
      report.cases.push({ name: `installed-database-${damage}-${operation}`, refused: true, sourceUnchanged: true });
    }, 60_000);
  });

  it("refuses a FIFO source without waiting for a writer and still installs a regular source", async () => {
    const f = await fixture();
    const fifo = join(f.cwd, "Pipe.swift");
    execFileSync("mkfifo", [fifo]);
    await writeFile(join(f.cwd, "Real.swift"), "import SwiftUI\n");
    const pending = agentCalls(f, f, [
      { action: "offer", feeds: [], appId: "pipe", name: "Pipe", source: { kind: "path", path: "Pipe.swift" } },
      { action: "offer", feeds: [], appId: "real", name: "Real", source: { kind: "path", path: "Real.swift" } },
    ]);
    let timer: NodeJS.Timeout | undefined;
    try {
      const results = await Promise.race([
        pending,
        new Promise<never>((_, reject) => {
          timer = setTimeout(() => reject(new Error("FIFO source install blocked waiting for a writer")), 5_000);
        }),
      ]);
      expect(results.map(result => result.isError)).toEqual([true, false]);
      expect(results[0]!.text).toContain("must be a file");
      expect(((await rpc(f, "apps.list")).apps as Array<{ id: string }>).map(app => app.id)).toEqual(["real"]);
      report.cases.push({ name: "fifo-refused-without-writer", regularSourceInstalled: true });
    } finally {
      clearTimeout(timer);
      // Release a regressed blocking open before disposing its runtime. This
      // writer is cleanup only: the outcome above must settle without one.
      const release = await open(fifo, constants.O_RDWR | constants.O_NONBLOCK);
      await release.close();
      await pending;
    }
  }, 60_000);

  it("refuses sources outside the tool's roots and reports a vanished store instead of an empty one", async () => {
    const f = await fixture();
    await writeFile(join(f.root, "Outside.swift"), "import SwiftUI\n");
    await writeFile(join(f.cwd, "notes.txt"), "not swift");
    await writeFile(join(f.cwd, ".Hidden.swift"), "import SwiftUI\n");
    await symlink(join(f.root, "Outside.swift"), join(f.cwd, "Link.swift"));
    await writeFile(join(f.cwd, "Real.swift"), "import SwiftUI\n");

    // F7
    const denied = ["../Outside.swift", join(f.root, "Outside.swift"), "notes.txt", ".Hidden.swift", "Link.swift"];
    const results = await agentCalls(f, f, [
      ...denied.map(path => ({ action: "offer", feeds: [], appId: "denied", name: "Denied", source: { kind: "path", path } })),
      { action: "offer", feeds: [], appId: "real", name: "Real", source: { kind: "path", path: "Real.swift" } },
    ]);
    expect(results.map(result => result.isError)).toEqual([true, true, true, true, true, false]);
    expect(((await rpc(f, "apps.list")).apps as Array<{ id: string }>).map(app => app.id)).toEqual(["real"]);

    // F8: the recorded container vanished; reads and installs refuse rather than start over.
    await rm(join(f.tronHome, "workspace", "state", "apps"), { recursive: true });
    expect((await rpcError(f, "apps.list", {})).message).toContain("missing after they were created");
    const [reinstall] = await agentCalls(f, f, [{ action: "offer", feeds: [], appId: "real", name: "Real", source: { kind: "path", path: "Real.swift" } }]);
    expect(reinstall!.isError).toBe(true);
    expect(reinstall!.text).toContain("missing after they were created");

    report.cases.push({ name: "source-boundaries-and-lost-store", denied, errors: results.slice(0, denied.length).map(result => result.text) });
  }, 60_000);

  it("keeps the phone's reads during an administrative drain and refuses a commit", async () => {
    const f = await fixture();
    await writeFile(join(f.cwd, "App.swift"), "import SwiftUI\n");
    const [installed] = await agentCalls(f, f, [{ action: "offer", feeds: [], appId: "kept", name: "Kept", source: { kind: "path", path: "App.swift" } }]);
    expect(installed!.isError).toBe(false);

    // F9: reads are disposable and stay available; a mutation would outlive the drain.
    f.registry.beginAdministrativeDrain();
    expect(((await rpc(f, "apps.list")).apps as Array<{ id: string }>).map(app => app.id)).toEqual(["kept"]);
    expect((await rpc(f, "apps.get", { appId: "kept" })).source).toBe("import SwiftUI\n");
    expect(await rpc(f, "apps.state", { appId: "kept" })).toEqual({ appId: "kept", revision: 0, entries: [] });
    const refused = await rpcError(f, "apps.commit", { commandId: "drain-0001", appId: "kept", expectedRevision: 0, set: [{ key: "a", value: 1 }] });
    expect(refused).toEqual({ code: "busy", message: "The Gateway is draining accepted work" });
    expect(await rpc(f, "apps.state", { appId: "kept" })).toEqual({ appId: "kept", revision: 0, entries: [] });
    report.cases.push({ name: "drain-reads-kept-commit-refused" });
  }, 60_000);
});
