import { createHash } from "node:crypto";
import { isUtf8 } from "node:buffer";
import { constants, type Stats } from "node:fs";
import { lstat, open, readdir, realpath, type FileHandle } from "node:fs/promises";
import { join } from "node:path";
import { GatewayError } from "../../errors.js";
import { appFileFormat, appSignatureMatches, type AppFileFormat } from "./apps-file-format.js";

export interface StreamedAppFile {
  path: string; size: number; stamp: string; digest: string; format?: AppFileFormat;
}
/** Small text owns its immutable bytes; large/binary files own a fenced byte
 * descriptor. There is no empty Buffer standing in for a streamed file. */
export type AppFileSnapshot = Buffer | StreamedAppFile;
export const snapshotDigest = (file: AppFileSnapshot): string => Buffer.isBuffer(file) ? createHash("sha256").update(file).digest("hex") : file.digest;
export const snapshotSize = (file: AppFileSnapshot): number => Buffer.isBuffer(file) ? file.length : file.size;
export interface AppBundleSnapshot {
  files: ReadonlyMap<string, AppFileSnapshot>; changedAt: number; size: number;
}
export const fileIdentity = (s: Stats): string => `${s.dev}:${s.ino}:${s.birthtimeMs}`;
export const fileStamp = (s: Stats): string => `${fileIdentity(s)}:${s.size}:${s.mtimeMs}:${s.ctimeMs}`;
export function safeRelative(path: string): boolean {
  return !!path && !path.includes("\\") && !path.includes("\0") && path.split("/").every(part => !!part && part !== "." && part !== "..");
}
function refuse(message: string): never { throw new GatewayError("invalid_request", message); }
/** The same descriptor edge admits scans and preview leases. Check every parent,
 * not just O_NOFOLLOW on the leaf: a nested link is forbidden even into this root. */
export async function openAppFile(root: string, relative: string): Promise<{ handle: FileHandle; stat: Stats }> {
  if (!safeRelative(relative)) refuse("Invalid entry path");
  const parents: Array<{ path: string; identity: string }> = [];
  let path = root;
  for (const part of ["", ...relative.split("/").slice(0, -1)]) {
    if (part) path = join(path, part);
    const info = await lstat(path);
    if (!info.isDirectory() || info.isSymbolicLink()) refuse("Entry parent is not a safe directory");
    parents.push({ path, identity: fileIdentity(info) });
  }
  path = join(root, relative);
  const before = await lstat(path), canonical = await realpath(path);
  // root is the canonical workspace namespace supplied by the index. Resolving
  // it again would bless an ancestor symlink swapped in after that admission.
  if (!before.isFile() || before.isSymbolicLink() || !canonical.startsWith(`${root}/`)) refuse("Entry contains a link or non-regular file");
  const handle = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const stat = await handle.stat();
    if (!stat.isFile() || fileStamp(stat) !== fileStamp(before)) refuse("Entry changed while opening");
    for (const parent of parents) {
      const current = await lstat(parent.path);
      if (!current.isDirectory() || current.isSymbolicLink() || fileIdentity(current) !== parent.identity) refuse("Entry changed while opening");
    }
    return { handle, stat };
  } catch (error) { await handle.close(); throw error; }
}

/** Stream all file hashes with one 64 KiB buffer. Only bounded text is retained;
 * images/video/documents remain descriptor metadata, never Buffer.alloc(size). */
export async function readAppBundle(root: string, signal?: AbortSignal): Promise<AppBundleSnapshot> {
  const files = new Map<string, AppFileSnapshot>();
  let size = 0, buffered = 0, binary = 0, changedAt = 0, directories = 0;
  const rootIdentity = fileIdentity(await lstat(root));
  async function walk(relative: string): Promise<void> {
    signal?.throwIfAborted();
    if (relative.length > 4096 || relative.split("/").length > 64) refuse("Entry path exceeds its bounds");
    const path = join(root, relative), before = await lstat(path);
    changedAt = Math.max(changedAt, before.mtimeMs);
    if (before.isSymbolicLink()) refuse("Symbolic links are not supported");
    if (before.isDirectory()) {
      if (++directories > 2000) refuse("Entry has too many directories");
      for (const name of (await readdir(path)).sort()) {
        if (files.size >= 1000) refuse("Bundle exceeds 1,000 files");
        await walk(relative ? `${relative}/${name}` : name);
      }
      const after = await lstat(path);
      if (fileStamp(after) !== fileStamp(before)) refuse("Entry changed while reading");
      return;
    }
    if (!before.isFile() || !relative) refuse("Entry contains a non-regular file");
    const format = appFileFormat(relative), retain = relative === "app.json" || format?.buffer === true;
    const maximum = relative === "app.json" ? 32 * 1024 : format?.maximumBytes ?? 25 * 1024 * 1024;
    if (before.size > maximum) refuse("Entry exceeds its byte limit");
    if (retain) buffered += before.size; else binary += before.size;
    if (buffered > 32 * 1024 * 1024 || binary > 2 * 1024 * 1024 * 1024) refuse("Bundle exceeds its byte limit");
    const { handle, stat } = await openAppFile(root, relative);
    try {
      if (fileStamp(stat) !== fileStamp(before)) refuse("Entry changed while opening");
      const digest = createHash("sha256"), scratch = Buffer.alloc(64 * 1024), chunks: Buffer[] = [];
      let offset = 0, prefix = Buffer.alloc(0);
      while (offset < stat.size) {
        signal?.throwIfAborted();
        const read = await handle.read(scratch, 0, Math.min(scratch.length, stat.size - offset), offset);
        if (!read.bytesRead) refuse("Entry changed while reading");
        const chunk = scratch.subarray(0, read.bytesRead);
        digest.update(chunk);
        if (retain) chunks.push(Buffer.from(chunk));
        if (!offset) prefix = Buffer.from(chunk.subarray(0, 16));
        offset += read.bytesRead;
      }
      signal?.throwIfAborted();
      if (fileStamp(await handle.stat()) !== fileStamp(stat)) refuse("Entry changed while reading");
      if (format && !appSignatureMatches(prefix, format.mimeType)) refuse("Entry media signature does not match its type");
      const bytes = retain ? Buffer.concat(chunks, stat.size) : undefined;
      if (bytes && format && (!isUtf8(bytes) || bytes.includes(0))) refuse("Entry text must be UTF-8 without NUL bytes");
      files.set(relative, bytes ?? { path: relative, size: stat.size, stamp: fileStamp(stat), digest: digest.digest("hex"), ...(format ? { format } : {}) });
      size += stat.size;
    } finally { await handle.close(); }
  }
  await walk("");
  if (fileIdentity(await lstat(root)) !== rootIdentity) refuse("Entry changed while reading");
  return { files, size, changedAt };
}
