import { mkdir, mkdtemp, readFile, realpath, rename, rm, symlink, writeFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { watch, type FSWatcher } from "node:fs";
import { TronWorkspace } from "../../workspace/tron-workspace.js";
import { AppsFolderIndex } from "./apps-folder-index.js";
import type { FolderWatchRequest } from "../../util/folder-watch.js";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall, type TranscriptContext } from "@earendil-works/pi-ai";
import { afterEach, expect, it, vi } from "vitest";
import { AppsFolderStore } from "./apps-folder-store.js";
import * as folderFormat from "./apps-folder-format.js";
import { createTestRegistry, displayOwnerOf } from "../../../test-support/gateway-registry.js";
import { TrustService } from "../../kernel/resources/trust-service.js";
import type { RuntimeRegistry } from "../../kernel/session/runtime-registry.js";
import { CommandReceiptStore } from "../../transport/command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../../transport/gateway-service.js";

import { waitFor } from "../../../test-support/wait-for.js";

const roots: string[] = [], registries: RuntimeRegistry[] = [];
const phone = { id: "phone", identity: "device:apps-folder", isLocal: false } as ClientContext;
afterEach(async () => {
  await Promise.all(registries.splice(0).map(registry => registry.dispose()));
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});
async function fixture(existingRoot?: string) {
  const root = existingRoot ?? await realpath(await mkdtemp(join(tmpdir(), "tron-apps-folder-")));
  if (!existingRoot) roots.push(root);
  const agentDir = join(root, "agent"), tronHome = join(root, "tron");
  await mkdir(agentDir, { recursive: true });
  const faux = fauxProvider({ provider: "apps-folder-fixture", tokensPerSecond: 100_000 });
  const registry = await createTestRegistry({ agentDir, tronHome, trust: new TrustService(agentDir),
    modelRuntimeFactory: async () => {
      const runtime = await ModelRuntime.create({ authPath: join(agentDir, "auth.json"), modelsPath: null, refreshOnCreate: false, allowModelNetwork: false });
      runtime.registerNativeProvider(faux.provider); return runtime;
    },
    broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {} });
  registries.push(registry); await registry.initialize(); await registry.initializeBlobStorage();
  const service = new GatewayService({ display: displayOwnerOf(registry),
    config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome, agentDir },
    sessions: registry, modules: registry.moduleHost, receipts: new CommandReceiptStore(tronHome), broadcast: () => {},
    globalProviderResources: { withStableSnapshot: async (operation: () => Promise<unknown>) => operation(), requestReload: () => {} },
  } as unknown as GatewayServiceDependencies);
  const apps = join(tronHome, "workspace/files/apps");
  await mkdir(apps, { recursive: true, mode: 0o700 });
  return { root, apps, service, registry, faux, rpc: async (method: string, params: Record<string, unknown> = {}) => await service.invoke(phone, method, params) as Record<string, any> };
}
it("isolates a malformed entry while a good Swift sibling opens through GatewayService", async () => {
  const f = await fixture();
  await mkdir(join(f.apps, "good")); await mkdir(join(f.apps, "broken"));
  const source = 'import SwiftUI\nstruct ContentView: View { var body: some View { Text("Good") } }';
  await writeFile(join(f.apps, "good/Main.swift"), source);
  await writeFile(join(f.apps, "broken/app.json"), "{broken");
  const catalog = await f.rpc("apps.catalog");
  expect(catalog.rows).toHaveLength(2);
  expect(catalog.rows.find((row: any) => row.id === "broken").status.kind).toBe("cannotOpen");
  const good = catalog.rows.find((row: any) => row.id === "good");
  expect(good.status.kind).toBe("ready");
  expect(await f.rpc("apps.open", { id: good.id, expectedContentRevision: good.contentRevision })).toMatchObject({ kind: "swift", source });
});

it("requires exact-code consent, persists state separately, and refuses a stale runner after deletion/recreation", async () => {
  const f = await fixture();
  await mkdir(join(f.apps, "counter"));
  const path = join(f.apps, "counter/Main.swift");
  await writeFile(path, 'import SwiftUI\nstruct ContentView: View { var body: some View { Text("Counter") } }');
  await writeFile(join(f.apps, "counter/app.json"), JSON.stringify({ permissions: { data: "readWrite" } }));
  let row = (await f.rpc("apps.catalog")).rows[0];
  const request = { id: row.id, expectedContentRevision: row.contentRevision };
  const prompt = await f.rpc("apps.open", request);
  expect(prompt.kind).toBe("permissionRequired");
  expect(prompt.token).toEqual(expect.any(String));
  await f.rpc("apps.permissions.grant", { commandId: "counter-consent", token: prompt.token });
  const opened = await f.rpc("apps.open", request);
  expect(opened.state.revision).toBe(0);
  const commit = { commandId: "counter-write", id: row.id, expectedContentRevision: row.contentRevision,
    grantRevision: opened.grantRevision, expectedRevision: 0, set: [{ key: "count", value: 7 }], remove: [] };
  expect(await f.rpc("apps.commit", commit)).toMatchObject({ revision: 1 });
  expect(await f.rpc("apps.commit", commit)).toMatchObject({ revision: 1 });
  const database = join(f.root, "tron/workspace/state/apps/counter/data.sqlite"), before = await readFile(database);
  await f.rpc("apps.deleteFiles", { commandId: "counter-delete", rowKey: row.rowKey, expectedContentRevision: row.contentRevision });
  expect(await readFile(database)).toEqual(before);
  expect((await f.rpc("apps.catalog")).rows).toHaveLength(0);
  await expect(f.rpc("apps.commit", { ...commit, commandId: "stale-write", expectedRevision: 1 })).rejects.toThrow();
  await mkdir(join(f.apps, "counter"));
  await writeFile(path, 'import SwiftUI\nstruct ContentView: View { var body: some View { Text("Counter 2") } }');
  await writeFile(join(f.apps, "counter/app.json"), JSON.stringify({ permissions: { data: "readWrite" } }));
  row = await waitFor(async () => (await f.rpc("apps.catalog")).rows[0], "recreated counter");
  const reprompt = await f.rpc("apps.open", { id: row.id, expectedContentRevision: row.contentRevision });
  expect(reprompt.kind).toBe("permissionRequired");
  await f.rpc("apps.permissions.grant", { commandId: "counter-new-consent", token: reprompt.token });
  const restored = await f.rpc("apps.open", { id: row.id, expectedContentRevision: row.contentRevision });
  expect(restored.state).toMatchObject({ revision: 1, entries: [{ key: "count", value: 7 }] });
});

it("rejects stale consent, keeps a title edit's grant, and revokes access without clearing data", async () => {
  const f = await fixture();
  await mkdir(join(f.apps, "grant"));
  const path = join(f.apps, "grant/Main.swift"), manifest = join(f.apps, "grant/app.json");
  await writeFile(path, "import SwiftUI\nstruct ContentView: View { var body: some View { Text(\"A\") } }");
  await writeFile(manifest, JSON.stringify({ permissions: { data: "readWrite" } }));
  let row = (await f.rpc("apps.catalog")).rows[0];
  const initial = await f.rpc("apps.open", { id: row.id, expectedContentRevision: row.contentRevision });
  await writeFile(path, "import SwiftUI\nstruct ContentView: View { var body: some View { Text(\"B\") } }");
  await expect(f.rpc("apps.permissions.grant", { commandId: "stale-consent", token: initial.token })).rejects.toMatchObject({ code: "conflict" });
  row = await waitFor(async () => {
    const current = (await f.rpc("apps.catalog")).rows[0];
    return current.contentRevision !== row.contentRevision ? current : undefined;
  }, "code change observed");
  const prompt = await f.rpc("apps.open", { id: row.id, expectedContentRevision: row.contentRevision });
  await f.rpc("apps.permissions.grant", { commandId: "current-consent", token: prompt.token });
  const granted = await f.rpc("apps.open", { id: row.id, expectedContentRevision: row.contentRevision });
  expect(granted.kind).toBe("swift");
  await writeFile(manifest, JSON.stringify({ title: "New title", permissions: { data: "readWrite" } }));
  row = await waitFor(async () => {
    const current = (await f.rpc("apps.catalog")).rows[0]; return current.title === "New title" ? current : undefined;
  }, "metadata-only edit");
  expect((await f.rpc("apps.open", { id: row.id, expectedContentRevision: row.contentRevision })).grantRevision).toBe(granted.grantRevision);
  await f.rpc("apps.permissions.revoke", { commandId: "grant-revoke", id: row.id });
  expect((await f.rpc("apps.open", { id: row.id, expectedContentRevision: row.contentRevision })).kind).toBe("permissionRequired");
  await expect(f.rpc("apps.commit", { commandId: "revoked-write", id: row.id, expectedContentRevision: row.contentRevision,
    grantRevision: granted.grantRevision, expectedRevision: 0, set: [{ key: "bad", value: true }] })).rejects.toMatchObject({ code: "auth_required" });
});

it("never opens a FIFO or executes an unsupported web/network entry and observes atomic replacement", async () => {
  const f = await fixture();
  for (const id of ["fifo", "web", "network", "safe"]) await mkdir(join(f.apps, id));
  execFileSync("/usr/bin/mkfifo", [join(f.apps, "fifo/Main.swift")]);
  await writeFile(join(f.apps, "web/index.html"), "<script>fetch('https://example.com')</script>");
  await writeFile(join(f.apps, "network/Main.swift"), "import SwiftUI");
  await writeFile(join(f.apps, "network/app.json"), JSON.stringify({ permissions: { network: ["https://example.com"] } }));
  await writeFile(join(f.apps, "safe/Main.swift"), "import SwiftUI");
  const rows = (await f.rpc("apps.catalog")).rows;
  expect(rows.filter((row: any) => row.status.kind === "ready").map((row: any) => row.id)).toEqual(["safe"]);
  for (const row of rows.filter((row: any) => row.id !== "safe")) {
    await expect(f.rpc("apps.open", { id: row.id, expectedContentRevision: row.contentRevision })).rejects.toMatchObject({ code: "unsupported" });
  }
  const row = rows.find((row: any) => row.id === "safe"), replacement = join(f.root, "replacement");
  await mkdir(replacement); await writeFile(join(replacement, "Main.swift"), "import SwiftUI\n// replacement");
  await rename(join(f.apps, "safe"), join(f.root, "old-safe")); await rename(replacement, join(f.apps, "safe"));
  await expect(f.rpc("apps.open", { id: row.id, expectedContentRevision: row.contentRevision })).rejects.toMatchObject({ code: "conflict" });
  const replaced = await waitFor(async () => {
    const current = (await f.rpc("apps.catalog")).rows.find((row: any) => row.id === "safe");
    return current.contentRevision !== row.contentRevision ? current : undefined;
  }, "atomic folder replacement");
  expect((await f.rpc("apps.open", { id: replaced.id, expectedContentRevision: replaced.contentRevision })).source).toContain("replacement");
});

it("does not restore revoked access when an old consent token is replayed with a fresh command id", async () => {
  const f = await fixture();
  await mkdir(join(f.apps, "replay"));
  await writeFile(join(f.apps, "replay/Main.swift"), "import SwiftUI");
  await writeFile(join(f.apps, "replay/app.json"), JSON.stringify({ permissions: { data: "readWrite" } }));
  const row = (await f.rpc("apps.catalog")).rows[0], request = { id: row.id, expectedContentRevision: row.contentRevision };
  const prompt = await f.rpc("apps.open", request);
  await f.rpc("apps.permissions.grant", { commandId: "replay-original-grant", token: prompt.token });
  await f.rpc("apps.permissions.revoke", { commandId: "replay-revoke-grant", id: row.id });
  await expect(f.rpc("apps.permissions.grant", { commandId: "replay-new-command", token: prompt.token })).rejects.toMatchObject({ code: "auth_required" });
  expect((await f.rpc("apps.open", request)).kind).toBe("permissionRequired");
});

it("initializes only the named app data directory even when its id matches an ancestor name", async () => {
  const f = await fixture();
  for (const id of ["state", "apps"]) {
    await mkdir(join(f.apps, id));
    await writeFile(join(f.apps, id, "Main.swift"), "import SwiftUI");
    await writeFile(join(f.apps, id, "app.json"), JSON.stringify({ permissions: { data: "readWrite" } }));
  }
  const rows = (await f.rpc("apps.catalog")).rows;
  for (const row of rows) {
    const request = { id: row.id, expectedContentRevision: row.contentRevision };
    const prompt = await f.rpc("apps.open", request);
    await f.rpc("apps.permissions.grant", { commandId: `consent-${row.id}`, token: prompt.token });
    expect((await f.rpc("apps.open", request)).state.revision).toBe(0);
  }
  await expect(readFile(join(f.root, "tron/workspace/state/data.sqlite"))).rejects.toMatchObject({ code: "ENOENT" });
  await expect(readFile(join(f.root, "tron/workspace/state/apps/data.sqlite"))).rejects.toMatchObject({ code: "ENOENT" });
});

it("keeps grants and SQLite CAS across restart, while a missing established database refuses restoration", async () => {
  let f = await fixture();
  await mkdir(join(f.apps, "persistent"));
  await writeFile(join(f.apps, "persistent/Main.swift"), "import SwiftUI");
  await writeFile(join(f.apps, "persistent/app.json"), JSON.stringify({ permissions: { data: "readWrite" } }));
  let row = (await f.rpc("apps.catalog")).rows[0];
  const prompt = await f.rpc("apps.open", { id: row.id, expectedContentRevision: row.contentRevision });
  await f.rpc("apps.permissions.grant", { commandId: "persist-consent", token: prompt.token });
  const opened = await f.rpc("apps.open", { id: row.id, expectedContentRevision: row.contentRevision });
  await f.rpc("apps.commit", { commandId: "persist-write", id: row.id, expectedContentRevision: row.contentRevision,
    grantRevision: opened.grantRevision, expectedRevision: 0, set: [{ key: "value", value: { count: 4 } }] });
  const old = f.registry; await old.dispose(); registries.splice(registries.indexOf(old), 1);
  f = await fixture(f.root);
  row = (await f.rpc("apps.catalog")).rows[0];
  const reopened = await f.rpc("apps.open", { id: row.id, expectedContentRevision: row.contentRevision });
  expect(reopened.state).toMatchObject({ revision: 1, entries: [{ key: "value", value: { count: 4 } }] });
  expect(reopened.grantRevision).toBe(opened.grantRevision);
  await expect(f.rpc("apps.commit", { commandId: "stale-cas", id: row.id, expectedContentRevision: row.contentRevision,
    grantRevision: opened.grantRevision, expectedRevision: 0, set: [{ key: "value", value: false }] })).rejects.toMatchObject({ code: "conflict" });
  await rm(join(f.root, "tron/workspace/state/apps/persistent/data.sqlite"));
  await expect(f.rpc("apps.open", { id: row.id, expectedContentRevision: row.contentRevision })).rejects.toMatchObject({ code: "conflict" });
});

it("distinguishes an empty Apps subfolder from lost workspace files and refuses stale file deletion", async () => {
  const f = await fixture();
  await rm(f.apps, { recursive: true });
  expect((await f.rpc("apps.catalog")).rows).toHaveLength(0);
  await mkdir(f.apps); await mkdir(join(f.apps, "note"));
  await writeFile(join(f.apps, "note/content.txt"), "original");
  const row = await waitFor(async () => (await f.rpc("apps.catalog")).rows[0], "new note");
  await writeFile(join(f.apps, "note/content.txt"), "replacement");
  await expect(f.rpc("apps.deleteFiles", { commandId: "stale-delete", rowKey: row.rowKey, expectedContentRevision: row.contentRevision })).rejects.toMatchObject({ code: "conflict" });
  expect(await readFile(join(f.apps, "note/content.txt"), "utf8")).toBe("replacement");
  await rename(join(f.root, "tron/workspace/files"), join(f.root, "saved-files"));
  await expect(f.rpc("apps.catalog")).rejects.toMatchObject({ code: "conflict" });
});

it("does not silently truncate 1,001 folders and rejects a cursor across a changed cut", async () => {
  const f = await fixture();
  for (let i = 0; i < 1001; i++) {
    const directory = join(f.apps, `entry-${i}`); await mkdir(directory); await writeFile(join(directory, "note.txt"), String(i));
  }
  let page = await f.rpc("apps.catalog");
  const first = page; const ids = new Set<string>();
  for (;;) {
    for (const row of page.rows) { expect(ids.has(row.id)).toBe(false); ids.add(row.id); }
    if (!page.nextCursor) break;
    page = await f.rpc("apps.catalog", { cursor: page.nextCursor });
  }
  expect(ids.size).toBe(1001);
  await rm(join(f.apps, "entry-0"), { recursive: true });
  await waitFor(async () => (await f.rpc("apps.catalog")).revision !== first.revision ? true : undefined, "catalog revision after external deletion");
  await expect(f.rpc("apps.catalog", { cursor: first.nextCursor })).rejects.toMatchObject({ diagnosticReason: "catalog_changed" });
});

it("supplies folder ownership instructions to a real Pi turn without a profile override", async () => {
  const f = await fixture(), project = join(f.root, "project"); await mkdir(project);
  const slot = await f.registry.create(project), model = f.faux.getModel(); await slot.setModel(model.provider, model.id);
  let context: TranscriptContext | undefined;
  f.faux.setResponses([value => { context = value; return fauxAssistantMessage("Acknowledged"); }]);
  await slot.prompt("Acknowledge.");
  await waitFor(() => context && !slot.isBusy ? true : undefined, "model receives built-in folder ownership context");
  const supplied = JSON.stringify(context!.messages);
  expect(supplied).toContain("files/apps/<id>/");
  expect(supplied).toContain("deleting files preserves saved app data");
});

it("reads and seeds orphan saved values through the real Pi app_data tool without granting access", async () => {
  const f = await fixture();
  const project = join(f.root, "project"); await mkdir(project);
  const slot = await f.registry.create(project), model = f.faux.getModel(); await slot.setModel(model.provider, model.id);
  let context: TranscriptContext | undefined;
  f.faux.setResponses([
    fauxAssistantMessage([
      fauxToolCall("app_data", { action: "state", id: "tool-data" }, { id: "data-read" }),
      fauxToolCall("app_data", { action: "commit", id: "tool-data", expectedRevision: 0, set: [{ key: "count", value: 9 }] }, { id: "data-seed" }),
      fauxToolCall("app_data", { action: "list" }, { id: "data-list" }),
      fauxToolCall("app_data", { action: "clear", id: "tool-data", expectedRevision: 1 }, { id: "data-unconfirmed-clear" }),
    ], { stopReason: "toolUse" }),
    value => { context = value; return fauxAssistantMessage("Done"); },
  ]);
  await slot.prompt("Read then seed the requested saved app values. Do not grant runtime access or authorize data clearing.");
  await waitFor(() => context && !slot.isBusy ? true : undefined, "app_data tool turn settles");
  const results = context!.messages.filter(message => message.role === "toolResult") as unknown as Array<Record<string, any>>;
  expect(results).toHaveLength(4);
  for (const result of results.slice(0, 3)) expect(result.isError, JSON.stringify(result.content)).not.toBe(true);
  expect(results[2]!.details.states).toMatchObject([{ id: "tool-data", orphan: true }]);
  expect(results[3]!.isError).toBe(true);
  expect(await f.rpc("apps.state", { id: "tool-data" })).toMatchObject({ revision: 1, entries: [{ key: "count", value: 9 }] });
  expect((await f.rpc("apps.catalog")).rows).toHaveLength(0);
  await expect(readFile(join(f.root, "tron/workspace/state/app-permissions/tool-data.json"))).rejects.toMatchObject({ code: "ENOENT" });
});

it("refuses a stale app_data inventory cursor instead of silently omitting a newly inserted id", async () => {
  const f = await fixture(), project = join(f.root, "project"); await mkdir(project);
  for (let index = 0; index < 51; index++) await f.rpc("apps.state", { id: `saved-${String(index).padStart(2, "0")}` });
  const slot = await f.registry.create(project), model = f.faux.getModel(); await slot.setModel(model.provider, model.id);
  let context: TranscriptContext | undefined;
  f.faux.setResponses([
    fauxAssistantMessage([fauxToolCall("app_data", { action: "list" }, { id: "inventory-first" })], { stopReason: "toolUse" }),
    async value => {
      const first = value.messages.findLast(message => message.role === "toolResult") as unknown as Record<string, any>;
      await f.rpc("apps.state", { id: "inserted-before-cursor" });
      return fauxAssistantMessage([fauxToolCall("app_data", { action: "list", cursor: first.details.nextCursor }, { id: "inventory-stale" })], { stopReason: "toolUse" });
    },
    value => { context = value; return fauxAssistantMessage("Done"); },
  ]);
  await slot.prompt("List the saved-data inventory, following its cursor.");
  await waitFor(() => context && !slot.isBusy ? true : undefined, "inventory tool turn settles");
  const results = context!.messages.filter(message => message.role === "toolResult") as unknown as Array<Record<string, any>>;
  expect(results[0]!.details.states).toHaveLength(50);
  expect(results[1]!.isError).toBe(true);
  expect((await f.rpc("apps.catalog")).rows).toHaveLength(0);
});

it("manages orphan saved data with explicit clear authorization and revision CAS, without creating membership or grants", async () => {
  const f = await fixture();
  expect(await f.rpc("apps.state", { id: "orphan" })).toMatchObject({ revision: 0, entries: [] });
  expect((await f.rpc("apps.catalog")).rows).toHaveLength(0);
  await expect(f.rpc("apps.reset", { commandId: "orphan-unconfirmed-clear", id: "orphan", expectedRevision: 0, confirmed: false })).rejects.toMatchObject({ code: "invalid_request" });
  expect(await f.rpc("apps.reset", { commandId: "orphan-confirmed-clear", id: "orphan", expectedRevision: 0, confirmed: true })).toMatchObject({ revision: 1 });
  await expect(f.rpc("apps.reset", { commandId: "orphan-stale-clear", id: "orphan", expectedRevision: 0, confirmed: true })).rejects.toMatchObject({ code: "conflict" });
  expect((await f.rpc("apps.catalog")).rows).toHaveLength(0);
  await expect(readFile(join(f.root, "tron/workspace/state/app-permissions/orphan.json"))).rejects.toMatchObject({ code: "ENOENT" });
});

it("never removes the live directory when an external writer replaces it after validation", async () => {
  const root = await realpath(await mkdtemp(join(tmpdir(), "tron-apps-delete-race-"))); roots.push(root);
  const workspace = new TronWorkspace(join(root, "tron")); await workspace.initialize();
  const apps = join(root, "tron/workspace/files/apps"), directory = join(apps, "victim");
  const store = new AppsFolderStore(workspace, join(root, "tron"));
  let validated = false, replaced = false;
  const originalRead = folderFormat.readAppEntry;
  const originalResolve = store.index.entryForDeletion.bind(store.index);
  const resolveHook = vi.spyOn(store.index, "entryForDeletion").mockImplementation(async key => {
    const entry = await originalResolve(key); validated = true; return entry;
  });
  // Wrap the real filesystem reader, without fabricating its returned facts.
  // The external writer runs exactly after the last validation read and before
  // the store resumes at rename; no production test hook or timing race is used.
  const validationHook = vi.spyOn(folderFormat, "readAppEntry").mockImplementation(async (path, name) => {
    const entry = await originalRead(path, name);
    if (validated && !replaced && path === apps && name === "victim") {
      replaced = true;
      await rename(directory, join(root, "original"));
      await mkdir(directory); await writeFile(join(directory, "note.txt"), "replacement");
    }
    return entry;
  });
  try {
    await mkdir(directory, { recursive: true, mode: 0o700 }); await writeFile(join(directory, "note.txt"), "original");
    const row = (await store.index.catalog()).rows[0]!;
    await expect(store.deleteFiles(row.rowKey, row.contentRevision)).rejects.toMatchObject({ code: expect.stringMatching(/conflict|unsupported/) });
    expect(replaced).toBe(true);
    expect(await readFile(join(directory, "note.txt"), "utf8")).toBe(replaced ? "replacement" : "original");
  } finally {
    validationHook.mockRestore(); resolveHook.mockRestore(); await store.dispose(); await workspace.dispose();
  }
});

it("keeps the replacement real watcher alive when a retired watch reports a delayed reset", async () => {
  const root = await realpath(await mkdtemp(join(tmpdir(), "tron-apps-watch-"))); roots.push(root);
  const workspace = new TronWorkspace(join(root, "tron")); await workspace.initialize();
  const apps = join(root, "tron/workspace/files/apps");
  const requests: FolderWatchRequest[] = [], watchers: FSWatcher[] = [], active = new Set<FSWatcher>();
  let secondClosed = false, secondChanged = false;
  const index = new AppsFolderIndex(workspace, () => {}, request => {
    requests.push(request);
    const watcher = watch(request.root, { recursive: true, persistent: false }, (_event, filename) => {
      request.onEvent(typeof filename === "string" ? filename : null);
      if (watchers[1] === watcher) secondChanged = true;
    });
    watcher.on("error", () => request.onReset("error"));
    watcher.on("close", () => { active.delete(watcher); if (watchers[1] === watcher) secondClosed = true; });
    watchers.push(watcher); active.add(watcher);
    return { close: () => watcher.close() };
  });
  try {
    await mkdir(apps, { recursive: true, mode: 0o700 });
    await index.catalog();
    requests[0]!.onReset("error");
    await waitFor(() => watchers.length >= 2 ? true : undefined, "replacement watch attached");
    requests[0]!.onReset("error");
    await mkdir(join(apps, "new-entry"));
    await waitFor(() => secondClosed || secondChanged ? true : undefined, "real watcher closes or observes new entry");
    expect(secondClosed).toBe(false);
    await writeFile(join(apps, "new-entry/note.txt"), "new content");
    await waitFor(async () => (await index.catalog()).rows.some(row => row.id === "new-entry" && row.status.kind === "ready") ? true : undefined, "replacement watcher membership");
    await index.dispose();
    await waitFor(() => active.size === 0 ? true : undefined, "all real watch handles closed");
  } finally { await index.dispose(); for (const watcher of active) watcher.close(); await workspace.dispose(); }
});

it("serves the real filesystem cut and recovers observation after the first watcher construction fails", async () => {
  const root = await realpath(await mkdtemp(join(tmpdir(), "tron-apps-watch-start-"))); roots.push(root);
  const workspace = new TronWorkspace(join(root, "tron")); await workspace.initialize();
  const apps = join(root, "tron/workspace/files/apps");
  let attempts = 0, observed = false;
  const watchers: FSWatcher[] = [];
  const index = new AppsFolderIndex(workspace, () => {}, request => {
    if (++attempts === 1) throw new Error("Injected backend construction failure");
    const watcher = watch(request.root, { recursive: true, persistent: false }, (_event, filename) => {
      observed = true; request.onEvent(typeof filename === "string" ? filename : null);
    });
    watcher.on("error", () => request.onReset("error")); watchers.push(watcher);
    return { close: () => watcher.close() };
  });
  try {
    await mkdir(join(apps, "note"), { recursive: true, mode: 0o700 });
    await writeFile(join(apps, "note/note.txt"), "before recovery");
    expect((await index.catalog()).rows).toHaveLength(1);
    await waitFor(() => watchers.length ? true : undefined, "watch construction recovers without a read");
    await writeFile(join(apps, "note/note.txt"), "after recovery");
    await waitFor(() => observed ? true : undefined, "recovered OS watcher observes external edit");
    const row = (await index.catalog()).rows[0]!;
    expect((await index.requireEntry("note", row.contentRevision)).files.get("note.txt")!.toString()).toBe("after recovery");
  } finally { await index.dispose(); for (const watcher of watchers) watcher.close(); await workspace.dispose(); }
});

it("keeps unsafe names and entry links as isolated broken rows, and watches a repair without restarting", async () => {
  const f = await fixture();
  await mkdir(join(f.apps, "Bad Name"));
  await symlink(f.root, join(f.apps, "linked"));
  await mkdir(join(f.apps, "repair")); await writeFile(join(f.apps, "repair/app.json"), "{bad");
  let rows = (await f.rpc("apps.catalog")).rows;
  expect(rows).toHaveLength(3);
  expect(rows.every((row: any) => row.status.kind === "cannotOpen")).toBe(true);
  expect(rows.find((row: any) => row.title === "Bad Name").id).toBeUndefined();
  await rm(join(f.apps, "repair/app.json")); await writeFile(join(f.apps, "repair/note.txt"), "repaired");
  rows = await waitFor(async () => {
    const rows = (await f.rpc("apps.catalog")).rows;
    return rows.find((row: any) => row.id === "repair").status.kind === "ready" ? rows : undefined;
  }, "repair reaches catalog");
  expect(rows.filter((row: any) => row.status.kind === "ready")).toHaveLength(1);
});
