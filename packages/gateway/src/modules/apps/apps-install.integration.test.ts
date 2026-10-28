import { createHash } from "node:crypto";
import { execFileSync, spawn } from "node:child_process";
import { once } from "node:events";
import { fileURLToPath, pathToFileURL } from "node:url";
import { mkdir, mkdtemp, readFile, readdir, realpath, rename, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall, type TranscriptContext } from "@earendil-works/pi-ai";
import { afterAll, afterEach, describe, expect, it, vi } from "vitest";
import { createTestRegistry, displayOwnerOf } from "../../../test-support/gateway-registry.js";
import { waitFor } from "../../../test-support/wait-for.js";
import { TrustService } from "../../kernel/resources/trust-service.js";
import type { RuntimeRegistry } from "../../kernel/session/runtime-registry.js";
import { CommandReceiptStore } from "../../transport/command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../../transport/gateway-service.js";

// Real RuntimeRegistry + faux model + GatewayService + durable Apps/receipt stores.
// No direct store calls: a source offer is produced by a real Pi tool turn and
// every installation/update/removal crosses the authenticated Gateway boundary.
const roots: string[] = [];
const live: RuntimeRegistry[] = [];
const results: string[] = [];
const phone = { id: "phone", identity: "device:apps-install", isLocal: false } as ClientContext;
const source = 'import SwiftUI\nstruct ContentView: View { var body: some View { Text("Builds") } }';
const sha = (text: string) => createHash("sha256").update(text).digest("hex");
afterEach(async () => {
  await Promise.all(live.splice(0).map(registry => registry.dispose()));
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
  vi.unstubAllEnvs();
});
afterAll(async () => {
  await mkdir("test-results/apps-install", { recursive: true });
  await writeFile("test-results/apps-install/report.json", JSON.stringify({ results }, null, 2));
});

async function start(root: string, faux: ReturnType<typeof fauxProvider>, receipts = new CommandReceiptStore(join(root, "tron"))) {
  const agentDir = join(root, "agent"), tronHome = join(root, "tron");
  const registry = await createTestRegistry({ agentDir, tronHome, trust: new TrustService(agentDir), idleRuntimeMs: 60_000,
    modelRuntimeFactory: async () => {
      const runtime = await ModelRuntime.create({ authPath: join(agentDir, "auth.json"), modelsPath: null, refreshOnCreate: false, allowModelNetwork: false });
      runtime.registerNativeProvider(faux.provider); return runtime;
    }, broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
  });
  live.push(registry); await registry.initialize(); await registry.initializeBlobStorage();
  const service = new GatewayService({ display: displayOwnerOf(registry),
    config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome, agentDir },
    sessions: registry, modules: registry.moduleHost, receipts, broadcast: () => {},
    globalProviderResources: { withStableSnapshot: async (operation: () => Promise<unknown>) => operation(), requestReload: () => {} },
  } as unknown as GatewayServiceDependencies);
  return { registry, service };
}
async function fixture() {
  const root = await realpath(await mkdtemp(join(tmpdir(), "tron-apps-install-"))); roots.push(root);
  await mkdir(join(root, "agent")); await mkdir(join(root, "project"));
  vi.stubEnv("PI_CODING_AGENT_DIR", join(root, "agent")); vi.stubEnv("HOME", root); vi.stubEnv("PI_OFFLINE", "1");
  await writeFile(join(root, "agent/settings.json"), JSON.stringify({ retry: { enabled: false }, compaction: { enabled: false } }));
  const faux = fauxProvider({ provider: "apps-install-fixture", tokensPerSecond: 100_000 });
  return { root, faux, displayReference: null as null | { sessionId: string; artifactId: string }, ...await start(root, faux) };
}
type Fixture = Awaited<ReturnType<typeof fixture>>;
async function tool(f: Fixture, args: Record<string, unknown>, contents = source, toolName = "swift_app") {
  await writeFile(join(f.root, "project/Builds.swift"), contents);
  const slot = await f.registry.create(join(f.root, "project"));
  const model = f.faux.getModel(); await slot.setModel(model.provider, model.id);
  let context: TranscriptContext | undefined;
  f.faux.setResponses([fauxAssistantMessage([fauxToolCall(toolName, args, { id: "offer-call" })], { stopReason: "toolUse" }),
    (value: TranscriptContext) => { context = value; return fauxAssistantMessage("Done"); }]);
  await slot.prompt("prepare the requested app");
  await waitFor(() => context && !slot.isBusy ? true : undefined, "the app tool turn");
  const result = (context!.messages as unknown as Array<Record<string, unknown>>).findLast(row => row.role === "toolResult" && row.toolName === toolName)!;
  expect(result.isError, JSON.stringify(result.content)).not.toBe(true);
  const details = result.details as Record<string, any>;
  if (details.display?.artifact?.id) f.displayReference = { sessionId: slot.id, artifactId: details.display.artifact.id };
  return details;
}
async function rpc(f: Pick<Fixture, "service"> & Partial<Pick<Fixture, "displayReference">>, method: string, params: Record<string, unknown> = {}) {
  const admitted = method === "apps.review" && params.sourceSha256 ? f.displayReference ?? params : params;
  return await f.service.invoke(phone, method, admitted) as Record<string, any>;
}
function offerArgs(feeds: string[] = []) { return { action: "offer", appId: "builds", name: "Builds", feeds, source: { kind: "path", path: "Builds.swift" } }; }
function installParams(review: Record<string, any>, commandId: string, upgradeToV2 = false) {
  return { commandId, ...review.reference, offerId: review.offer.id, expectedRevision: review.installed?.revision ?? null,
    expectedSourceSha256: review.installed?.sourceSha256 ?? null, expectedInstanceId: review.installed?.instanceId ?? null, upgradeToV2 };
}

function publish(f: Fixture, title: string): void {
  const ipa = join(f.root, "fixture.ipa");
  execFileSync("/usr/bin/python3", ["-c", "import sys,zipfile,plistlib\nwith zipfile.ZipFile(sys.argv[1],'w') as z: z.writestr('Payload/Tron.app/Info.plist',plistlib.dumps({'CFBundleIdentifier':'com.tron.mobile','CFBundleShortVersionString':'1.0'}))", ipa]);
  execFileSync("/usr/bin/python3", [fileURLToPath(new URL("../../../../../scripts/ios-share-publish.py", import.meta.url)), "--ipa", ipa,
    "--dir", join(f.root, "tron/ios-builds"), "--base-url", "https://mac.example.ts.net:8443", "--title", title, "--notes", "Read the full notes", "--commit", "a".repeat(40), "--branch", "feature/builds"]);
}

describe("reviewed Swift app lifecycle through the Gateway", () => {
  it("binds each offer's config to its exact canonical session/artifact, not shared source bytes", async () => {
    const f = await fixture(); await tool(f, offerArgs());
    const referenceA = { ...f.displayReference! };
    const reviewA = await rpc(f, "apps.review", referenceA);
    await tool(f, { title: "Same source, no offer", altText: "Swift source", source: { kind: "path", path: "Builds.swift" } }, source, "display");
    const referenceB = { ...f.displayReference! };
    await expect(rpc(f, "apps.review", referenceB)).rejects.toMatchObject({ code: "not_found" });
    await tool(f, { ...offerArgs(["ios-builds"]), appId: "other-app", name: "Other app" });
    const other = await rpc(f, "apps.review", f.displayReference!);
    expect(other.offer.id).not.toBe(reviewA.offer.id);
    expect(await rpc(f, "apps.review", referenceA)).toMatchObject({ offer: { appId: "builds", name: "Builds", feeds: [], id: reviewA.offer.id } });
    await expect(rpc(f, "apps.install", { ...installParams(reviewA, "foreign-artifact-install"), ...referenceB })).rejects.toMatchObject({ code: "not_found" });
    expect(await rpc(f, "apps.list")).toEqual({ apps: [] });
    expect(await rpc(f, "apps.install", installParams(reviewA, "exact-artifact-install"))).toMatchObject({ app: { id: "builds", feeds: [] } });
    results.push("exact session/artifact source/config grants and cross-session same-source refusal");
  });
  it("canonicalizes the configured home but refuses a linked publisher root", async () => {
    const f = await fixture(); publish(f, "Canonical home build");
    const alias = join(f.root, "alias"); await symlink(f.root, alias, "dir");
    await f.registry.dispose(); live.splice(live.indexOf(f.registry), 1);
    Object.assign(f, await start(alias, f.faux));
    await tool(f, offerArgs(["ios-builds"]));
    await rpc(f, "apps.install", installParams(await rpc(f, "apps.review", { sourceSha256: sha(source) }), "canonical-home-install"));
    expect((await rpc(f, "apps.open", { appId: "builds" })).feeds["ios-builds"].status).toBe("ready");
    const publisher = join(f.root, "tron/ios-builds");
    await rename(publisher, publisher + "-target"); await symlink(publisher + "-target", publisher, "dir");
    expect((await rpc(f, "apps.open", { appId: "builds" })).feeds["ios-builds"].status).toBe("unavailable");
    results.push("canonical configured home versus refused linked publisher root");
  });
  it("reclaims removed source/data after a fixture kill at the fsynced retirement cut and registry lease release", async () => {
    const f = await fixture(); await tool(f, offerArgs());
    const installed = await rpc(f, "apps.install", installParams(await rpc(f, "apps.review", f.displayReference!), "remove-cut-install"));
    await rpc(f, "apps.commit", { commandId: "remove-cut-save", appId: "builds", expectedRevision: 0,
      expectedSourceRevision: 1, expectedInstanceId: installed.app.instanceId, set: [{ key: "private-draft", value: "retire these bytes" }] });
    const params = { appId: "builds", expectedInstanceId: installed.app.instanceId, commandId: "remove-cut-command" };
    await writeFile(join(f.root, "request.json"), JSON.stringify({ method: "apps.remove", params }));
    await f.registry.dispose(); live.splice(live.indexOf(f.registry), 1);
    const marker = join(f.root, "retirement-barrier");
    const child = spawn(process.execPath, ["--experimental-transform-types", "--import",
      pathToFileURL(fileURLToPath(new URL("../../../test-support/apps-crash-preload.mjs", import.meta.url))).href,
      fileURLToPath(new URL("../../../test-support/apps-crash-child.ts", import.meta.url)), f.root, "retirement", marker],
    { stdio: ["pipe", "pipe", "pipe"], env: { ...process.env, PI_OFFLINE: "1", TRON_APPS_CRASH_CUT: "retirement", TRON_APPS_CRASH_ROOT: f.root } });
    let output = "";
    child.stdout.on("data", bytes => { output += bytes.toString(); }); child.stderr.on("data", bytes => { output += bytes.toString(); });
    const exited = once(child, "exit");
    try {
      await waitFor(async () => {
        try { return await readFile(marker, "utf8"); }
        catch { if (child.exitCode !== null || child.signalCode !== null) throw new Error(`Removal fixture exited: ${output}`); return undefined; }
      }, "fsynced Apps retirement after registry release", { boundMs: 15_000 });
      const appRoot = join(f.root, "tron/workspace/state/apps");
      const retired = (await readdir(appRoot)).filter(name => name.startsWith(".removed-"));
      expect(retired).toHaveLength(1);
      expect((await readFile(join(appRoot, retired[0], "data.sqlite"))).length).toBeGreaterThan(0);
      child.kill("SIGKILL"); expect((await exited)[1]).toBe("SIGKILL");
      Object.assign(f, await start(f.root, f.faux));
      expect(await rpc(f, "apps.list")).toEqual({ apps: [] });
      expect((await readdir(appRoot)).filter(name => name.startsWith(".removed-"))).toEqual([]);
      await expect(rpc(f, "apps.remove", params)).rejects.toMatchObject({ code: "conflict", details: { outcomeUnknown: true } });
      results.push("fixture kill after registry release at fsynced remove retirement: source/data reclaimed, uncertain receipt fenced");
    } finally {
      if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
      await exited;
    }
  });
  it("takes a fresh v1 backup after a failed upgrade and later state edits, retaining the earlier backup", async () => {
    const f = await fixture(); await tool(f, { action: "install", appId: "builds", name: "Legacy Builds", source: { kind: "path", path: "Builds.swift" } });
    await rpc(f, "apps.commit", { commandId: "backup-first-state", appId: "builds", expectedRevision: 0, set: [{ key: "draft", value: "first backup" }] });
    const directory = join(f.root, "tron/workspace/state/apps/builds");
    const firstBytes = await readFile(join(directory, "data.sqlite"));
    await tool(f, offerArgs(), source + "\n// explicit v1 upgrade");
    const review = await rpc(f, "apps.review", f.displayReference!);
    const obstruction = join(directory, "sources", `${review.offer.sourceSha256}.swift`);
    await mkdir(obstruction, { recursive: true, mode: 0o700 });
    await expect(rpc(f, "apps.install", { ...installParams(review, "backup-refused-publication"), upgradeToV2: true })).rejects.toMatchObject({ code: "EISDIR" });
    expect(await readFile(join(directory, "backups/v1-1/data.sqlite"))).toEqual(firstBytes);
    await rpc(f, "apps.commit", { commandId: "backup-later-state", appId: "builds", expectedRevision: 1, set: [{ key: "draft", value: "edited after failed upgrade" }] });
    const latestBytes = await readFile(join(directory, "data.sqlite"));
    await rm(obstruction, { recursive: true });
    await rpc(f, "apps.install", { ...installParams(await rpc(f, "apps.review", f.displayReference!), "backup-fresh-explicit-attempt"), upgradeToV2: true });
    expect((await rpc(f, "apps.open", { appId: "builds" })).state.entries).toEqual([{ key: "draft", value: "edited after failed upgrade" }]);
    const backups = (await readdir(join(directory, "backups"))).filter(name => name.startsWith("v1-1"));
    expect(backups).toHaveLength(2);
    expect(await readFile(join(directory, "backups/v1-1/data.sqlite"))).toEqual(firstBytes);
    expect(await readFile(join(directory, "backups", backups.find(name => name !== "v1-1")!, "data.sqlite"))).toEqual(latestBytes);
    expect((await readdir(directory)).includes("App.swift")).toBe(false);
    results.push("failed v1 publication retry: fresh byte-identical SQLite backup, prior backup retained, legacy source retired only after v2 head");
  });
  const cuts = ["pending", "source", "effects", "completion"] as const;
  const crashCases = ["install", "update", "save"].flatMap(operation => cuts.filter(cut => operation !== "save" || cut !== "source").map(cut => ({ operation, cut })));
  it.each(crashCases)("restarts the killed fixture after registry release during $operation at $cut without replay or data loss", async ({ operation, cut }) => {
    const f = await fixture();
    await tool(f, offerArgs());
    let initial: Record<string, any> | undefined;
    if (operation !== "install") {
      initial = await rpc(f, "apps.install", installParams(await rpc(f, "apps.review", { sourceSha256: sha(source) }), "crash-prepare-app"));
      if (operation === "update") {
        await rpc(f, "apps.commit", { commandId: "crash-prepare-data", appId: "builds", expectedRevision: 0,
          expectedSourceRevision: 1, expectedInstanceId: initial.app.instanceId, set: [{ key: "count", value: 7 }] });
        await tool(f, { ...offerArgs(), name: "Builds updated" }, source + "\n// reviewed update");
      }
    }
    const commandId = `crash-${operation}-${cut}-command`;
    const method = operation === "save" ? "apps.commit" : "apps.install";
    const params = operation === "save" ? { commandId, appId: "builds", expectedRevision: 0, expectedSourceRevision: 1,
      expectedInstanceId: initial!.app.instanceId, set: [{ key: "count", value: 4 }] }
      : installParams(await rpc(f, "apps.review", { sourceSha256: sha(source) }), commandId);
    await writeFile(join(f.root, "request.json"), JSON.stringify({ method, params }));
    await f.registry.dispose(); live.splice(live.indexOf(f.registry), 1);
    const marker = join(f.root, "barrier");
    const child = spawn(process.execPath, ["--experimental-transform-types", "--import",
      pathToFileURL(fileURLToPath(new URL("../../../test-support/apps-crash-preload.mjs", import.meta.url))).href,
      fileURLToPath(new URL("../../../test-support/apps-crash-child.ts", import.meta.url)), f.root, cut, marker],
    { stdio: ["pipe", "pipe", "pipe"], env: { ...process.env, PI_OFFLINE: "1", TRON_APPS_CRASH_CUT: cut, TRON_APPS_CRASH_ROOT: f.root } });
    let output = "";
    child.stdout.on("data", bytes => { output += bytes.toString(); }); child.stderr.on("data", bytes => { output += bytes.toString(); });
    const exited = once(child, "exit");
    try {
      await waitFor(async () => {
        try { return await readFile(marker, "utf8"); }
        catch { if (child.exitCode !== null || child.signalCode !== null) throw new Error(`Crash fixture exited: ${output}`); return undefined; }
      }, `${operation} ${cut} real durability cut`, { boundMs: 15_000 });
      child.kill("SIGKILL");
      const [, signal] = await exited;
      expect(signal).toBe("SIGKILL");
      Object.assign(f, await start(f.root, f.faux));
      const applied = cut === "effects" || cut === "completion";
      if (operation === "install" && !applied) {
        expect(await rpc(f, "apps.list")).toEqual({ apps: [] });
      } else {
        const reopened = await rpc(f, "apps.open", { appId: "builds" });
        expect(reopened.app.revision).toBe(operation === "update" && applied ? 2 : 1);
        expect(reopened.source).toBe(source + (operation === "update" && applied ? "\n// reviewed update" : ""));
        expect(reopened.state).toMatchObject({ revision: operation === "update" || operation === "save" && applied ? 1 : 0,
          entries: operation === "update" ? [{ key: "count", value: 7 }] : operation === "save" && applied ? [{ key: "count", value: 4 }] : [] });
      }
      if (cut === "completion") {
        const first = await rpc(f, method, params);
        expect(await rpc(f, method, params)).toEqual(first);
      } else {
        await expect(rpc(f, method, params)).rejects.toMatchObject({ code: "conflict", details: { outcomeUnknown: true } });
      }
      const appRoot = join(f.root, "tron/workspace/state/apps");
      expect((await readdir(appRoot)).filter(name => name.startsWith(".install-"))).toEqual([]);
      if (operation === "update") {
        expect((await readdir(join(appRoot, "builds/sources"))).filter(name => name.endsWith(".tmp"))).toEqual([]);
      }
      results.push(`fixture process after registry release ${operation}/${cut}: ${applied ? "applied once" : "not applied"}; ${cut === "completion" ? "completed replay" : "uncertain replay fenced"}`);
    } finally {
      if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
      await exited;
    }
  });
  it.skipIf(process.platform !== "darwin")("injects the real feed into a fresh native interpreter and fences exact install URLs to explicit user actions", async () => {
    const f = await fixture(); publish(f, "Native feed build");
    const id = (await readdir(join(f.root, "tron/ios-builds/builds"))).find(name => !name.startsWith("."))!;
    const manifest = `https://mac.example.ts.net:8443/builds/${id}/manifest.plist`;
    const install = (value: string) => `itms-services://?action=download-manifest&url=${encodeURIComponent(value)}`;
    const program = `import SwiftUI
let feed = AppFeed.iosBuilds()
let build = feed.builds[0]
struct ContentView: View {
  @Environment(\\.openURL) var openURL
  var report: String { build.title + ":" + build.commit }
  var body: some View { Text(report) }
  func install() { openURL(URL(string: build.installURL)!) }
  func wrongPort() { openURL(URL(string: "${install(manifest.replace(":8443", ":8444"))}")!) }
  func wrongPath() { openURL(URL(string: "${install(manifest.replace("manifest.plist", "other.plist"))}")!) }
  func queryManifest() { openURL(URL(string: "${install(manifest + "?alternate=1")}")!) }
}`;
    await tool(f, offerArgs(["ios-builds"]), program);
    await rpc(f, "apps.install", installParams(await rpc(f, "apps.review", { sourceSha256: sha(program) }), "native-feed-install"));
    const snapshot = await rpc(f, "apps.open", { appId: "builds" });
    const engine = fileURLToPath(new URL("../../../../ios-app/SwiftAppEngine/", import.meta.url));
    const probe = fileURLToPath(new URL("./fixtures/FeedsBoundaryMain.swift", import.meta.url));
    const binary = join(f.root, "feeds-boundary");
    const swift = (await readdir(engine)).filter(name => name.endsWith(".swift")).map(name => join(engine, name));
    execFileSync("/usr/bin/xcrun", ["swiftc", "-swift-version", "6", "-package-name", "TronIOSApp", "-parse-as-library", "-D", "SWIFT_APP_FEEDS_BOUNDARY", "-o", binary, ...swift, probe], { timeout: 240_000, env: { ...process.env, CLANG_MODULE_CACHE_PATH: join(f.root, "clang-cache") } });
    const run = (action: string | null, userInitiated: boolean, overrides: Record<string, unknown> = {}) => {
      const output = execFileSync(binary, {
        input: JSON.stringify({ source: snapshot.source, feeds: snapshot.feeds, host: "mac.example.ts.net", action, userInitiated, ...overrides }), encoding: "utf8", timeout: 15_000,
      });
      results.push(`native ${action ?? "open"} user=${userInitiated}: ${output}`);
      return JSON.parse(output);
    };
    expect(run(null, false)).toMatchObject({ report: `Native feed build:${"a".repeat(40)}`, succeeded: true });
    expect(run("install", false)).toMatchObject({ succeeded: false, error: expect.stringContaining("explicit user action") });
    expect(run("install", true)).toMatchObject({ succeeded: true, link: install(manifest) });
    for (const action of ["wrongPort", "wrongPath", "queryManifest"]) {
      const denied = run(action, true);
      expect(denied.succeeded, action).toBe(false);
      expect(denied.link, action).toBeUndefined();
    }
    expect(run("install", true, { host: "other.example.ts.net" })).toMatchObject({ succeeded: false, error: expect.stringContaining("not allowed") });
    expect(run(null, false, { feeds: null })).toMatchObject({ succeeded: false, error: expect.stringContaining("require an installed app") });
    expect(run(null, false, { feeds: {} })).toMatchObject({ succeeded: false, error: expect.stringContaining("does not declare") });
    results.push("real Gateway to fresh native interpreter; exact manifest/port/path/query/host and user-action gates");
  });
  it("delivers only declared bounded live publisher records and sees new builds without reinstall", async () => {
    const f = await fixture(); publish(f, "First build");
    await tool(f, offerArgs());
    const installed = await rpc(f, "apps.install", installParams(await rpc(f, "apps.review", { sourceSha256: sha(source) }), "feed-install-empty"));
    expect((await rpc(f, "apps.open", { appId: "builds" })).feeds).toEqual({});
    await tool(f, offerArgs(["ios-builds"]));
    await rpc(f, "apps.install", installParams(await rpc(f, "apps.review", { sourceSha256: sha(source) }), "feed-update-declared"));
    const first = await rpc(f, "apps.open", { appId: "builds" });
    expect(first.feeds["ios-builds"]).toMatchObject({ status: "ready", builds: [{ title: "First build", commit: "a".repeat(40), branch: "feature/builds" }] });
    expect(first.feeds["ios-builds"].builds[0].manifestURL).toMatch(/^https:\/\/mac\.example\.ts\.net:8443\/builds\/[a-zA-Z0-9-]+\/manifest\.plist$/);
    publish(f, "Second build");
    const next = await rpc(f, "apps.open", { appId: "builds" });
    expect(next.app.revision).toBe(2);
    expect(next.app.instanceId).toBe(installed.app.instanceId);
    expect(next.feeds["ios-builds"].builds.map((build: Record<string, unknown>) => build.title)).toEqual(["Second build", "First build"]);
    // Publisher staging is never a feed record, even if it contains malformed metadata.
    await mkdir(join(f.root, "tron/ios-builds/builds/.staging-incomplete"));
    await writeFile(join(f.root, "tron/ios-builds/builds/.staging-incomplete/build.json"), "broken");
    expect((await rpc(f, "apps.open", { appId: "builds" })).feeds["ios-builds"].builds).toHaveLength(2);
    // Committed malformed records are an explicit failure, never an empty-success feed.
    const ids = (await readdir(join(f.root, "tron/ios-builds/builds"))).filter(id => !id.startsWith("."));
    await writeFile(join(f.root, "tron/ios-builds/builds", ids[0]!, "build.json"), "broken");
    expect((await rpc(f, "apps.open", { appId: "builds" })).feeds["ios-builds"]).toMatchObject({ status: "unavailable", builds: [] });
    results.push("declared live publisher feed, refresh without reinstall, staging exclusion and malformed refusal");
  });
  it("offers without installing, reviews exact source/config, installs once, updates preserving data and removes", async () => {
    const f = await fixture();
    await tool(f, offerArgs());
    expect(await rpc(f, "apps.list")).toEqual({ apps: [] });
    const review = await rpc(f, "apps.review", { sourceSha256: sha(source) });
    expect(review).toMatchObject({ offer: { appId: "builds", name: "Builds", sourceSha256: sha(source), sourceBytes: Buffer.byteLength(source), feeds: [] }, installed: null });
    const request = installParams(review, "install-builds-0001");
    const installed = await rpc(f, "apps.install", request);
    expect(installed).toMatchObject({ created: true, app: { version: 2, id: "builds", revision: 1, feeds: [] } });
    expect(await rpc(f, "apps.install", request)).toEqual(installed);
    expect(await rpc(f, "apps.open", { appId: "builds" })).toMatchObject({ source, state: { revision: 0, entries: [] } });
    await rpc(f, "apps.commit", { commandId: "save-builds-00001", appId: "builds", expectedRevision: 0,
      expectedSourceRevision: 1, expectedInstanceId: installed.app.instanceId, set: [{ key: "count", value: 7 }] });
    await tool(f, { ...offerArgs(), name: "Builds updated", feeds: ["ios-builds"] });
    const update = await rpc(f, "apps.review", { sourceSha256: sha(source) });
    const updated = await rpc(f, "apps.install", installParams(update, "update-builds-0001"));
    expect(updated).toMatchObject({ created: false, app: { version: 2, revision: 2, name: "Builds updated", instanceId: installed.app.instanceId } });
    expect(await rpc(f, "apps.state", { appId: "builds" })).toMatchObject({ revision: 1, entries: [{ key: "count", value: 7 }] });
    await expect(rpc(f, "apps.install", { ...request, commandId: "stale-install-0001" })).rejects.toMatchObject({ code: "conflict" });
    const remove = { commandId: "remove-builds-0001", appId: "builds", expectedInstanceId: installed.app.instanceId };
    expect(await rpc(f, "apps.remove", remove)).toMatchObject({ removed: true });
    expect(await rpc(f, "apps.remove", remove)).toMatchObject({ removed: true });
    expect(await rpc(f, "apps.list")).toEqual({ apps: [] });
    results.push("exact offer/install/replay/update/data/remove");
  });

  it("keeps named v1 reads unchanged and requires a backed-up opt-in update to v2 without changing SQLite", async () => {
    const f = await fixture();
    await tool(f, { action: "install", appId: "builds", name: "Builds", source: { kind: "path", path: "Builds.swift" } });
    const directory = join(f.root, "tron/workspace/state/apps/builds");
    const before = await Promise.all(["app.json", "App.swift", "data.sqlite"].map(name => readFile(join(directory, name))));
    expect(await rpc(f, "apps.get", { appId: "builds" })).toMatchObject({ app: { version: 1 }, source });
    await tool(f, offerArgs(["ios-builds"]));
    const review = await rpc(f, "apps.review", { sourceSha256: sha(source) });
    await expect(rpc(f, "apps.install", installParams(review, "upgrade-refused-01"))).rejects.toMatchObject({ code: "conflict" });
    expect(await readFile(join(directory, "app.json"))).toEqual(before[0]);
    const upgraded = await rpc(f, "apps.install", installParams(review, "upgrade-approved-1", true));
    expect(upgraded.app).toMatchObject({ version: 2, revision: 2, feeds: ["ios-builds"] });
    expect(await readFile(join(directory, "data.sqlite"))).toEqual(before[2]);
    const backup = join(directory, "backups/v1-1");
    expect(await Promise.all(["app.json", "App.swift", "data.sqlite"].map(name => readFile(join(backup, name))))).toEqual(before);
    results.push("v1 byte preservation and explicit backed-up v2 upgrade");
  });

  it("refuses stale incarnations after remove/reinstall", async () => {
    const f = await fixture(); await tool(f, offerArgs());
    const first = await rpc(f, "apps.install", installParams(await rpc(f, "apps.review", { sourceSha256: sha(source) }), "incarnation-one-01"));
    await rpc(f, "apps.remove", { commandId: "incarnation-remove", appId: "builds", expectedInstanceId: first.app.instanceId });
    const second = await rpc(f, "apps.install", installParams(await rpc(f, "apps.review", { sourceSha256: sha(source) }), "incarnation-two-01"));
    expect(second.app.instanceId).not.toBe(first.app.instanceId);
    await expect(rpc(f, "apps.commit", { commandId: "old-incarnation-save", appId: "builds", expectedRevision: 0,
      expectedSourceRevision: 1, expectedInstanceId: first.app.instanceId, set: [{ key: "count", value: 99 }] })).rejects.toMatchObject({ code: "conflict" });
    await expect(rpc(f, "apps.remove", { commandId: "old-incarnation-remove", appId: "builds", expectedInstanceId: first.app.instanceId })).rejects.toMatchObject({ code: "conflict" });
    expect(await rpc(f, "apps.state", { appId: "builds" })).toMatchObject({ revision: 0, entries: [] });
    results.push("incarnation fences");
  });
});
