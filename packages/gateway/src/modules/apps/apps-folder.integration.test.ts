import { mkdir, mkdtemp, readFile, realpath, rename, rm, symlink, writeFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it } from "vitest";
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
  const registry = await createTestRegistry({ agentDir, tronHome, trust: new TrustService(agentDir),
    broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {} });
  registries.push(registry); await registry.initialize(); await registry.initializeBlobStorage();
  const service = new GatewayService({ display: displayOwnerOf(registry),
    config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome, agentDir },
    sessions: registry, modules: registry.moduleHost, receipts: new CommandReceiptStore(tronHome), broadcast: () => {},
    globalProviderResources: { withStableSnapshot: async (operation: () => Promise<unknown>) => operation(), requestReload: () => {} },
  } as unknown as GatewayServiceDependencies);
  const apps = join(tronHome, "workspace/files/apps");
  await mkdir(apps, { recursive: true, mode: 0o700 });
  return { root, apps, service, registry, rpc: async (method: string, params: Record<string, unknown> = {}) => await service.invoke(phone, method, params) as Record<string, any> };
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
