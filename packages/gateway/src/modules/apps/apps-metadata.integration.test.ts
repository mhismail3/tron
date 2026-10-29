import { mkdir, mkdtemp, readFile, realpath, rename, rm, utimes, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { afterEach, expect, inject, it, vi } from "vitest";
import { createTestRegistry, displayOwnerOf } from "../../../test-support/gateway-registry.js";
import { TrustService } from "../../kernel/resources/trust-service.js";
import { GatewayService, type GatewayServiceDependencies } from "../../transport/gateway-service.js";
import { CommandReceiptStore } from "../../transport/command-receipts.js";
import { waitFor } from "../../../test-support/wait-for.js";
import { AppPublicationStaging } from "./apps-publication-staging.js";
import { manifestReplacer, type ManifestReplacer } from "../../machine/directory-publication.js";

const cleanup: Array<() => Promise<void>> = [];
afterEach(async () => { for (const close of cleanup.splice(0).reverse()) await close(); });
async function fixture(root?: string, replaceManifest?: ManifestReplacer) {
  root ??= await realpath(await mkdtemp(join(tmpdir(), "tron-app-metadata-")));
  const home = join(root, "tron"), agentDir = join(root, "agent"), apps = join(home, "workspace/files/apps");
  if (!cleanup.length) cleanup.push(() => rm(root!, { recursive: true, force: true }));
  await mkdir(agentDir, { recursive: true }); await mkdir(apps, { recursive: true, mode: 0o700 });
  const events: string[] = [];
  const registry = await createTestRegistry({ ...(replaceManifest ? { manifestReplacer: replaceManifest } : {}), appsChanged: revision => events.push(revision), tronHome: home, agentDir, trust: new TrustService(agentDir),
    modelRuntimeFactory: () => ModelRuntime.create({ authPath: join(agentDir, "auth.json"), modelsPath: null, refreshOnCreate: false, allowModelNetwork: false }),
    broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {} });
  cleanup.push(() => registry.dispose()); await registry.initialize(); await registry.initializeBlobStorage();
  const service = new GatewayService({ display: displayOwnerOf(registry), sessions: registry, modules: registry.moduleHost,
    config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome: home, agentDir }, receipts: new CommandReceiptStore(home), broadcast: () => {},
    globalProviderResources: { withStableSnapshot: async (run: () => Promise<unknown>) => run(), requestReload: () => {} },
  } as unknown as GatewayServiceDependencies);
  const rpc = (method: string, params: Record<string, unknown> = {}) => service.invoke({ id: "phone", identity: "device:metadata", isLocal: false } as never, method, params) as Promise<any>;
  const path = join(apps, "counter"); await mkdir(path, { recursive: true });
  return { root, registry, path, rpc, events, row: async () => (await rpc("apps.catalog")).rows[0] };
}

it("receipt-backs label-only edits without replacing code, scopes, saved data or the existing grant", async () => {
  const f = await fixture(), source = 'import SwiftUI\nText("Counter")';
  await writeFile(join(f.path, "Main.swift"), source);
  const configuration = { entry: "Main.swift", kind: "swift", permissions: { data: "readWrite", feeds: [], network: [] } };
  await writeFile(join(f.path, "app.json"), JSON.stringify(configuration));
  let row = await f.row();
  const prompt = await f.rpc("apps.open", { id: row.id, expectedContentRevision: row.contentRevision });
  await f.rpc("apps.permissions.grant", { commandId: "metadata-consent", token: prompt.token });
  const opened = await f.rpc("apps.open", { id: row.id, expectedContentRevision: row.contentRevision });
  await f.rpc("apps.commit", { commandId: "metadata-write", id: row.id, expectedContentRevision: row.contentRevision, grantRevision: opened.grantRevision, expectedRevision: 0, set: [{ key: "count", value: 9 }] });
  const edit = { commandId: "metadata-label", id: row.id, expectedContentRevision: row.contentRevision, title: "Renamed counter", icon: "number" };
  const result = await f.rpc("apps.setMetadata", edit); row = await f.row();
  expect(result).toEqual({ row });
  expect(row).toMatchObject({ title: "Renamed counter", icon: "number", status: { kind: "ready" } });
  expect(await readFile(join(f.path, "Main.swift"), "utf8")).toBe(source);
  expect(JSON.parse(await readFile(join(f.path, "app.json"), "utf8"))).toEqual({ ...configuration, title: edit.title, icon: edit.icon });
  expect(await f.rpc("apps.open", { id: row.id, expectedContentRevision: row.contentRevision })).toMatchObject({ kind: "swift", grantRevision: opened.grantRevision, state: { revision: 1, entries: [{ key: "count", value: 9 }] } });
  await writeFile(join(f.path, "Main.swift"), `${source}\n// external edit`);
  expect(await f.rpc("apps.setMetadata", edit)).toEqual(result);
  expect(await readFile(join(f.path, "Main.swift"), "utf8")).toContain("external edit");
  await f.registry.dispose(); const restarted = await fixture(f.root);
  expect(await restarted.rpc("apps.setMetadata", edit)).toEqual(result);
  expect((await restarted.row()).title).toBe("Renamed counter");
});

it("refuses stale metadata edits and invalid labels without publishing a partial manifest", async () => {
  const f = await fixture(); await writeFile(join(f.path, "Main.swift"), "import SwiftUI");
  const row = await f.row();
  for (const fields of [{ title: "" }, { icon: "bad\nicon" }, { title: "x".repeat(81) }, { permissions: { data: "readWrite" } }, {}]) {
    await expect(f.rpc("apps.setMetadata", { commandId: `invalid-${JSON.stringify(fields)}`, id: row.id, expectedContentRevision: row.contentRevision, ...fields })).rejects.toMatchObject({ code: "invalid_request" });
    await expect(readFile(join(f.path, "app.json"))).rejects.toMatchObject({ code: "ENOENT" });
  }
  await writeFile(join(f.path, "Main.swift"), "import SwiftUI\n// changed");
  await expect(f.rpc("apps.setMetadata", { commandId: "stale-label", id: row.id, expectedContentRevision: row.contentRevision, title: "Stale" })).rejects.toMatchObject({ code: "conflict" });
  await expect(readFile(join(f.path, "app.json"))).rejects.toMatchObject({ code: "ENOENT" });
});

it("retains the successful receipt when files become unavailable after verified metadata publication", async () => {
  const f = await fixture(); await writeFile(join(f.path, "Main.swift"), "import SwiftUI");
  const row = await f.row(), files = join(f.root, "tron/workspace/files"), parked = join(f.root, "parked-files");
  const create = AppPublicationStaging.prototype.create;
  // Interpose at the real cleanup boundary, not at a mocked publication: the
  // native rename, fsync, post-write validation and private stage removal run.
  const cut = vi.spyOn(AppPublicationStaging.prototype, "create").mockImplementation(async function(this: AppPublicationStaging) {
    const stage = await create.call(this);
    return { ...stage, release: async () => { await stage.release(); await rename(files, parked); } };
  });
  try {
    const outcome = await f.rpc("apps.setMetadata", { commandId: "metadata-lost-refresh", id: row.id, expectedContentRevision: row.contentRevision, title: "Committed title" })
      .then(result => ({ result }), error => ({ error }));
    expect(JSON.parse(await readFile(join(parked, "apps/counter/app.json"), "utf8"))).toEqual({ title: "Committed title" });
    expect(await f.rpc("command.status", { method: "apps.setMetadata", commandId: "metadata-lost-refresh" })).toMatchObject({ status: "completed", result: { row: { title: "Committed title" } } });
    expect(outcome).toMatchObject({ result: { row: { title: "Committed title" } } });
  } finally { cut.mockRestore(); await rename(parked, files); }
});

it("keeps an uncertain receipt fenced when the visible incarnation is replaced after the native metadata write", async () => {
  const replace = manifestReplacer(inject("nativePublicationBinary"));
  let externalCut = async () => {};
  const f = await fixture(undefined, async (source, destination) => { await replace(source, destination); await externalCut(); });
  await writeFile(join(f.path, "Main.swift"), "import SwiftUI");
  const row = await f.row(), parked = join(f.root, "original-counter");
  externalCut = async () => {
    await rename(f.path, parked); await mkdir(f.path);
    await writeFile(join(f.path, "Main.swift"), "import SwiftUI\n// replacement");
    await writeFile(join(f.path, "app.json"), '{"title":"Replacement"}');
  };
  const command = { commandId: "metadata-incarnation-cut", id: row.id, expectedContentRevision: row.contentRevision, title: "Original updated" };
  await expect(f.rpc("apps.setMetadata", command)).rejects.toMatchObject({ code: "conflict", details: { outcomeUnknown: true } });
  expect(JSON.parse(await readFile(join(parked, "app.json"), "utf8"))).toEqual({ title: "Original updated" });
  expect(await f.rpc("command.status", { method: "apps.setMetadata", commandId: command.commandId })).toMatchObject({ status: "pending" });
  await expect(f.rpc("apps.setMetadata", command)).rejects.toMatchObject({ code: "conflict" });
  expect(await readFile(join(f.path, "app.json"), "utf8")).toBe('{"title":"Replacement"}');
});

it("invalidates a page cursor when a byte-identical metadata edit changes the catalog's ordering", async () => {
  const f = await fixture(), second = join(f.path, "../newer");
  await writeFile(join(f.path, "Main.swift"), "import SwiftUI");
  await writeFile(join(f.path, "app.json"), '{"title":"counter"}\n');
  await mkdir(second); await writeFile(join(second, "Main.swift"), "import SwiftUI");
  const old = new Date("2000-01-01T00:00:00Z"), newer = new Date("2001-01-01T00:00:00Z");
  for (const path of [join(f.path, "Main.swift"), join(f.path, "app.json"), f.path]) await utimes(path, old, old);
  for (const path of [join(second, "Main.swift"), second]) await utimes(path, newer, newer);
  const firstPage = await f.rpc("apps.catalog", { limit: 1 }), row = (await f.rpc("apps.catalog")).rows.find((row: any) => row.id === "counter");
  expect(firstPage.rows[0].id).toBe("newer"); expect(firstPage.nextCursor).toEqual(expect.any(String));
  const result = await f.rpc("apps.setMetadata", { commandId: "same-label-new-order", id: row.id, expectedContentRevision: row.contentRevision, title: "counter" });
  expect(result.row.contentRevision).toBe(row.contentRevision);
  expect((await f.rpc("apps.catalog")).rows[0].id).toBe("counter");
  await expect(f.rpc("apps.catalog", { limit: 1, cursor: firstPage.nextCursor })).rejects.toMatchObject({ code: "conflict", diagnosticReason: "catalog_changed" });
});

it("emits invalidation hints for file/access changes and availability transitions without a failing-read event loop", async () => {
  const f = await fixture(); await writeFile(join(f.path, "Main.swift"), "import SwiftUI");
  await writeFile(join(f.path, "app.json"), JSON.stringify({ permissions: { data: "readWrite" } }));
  let catalog = await f.rpc("apps.catalog");
  expect(f.events).toContain(catalog.revision);
  let count = f.events.length;
  await writeFile(join(f.path, "Main.swift"), "import SwiftUI\n// watched edit");
  await waitFor(() => f.events.length > count ? true : undefined, "file edit emits Apps invalidation");
  catalog = await f.rpc("apps.catalog"); const row = catalog.rows[0];
  const prompt = await f.rpc("apps.open", { id: row.id, expectedContentRevision: row.contentRevision });
  count = f.events.length;
  await f.rpc("apps.permissions.grant", { commandId: "hint-grant", token: prompt.token });
  expect(f.events.slice(count)).toEqual([catalog.revision]);
  count = f.events.length;
  await f.rpc("apps.permissions.revoke", { commandId: "hint-revoke", id: row.id });
  expect(f.events.slice(count)).toEqual([catalog.revision]);
  const files = join(f.root, "tron/workspace/files"), parked = join(f.root, "parked-files");
  await rename(files, parked);
  await expect(f.rpc("apps.catalog")).rejects.toMatchObject({ code: "conflict" });
  count = f.events.length;
  await expect(f.rpc("apps.catalog")).rejects.toMatchObject({ code: "conflict" });
  expect(f.events).toHaveLength(count);
  await rename(parked, files);
  expect((await f.rpc("apps.catalog")).revision).toBe(catalog.revision);
  expect(f.events.slice(count)).toEqual([catalog.revision]);
});

it("serializes two accepted metadata commands against the same cut and supports clearing inferred overrides", async () => {
  const f = await fixture(); await writeFile(join(f.path, "Main.swift"), "import SwiftUI");
  let row = await f.row();
  const outcomes = await Promise.allSettled(["First", "Second"].map(title => f.rpc("apps.setMetadata", { commandId: `rename-${title}`, id: row.id, expectedContentRevision: row.contentRevision, title, icon: "star" })));
  expect(outcomes.filter(result => result.status === "fulfilled")).toHaveLength(1);
  expect(outcomes.find(result => result.status === "rejected")).toMatchObject({ reason: { code: "conflict" } });
  row = await f.row();
  const cleared = await f.rpc("apps.setMetadata", { commandId: "clear-labels", id: row.id, expectedContentRevision: row.contentRevision, title: null, icon: null });
  expect(cleared.row).toMatchObject({ title: "counter", icon: "app", kind: "swift" });
  expect(JSON.parse(await readFile(join(f.path, "app.json"), "utf8"))).toEqual({});
});
