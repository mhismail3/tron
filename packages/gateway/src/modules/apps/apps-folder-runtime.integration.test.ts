import { DatabaseSync } from "node:sqlite";
import { lstat, stat } from "node:fs/promises";
import { execFileSync, spawn } from "node:child_process";
import { once } from "node:events";
import { fileURLToPath, pathToFileURL } from "node:url";
import { mkdir, mkdtemp, readFile, readdir, realpath, rename, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxProvider } from "@earendil-works/pi-ai";
import { afterAll, afterEach, describe, expect, it, vi } from "vitest";
import { createTestRegistry, displayOwnerOf } from "../../../test-support/gateway-registry.js";
import { waitFor } from "../../../test-support/wait-for.js";
import { TrustService } from "../../kernel/resources/trust-service.js";
import type { RuntimeRegistry } from "../../kernel/session/runtime-registry.js";
import { CommandReceiptStore } from "../../transport/command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../../transport/gateway-service.js";
// Surviving runtime oracles: real Gateway/SQLite/processes, folder membership and native consent.
const roots: string[] = [];
const live: RuntimeRegistry[] = [];
const results: string[] = [];
const published = new Map<string, Record<string, any>>();
const phone = { id: "phone", identity: "device:apps-folder-runtime", isLocal: false } as ClientContext;
const source = 'import SwiftUI\nstruct ContentView: View { var body: some View { Text("Builds") } }';
const sha = (text: string) => createHash("sha256").update(text).digest("hex");
afterEach(async () => {
  await Promise.all(live.splice(0).map(registry => registry.dispose()));
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
  vi.unstubAllEnvs(); published.clear();
});
afterAll(async () => {
  await mkdir("test-results/apps-folder-runtime", { recursive: true });
  await writeFile("test-results/apps-folder-runtime/report.json", JSON.stringify({ results }, null, 2));
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
  const root = await realpath(await mkdtemp(join(tmpdir(), "tron-apps-folder-runtime-"))); roots.push(root);
  await mkdir(join(root, "agent")); await mkdir(join(root, "project"));
  vi.stubEnv("PI_CODING_AGENT_DIR", join(root, "agent")); vi.stubEnv("HOME", root); vi.stubEnv("PI_OFFLINE", "1");
  await writeFile(join(root, "agent/settings.json"), JSON.stringify({ retry: { enabled: false }, compaction: { enabled: false } }));
  const faux = fauxProvider({ provider: "apps-folder-runtime-fixture", tokensPerSecond: 100_000 });
  const gateway = await start(root, faux);
  await mkdir(join(root, "tron/workspace/files/apps"), { recursive: true, mode: 0o700 });
  return { root, faux, ...gateway };
}
type Fixture = Awaited<ReturnType<typeof fixture>>;

async function rpc(f: Pick<Fixture, "service">, method: string, params: Record<string, unknown> = {}) {
  return await f.service.invoke(phone, method, params) as Record<string, any>;
}
async function seed(f: Fixture, id: string, program = source, permissions: Record<string, unknown> = {}) {
  // Publish the baseline before its first catalog read. Observation startup is
  // exercised independently by apps-folder.integration, not this runtime fixture.
  const key = `${f.root}/${id}`, previous = published.get(key);
  const directory = join(f.root, "tron/workspace/files/apps", id);
  await mkdir(directory, { recursive: true });
  await writeFile(join(directory, "Main.swift"), program);
  await writeFile(join(directory, "app.json"), JSON.stringify({ permissions }));
  const observed = await waitFor(async () => {
    const row = (await rpc(f, "apps.catalog")).rows.find((row: any) => row.id === id);
    return row && row.contentRevision !== previous?.contentRevision ? row : undefined;
  }, "folder content publication").catch(async error => {
    await writeFile("test-results/apps-folder/seed-observation.json", JSON.stringify({ id, previous, catalog: await rpc(f, "apps.catalog"), files: await readdir(directory) }, null, 2));
    throw error;
  });
  published.set(key, observed);
}
let consent = 0;
async function openEntry(f: Pick<Fixture, "service">, id = "builds") {
  const row = (await rpc(f, "apps.catalog")).rows.find((row: any) => row.id === id);
  const params = { id, expectedContentRevision: row.contentRevision };
  const first = await rpc(f, "apps.open", params);
  if (first.kind !== "permissionRequired") return first;
  await rpc(f, "apps.permissions.grant", { commandId: `native-consent-${++consent}`, token: first.token });
  return rpc(f, "apps.open", params);
}
async function commitParams(f: Pick<Fixture, "service">, id: string, params: Record<string, unknown>) {
  const opened = await openEntry(f, id);
  return { ...params, id, expectedContentRevision: opened.row.contentRevision, grantRevision: opened.grantRevision };
}
function publish(f: Fixture, title: string): void {
  const ipa = join(f.root, "fixture.ipa");
  execFileSync("/usr/bin/python3", ["-c", "import sys,zipfile,plistlib\nwith zipfile.ZipFile(sys.argv[1],'w') as z: z.writestr('Payload/Tron.app/Info.plist',plistlib.dumps({'CFBundleIdentifier':'com.tron.mobile','CFBundleShortVersionString':'1.0'}))", ipa]);
  execFileSync("/usr/bin/python3", [fileURLToPath(new URL("../../../../../scripts/ios-share-publish.py", import.meta.url)), "--ipa", ipa,
    "--dir", join(f.root, "tron/ios-builds"), "--base-url", "https://mac.example.ts.net:8443", "--title", title, "--notes", "Read the full notes", "--commit", "a".repeat(40), "--branch", "feature/builds"]);
}

describe("folder app runtime preservation boundaries", () => {
  it("canonicalizes the configured home but refuses a linked publisher root", async () => {
    const f = await fixture(); publish(f, "Canonical home build");
    const alias = join(f.root, "alias"); await symlink(f.root, alias, "dir");
    await f.registry.dispose(); live.splice(live.indexOf(f.registry), 1);
    Object.assign(f, await start(alias, f.faux));
    await seed(f, "builds", source, { feeds: ["ios-builds"] });
    expect((await openEntry(f)).feeds["ios-builds"].status).toBe("ready");
    const publisher = join(f.root, "tron/ios-builds");
    await rename(publisher, publisher + "-target"); await symlink(publisher + "-target", publisher, "dir");
    expect((await openEntry(f)).feeds["ios-builds"].status).toBe("unavailable");
  });

  it("clears saved values once across a restarted receipt owner without removing files", async () => {
    const f = await fixture();
    await seed(f, "kept", source, { data: "readWrite" });
    const commit = await commitParams(f, "kept", { commandId: "before-clear", expectedRevision: 0, set: [{ key: "count", value: 7 }] });
    await rpc(f, "apps.commit", commit);
    const params = { commandId: "clear-values", id: "kept", expectedRevision: 1, confirmed: true };
    const cleared = await rpc(f, "apps.reset", params);
    expect(await rpc(f, "apps.reset", params)).toEqual(cleared);
    await f.registry.dispose(); live.splice(live.indexOf(f.registry), 1);
    const restarted = await start(f.root, f.faux);
    expect(await rpc(restarted, "apps.reset", params)).toEqual(cleared);
    expect(await rpc(restarted, "apps.state", { id: "kept" })).toEqual({ appId: "kept", revision: 2, entries: [] });
    expect((await openEntry(restarted, "kept")).source).toBe(source);
  });
  it("preserves bounded JSON, stale-writer CAS and unchanged data on refused writes", async () => {
    const f = await fixture();
    await seed(f, "builds", source, { data: "readWrite" });
    const commit = await commitParams(f, "builds", { commandId: "commit-0001", expectedRevision: 0, set: [{ key: "filter", value: "Optimized" }, { key: "starred", value: ["f95544a20", { pinned: true, count: 2 }] }] });
    expect(await rpc(f, "apps.commit", commit)).toEqual({ appId: "builds", revision: 1 });
    expect(await rpc(f, "apps.commit", commit)).toEqual({ appId: "builds", revision: 1 });
    const error = async (params: Record<string, unknown>) => rpc(f, "apps.commit", params).catch(error => error);
    const stale = await error({ ...commit, commandId: "commit-0002", set: [{ key: "filter", value: "All" }] });
    expect(stale.code).toBe("conflict");
    expect(stale.message).toContain("revision 1, not 0");
    const current = { ...commit, expectedRevision: 1 };
    const refusals = await Promise.all([
      error({ ...current, commandId: "commit-0003", set: [{ key: "big", value: "x".repeat(300_000) }] }),
      error({ ...current, commandId: "commit-0004", set: [], remove: [] }),
      error({ ...current, commandId: "commit-0005", set: [{ key: "a", value: 1 }], remove: ["a"] }),
      error({ ...current, commandId: "commit-0006", id: "../escape", set: [{ key: "a", value: 1 }] }),
      error({ ...current, commandId: "commit-0007", set: Array.from({ length: 300 }, (_, index) => ({ key: `k${index}`, value: index })) }),
    ]);
    expect(refusals.map(refusal => refusal.code)).toEqual(["invalid_request", "invalid_request", "invalid_request", "invalid_request", "invalid_request"]);
    const overflow = Array.from({ length: 3 }, (_, index) => ({ key: `chunk${index}`, value: "y".repeat(200_000) }));
    expect((await error({ ...current, commandId: "commit-0008", set: overflow })).code).toBe("conflict");
    const afterRefusals = await rpc(f, "apps.state", { id: "builds" });
    expect(afterRefusals).toEqual({ appId: "builds", revision: 1, entries: [
      { key: "filter", value: "Optimized" }, { key: "starred", value: ["f95544a20", { pinned: true, count: 2 }] },
    ] });
  }, 60_000);

  describe.each(["missing", "uninitialized", "linked", "newer"] as const)("saved data with a %s database", damage => {
    it.each(["state", "commit"] as const)("refuses %s without recreating or changing saved bytes", async operation => {
      const f = await fixture();
      await seed(f, "kept", source, { data: "readWrite" });
      const commit = await commitParams(f, "kept", { commandId: "seed-state", expectedRevision: 0, set: [{ key: "kept", value: 42 }] });
      expect(await rpc(f, "apps.commit", commit)).toEqual({ appId: "kept", revision: 1 });
      const directory = join(f.root, "tron/workspace/state/apps/kept"), database = join(directory, "data.sqlite");
      const originalBytes = await readFile(database), linked = join(f.root, "Other.sqlite");
      const before = (await rpc(f, "apps.catalog")).rows;
      if (damage === "newer") {
        const future = new DatabaseSync(database);
        try { future.exec("PRAGMA journal_mode = WAL; PRAGMA user_version = 2;"); } finally { future.close(); }
      } else if (damage === "linked") {
        await rename(database, linked); await symlink(linked, database);
      } else {
        await rm(database);
        if (damage === "uninitialized") new DatabaseSync(database).close();
      }
      const bytes = damage === "missing" ? undefined : await readFile(database);
      const params = operation === "state" ? { id: "kept" } : {
        ...commit, commandId: "after-loss", expectedRevision: damage === "linked" ? 1 : 0, set: [{ key: "replacement", value: true }],
      };
      const refused = await rpc(f, `apps.${operation}`, params).catch(error => error);
      expect(refused.code).toBe("conflict");
      expect((await rpc(f, "apps.catalog")).rows).toEqual(before);
      if (bytes) expect(await readFile(database)).toEqual(bytes);
      else await expect(stat(database)).rejects.toMatchObject({ code: "ENOENT" });
      if (damage === "linked") expect((await lstat(database)).isSymbolicLink()).toBe(true);
      await rm(database, { force: true }); await writeFile(database, originalBytes);
      expect(await rpc(f, "apps.state", { id: "kept" })).toEqual({ appId: "kept", revision: 1, entries: [{ key: "kept", value: 42 }] });
    }, 60_000);
  });
  it.each(["pending", "effects", "completion"])("fences a killed state writer at the real %s receipt durability cut", async cut => {
    const f = await fixture();
    await seed(f, "builds", source, { data: "readWrite" });
    const params = await commitParams(f, "builds", { commandId: `crash-save-${cut}`, expectedRevision: 0, set: [{ key: "count", value: 4 }] });
    await writeFile(join(f.root, "request.json"), JSON.stringify({ method: "apps.commit", params }));
    await f.registry.dispose(); live.splice(live.indexOf(f.registry), 1);
    const marker = join(f.root, "barrier");
    const child = spawn(process.execPath, ["--experimental-transform-types", "--import",
      pathToFileURL(fileURLToPath(new URL("../../../test-support/apps-crash-preload.mjs", import.meta.url))).href,
      fileURLToPath(new URL("../../../test-support/apps-crash-child.ts", import.meta.url)), f.root, cut, marker],
      { stdio: ["pipe", "pipe", "pipe"], env: { ...process.env, PI_OFFLINE: "1" } });
    let output = "";
    child.stdout.on("data", bytes => { output += bytes.toString(); }); child.stderr.on("data", bytes => { output += bytes.toString(); });
    const exited = once(child, "exit");
    try {
      await waitFor(async () => {
        try { return await readFile(marker, "utf8"); }
        catch { if (child.exitCode !== null || child.signalCode !== null) throw new Error(`Crash fixture exited: ${output}`); return undefined; }
      }, `save ${cut} real durability cut`, { boundMs: 15_000 });
      child.kill("SIGKILL");
      const [, signal] = await exited;
      expect(signal).toBe("SIGKILL");
      Object.assign(f, await start(f.root, f.faux));
      const applied = cut === "effects" || cut === "completion";
      const reopened = await openEntry(f);
      expect(reopened.source).toBe(source);
      expect(reopened.state).toMatchObject({ revision: applied ? 1 : 0, entries: applied ? [{ key: "count", value: 4 }] : [] });
      if (cut === "completion") {
        const first = await rpc(f, "apps.commit", params);
        expect(await rpc(f, "apps.commit", params)).toEqual(first);
      } else {
        await expect(rpc(f, "apps.commit", params)).rejects.toMatchObject({ code: "conflict", details: { outcomeUnknown: true } });
      }
      results.push(`state writer killed at ${cut}: ${applied ? "applied once" : "not applied"}; receipt fenced`);
    } finally {
      if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
      await exited;
    }
  });

  it("keeps phone reads during administrative drain and refuses a state commit", async () => {
    const f = await fixture();
    await seed(f, "kept", "import SwiftUI\n", { data: "readWrite" });
    const params = await commitParams(f, "kept", { commandId: "drain-0001", expectedRevision: 0, set: [{ key: "a", value: 1 }] });
    f.registry.beginAdministrativeDrain();
    expect((await rpc(f, "apps.catalog")).rows.map((app: { id: string }) => app.id)).toEqual(["kept"]);
    expect((await openEntry(f, "kept")).source).toBe("import SwiftUI\n");
    expect(await rpc(f, "apps.state", { id: "kept" })).toEqual({ appId: "kept", revision: 0, entries: [] });
    const refused = await rpc(f, "apps.commit", params).catch(error => ({ code: error.code, message: error.message }));
    expect(refused).toEqual({ code: "busy", message: "The Gateway is draining accepted work" });
    expect(await rpc(f, "apps.state", { id: "kept" })).toEqual({ appId: "kept", revision: 0, entries: [] });
  }, 60_000);
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
    await seed(f, "builds", program, { feeds: ["ios-builds"] });
    const snapshot = await openEntry(f);
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
  it("lists retained timestamp/commit publications alongside UUID publications without relaxing safe reads", async () => {
    const f = await fixture(); publish(f, "Retained build");
    // The publisher retains pre-UUID releases in place. Recreate that committed
    // on-disk shape, including its exact manifest path, using only fixture data.
    const publisher = join(f.root, "tron/ios-builds/builds");
    const retainedId = "20261024T013208Z-aaaaaaaaa";
    execFileSync("/usr/bin/python3", ["-c", `import json, pathlib, plistlib, sys
root = pathlib.Path(sys.argv[1])
child = next(p for p in root.iterdir() if not p.name.startswith('.'))
record = json.loads((child / 'build.json').read_text())
record.update(id=sys.argv[2], time='2026-10-24T01:32:08+00:00')
(child / 'build.json').write_text(json.dumps(record))
manifest = plistlib.loads((child / 'manifest.plist').read_bytes())
manifest['items'][0]['assets'][0]['url'] = 'https://mac.example.ts.net:8443/builds/' + sys.argv[2] + '/TronMobile.ipa'
(child / 'manifest.plist').write_bytes(plistlib.dumps(manifest))
child.rename(root / sys.argv[2])`, publisher, retainedId]);
    publish(f, "Current build");
    await seed(f, "builds", source, { feeds: ["ios-builds"] });
    const feed = (await openEntry(f)).feeds["ios-builds"];
    expect(feed.status).toBe("ready");
    expect(feed.builds.map((build: Record<string, unknown>) => build.title)).toEqual(["Current build", "Retained build"]);
    const manifestURL = `https://mac.example.ts.net:8443/builds/${retainedId}/manifest.plist`;
    expect(feed.builds[1]).toMatchObject({ id: retainedId, manifestURL,
      installURL: `itms-services://?action=download-manifest&url=${encodeURIComponent(manifestURL)}` });

    if (process.platform === "darwin") {
      const program = `import SwiftUI
let feed = AppFeed.iosBuilds()
let build = feed.builds[1]
struct ContentView: View {
  @Environment(\\.openURL) var openURL
  var report: String { build.title + ":" + build.id }
  var body: some View { Text(report) }
  func install() { openURL(URL(string: build.installURL)!) }
}`;
      const engine = fileURLToPath(new URL("../../../../ios-app/SwiftAppEngine/", import.meta.url));
      const probe = fileURLToPath(new URL("./fixtures/FeedsBoundaryMain.swift", import.meta.url));
      const binary = join(f.root, "retained-feeds-boundary");
      const swift = (await readdir(engine)).filter(name => name.endsWith(".swift")).map(name => join(engine, name));
      execFileSync("/usr/bin/xcrun", ["swiftc", "-swift-version", "6", "-package-name", "TronIOSApp", "-parse-as-library", "-D", "SWIFT_APP_FEEDS_BOUNDARY", "-o", binary, ...swift, probe],
        { env: { ...process.env, CLANG_MODULE_CACHE_PATH: join(f.root, "clang-cache") } });
      const output = execFileSync(binary, { input: JSON.stringify({ source: program, feeds: { "ios-builds": feed }, host: "mac.example.ts.net", action: "install", userInitiated: true }), encoding: "utf8" });
      results.push(`native retained feed: ${output}`);
      expect(JSON.parse(output)).toMatchObject({ report: `Retained build:${retainedId}`, succeeded: true,
        link: `itms-services://?action=download-manifest&url=${encodeURIComponent(manifestURL)}` });
    }

    const retained = join(publisher, retainedId);
    const originals = new Map(await Promise.all(["build.json", "manifest.plist", "TronMobile.ipa"].map(async name => [name, await readFile(join(retained, name))] as const)));
    const unavailable = async () => expect((await openEntry(f)).feeds["ios-builds"]).toMatchObject({ status: "unavailable", builds: [] });
    // Accepting a retained name must not admit a linked file/directory, a
    // mismatched record, a wrong manifest path or an inconsistent IPA size.
    for (const name of originals.keys()) {
      const file = join(retained, name), target = join(f.root, `outside-${name}`);
      await rename(file, target); await symlink(target, file);
      await unavailable(); await rm(file); await rename(target, file);
    }
    const target = join(f.root, "outside-build");
    await rename(retained, target); await symlink(target, retained, "dir");
    await unavailable(); await rm(retained); await rename(target, retained);
    const record = JSON.parse(originals.get("build.json")!.toString());
    for (const change of [{ id: "20261024T013208Z-bbbbbbbbb" }, { bytes: record.bytes + 1 }]) {
      await writeFile(join(retained, "build.json"), JSON.stringify({ ...record, ...change }));
      await unavailable();
    }
    await writeFile(join(retained, "build.json"), originals.get("build.json")!);
    await writeFile(join(retained, "manifest.plist"), originals.get("manifest.plist")!.toString().replace(`/builds/${retainedId}/`, "/builds/20261024T013208Z-bbbbbbbbb/"));
    await unavailable();
    await writeFile(join(retained, "manifest.plist"), originals.get("manifest.plist")!);
    for (const name of ["20261024T013208Z-aaaaaaaaaa", "20261024T013208Z-" + "b".repeat(31) + "-aaaaaaaaa", "20261024T013208Z-%2faaaaaaaaa"]) {
      const invalid = join(publisher, name);
      // Keep record/path identity consistent so only name admission can refuse.
      await writeFile(join(retained, "build.json"), JSON.stringify({ ...record, id: name }));
      await writeFile(join(retained, "manifest.plist"), originals.get("manifest.plist")!.toString().replace(`/builds/${retainedId}/`, `/builds/${name}/`));
      await rename(retained, invalid); await unavailable(); await rename(invalid, retained);
    }
    await writeFile(join(retained, "build.json"), originals.get("build.json")!);
    await writeFile(join(retained, "manifest.plist"), originals.get("manifest.plist")!);
    expect((await openEntry(f)).feeds["ios-builds"].status).toBe("ready");
    results.push("mixed retained/current publisher records; retained file/directory links, identity, IPA size, manifest path and malformed-name refusals");
  });
  it("delivers only declared bounded live publisher records and sees new builds without reinstall", async () => {
    const f = await fixture(); publish(f, "First build");
    await seed(f, "builds");
    expect((await openEntry(f)).feeds).toEqual({});
    await seed(f, "builds", source, { feeds: ["ios-builds"] });
    const first = await openEntry(f);
    expect(first.feeds["ios-builds"]).toMatchObject({ status: "ready", builds: [{ title: "First build", commit: "a".repeat(40), branch: "feature/builds" }] });
    expect(first.feeds["ios-builds"].builds[0].manifestURL).toMatch(/^https:\/\/mac\.example\.ts\.net:8443\/builds\/[a-zA-Z0-9-]+\/manifest\.plist$/);
    publish(f, "Second build");
    const next = await openEntry(f);
    expect(next.feeds["ios-builds"].builds.map((build: Record<string, unknown>) => build.title)).toEqual(["Second build", "First build"]);
    // Publisher staging is never a feed record, even if it contains malformed metadata.
    await mkdir(join(f.root, "tron/ios-builds/builds/.staging-incomplete"));
    await writeFile(join(f.root, "tron/ios-builds/builds/.staging-incomplete/build.json"), "broken");
    expect((await openEntry(f)).feeds["ios-builds"].builds).toHaveLength(2);
    // Committed malformed records are an explicit failure, never an empty-success feed.
    const ids = (await readdir(join(f.root, "tron/ios-builds/builds"))).filter(id => !id.startsWith("."));
    await writeFile(join(f.root, "tron/ios-builds/builds", ids[0]!, "build.json"), "broken");
    expect((await openEntry(f)).feeds["ios-builds"]).toMatchObject({ status: "unavailable", builds: [] });
    results.push("declared live publisher feed, refresh without reinstall, staging exclusion and malformed refusal");
  });
  it.skipIf(process.platform !== "darwin")("persists real native interpreter actions through Gateway receipts and restores a fresh process", async () => {
    const f = await fixture();
    const engine = fileURLToPath(new URL("../../../../ios-app/SwiftAppEngine/", import.meta.url));
    const probe = fileURLToPath(new URL("./fixtures/PersistenceBoundaryMain.swift", import.meta.url));
    const binary = join(f.root, "persistence-boundary");
    const swift = (await readdir(engine)).filter(name => name.endsWith(".swift")).map(name => join(engine, name));
    execFileSync("/usr/bin/xcrun", ["swiftc", "-swift-version", "6", "-package-name", "TronIOSApp", "-parse-as-library", "-D", "SWIFT_APP_PERSISTENCE_BOUNDARY", "-o", binary, ...swift, probe], {
      timeout: 240_000, env: { ...process.env, CLANG_MODULE_CACHE_PATH: join(f.root, "clang-cache") },
    });
    const source = `import SwiftUI
struct Item { var title: String; var count: Int }
class Ledger { var count = 0 }
struct ContentView: View {
    @AppStorage("count") var count = 0
    @Persisted var items: [Item] = []
    @Persisted var unsupported: [Ledger] = []
    @State var scratch = 0
    var report: String { "\\(count)|\\(items.count)|\\(items.first?.title ?? "none")|\\(scratch)" }
    var body: some View { Text(report) }
    func increment() { count += 1; items.append(Item(title: "Saved", count: count)); scratch += 1 }
    func rollback() { count = 999; items = []; scratch = 999; let values = [1]; let bad = values[9] }
    func invalidType() { count += 1; unsupported = [Ledger()]; scratch += 1 }
    func overflow() { count += 1; items = [Item(title: "${"x".repeat(270_000)}", count: 1)]; scratch += 1 }
}
`;
    await seed(f, "persisted", source, { data: "readWrite" });
    await openEntry(f, "persisted");
    interface NativeResult {
      batches: Array<Array<{ key: string; json: string }>>;
      observations: Array<{ action: string; succeeded: boolean; report: string; error?: string }>;
      error?: string;
    }
    const run = (snapshot: Record<string, unknown>, actions: string[], installed = true, program = source): NativeResult => {
      const entries = Object.fromEntries((snapshot.entries as Array<{ key: string; value: unknown }>).map(entry => [entry.key, Buffer.from(JSON.stringify(entry.value)).toString("base64")]));
      return JSON.parse(execFileSync(binary, [], { input: JSON.stringify({ source: program, entries, actions, installed }), timeout: 20_000, encoding: "utf8" })) as NativeResult;
    };
    const initial = await rpc(f, "apps.state", { id: "persisted" });
    const changed = run(initial, ["increment", "rollback", "invalidType", "overflow", "binding"]);
    expect(changed.error).toBeUndefined();
    expect(changed.observations.map(item => [item.action, item.succeeded, item.report])).toEqual([
      ["opened", true, "0|0|none|0"], ["increment", true, "1|1|Saved|1"],
      ["rollback", false, "1|1|Saved|1"], ["invalidType", false, "1|1|Saved|1"],
      ["overflow", false, "1|1|Saved|1"], ["binding", true, "7|1|Saved|1"],
    ]);
    expect(changed.batches).toHaveLength(2);
    let revision = initial.revision as number;
    for (const [index, batch] of changed.batches.entries()) {
      const params = await commitParams(f, "persisted", { commandId: `native-persist-${index}`, expectedRevision: revision,
        set: batch.map(write => ({ key: write.key, value: JSON.parse(Buffer.from(write.json, "base64").toString("utf8")) })) });
      const committed = await rpc(f, "apps.commit", params);
      expect(await rpc(f, "apps.commit", params)).toEqual(committed);
      revision = committed.revision as number;
    }
    const stored = await rpc(f, "apps.state", { id: "persisted" });
    expect(stored.revision).toBe(2);
    expect(run(stored, []).observations).toEqual([{ action: "opened", succeeded: true, report: "7|1|Saved|0" }]);
    const recordDisplay = source.replace(/var report: String \{[^\n]+\}/u, 'var report: String { "\\(items[0])" }');
    expect(run(stored, [], true, recordDisplay).observations[0]?.report).toBe('Item(title: "Saved", count: 1)');
    expect(run(initial, [], false).error).toContain("requires an installed app");
    await f.registry.dispose();
    live.splice(live.indexOf(f.registry), 1);
    const restarted = await start(f.root, f.faux);
    const restored = await rpc(restarted, "apps.state", { id: "persisted" });
    expect(run(restored, []).observations).toEqual([{ action: "opened", succeeded: true, report: "7|1|Saved|0" }]);
    results.push(JSON.stringify({ name: "native-interpreter-persistence", revision, observations: changed.observations, restored: run(restored, []).observations }));

    const dictionaries = `import SwiftUI
struct Item { var title: String }
struct ContentView: View {
    @AppStorage("flag") var flag = false
    @AppStorage("flag") var alias = false
    @AppStorage("ratio") var ratio = 1.25
    @AppStorage("label") var label = "initial"
    @Persisted var table: [String: Item] = [:]
    @Persisted var numeric: [Int: String] = [:]
    @Persisted var switches: [Bool: String] = [:]
    var report: String { "\\(flag)/\\(alias)|\\(ratio)|\\(label)|\\(table["one"]?.title ?? "none")|\\(numeric[2] ?? "none")|\\(switches[true] ?? "none")" }
    var body: some View { Text(report) }
    func update() { flag = true; ratio = 2.5; label = "Saved"; table["one"] = Item(title: "record"); numeric[2] = "int"; switches[true] = "bool" }
}
`;
    await seed({ ...f, ...restarted }, "dictionaries", dictionaries, { data: "readWrite" });
    await openEntry(restarted, "dictionaries");
    const empty = await rpc(restarted, "apps.state", { id: "dictionaries" });
    const updated = run(empty, ["update"], true, (await openEntry(restarted, "dictionaries")).source as string);
    expect(updated.error).toBeUndefined();
    expect(updated.batches).toHaveLength(1);
    await rpc(restarted, "apps.commit", await commitParams(restarted, "dictionaries", { commandId: "native-dictionary-1", expectedRevision: 0,
      set: updated.batches[0]!.map(write => ({ key: write.key, value: JSON.parse(Buffer.from(write.json, "base64").toString("utf8")) })) }));
    const dictionariesStored = await rpc(restarted, "apps.state", { id: "dictionaries" });
    expect(run(dictionariesStored, [], true, dictionaries).observations).toEqual([
      { action: "opened", succeeded: true, report: "true/true|2.5|Saved|record|int|bool" },
    ]);
    expect(run(restored, [], true, source.replace("var title: String; var count: Int", "var renamed: String; var count: Int")).error).toContain("does not match the current app source");
    results.push(JSON.stringify({ name: "native-dictionary-and-scalar-roundtrip", restored: run(dictionariesStored, [], true, dictionaries).observations }));
  }, 300_000);

});
