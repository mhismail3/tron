import { createHash } from "node:crypto";
import { isUtf8 } from "node:buffer";
import { constants } from "node:fs";
import { lstat, open, readdir, realpath } from "node:fs/promises";
import { extname, join } from "node:path";
import { GatewayError } from "../../errors.js";

export const APP_ID = /^[a-z0-9][a-z0-9-]{0,79}$/;
export const hash = (bytes: string | Buffer): string => createHash("sha256").update(bytes).digest("hex");
export type AppKind = "swift" | "web" | "document" | "image" | "video" | "link" | "live";
export interface AppPermissions { data: "none" | "read" | "readWrite"; feeds: string[]; network: string[] }
export interface AppManifest { title?: string; icon?: string; entry?: string; kind?: AppKind; permissions?: AppPermissions }
export interface AppRow {
  id?: string; rowKey: string; title: string; icon: string; kind?: AppKind; section: "Apps" | "Artifacts";
  contentRevision: string; status: { kind: "ready" } | { kind: "cannotOpen"; code: string; reason: string };
}
interface EntryIdentity { name: string; identity: string; changedAt: number }
export interface ReadyAppEntry extends EntryIdentity {
  row: AppRow & { id: string; kind: AppKind; status: { kind: "ready" } };
  manifest: AppManifest; permissions: AppPermissions; executableDigest: string;
  files: ReadonlyMap<string, Buffer>; entry: string; source: Buffer;
}
export interface BrokenAppEntry extends EntryIdentity {
  row: AppRow & { status: { kind: "cannotOpen"; code: string; reason: string } };
}
export type AppEntry = ReadyAppEntry | BrokenAppEntry;
export function isReadyAppEntry(entry: AppEntry): entry is ReadyAppEntry { return entry.row.status.kind === "ready"; }
const kinds: AppKind[] = ["swift", "web", "document", "image", "video", "link", "live"];
const emptyPermissions = (): AppPermissions => ({ data: "none", feeds: [], network: [] });
function fail(reason: string): never { throw new GatewayError("invalid_request", reason); }
function object(value: unknown, keys: string[]): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value) || Object.keys(value).some(key => !keys.includes(key))) fail("Unknown or malformed manifest field");
  return value as Record<string, unknown>;
}
function label(value: unknown, field: string): string {
  if (typeof value !== "string" || !value.trim() || Buffer.byteLength(value) > 80 || /[\u0000-\u001f\u007f]/u.test(value)) fail(`Invalid ${field}`);
  return value;
}
function stringList(value: unknown, maximum: number): string[] {
  if (!Array.isArray(value) || value.length > maximum || value.some(item => typeof item !== "string")) fail("Invalid permission list");
  if (new Set(value).size !== value.length) fail("Duplicate permission scope");
  return [...value].sort();
}
export function safeRelative(path: string): boolean {
  return !!path && !path.includes("\\") && !path.includes("\0") && path.split("/").every(part => !!part && part !== "." && part !== "..");
}
function readAppManifest(bytes: Buffer | undefined): AppManifest {
  if (!bytes) return {};
  if (bytes.length > 32 * 1024) fail("Manifest exceeds 32 KiB");
  let value: unknown;
  try { value = JSON.parse(bytes.toString("utf8")); } catch { fail("Malformed app.json"); }
  const raw = object(value, ["title", "icon", "entry", "kind", "permissions"]);
  const result: AppManifest = {};
  if (raw.title !== undefined) result.title = label(raw.title, "title");
  if (raw.icon !== undefined) result.icon = label(raw.icon, "icon");
  if (raw.entry !== undefined) {
    if (typeof raw.entry !== "string" || !safeRelative(raw.entry)) fail("Entry must be a safe relative file");
    result.entry = raw.entry;
  }
  if (raw.kind !== undefined) {
    if (!kinds.includes(raw.kind as AppKind)) fail("Unknown app kind");
    result.kind = raw.kind as AppKind;
  }
  if (raw.permissions !== undefined) {
    const p = object(raw.permissions, ["data", "feeds", "network"]);
    if (p.data !== undefined && !["none", "read", "readWrite"].includes(p.data as string)) fail("Unknown data permission");
    const feeds = p.feeds === undefined ? [] : stringList(p.feeds, 1);
    if (feeds.some(feed => feed !== "ios-builds")) fail("Unknown feed");
    const network = p.network === undefined ? [] : stringList(p.network, 32);
    for (const origin of network) {
      let url: URL; try { url = new URL(origin); } catch { fail("Invalid network origin"); }
      if (url.protocol !== "https:" || url.origin !== origin || url.username || url.password) fail("Network access requires canonical HTTPS origins");
    }
    result.permissions = { data: (p.data ?? "none") as AppPermissions["data"], feeds, network };
  }
  return result;
}
function inferKind(path: string): AppKind | undefined {
  if (path === "entry.link.json") return "link";
  if (path === "entry.live.json") return "live";
  const extension = extname(path).toLowerCase();
  if (extension === ".swift") return "swift";
  if ([".html", ".htm"].includes(extension)) return "web";
  if ([".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".bmp"].includes(extension)) return "image";
  if ([".mp4", ".mov", ".m4v"].includes(extension)) return "video";
  if ([".pdf", ".md", ".txt", ".rtf", ".csv", ".json"].includes(extension)) return "document";
  return undefined;
}
const identityOf = (s: Awaited<ReturnType<typeof lstat>>): string => `${s.dev}:${s.ino}:${s.birthtimeMs}`;
/** Refuse links/special files before opening; O_NONBLOCK means an external FIFO
 * replacement cannot make indexing wait for a writer. Each descriptor is bounded. */
async function readBundle(root: string): Promise<{ files: Map<string, Buffer>; changedAt: number }> {
  const files = new Map<string, Buffer>(); let total = 0, changedAt = 0, directories = 0;
  const rootIdentity = identityOf(await lstat(root));
  async function walk(relative: string): Promise<void> {
    if (relative.length > 4096 || relative.split("/").length > 64) fail("Entry path exceeds its bounds");
    const path = join(root, relative), before = await lstat(path);
    const canonical = await realpath(path);
    if (canonical !== root && !canonical.startsWith(`${root}/`)) fail("Entry path escaped its directory");
    changedAt = Math.max(changedAt, before.mtimeMs);
    if (before.isSymbolicLink()) fail("Symbolic links are not supported");
    if (before.isDirectory()) {
      if (++directories > 2000) fail("Entry has too many directories");
      for (const name of (await readdir(path)).sort()) {
        if (files.size >= 1000) fail("Bundle exceeds 1,000 files");
        await walk(relative ? `${relative}/${name}` : name);
      }
      const after = await lstat(path);
      if (identityOf(after) !== identityOf(before) || after.mtimeMs !== before.mtimeMs) fail("Entry changed while reading");
      return;
    }
    if (!before.isFile() || !relative) fail("Entry contains a non-regular file");
    const limit = relative === "app.json" ? 32 * 1024 : extname(relative) === ".swift" ? 320_000 : 32 * 1024 * 1024;
    if (before.size > limit || total + before.size > 32 * 1024 * 1024) fail("Entry exceeds its byte limit");
    const handle = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    try {
      const s = await handle.stat();
      if (!s.isFile() || identityOf(s) !== identityOf(before) || s.size !== before.size) fail("Entry changed while reading");
      const bytes = Buffer.alloc(before.size);
      let offset = 0;
      while (offset < bytes.length) {
        const read = await handle.read(bytes, offset, bytes.length - offset, offset);
        if (!read.bytesRead) break;
        offset += read.bytesRead;
      }
      const after = await handle.stat();
      if (offset !== before.size || after.mtimeMs !== s.mtimeMs || after.size !== s.size) fail("Entry changed while reading");
      total += bytes.length; files.set(relative, bytes);
    } finally { await handle.close(); }
  }
  await walk("");
  if (identityOf(await lstat(root)) !== rootIdentity) fail("Entry changed while reading");
  return { files, changedAt };
}
export async function readAppEntry(root: string, name: string): Promise<AppEntry> {
  const info = await lstat(join(root, name)), identity = identityOf(info);
  const row: AppRow = { ...(APP_ID.test(name) ? { id: name } : {}), rowKey: hash(`${name}\0${identity}`),
    title: name, icon: "doc", section: "Artifacts", contentRevision: hash(`${identity}:${info.mtimeMs}:${info.size}`), status: { kind: "ready" } };
  let changedAt = info.mtimeMs;
  try {
    if (!APP_ID.test(name)) fail("Invalid entry directory name");
    if (!info.isDirectory() || info.isSymbolicLink()) fail("Entry must be a directory, not a symbolic link");
    const bundle = await readBundle(join(root, name)); changedAt = bundle.changedAt;
    const canonical = [...bundle.files].map(([path, bytes]) => [path, hash(bytes)]);
    row.contentRevision = hash(JSON.stringify([identity, canonical]));
    const manifest = readAppManifest(bundle.files.get("app.json"));
    row.title = manifest.title ?? name; row.icon = manifest.icon ?? "doc";
    let entry = manifest.entry;
    if (!entry) {
      const preferred = ["index.html", "Main.swift", "App.swift"].filter(path => bundle.files.has(path));
      const candidates = preferred.length ? preferred : [...bundle.files.keys()].filter(path => !path.includes("/") && path !== "app.json" && inferKind(path));
      if (candidates.length !== 1) fail(candidates.length ? "Choose an entry file in app.json" : "No supported entry file");
      entry = candidates[0]!;
    }
    if (!bundle.files.has(entry)) fail("Entry file is missing");
    const source = bundle.files.get(entry)!;
    if ([".swift", ".html", ".htm"].includes(extname(entry).toLowerCase()) && (!isUtf8(source) || source.includes(0))) fail("Executable source must be UTF-8 text without NUL bytes");
    const inferred = inferKind(entry), kind = manifest.kind ?? inferred;
    if (!kind) fail("Unsupported file type");
    if (inferred !== kind && !(kind === "document" && inferred === "web")) fail("Entry kind does not match file type");
    row.kind = kind; row.section = ["swift", "web"].includes(kind) ? "Apps" : "Artifacts";
    row.icon = manifest.icon ?? (kind === "swift" ? "app" : kind === "image" ? "photo" : "doc");
    const p = manifest.permissions ?? emptyPermissions();
    if (!["swift", "web"].includes(kind) && (p.data !== "none" || p.feeds.length || p.network.length && !["link", "video"].includes(kind))) fail("Permissions are not supported for this kind");
    const executableDigest = hash(JSON.stringify([identity, canonical.filter(([path]) => path !== "app.json"), entry, kind, p]));
    if (kind === "web" || p.network.length) throw new GatewayError("unsupported", "This entry needs a sandbox that is not available yet");
    if (kind === "live" || kind === "link") throw new GatewayError("unsupported", "This reference needs its display owner to open");
    return { name, identity, changedAt, row: { ...row, id: name, kind, status: { kind: "ready" } },
      manifest, permissions: p, executableDigest, files: bundle.files, entry, source };
  } catch (error) {
    return { name, identity, changedAt, row: { ...row, status: { kind: "cannotOpen",
      code: error instanceof GatewayError ? error.code : "invalid_request",
      reason: error instanceof GatewayError ? error.message : "Entry could not be read safely" } } };
  }
}
