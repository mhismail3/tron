import { mkdir, mkdtemp, open, readFile, realpath, rename, rm, symlink, unlink, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { afterEach, expect, it, vi } from "vitest";
import * as files from "./apps-folder-files.js";
import { TronWorkspace } from "../../workspace/tron-workspace.js";
import { AppsFolderStore } from "./apps-folder-store.js";

const cleanup: Array<() => Promise<void>> = [];
afterEach(async () => { vi.restoreAllMocks(); for (const close of cleanup.splice(0).reverse()) await close(); });
async function fixture() {
  const root = await realpath(await mkdtemp(join(tmpdir(), "tron-app-preview-")));
  cleanup.push(() => rm(root, { recursive: true, force: true }));
  const workspace = new TronWorkspace(join(root, "tron")); await workspace.initialize();
  const store = new AppsFolderStore(workspace, join(root, "tron"));
  cleanup.push(async () => { await store.dispose(); await workspace.dispose(); });
  const directory = join(root, "tron/workspace/files/apps/preview"); await mkdir(directory, { recursive: true });
  return { root, workspace, store, directory };
}

it("admits an 80 MiB video and reads only its requested range from the index-owned file lease", async () => {
  const f = await fixture(), path = join(f.directory, "clip.mp4");
  const header = Buffer.from("000000186674797069736f6d", "hex"), file = await open(path, "w");
  try { await file.write(header); await file.truncate(80 * 1024 * 1024); } finally { await file.close(); }
  const row = (await f.store.index.catalog()).rows[0]!;
  expect(row.status.kind).toBe("ready");
  const projection = await f.store.open("preview", row.contentRevision, "phone");
  expect(projection).toMatchObject({ kind: "artifact", artifact: { media: "video", mimeType: "video/mp4", size: 80 * 1024 * 1024 } });
  expect(projection).not.toHaveProperty("source");
  const lease = await f.store.acquireArtifact("preview", row.contentRevision, { start: 4, end: 11 });
  try {
    const chunks: Buffer[] = []; for await (const chunk of lease.stream) chunks.push(Buffer.from(chunk));
    expect(Buffer.concat(chunks)).toEqual(header.subarray(4, 12));
    expect(lease).toMatchObject({ size: 8, totalSize: 80 * 1024 * 1024, rangeStart: 4, rangeEnd: 11 });
  } finally { await lease.release(); }
});

it("refuses a namespace-ancestor symlink swapped in after range admission", async () => {
  const f = await fixture(); await writeFile(join(f.directory, "page.pdf"), "%PDF-1.7\n");
  const row = (await f.store.index.catalog()).rows[0]!, parent = dirname(f.directory), parked = `${parent}-parked`, original = files.openAppFile;
  vi.spyOn(files, "openAppFile").mockImplementationOnce(async (root, path) => {
    await rename(parent, parked); await symlink(parked, parent);
    try { return await original(root, path); }
    finally { await unlink(parent); await rename(parked, parent); }
  });
  await expect(f.store.acquireArtifact("preview", row.contentRevision)).rejects.toMatchObject({ code: "invalid_request" });
});

it("keeps PDF bytes out of the JSON open projection and preserves exact binary bytes in its lease", async () => {
  const f = await fixture(), bytes = Buffer.concat([Buffer.from("%PDF-1.7\n"), Buffer.from([0, 255, 128, 13, 10])]);
  await writeFile(join(f.directory, "page.pdf"), bytes);
  const row = (await f.store.index.catalog()).rows[0]!;
  expect(await f.store.open("preview", row.contentRevision, "phone")).toMatchObject({ kind: "artifact", artifact: { media: "pdf", size: bytes.length } });
  const lease = await f.store.acquireArtifact("preview", row.contentRevision);
  try { const chunks: Buffer[] = []; for await (const chunk of lease.stream) chunks.push(Buffer.from(chunk)); expect(Buffer.concat(chunks)).toEqual(bytes); }
  finally { await lease.release(); }
  await expect(f.store.acquireArtifact("preview", row.contentRevision, { start: bytes.length })).rejects.toMatchObject({ code: "invalid_request", details: { rangeUnsatisfiable: true, totalSize: bytes.length } });
});

it("refuses a stale artifact and an in-place change after lease admission without granting code execution", async () => {
  const f = await fixture(), path = join(f.directory, "note.txt"); await writeFile(path, "original");
  const row = (await f.store.index.catalog()).rows[0]!, lease = await f.store.acquireArtifact("preview", row.contentRevision);
  try {
    await writeFile(path, "replacement");
    await expect((async () => { for await (const _ of lease.stream) { /* Consume actual stream errors. */ } })()).rejects.toMatchObject({ code: "conflict" });
  } finally { await lease.release(); }
  await expect(f.store.acquireArtifact("preview", row.contentRevision)).rejects.toMatchObject({ code: "conflict" });
  expect(await readFile(path, "utf8")).toBe("replacement");
});

it("aborts disposable reads without leaving a descriptor or consuming reader capacity", async () => {
  const f = await fixture(); await writeFile(join(f.directory, "note.txt"), "content");
  const row = (await f.store.index.catalog()).rows[0]!;
  for (let i = 0; i < 6; i++) {
    const cancelled = new AbortController(); cancelled.abort();
    await expect(f.store.acquireArtifact("preview", row.contentRevision, undefined, cancelled.signal)).rejects.toMatchObject({ name: "AbortError" });
  }
  const active = new AbortController(), lease = await f.store.acquireArtifact("preview", row.contentRevision, undefined, active.signal);
  active.abort(); await lease.release(); expect(lease.stream.destroyed).toBe(true);
  const readers = await Promise.all(Array.from({ length: 4 }, () => f.store.acquireArtifact("preview", row.contentRevision)));
  await Promise.all(readers.map(reader => reader.release()));
});

it("bounds active leases, releases them on disposal and never serves Swift through a preview lease", async () => {
  const f = await fixture(); await writeFile(join(f.directory, "note.txt"), "content");
  const row = (await f.store.index.catalog()).rows[0]!, leases = [];
  for (let i = 0; i < 4; i++) leases.push(await f.store.acquireArtifact("preview", row.contentRevision));
  await expect(f.store.acquireArtifact("preview", row.contentRevision)).rejects.toMatchObject({ code: "busy" });
  await leases[0]!.release(); const replacement = await f.store.acquireArtifact("preview", row.contentRevision);
  await f.store.dispose(); expect(replacement.stream.destroyed).toBe(true);
  await Promise.all(leases.map(lease => lease.release())); await replacement.release();
  await writeFile(join(f.directory, "Main.swift"), "import SwiftUI");
  const next = new AppsFolderStore(f.workspace, join(f.root, "tron"));
  try { const swift = (await next.index.catalog()).rows[0]!; await expect(next.acquireArtifact("preview", swift.contentRevision)).rejects.toMatchObject({ code: "unsupported" }); }
  finally { await next.dispose(); }
});
