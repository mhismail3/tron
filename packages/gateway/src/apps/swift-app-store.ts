import { createHash, randomBytes } from "node:crypto";
import { constants, lstatSync } from "node:fs";
import { lstat, mkdir, open, readdir, realpath, rename, rm } from "node:fs/promises";
import { isAbsolute, join, resolve, sep } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { pathToFileURL } from "node:url";
import { GatewayError } from "../errors.js";
import type { JsonValue } from "../protocol/types.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { durableAtomicWriteJson, durableAtomicWriteText, syncDurably } from "../util/durable-json.js";
import { readSecureJson, readSecureText } from "../util/secure-json.js";
import type { TronWorkspace } from "../workspace/tron-workspace.js";

/** Installed single-file Swift apps (#1156). One owner for
 * `<workspace>/state/apps/<appId>/`: `app.json` (manifest), `App.swift` (source)
 * and `data.sqlite` (the app's key/value state). docs/swift-apps.md owns the
 * contract that #1158 persistence, #1159 feeds and #1161 the Apps sheet build on. */
export const SWIFT_APPS_CAPABILITY = "swift-apps.v1";

export const SWIFT_APP_LIMITS = {
  /** Matches the iPhone's complete-text preview bound; a longer file could never run. */
  sourceBytes: 320_000,
  nameBytes: 80,
  iconBytes: 80,
  apps: 200,
  keyBytes: 256,
  valueBytes: 256 * 1_024,
  entries: 1_000,
  /** Keys plus encoded values; a full snapshot stays well inside one RPC frame. */
  stateBytes: 512 * 1_024,
  writesPerCommit: 256,
  valueDepth: 32,
} as const;

const APP_ID = /^[a-z0-9][a-z0-9-]{0,62}$/;
const MANIFEST_BYTES = 4_096;
const MANIFEST_KEYS = ["version", "id", "name", "icon", "revision", "sourceSha256", "sourceBytes", "updatedAt"];
const SCHEMA_VERSION = 1;

export interface SwiftAppManifest {
  version: 1;
  id: string;
  name: string;
  icon?: string;
  /** Source revision: 1 at install, +1 for each reinstall. State has its own revision. */
  revision: number;
  sourceSha256: string;
  sourceBytes: number;
  updatedAt: string;
}

export interface SwiftAppStateSnapshot {
  appId: string;
  revision: number;
  entries: Array<{ key: string; value: JsonValue }>;
}

export interface SwiftAppCommit {
  appId: string;
  expectedRevision: number;
  set: Array<{ key: string; value: JsonValue }>;
  remove: string[];
}

export function admitSwiftAppId(value: unknown): string {
  if (typeof value !== "string" || !APP_ID.test(value)) {
    throw new GatewayError("invalid_request", "App id must be 1-63 lowercase letters, digits or hyphens, starting with a letter or digit");
  }
  return value;
}

function boundedLabel(value: unknown, label: string, maximumBytes: number): string {
  if (typeof value !== "string" || value.trim().length === 0 || Buffer.byteLength(value) > maximumBytes || /[\u0000-\u001f\u007f]/u.test(value)) {
    throw new GatewayError("invalid_request", `App ${label} must be 1-${maximumBytes} bytes of single-line text`);
  }
  return value;
}

function admitKey(value: unknown): string {
  if (typeof value !== "string" || value.length === 0 || Buffer.byteLength(value) > SWIFT_APP_LIMITS.keyBytes || /[\u0000-\u001f\u007f]/u.test(value)) {
    throw new GatewayError("invalid_request", `State keys must be 1-${SWIFT_APP_LIMITS.keyBytes} bytes without control characters`);
  }
  return value;
}

/** Plain JSON only: finite numbers, bounded depth, no prototypes or holes. */
function admitValue(value: unknown, depth = 0): void {
  if (depth > SWIFT_APP_LIMITS.valueDepth) throw new GatewayError("invalid_request", `State values may nest at most ${SWIFT_APP_LIMITS.valueDepth} levels`);
  if (value === null || typeof value === "string" || typeof value === "boolean") return;
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new GatewayError("invalid_request", "State numbers must be finite");
    return;
  }
  if (Array.isArray(value)) { for (const item of value) admitValue(item, depth + 1); return; }
  if (typeof value === "object" && Object.getPrototypeOf(value) === Object.prototype) {
    for (const item of Object.values(value as Record<string, unknown>)) admitValue(item, depth + 1);
    return;
  }
  throw new GatewayError("invalid_request", "State values must be JSON");
}

function validManifest(value: unknown, id: string): SwiftAppManifest {
  const record = value as Record<string, unknown> | null;
  if (!record || typeof record !== "object" || Array.isArray(record)
    || Object.keys(record).some(key => !MANIFEST_KEYS.includes(key))
    || record.version !== 1 || record.id !== id
    || typeof record.name !== "string" || (record.icon !== undefined && typeof record.icon !== "string")
    || !Number.isSafeInteger(record.revision) || (record.revision as number) < 1
    || typeof record.sourceSha256 !== "string" || !/^[a-f0-9]{64}$/.test(record.sourceSha256)
    || !Number.isSafeInteger(record.sourceBytes) || (record.sourceBytes as number) < 1 || (record.sourceBytes as number) > SWIFT_APP_LIMITS.sourceBytes
    || typeof record.updatedAt !== "string") {
    throw new GatewayError("conflict", `App ${id} has an unreadable or newer manifest; it was left unchanged`);
  }
  return record as unknown as SwiftAppManifest;
}

async function syncDirectory(path: string): Promise<void> {
  const handle = await open(path, constants.O_RDONLY);
  try { await syncDurably(handle); } finally { await handle.close(); }
}

/** Present, owner-only and not a link; absent is `false`; anything else refuses. */
async function ownerDirectory(path: string): Promise<boolean> {
  let info;
  try { info = await lstat(path); } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return false;
    throw new GatewayError("conflict", "Swift app storage could not be inspected");
  }
  if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid?.() || (info.mode & 0o777) !== 0o700) {
    throw new GatewayError("conflict", "Swift app storage must be owner-only directories; it was left unchanged");
  }
  return true;
}

async function ensureOwnerDirectory(path: string): Promise<boolean> {
  try { await mkdir(path, { mode: 0o700 }); } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
    await ownerDirectory(path);
    return false;
  }
  await ownerDirectory(path);
  return true;
}

/** Read the source an agent names: a visible relative path under `root`, no
 * links, a regular file within the source bound. */
export async function readSwiftAppSourceFile(root: string, requestedPath: string): Promise<string> {
  if (!requestedPath || isAbsolute(requestedPath) || requestedPath.includes("\0")
    || requestedPath.split(/[\\/]/).some(part => !part || part === "." || part === ".." || part.startsWith("."))) {
    throw new GatewayError("invalid_request", "The app source must be a visible relative path");
  }
  if (!requestedPath.endsWith(".swift")) throw new GatewayError("invalid_request", "The app source must be a .swift file");
  const base = await realpath(resolve(root));
  let path = base;
  for (const part of requestedPath.split(/[\\/]/)) {
    path = join(path, part);
    let info;
    try { info = await lstat(path); } catch { throw new GatewayError("not_found", `No file at ${requestedPath}`); }
    if (info.isSymbolicLink()) throw new GatewayError("invalid_request", "The app source path cannot contain symbolic links");
  }
  // A FIFO must reach descriptor validation without waiting for a writer.
  const handle = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const info = await handle.stat();
    if (!info.isFile() || info.size < 1 || info.size > SWIFT_APP_LIMITS.sourceBytes || !(await realpath(path)).startsWith(base + sep)) {
      throw new GatewayError("invalid_request", `The app source must be a file of 1-${SWIFT_APP_LIMITS.sourceBytes} bytes`);
    }
    const bytes = await handle.readFile();
    if (bytes.byteLength !== info.size) throw new GatewayError("conflict", "The app source changed while it was read", true);
    const text = bytes.toString("utf8");
    if (!Buffer.from(text, "utf8").equals(bytes)) throw new GatewayError("invalid_request", "The app source must be UTF-8 text");
    return text;
  } finally { await handle.close(); }
}

export class SwiftAppStore {
  private readonly mutex = new AsyncMutex();

  constructor(private readonly workspace: TronWorkspace) {}

  private async appsRoot(create: boolean): Promise<string | undefined> {
    const descriptor = await this.workspace.describe();
    if (!descriptor.available) throw new GatewayError("conflict", "Tron internal workspace is unavailable; installed apps cannot be read");
    const state = join(descriptor.root, "state");
    const apps = join(state, "apps");
    const initialized = await this.workspace.featureInitialized("apps")
      .catch(() => { throw new GatewayError("conflict", "The installed-apps initialization record is unreadable; it was left unchanged"); });
    if (!create) {
      if (await ownerDirectory(apps)) return apps;
      // A recorded container that has gone is lost state, never a fresh start.
      if (initialized) throw new GatewayError("conflict", "Installed apps are missing after they were created; restore state/apps");
      return undefined;
    }
    if (!(await ownerDirectory(apps)) && initialized) {
      throw new GatewayError("conflict", "Installed apps are missing after they were created; restore state/apps");
    }
    const createdState = await ensureOwnerDirectory(state);
    const createdApps = await ensureOwnerDirectory(apps);
    if (createdState) await syncDirectory(descriptor.root);
    if (createdApps) await syncDirectory(state);
    if (!initialized) await this.workspace.markFeatureInitialized("apps");
    return apps;
  }

  private async appDirectory(appId: string): Promise<string> {
    const apps = await this.appsRoot(false);
    const directory = apps ? join(apps, appId) : undefined;
    if (!directory || !(await ownerDirectory(directory))) throw new GatewayError("not_found", `No installed app ${appId}`);
    return directory;
  }

  private async readManifest(directory: string, appId: string): Promise<SwiftAppManifest> {
    let read;
    try { read = await readSecureJson<unknown>(join(directory, "app.json"), MANIFEST_BYTES); }
    catch { throw new GatewayError("conflict", `App ${appId} has an unreadable manifest; it was left unchanged`); }
    if (!read.present) throw new GatewayError("conflict", `App ${appId} has no manifest; it was left unchanged`);
    return validManifest(read.value, appId);
  }

  async list(): Promise<SwiftAppManifest[]> {
    return this.mutex.run(async () => {
      const apps = await this.appsRoot(false);
      if (!apps) return [];
      const manifests: SwiftAppManifest[] = [];
      for (const name of (await readdir(apps)).sort()) {
        if (!APP_ID.test(name)) continue;
        if (!(await ownerDirectory(join(apps, name)))) continue;
        manifests.push(await this.readManifest(join(apps, name), name));
      }
      return manifests;
    });
  }

  async get(appId: string): Promise<{ app: SwiftAppManifest; source: string }> {
    admitSwiftAppId(appId);
    return this.mutex.run(async () => {
      const directory = await this.appDirectory(appId);
      const app = await this.readManifest(directory, appId);
      let read;
      try { read = await readSecureText(join(directory, "App.swift"), SWIFT_APP_LIMITS.sourceBytes); }
      catch { read = { present: false as const }; }
      // The source is published before its manifest, so a torn reinstall shows
      // as a hash mismatch: refuse it rather than run code the manifest does not name.
      if (!read.present || createHash("sha256").update(read.value).digest("hex") !== app.sourceSha256) {
        throw new GatewayError("conflict", `App ${appId}'s source does not match its manifest; reinstall it`);
      }
      return { app, source: read.value };
    });
  }

  /** Install, or replace an installed app's source and name while keeping its data. */
  async install(input: { appId: string; name: string; icon?: string; source: string }): Promise<{ app: SwiftAppManifest; created: boolean }> {
    const appId = admitSwiftAppId(input.appId);
    const name = boundedLabel(input.name, "name", SWIFT_APP_LIMITS.nameBytes);
    const icon = input.icon === undefined ? undefined : boundedLabel(input.icon, "icon", SWIFT_APP_LIMITS.iconBytes);
    const sourceBytes = Buffer.byteLength(input.source);
    if (sourceBytes < 1 || sourceBytes > SWIFT_APP_LIMITS.sourceBytes) {
      throw new GatewayError("invalid_request", `App source must be 1-${SWIFT_APP_LIMITS.sourceBytes} bytes`);
    }
    return this.mutex.run(async () => {
      const apps = (await this.appsRoot(true))!;
      const directory = join(apps, appId);
      const existing = await ownerDirectory(directory) ? await this.readManifest(directory, appId) : undefined;
      if (!existing) {
        const count = (await readdir(apps)).filter(entry => APP_ID.test(entry)).length;
        if (count >= SWIFT_APP_LIMITS.apps) throw new GatewayError("conflict", `At most ${SWIFT_APP_LIMITS.apps} apps can be installed`);
        if (await ensureOwnerDirectory(directory)) await syncDirectory(apps);
      }
      // A new app's state database exists before its manifest, so a listed app always has state.
      this.withDatabase(directory, () => undefined, !existing);
      await durableAtomicWriteText(join(directory, "App.swift"), input.source);
      const app: SwiftAppManifest = {
        version: 1, id: appId, name, ...(icon ? { icon } : {}),
        revision: (existing?.revision ?? 0) + 1,
        sourceSha256: createHash("sha256").update(input.source).digest("hex"),
        sourceBytes, updatedAt: new Date().toISOString(),
      };
      await durableAtomicWriteJson(join(directory, "app.json"), app);
      return { app, created: !existing };
    });
  }

  /** Delete the app folder (manifest, source and data). The folder is first
   * renamed aside so a crash can never leave a half-removed app listed. */
  async remove(appId: string): Promise<{ appId: string; removed: true }> {
    admitSwiftAppId(appId);
    return this.mutex.run(async () => {
      const directory = await this.appDirectory(appId);
      const apps = join(directory, "..");
      const retired = join(apps, `.removed-${appId}-${randomBytes(6).toString("hex")}`);
      await rename(directory, retired);
      await syncDirectory(apps);
      await rm(retired, { recursive: true, force: true });
      return { appId, removed: true };
    });
  }

  async state(appId: string): Promise<SwiftAppStateSnapshot> {
    admitSwiftAppId(appId);
    return this.mutex.run(async () => {
      const directory = await this.appDirectory(appId);
      return this.withDatabase(directory, database => this.snapshot(database, appId));
    });
  }

  /** Optimistic: a commit names the state revision it was computed from, and
   * a stale one is refused so the caller reloads instead of overwriting. */
  async commit(input: SwiftAppCommit): Promise<{ appId: string; revision: number }> {
    const appId = admitSwiftAppId(input.appId);
    if (!Number.isSafeInteger(input.expectedRevision) || input.expectedRevision < 0) throw new GatewayError("invalid_request", "expectedRevision must be a non-negative integer");
    if (!Array.isArray(input.set) || !Array.isArray(input.remove) || input.set.length + input.remove.length === 0
      || input.set.length + input.remove.length > SWIFT_APP_LIMITS.writesPerCommit) {
      throw new GatewayError("invalid_request", `A commit carries 1-${SWIFT_APP_LIMITS.writesPerCommit} writes`);
    }
    const touched = new Set<string>();
    const sets = input.set.map(write => {
      if (!write || typeof write !== "object" || Array.isArray(write) || Object.keys(write).some(key => key !== "key" && key !== "value") || !("value" in write)) {
        throw new GatewayError("invalid_request", "Each set write is {key, value}");
      }
      const key = admitKey(write.key);
      admitValue(write.value);
      const encoded = JSON.stringify(write.value);
      if (Buffer.byteLength(encoded) > SWIFT_APP_LIMITS.valueBytes) throw new GatewayError("invalid_request", `A state value may be at most ${SWIFT_APP_LIMITS.valueBytes} bytes`);
      if (touched.has(key)) throw new GatewayError("invalid_request", `State key ${JSON.stringify(key)} is written twice`);
      touched.add(key);
      return { key, encoded };
    });
    const removes = input.remove.map(raw => {
      const key = admitKey(raw);
      if (touched.has(key)) throw new GatewayError("invalid_request", `State key ${JSON.stringify(key)} is written twice`);
      touched.add(key);
      return key;
    });
    return this.mutex.run(async () => {
      const directory = await this.appDirectory(appId);
      return this.withDatabase(directory, database => {
        database.exec("BEGIN IMMEDIATE");
        try {
          const revision = this.revision(database);
          if (revision !== input.expectedRevision) {
            throw new GatewayError("conflict", `App ${appId}'s state is at revision ${revision}, not ${input.expectedRevision}; reload it`, false, { revision });
          }
          const upsert = database.prepare("INSERT INTO state(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value");
          for (const write of sets) upsert.run(write.key, write.encoded);
          const remove = database.prepare("DELETE FROM state WHERE key = ?");
          for (const key of removes) remove.run(key);
          const totals = database.prepare("SELECT COUNT(*) AS entries, COALESCE(SUM(LENGTH(CAST(key AS BLOB)) + LENGTH(CAST(value AS BLOB))), 0) AS bytes FROM state").get() as { entries: number; bytes: number };
          if (totals.entries > SWIFT_APP_LIMITS.entries || totals.bytes > SWIFT_APP_LIMITS.stateBytes) {
            throw new GatewayError("conflict", `App state is limited to ${SWIFT_APP_LIMITS.entries} keys and ${SWIFT_APP_LIMITS.stateBytes} bytes`);
          }
          database.prepare("UPDATE meta SET value = ? WHERE name = 'revision'").run(revision + 1);
          database.exec("COMMIT");
          return { appId, revision: revision + 1 };
        } catch (error) {
          database.exec("ROLLBACK");
          throw error;
        }
      });
    });
  }

  private revision(database: DatabaseSync): number {
    const row = database.prepare("SELECT value FROM meta WHERE name = 'revision'").get() as { value: number } | undefined;
    if (!row || !Number.isSafeInteger(row.value) || row.value < 0) throw new GatewayError("conflict", "App state has no valid revision; it was left unchanged");
    return row.value;
  }

  private snapshot(database: DatabaseSync, appId: string): SwiftAppStateSnapshot {
    const rows = database.prepare("SELECT key, value FROM state ORDER BY key").all() as Array<{ key: string; value: string }>;
    return { appId, revision: this.revision(database), entries: rows.map(row => ({ key: row.key, value: JSON.parse(row.value) as JsonValue })) };
  }

  /** One short-lived connection per operation under the store mutex. Only a
   * first install may create state; an existing manifest is not a fresh start. */
  private withDatabase<T>(directory: string, operation: (database: DatabaseSync) => T, create = false): T {
    const path = join(directory, "data.sqlite");
    let database: DatabaseSync;
    try {
      if (!create) {
        const entry = lstatSync(path);
        if (!entry.isFile() || entry.uid !== process.getuid?.()) throw new Error("Unsafe app database");
      }
      // SQLite's no-create mode also protects deletion between inspection and
      // open. Escape the path as a URI so workspace names cannot change its mode.
      database = new DatabaseSync(`${pathToFileURL(path).href}?mode=${create ? "rwc" : "rw"}`, { allowExtension: false });
    } catch {
      throw new GatewayError("conflict", "App state is missing or unsafe; restore its data.sqlite");
    }
    try {
      database.exec("PRAGMA trusted_schema = OFF; PRAGMA busy_timeout = 1000;");
      const version = (database.prepare("PRAGMA user_version").get() as { user_version: number }).user_version;
      if (version !== SCHEMA_VERSION && !(create && version === 0)) {
        throw new GatewayError("conflict", "App state has an unsupported schema; it was left unchanged");
      }
      database.exec("PRAGMA journal_mode = DELETE; PRAGMA synchronous = EXTRA; PRAGMA secure_delete = ON;");
      if (create && version === 0) {
        database.exec(`BEGIN IMMEDIATE;
          CREATE TABLE meta(name TEXT PRIMARY KEY, value INTEGER NOT NULL) STRICT;
          CREATE TABLE state(key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT;
          INSERT INTO meta(name, value) VALUES ('revision', 0);
          PRAGMA user_version = ${SCHEMA_VERSION};
          COMMIT;`);
      }
      return operation(database);
    } finally {
      database.close();
    }
  }
}
