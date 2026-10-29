import { createHash } from "node:crypto";
import { lstat } from "node:fs/promises";
import { join } from "node:path";
import { appArtifactPath } from "./apps-artifact-resource.js";
import { appFileFormat, type ArtifactMedia } from "./apps-file-format.js";
import { fileIdentity, readAppBundle, safeRelative, snapshotDigest, snapshotSize, type AppFileSnapshot } from "./apps-folder-files.js";
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
  files: ReadonlyMap<string, AppFileSnapshot>; entry: string; file: AppFileSnapshot;
  payload: { kind: "swift"; source: Buffer } | { kind: "artifact"; artifact: AppArtifact };
}
export interface AppArtifact {
  entry: string; resourcePath: string; media: ArtifactMedia; mimeType: string; size: number; digest: string;
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
export async function readAppEntry(root: string, name: string, signal?: AbortSignal): Promise<AppEntry> {
  const info = await lstat(join(root, name)), identity = fileIdentity(info);
  const row: AppRow = { ...(APP_ID.test(name) ? { id: name } : {}), rowKey: hash(`${name}\0${identity}`),
    title: name, icon: "doc", section: "Artifacts", contentRevision: hash(`${identity}:${info.mtimeMs}:${info.size}`), status: { kind: "ready" } };
  let changedAt = info.mtimeMs;
  try {
    if (!APP_ID.test(name)) fail("Invalid entry directory name");
    if (!info.isDirectory() || info.isSymbolicLink()) fail("Entry must be a directory, not a symbolic link");
    const bundle = await readAppBundle(join(root, name), signal); changedAt = bundle.changedAt;
    const canonical = [...bundle.files].map(([path, file]) => [path, snapshotDigest(file)]);
    row.contentRevision = hash(JSON.stringify([identity, canonical]));
    const manifestFile = bundle.files.get("app.json");
    if (manifestFile && !Buffer.isBuffer(manifestFile)) fail("Manifest must be bounded text");
    const manifest = readAppManifest(manifestFile);
    row.title = manifest.title ?? name; row.icon = manifest.icon ?? "doc";
    let entry = manifest.entry;
    if (!entry) {
      const preferred = ["index.html", "Main.swift", "App.swift"].filter(path => bundle.files.has(path));
      const candidates = preferred.length ? preferred : [...bundle.files.keys()].filter(path => !path.includes("/") && path !== "app.json" && appFileFormat(path));
      if (candidates.length !== 1) fail(candidates.length ? "Choose an entry file in app.json" : "No supported entry file");
      entry = candidates[0]!;
    }
    const source = bundle.files.get(entry);
    if (!source) fail("Entry file is missing");
    const format = appFileFormat(entry), inferred = format?.kind, kind = manifest.kind ?? inferred;
    if (!kind) fail("Unsupported file type");
    if (inferred !== kind && !(kind === "document" && inferred === "web")) fail("Entry kind does not match file type");
    row.kind = kind; row.section = ["swift", "web"].includes(kind) ? "Apps" : "Artifacts";
    row.icon = manifest.icon ?? (kind === "swift" ? "app" : kind === "image" ? "photo" : "doc");
    const p = manifest.permissions ?? emptyPermissions();
    if (!["swift", "web"].includes(kind) && (p.data !== "none" || p.feeds.length || p.network.length && !["link", "video"].includes(kind))) fail("Permissions are not supported for this kind");
    const executableDigest = hash(JSON.stringify([identity, canonical.filter(([path]) => path !== "app.json"), entry, kind, p]));
    if (["swift", "web"].includes(kind) && bundle.size > 32 * 1024 * 1024) fail("Executable bundle exceeds 32 MiB");
    if (kind === "web" || p.network.length) throw new GatewayError("unsupported", "This entry needs a sandbox that is not available yet");
    if (kind === "live" || kind === "link") throw new GatewayError("unsupported", "This reference needs its display owner to open");
    if (!format) fail("Unsupported file type");
    if (kind === "swift" && !Buffer.isBuffer(source)) fail("Swift source must be bounded text");
    const payload: ReadyAppEntry["payload"] = kind === "swift" && Buffer.isBuffer(source) ? { kind: "swift", source }
      : { kind: "artifact", artifact: { entry, resourcePath: appArtifactPath(name, row.contentRevision), media: format.media, mimeType: format.mimeType, size: snapshotSize(source), digest: snapshotDigest(source) } };
    return { name, identity, changedAt, row: { ...row, id: name, kind, status: { kind: "ready" } },
      manifest, permissions: p, executableDigest, files: bundle.files, entry, file: source, payload };
  } catch (error) {
    signal?.throwIfAborted();
    return { name, identity, changedAt, row: { ...row, status: { kind: "cannotOpen",
      code: error instanceof GatewayError ? error.code : "invalid_request",
      reason: error instanceof GatewayError ? error.message : "Entry could not be read safely" } } };
  }
}
