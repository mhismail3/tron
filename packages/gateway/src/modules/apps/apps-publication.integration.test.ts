import { createHash, randomUUID } from "node:crypto";
import { Readable } from "node:stream";
import { fstatSync } from "node:fs";
import type { AppPublicationFile } from "./apps-publication.js";
import { lstat, mkdir, mkdtemp, readFile, readdir, realpath, rename, rm, symlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { directoryPublisher, type DirectoryPublisher } from "../../machine/directory-publication.js";
import { afterEach, expect, inject, it } from "vitest";
import { TronWorkspace } from "../../workspace/tron-workspace.js";
import { AppsFolderIndex } from "./apps-folder-index.js";
import { AppsFolderStore } from "./apps-folder-store.js";
import { ModuleHost } from "../../kernel/host/module-host.js";
import { workspaceModule } from "../../workspace/workspace-module.js";
import { createAppsModule } from "./module.js";
import type { ByteLease } from "../../util/byte-stream.js";
import { awaitsWithin, waitFor } from "../../../test-support/wait-for.js";

const cleanup: Array<() => Promise<void>> = [];
afterEach(async () => { for (const close of cleanup.splice(0).reverse()) await close(); });
async function fixture(decorate: (publish: DirectoryPublisher, files: string) => DirectoryPublisher = value => value) {
  const root = await realpath(await mkdtemp(join(tmpdir(), "tron-app-publish-")));
  cleanup.push(() => rm(root, { recursive: true, force: true }));
  const workspace = new TronWorkspace(join(root, "tron")); await workspace.initialize();
  const files = join(root, "tron/workspace/files"); await mkdir(files, { mode: 0o700 });
  const publish = decorate(directoryPublisher(inject("nativePublicationBinary")), files);
  const index = new AppsFolderIndex(workspace, undefined, undefined, publish);
  cleanup.push(async () => { await index.dispose(); await workspace.dispose(); });
  return { root, workspace, files, index };
}
function file(path: string, text: string) {
  const bytes = Buffer.from(text);
  return { path, size: bytes.length, digest: createHash("sha256").update(bytes).digest("hex"), acquire: async (): Promise<ByteLease> => ({
    stream: Readable.from([bytes]), mimeType: "text/plain", size: bytes.length, totalSize: bytes.length,
    rangeStart: 0, rangeEnd: bytes.length - 1, release: async () => {},
  }) };
}
const plan = (text = "immutable") => ({ kind: "document" as const, entry: "note.txt", title: "Original", files: [file("note.txt", text)] });

it("disposes while the accepted byte stream is stalled without a next chunk", async () => {
  const f = await fixture(), stream = new Readable({ read() {} });
  let entered!: () => void; const admission = new Promise<void>(resolve => { entered = resolve; });
  const input = plan(); input.files[0]!.acquire = async () => { entered(); return { stream, size: 9, totalSize: 9, rangeStart: 0, rangeEnd: 8, mimeType: "text/plain", release: async () => { stream.destroy(); } }; };
  const publishing = f.index.publish(input); await admission; const closing = f.index.dispose();
  try {
    const result = await awaitsWithin(Promise.allSettled([publishing, closing]), "publication disposal must retire a stalled stream");
    expect(result.map(value => value.status)).toEqual(["rejected", "fulfilled"]);
  }
  finally { stream.destroy(); await Promise.allSettled([publishing, closing]); }
});

it("cancels source acquisition through its publication owner before waiting for lane disposal", async () => {
  const f = await fixture(); let entered!: () => void, retire!: (error: Error) => void;
  const admission = new Promise<void>(resolve => { entered = resolve; });
  const source: AppPublicationFile = { ...file("note.txt", "immutable"), acquire: signal => new Promise((_, reject) => {
    retire = reject; signal.addEventListener("abort", () => reject(signal.reason), { once: true }); entered();
  }) };
  const publishing = f.index.publish({ ...plan(), files: [source] }); await admission; const closing = f.index.dispose();
  try { expect((await awaitsWithin(Promise.allSettled([publishing, closing]), "publication acquisition cancellation")).map(result => result.status)).toEqual(["rejected", "fulfilled"]); }
  finally { retire(new Error("fixture release")); await Promise.allSettled([publishing, closing]); }
});
it("keeps parent descriptors until an accepted native completion joins, even after disposal", async () => {
  let entered!: () => void, release!: () => void, descriptor = -1, id = "";
  const admission = new Promise<void>(resolve => { entered = resolve; }), gate = new Promise<void>(resolve => { release = resolve; });
  const f = await fixture(native => async (...args) => {
    const accepted = await native(...args); descriptor = args[2]; id = args[3]; entered(); await gate; return accepted;
  });
  await mkdir(join(f.files, "apps"));
  const publishing = f.index.publish(plan()); await admission; const closing = f.index.dispose();
  try { expect(fstatSync(descriptor).isDirectory()).toBe(true); }
  finally { release(); await Promise.allSettled([publishing, closing]); }
  expect(() => fstatSync(descriptor)).toThrow();
  expect(await readFile(join(f.files, "apps", id, "note.txt"), "utf8")).toBe("immutable");
});

it("removes its destination-filesystem private stage when cancelled mid-copy without a partial destination", async () => {
  let prefix = true;
  const f = await fixture(), stream = new Readable({ read() { if (prefix) { prefix = false; this.push(Buffer.from("imm")); } } });
  let entered!: () => void; const admission = new Promise<void>(resolve => { entered = resolve; });
  const input = plan(); input.files[0]!.acquire = async () => { entered(); return { stream, size: 9, totalSize: 9, rangeStart: 0, rangeEnd: 8, mimeType: "text/plain", release: async () => { stream.destroy(); } }; };
  const publishing = f.index.publish(input); void publishing.catch(() => {}); await admission;
  const stageRoot = join(f.root, "tron/workspace/state/apps-publication-staging");
  try {
    const stages = await readdir(stageRoot); expect(stages).toHaveLength(1);
    const bundles = await readdir(join(stageRoot, stages[0]!, "files/apps"));
    const partial = join(stageRoot, stages[0]!, "files/apps", bundles[0]!, "note.txt");
    await waitFor(async () => (await lstat(partial).catch(() => undefined))?.size === 3, "partial staged bytes before cancellation");
  }
  finally { await f.index.dispose(); await Promise.allSettled([publishing]); stream.destroy(); }
  expect(await readdir(stageRoot)).toEqual([]);
  expect(await readdir(join(f.files, "apps")).catch(error => error.code)).toBe("ENOENT");
});
it("recovers only orphaned private stages at index startup, not user entries", async () => {
  const f = await fixture(), stageRoot = join(f.root, "tron/workspace/state/apps-publication-staging");
  await mkdir(stageRoot, { recursive: true, mode: 0o700 });
  const orphan = join(stageRoot, `stage-${randomUUID()}`); await mkdir(orphan, { mode: 0o700 }); await writeFile(join(orphan, "partial"), "orphan");
  await mkdir(join(f.files, "apps/user"), { recursive: true }); await writeFile(join(f.files, "apps/user/note.txt"), "retained");
  await f.index.dispose(); await f.workspace.dispose();
  const apps = createAppsModule(), modules = await ModuleHost.start([workspaceModule, apps], { tronHome: join(f.root, "tron"), log: { log: () => {} } }, []);
  const workspace = modules.contract(workspaceModule), lifecycles = modules.observers("kernelLifecycle").map(factory => factory());
  cleanup.push(async () => { for (const lifecycle of lifecycles) lifecycle.closing(); for (const lifecycle of lifecycles) await lifecycle.dispose(); await modules.stop(); await workspace.dispose(); });
  for (const lifecycle of lifecycles) await lifecycle.initialize();
  await workspace.initialize(); for (const lifecycle of lifecycles) lifecycle.started();
  await modules.contract(apps).index.catalog(); // Joins the startup recovery cut without requesting recovery itself.
  expect(await readdir(stageRoot)).toEqual([]);
  expect(await readFile(join(f.files, "apps/user/note.txt"), "utf8")).toBe("retained");
});
it("refuses unknown private-root entries instead of deleting unowned data or losing catalog siblings", async () => {
  const f = await fixture(), stageRoot = join(f.root, "tron/workspace/state/apps-publication-staging");
  await mkdir(stageRoot, { recursive: true, mode: 0o700 }); await writeFile(join(stageRoot, "unknown.txt"), "retain");
  await mkdir(join(f.files, "apps/known"), { recursive: true }); await writeFile(join(f.files, "apps/known/note.txt"), "sibling");
  await expect(f.index.recoverPublications()).rejects.toMatchObject({ code: "conflict" });
  expect(await readFile(join(stageRoot, "unknown.txt"), "utf8")).toBe("retain");
  expect((await f.index.catalog()).rows.map(row => row.id)).toEqual(["known"]);
});
it("keeps staging cleanup independent of a replaced files path", async () => {
  const f = await fixture(), input = plan(), original = input.files[0]!.acquire;
  input.files[0]!.acquire = async () => {
    await rename(f.files, `${f.files}-parked`); await mkdir(f.files); await writeFile(join(f.files, "keep"), "replacement");
    return original();
  };
  await expect(f.index.publish(input)).rejects.toMatchObject({ code: "conflict" });
  expect(await readdir(join(f.root, "tron/workspace/state/apps-publication-staging"))).toEqual([]);
  expect(await readFile(join(f.files, "keep"), "utf8")).toBe("replacement");
});

it("drains store shutdown when an open holds its mutex behind a stalled publication", async () => {
  const f = await fixture(); await f.index.dispose();
  const store = new AppsFolderStore(f.workspace, join(f.root, "tron")); cleanup.push(() => store.dispose());
  await mkdir(join(f.files, "apps/known"), { recursive: true }); await writeFile(join(f.files, "apps/known/note.txt"), "retained");
  const row = (await store.index.catalog()).rows[0]!;
  const stream = new Readable({ read() {} }); let admitted!: () => void, openEntered!: () => void;
  const admission = new Promise<void>(resolve => { admitted = resolve; }), openingCut = new Promise<void>(resolve => { openEntered = resolve; });
  const input = plan(); input.files[0]!.acquire = async () => { admitted(); return { stream, size: 9, totalSize: 9, rangeStart: 0, rangeEnd: 8, mimeType: "text/plain", release: async () => { stream.destroy(); } }; };
  const requireEntry = store.index.requireEntry.bind(store.index);
  store.index.requireEntry = async (...args) => { openEntered(); return requireEntry(...args); };
  const publishing = store.index.publish(input); await admission;
  const opening = store.open(row.id!, row.contentRevision, "phone"); await openingCut;
  const closing = store.dispose();
  try { await awaitsWithin(Promise.allSettled([publishing, opening, closing]), "Apps store shutdown must cancel before waiting for its mutex"); }
  finally { stream.destroy(); await Promise.allSettled([publishing, opening, closing]); }
  expect(await readdir(join(f.root, "tron/workspace/state/apps-publication-staging"))).toEqual([]);
  expect(await readFile(join(f.files, "apps/known/note.txt"), "utf8")).toBe("retained");
});

it("copies a large admitted chunk exactly and refuses an oversized chunk without another destination", async () => {
  const f = await fixture(), bytes = Buffer.alloc(1024 * 1024, 0x61), digest = createHash("sha256").update(bytes).digest("hex");
  const source: AppPublicationFile = { path: "note.txt", size: bytes.length, digest, acquire: async () => ({
    stream: Readable.from([bytes]), size: bytes.length, totalSize: bytes.length, rangeStart: 0, rangeEnd: bytes.length - 1, mimeType: "text/plain", release: async () => {},
  }) };
  const row = await f.index.publish({ ...plan(), files: [source] });
  expect(createHash("sha256").update(await readFile(join(f.files, "apps", row.id, "note.txt"))).digest("hex")).toBe(digest);
  await expect(f.index.publish({ ...plan(), files: [{ ...source, size: 1 }] })).rejects.toMatchObject({ code: "conflict" });
  expect((await f.index.catalog()).rows).toHaveLength(1);
});

it("publishes through the index's real native port, bootstraps only apps, and immediately admits exact copied bytes", async () => {
  const f = await fixture(), row = await f.index.publish(plan());
  expect(row.id).toMatch(/^display-[0-9a-f]{64}$/);
  expect((await f.index.catalog()).rows).toEqual([row]);
  expect(await readFile(join(f.files, "apps", row.id!, "note.txt"), "utf8")).toBe("immutable");
  expect(await f.index.requireEntry(row.id!, row.contentRevision)).toMatchObject({ entry: "note.txt", payload: { kind: "artifact" } });
});
it("serializes identical copies, ignores presentation metadata in identity, and refuses edits at an existing digest", async () => {
  const f = await fixture(), rows = await Promise.all([f.index.publish(plan()), f.index.publish({ ...plan(), title: "Another chat" })]);
  expect(rows[0]).toEqual(rows[1]); expect((await f.index.catalog()).rows).toHaveLength(1);
  const path = join(f.files, "apps", rows[0]!.id!, "note.txt"); await writeFile(path, "user changed");
  await expect(f.index.publish(plan())).rejects.toMatchObject({ code: "conflict" });
  expect(await readFile(path, "utf8")).toBe("user changed");
});
it("copies the admitted dependency set and refuses forged bytes before publishing any row", async () => {
  const f = await fixture(), bytes = file("note.txt", "original");
  bytes.acquire = file("note.txt", "changed!").acquire;
  await expect(f.index.publish({ ...plan(), files: [bytes] })).rejects.toMatchObject({ code: "conflict" });
  expect((await f.index.catalog()).rows).toEqual([]);
  const row = await f.index.publish({ ...plan(), files: [file("note.txt", "original"), file("assets/extra.txt", "dependency")] });
  expect(await readFile(join(f.files, "apps", row.id!, "assets/extra.txt"), "utf8")).toBe("dependency");
});
it("does not accept publication into a replaced canonical parent", async () => {
  const f = await fixture(), input = plan(), original = input.files[0]!.acquire;
  input.files[0]!.acquire = async () => {
    await rename(f.files, `${f.files}-parked`); await symlink(`${f.files}-parked`, f.files);
    return original();
  };
  await expect(f.index.publish(input)).rejects.toMatchObject({ code: "conflict" });
});

it("creates the files namespace only for an explicit publication, never recreates a lost workspace", async () => {
  const f = await fixture(); await rm(f.files, { recursive: true });
  const row = await f.index.publish(plan()); expect((await f.index.catalog()).rows).toEqual([row]);
  await rename(join(f.root, "tron/workspace"), join(f.root, "tron/workspace-parked"));
  await expect(f.index.publish(plan("new"))).rejects.toMatchObject({ code: "conflict" });
});
it("preserves an external empty digest directory created at native admission", async () => {
  let occupied = "";
  const f = await fixture((native, files) => async (source, leaf, destination, name) => {
    occupied = join(files, "apps", name); await mkdir(occupied);
    return native(source, leaf, destination, name);
  });
  await mkdir(join(f.files, "apps"));
  await expect(f.index.publish(plan())).rejects.toMatchObject({ code: "conflict" });
  expect(await readFile(join(occupied, "note.txt"), "utf8").catch(error => error.code)).toBe("ENOENT");
});
it("refuses success if an external actor replaces the Apps parent after native completion", async () => {
  const f = await fixture((native, files) => async (...args) => {
    const accepted = await native(...args);
    await rename(join(files, "apps"), join(files, "apps-parked")); await mkdir(join(files, "apps"));
    return accepted;
  });
  await mkdir(join(f.files, "apps"));
  await expect(f.index.publish(plan())).rejects.toMatchObject({ code: "conflict" });
  expect((await f.index.catalog()).rows).toEqual([]);
});
it("joins disposal during byte admission without publishing later work", async () => {
  const f = await fixture(), input = plan(), original = input.files[0]!.acquire;
  let closing: Promise<void> | undefined;
  input.files[0]!.acquire = async () => { closing = f.index.dispose(); return original(); };
  await expect(f.index.publish(input)).rejects.toMatchObject({ code: "conflict" }); await closing;
  expect(await readFile(join(f.files, "apps"), "utf8").catch(error => error.code)).toBe("ENOENT");
});
