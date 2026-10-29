import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { lstat, mkdir, open, type FileHandle } from "node:fs/promises";
import { dirname, join } from "node:path";
import { addAbortSignal } from "node:stream";
import { finished } from "node:stream/promises";
import { GatewayError } from "../../errors.js";
import type { DirectoryPublisher } from "../../machine/directory-publication.js";
import type { ByteLease } from "../../util/byte-stream.js";
import { syncDurably } from "../../util/durable-json.js";
import type { TronWorkspace } from "../../workspace/tron-workspace.js";
import type { AppPublicationStaging } from "./apps-publication-staging.js";
import { appFileFormat } from "./apps-file-format.js";
import { fileIdentity, safeRelative, snapshotDigest } from "./apps-folder-files.js";
import { hash, isReadyAppEntry, readAppEntry, type AppKind, type AppPermissions, type ReadyAppEntry } from "./apps-folder-format.js";

/** Producers must cancel pending acquisition on signal; after acquisition this
 * owner cancels the readable and joins the lease's physical release. */
export interface AppPublicationFile { path: string; size: number; digest: string; acquire(signal: AbortSignal): Promise<ByteLease> }
export interface AppPublication { entry: string; kind: AppKind; title?: string; icon?: string; permissions?: AppPermissions; files: readonly AppPublicationFile[] }
function conflict(): never { throw new GatewayError("conflict", "Publication bytes or canonical namespace changed; display again"); }
function key(kind: AppKind, entry: string, p: AppPermissions, files: Array<[string, string]>): string {
  return hash(JSON.stringify([kind, entry, { data: p.data, feeds: [...p.feeds].sort(), network: [...p.network].sort() }, files.sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)]));
}
function entryKey(entry: ReadyAppEntry): string {
  return key(entry.row.kind, entry.entry, entry.permissions, [...entry.files].filter(([name]) => name !== "app.json").map(([name, file]) => [name, snapshotDigest(file)]));
}
/** Index-internal write scope. No registry, manifest decoder or execution grant.
 * Staging is private on the destination filesystem, outside user membership. Never
 * substitute copy/overwrite for native exclusive rename. */
export async function publishApp(workspace: TronWorkspace, input: AppPublication, publish: DirectoryPublisher, active: () => void, signal: AbortSignal, staging: AppPublicationStaging): Promise<ReadyAppEntry> {
  active();
  const files = input.files.map(file => ({ ...file })), entry = input.entry, kind = input.kind;
  const p = input.permissions ? { data: input.permissions.data, feeds: [...input.permissions.feeds], network: [...input.permissions.network] } : { data: "none" as const, feeds: [], network: [] };
  let total = 0;
  if (!files.length || files.length > 999 || !safeRelative(entry)) throw new GatewayError("invalid_request", "Invalid publication bundle");
  const names = new Set<string>(), parents = new Set<string>();
  for (const file of files) {
    if (!safeRelative(file.path) || file.path === "app.json" || file.path.length > 4096 || file.path.split("/").length > 64 || names.has(file.path)
      || !/^[0-9a-f]{64}$/.test(file.digest) || !Number.isSafeInteger(file.size) || file.size < 0
      || file.size > (appFileFormat(file.path)?.maximumBytes ?? 25 * 1024 * 1024)) throw new GatewayError("invalid_request", "Invalid publication file");
    names.add(file.path); total += file.size;
    const parts = file.path.split("/");
    for (let i = 1; i < parts.length; i++) parents.add(parts.slice(0, i).join("/"));
    if (parents.size > 1999) throw new GatewayError("invalid_request", "Publication has too many directories");
  }
  if (!names.has(entry) || total > 2 * 1024 ** 3 + 32 * 1024 ** 2 || ["swift", "web"].includes(kind) && total > 32 * 1024 ** 2) throw new GatewayError("invalid_request", "Publication exceeds its bounds");
  const digest = key(kind, entry, p, files.map(file => [file.path, file.digest])), id = `display-${digest}`;
  const manifest = JSON.stringify({ entry, kind, permissions: p, ...(input.title === undefined ? {} : { title: input.title }), ...(input.icon === undefined ? {} : { icon: input.icon }) });
  if (Buffer.byteLength(manifest) > 32768) throw new GatewayError("invalid_request", "Publication manifest exceeds its bounds");
  const descriptor = await workspace.describe();
  if (!descriptor.available) conflict();
  const scope = await staging.create(), stage = scope.path;
  const bundle = join(stage, "files/apps", id), handles: FileHandle[] = [], canonical: FileHandle[] = [];
  try {
    await mkdir(bundle, { recursive: true, mode: 0o700 });
    const directories = new Set([stage, join(stage, "files"), join(stage, "files/apps"), bundle]);
    for (const file of files) {
      active(); const path = join(bundle, file.path);
      await mkdir(dirname(path), { recursive: true, mode: 0o700 });
      for (let parent = dirname(path); parent !== bundle; parent = dirname(parent)) directories.add(parent);
      active(); const lease = await file.acquire(signal);
      const ended = finished(lease.stream, { cleanup: true }); void ended.catch(() => {});
      addAbortSignal(signal, lease.stream);
      try {
        const output = await open(path, "wx", 0o600), digest = createHash("sha256"); let size = 0;
        try {
          for await (const chunk of lease.stream) {
            active();
            if (!(chunk instanceof Uint8Array)) throw new GatewayError("invalid_request", "Publication leases must yield bytes");
            size += chunk.byteLength; if (size > file.size) conflict();
            for (let offset = 0; offset < chunk.byteLength; offset += 65536) {
              active(); const bytes = Buffer.from(chunk.subarray(offset, offset + 65536));
              digest.update(bytes); await output.writeFile(bytes);
            }
          }
          if (size !== file.size || digest.digest("hex") !== file.digest) conflict();
          await syncDurably(output);
        } finally { await output.close(); }
      } finally {
        lease.stream.destroy();
        try { await lease.release(); } finally { await ended.catch(() => {}); }
      }
    }
    const metadata = await open(join(bundle, "app.json"), "wx", 0o600);
    try { await metadata.writeFile(manifest); await syncDurably(metadata); } finally { await metadata.close(); }
    const candidate = await readAppEntry(join(stage, "files/apps"), id, signal);
    if (!isReadyAppEntry(candidate)) throw new GatewayError("unsupported", candidate.row.status.reason);
    if (entryKey(candidate) !== digest) conflict();
    for (const directory of [...directories].sort((a, b) => b.length - a.length)) {
      const handle = await open(directory, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
      try { await syncDurably(handle); } finally { await handle.close(); }
    }
    for (const path of [stage, join(stage, "files"), join(stage, "files/apps")]) handles.push(await open(path, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW));
    const paths = [descriptor.root, join(descriptor.root, "files"), join(descriptor.root, "files/apps")];
    const fence = async () => {
      active(); await scope.fence(); if (!(await workspace.describe()).available) conflict();
      for (let i = 0; i < canonical.length; i++) {
        const info = await lstat(paths[i]!);
        if (info.isSymbolicLink() || !info.isDirectory() || fileIdentity(info) !== fileIdentity(await canonical[i]!.stat())) conflict();
      }
      if (canonical.length > 1) await workspace.filesRoot();
      active();
    };
    canonical.push(await open(paths[0]!, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW)); await fence();
    let moved = false;
    for (let i = 1; i < paths.length; i++) {
      const leaf = i === 1 ? "files" : "apps";
      try { await lstat(paths[i]!); }
      catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
        await fence(); moved = await publish(handles[i - 1]!.fd, leaf, canonical[i - 1]!.fd, leaf);
        await syncDurably(canonical[i - 1]!); await fence();
      }
      canonical.push(await open(paths[i]!, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW)); await fence();
    }
    if (!moved) { await fence(); await publish(handles[2]!.fd, id, canonical[2]!.fd, id); await syncDurably(canonical[2]!); }
    await fence();
    const accepted = await readAppEntry(paths[2]!, id, signal); await fence();
    if (!isReadyAppEntry(accepted) || entryKey(accepted) !== digest || fileIdentity(await lstat(join(paths[2]!, id))) !== accepted.identity) conflict();
    return accepted;
  } finally {
    const closed = await Promise.allSettled([...canonical, ...handles].map(handle => handle.close()));
    await scope.release(); // Private state, never a user entry or files ancestor.
    const failed = closed.filter(result => result.status === "rejected");
    if (failed.length) throw new AggregateError(failed.map(result => result.reason), "Publication descriptor retirement failed");
  }
}
