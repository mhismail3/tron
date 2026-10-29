import { lstatSync } from "node:fs";
import { lstat, mkdir, open } from "node:fs/promises";
import { dirname, join } from "node:path";
import { syncDurably } from "../../util/durable-json.js";
import { DatabaseSync } from "node:sqlite";
import { pathToFileURL } from "node:url";
import { GatewayError } from "../../errors.js";
import type { JsonValue } from "../../protocol/types.js";
import type { TronWorkspace } from "../../workspace/tron-workspace.js";
import { APP_ID } from "./apps-folder-format.js";

const SWIFT_APP_LIMITS = {
  keyBytes: 256,
  valueBytes: 256 * 1_024,
  entries: 1_000,
  /** Keys plus encoded values; a full snapshot stays well inside one RPC frame. */
  stateBytes: 512 * 1_024,
  writesPerCommit: 256,
  valueDepth: 32,
} as const;


const SCHEMA_VERSION = 1;
export interface SwiftAppStateSnapshot {
  appId: string;
  revision: number;
  entries: Array<{ key: string; value: JsonValue }>;
}


export interface AppDataCommit {
  appId: string; expectedRevision: number;
  set: Array<{ key: string; value: JsonValue }>; remove: string[];
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


/** SQLite format and CAS are unchanged. The Apps owner serializes admission,
 * grants, file deletion and every data operation before entering this store. */
export class AppDataStore {
  constructor(private readonly workspace: TronWorkspace) {}
  private async directory(appId: string): Promise<string> {
    if (!APP_ID.test(appId)) throw new GatewayError("invalid_request", "Invalid app id");
    const descriptor = await this.workspace.describe();
    if (!descriptor.available) throw new GatewayError("conflict", "Tron workspace is unavailable");
    const initialized = await this.workspace.featureInitialized("apps");
    if (initialized) {
      try {
        const info = await lstat(join(descriptor.root, "state/apps"));
        if (!info.isDirectory() || info.isSymbolicLink()) throw new Error("Unsafe data root");
      } catch { throw new GatewayError("conflict", "App data root is missing or unsafe; restore state/apps"); }
    }
    let path = descriptor.root;
    for (const [depth, part] of ["state", "apps", appId].entries()) {
      path = join(path, part);
      let created = false;
      try { await mkdir(path, { mode: 0o700 }); created = true; }
      catch (error) { if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error; }
      const info = await lstat(path);
      if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid?.() || (info.mode & 0o777) !== 0o700) throw new GatewayError("conflict", "App data directory is unsafe");
      if (created) {
        const parent = await open(dirname(path), "r");
        try { await syncDurably(parent); } finally { await parent.close(); }
      }
      if (depth === 1 && !initialized) await this.workspace.markFeatureInitialized("apps");
      if (depth === 2 && created) this.withDatabase(path, () => {}, true);
    }
    return path;
  }
  async state(appId: string): Promise<SwiftAppStateSnapshot> {
    return this.withDatabase(await this.directory(appId), database => this.snapshot(database, appId));
  }
  async reset(appId: string, expectedRevision: number): Promise<{ appId: string; revision: number }> {
    const directory = await this.directory(appId);
    return this.withDatabase(directory, database => {
      database.exec("BEGIN IMMEDIATE");
      try {
        const revision = this.revision(database);
        if (revision !== expectedRevision) throw new GatewayError("conflict", "App data revision changed", false, { revision });
        database.exec("DELETE FROM state");
        database.prepare("UPDATE meta SET value = ? WHERE name = 'revision'").run(revision + 1);
        database.exec("COMMIT");
        return { appId, revision: revision + 1 };
      } catch (error) { database.exec("ROLLBACK"); throw error; }
    });
  }
  async commit(input: AppDataCommit, admit: () => Promise<void>): Promise<{ appId: string; revision: number }> {
    const appId = input.appId;
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
    const directory = await this.directory(appId);
      // No await separates the final authority cut from the SQLite transaction.
      await admit();
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

  /** One short-lived connection per operation under the Apps owner mutex.
   * Only a newly created data directory may initialize its database. */
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
