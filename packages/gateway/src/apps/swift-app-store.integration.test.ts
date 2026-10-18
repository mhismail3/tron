/**
 * Installed Swift apps (#1157), end to end through a real RuntimeRegistry and
 * GatewayService: a faux model calls the `swift_app` tool in an ordinary
 * session, and the iPhone's RPCs (`apps.list/get/state/commit`) read and write
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
 *
 * The retained artifact is `test-results/swift-app-store/report.json`.
 */
import { lstat, mkdir, mkdtemp, readFile, realpath, rename, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall, type TranscriptContext } from "@earendil-works/pi-ai";
import { afterAll, afterEach, describe, expect, it, vi } from "vitest";
import { waitFor } from "../../test-support/wait-for.js";
import { TrustService } from "../admin/trust-service.js";
import { RuntimeRegistry } from "../sessions/runtime-registry.js";
import { CommandReceiptStore } from "../transport/command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../transport/gateway-service.js";
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
  const failures = [...disposals, ...removals].flatMap(result => result.status === "rejected" ? [result.reason] : []);
  if (failures.length > 0) throw new AggregateError(failures, "swift-app-store fixture teardown failed");
});

afterAll(async () => {
  await mkdir(join(process.cwd(), "test-results", "swift-app-store"), { recursive: true });
  await writeFile(join(process.cwd(), REPORT_PATH), `${JSON.stringify(report, null, 2)}\n`);
});

interface Gateway { registry: RuntimeRegistry; service: GatewayService }

async function gateway(root: string, faux: ReturnType<typeof fauxProvider>): Promise<Gateway> {
  const agentDir = join(root, "agent");
  const tronHome = join(root, "tron");
  const registry = new RuntimeRegistry({
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
  const service = new GatewayService({
    config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome, agentDir },
    sessions: registry, receipts: new CommandReceiptStore(tronHome), broadcast: () => {},
    globalProviderResources: { withStableSnapshot: async (operation: () => Promise<unknown>) => operation(), requestReload: () => {} },
  } as unknown as GatewayServiceDependencies);
  return { registry, service };
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

/** One agent turn whose only step calls swift_app with each of `calls`. */
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
  return messages.filter(message => message.role === "toolResult" && message.toolName === "swift_app").map(message => ({
    isError: message.isError === true,
    text: ((message.content as Array<{ text?: string }>)[0]?.text) ?? "",
    details: (message.details ?? {}) as Record<string, unknown>,
  }));
}

async function rpc(g: Gateway, method: string, params: Record<string, unknown> = {}): Promise<Record<string, unknown>> {
  return await g.service.invoke(client, method, params) as Record<string, unknown>;
}

async function rpcError(g: Gateway, method: string, params: Record<string, unknown>): Promise<{ code: string; message: string }> {
  try { await g.service.invoke(client, method, params); } catch (error) {
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
  it("installs from the agent, serves the phone's RPCs, keeps data across reinstall and restart, then removes", async () => {
    const f = await fixture();
    const sourceV1 = bigSource("v1");
    expect(sourceV1.length).toBeGreaterThan(100_000);
    await writeFile(join(f.cwd, "Builds.swift"), sourceV1);

    const info = await rpc(f, "system.info");
    expect(info.capabilities).toContain(SWIFT_APPS_CAPABILITY);
    expect(await rpc(f, "apps.list")).toEqual({ apps: [] });

    // F1: the agent installs; the phone lists and reads the exact source.
    const [installed] = await agentCalls(f, f, [{ action: "install", appId: "builds", name: "Tron builds", icon: "shippingbox", source: { kind: "path", path: "Builds.swift" } }]);
    expect(installed!.isError).toBe(false);
    expect(installed!.text).toContain("Installed Tron builds (builds)");
    const listed = (await rpc(f, "apps.list")).apps as Array<Record<string, unknown>>;
    expect(listed.map(app => [app.id, app.name, app.icon, app.revision])).toEqual([["builds", "Tron builds", "shippingbox", 1]]);
    const got = await rpc(f, "apps.get", { appId: "builds" });
    expect(got.source).toBe(sourceV1);
    const directory = join(f.tronHome, "workspace", "state", "apps", "builds");
    expect((await stat(join(directory, "data.sqlite"))).isFile()).toBe(true);
    expect(await readFile(join(directory, "App.swift"), "utf8")).toBe(sourceV1);

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
      { action: "install", appId: "builds", name: "Builds", source: { kind: "internal_file", path: "apps/Builds.swift" } },
      { action: "commit", appId: "builds", expectedRevision: 1, set: [{ key: "seen", value: 3 }], remove: ["filter"] },
      { action: "state", appId: "builds" },
    ]);
    expect([reinstalled!.isError, seeded!.isError, read!.isError]).toEqual([false, false, false]);
    expect(reinstalled!.text).toContain("its data was kept");
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
    const [removed] = await agentCalls(f, restarted, [{ action: "remove", appId: "builds" }]);
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
      const install = { action: "install", appId: "kept", name: "Kept", source: { kind: "path", path: "App.swift" } };
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
        const [result] = await agentCalls(f, f, [install]);
        expect(result!.isError).toBe(true);
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
      ...denied.map(path => ({ action: "install", appId: "denied", name: "Denied", source: { kind: "path", path } })),
      { action: "install", appId: "real", name: "Real", source: { kind: "path", path: "Real.swift" } },
    ]);
    expect(results.map(result => result.isError)).toEqual([true, true, true, true, true, false]);
    expect(((await rpc(f, "apps.list")).apps as Array<{ id: string }>).map(app => app.id)).toEqual(["real"]);

    // F8: the recorded container vanished; reads and installs refuse rather than start over.
    await rm(join(f.tronHome, "workspace", "state", "apps"), { recursive: true });
    expect((await rpcError(f, "apps.list", {})).message).toContain("missing after they were created");
    const [reinstall] = await agentCalls(f, f, [{ action: "install", appId: "real", name: "Real", source: { kind: "path", path: "Real.swift" } }]);
    expect(reinstall!.isError).toBe(true);
    expect(reinstall!.text).toContain("missing after they were created");

    report.cases.push({ name: "source-boundaries-and-lost-store", denied, errors: results.slice(0, denied.length).map(result => result.text) });
  }, 60_000);
});
