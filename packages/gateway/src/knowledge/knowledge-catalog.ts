import { DatabaseSync, type SQLInputValue } from "node:sqlite";

export type CatalogCollection = "records" | "coverage" | "suppressions" | "scopeExclusions" | "receipts" | "cleanup" | "recordCleanup" | "sourceIdentities";

// Validate rows at their read/write boundary, without materializing the corpus.
function catalogValue<T>(collection: CatalogCollection, raw: unknown): T {
  let decoded: unknown;
  if (collection === "sourceIdentities" && typeof raw === "string") {
    try { decoded = JSON.parse(raw); } catch { decoded = raw; }
  } else decoded = typeof raw === "string" ? JSON.parse(raw) : raw;
  if (collection === "cleanup") {
    if (decoded !== true) throw new Error("Invalid Knowledge object cleanup row");
    return decoded as T;
  }
  if (collection === "sourceIdentities") {
    if (typeof decoded !== "string") throw new Error("Invalid Knowledge source identity row");
    return decoded as T;
  }
  if (!decoded || typeof decoded !== "object" || Array.isArray(decoded)) throw new Error(`Invalid Knowledge ${collection} row`);
  const value = decoded as Record<string, unknown>;
  const strings = (item: unknown): item is string[] => Array.isArray(item) && item.every(part => typeof part === "string");
  switch (collection) {
    case "records":
      if (typeof value.latestRevisionId !== "string" || !strings(value.revisionIds) || !value.revisionIds.includes(value.latestRevisionId)
        || !["observation", "source", "note"].includes(value.kind as string) || !["personal", "research"].includes(value.scope as string)
        || typeof value.sortAt !== "number" || !Number.isFinite(value.sortAt) || !strings(value.recordRefs) || !strings(value.objectHashes)
        || (value.sourceIdentities !== undefined && !strings(value.sourceIdentities))
        || !Array.isArray(value.searchFields) || !value.searchFields.every(field => strings(field) && field.length === 2)) throw new Error("Invalid Knowledge record head");
      break;
    case "suppressions":
      if (typeof value.excluded !== "boolean" || typeof value.forgotten !== "boolean") throw new Error("Invalid Knowledge suppression");
      break;
    case "scopeExclusions":
      if (typeof value.excluded !== "boolean") throw new Error("Invalid Knowledge scope exclusion");
      break;
    case "receipts":
      if (typeof value.operation !== "string" || typeof value.requestHash !== "string" || !strings(value.recordIds)
        || !value.result || typeof value.result !== "object" || (value.invalidated !== undefined && typeof value.invalidated !== "boolean")) throw new Error("Invalid Knowledge receipt");
      break;
    case "recordCleanup":
      if (typeof value.recordId !== "string" || typeof value.revisionId !== "string") throw new Error("Invalid Knowledge record cleanup row");
      break;
    case "coverage":
      if (typeof value.id !== "string" || !value.range || !["observed", "empty", "excluded", "pending", "failed", "unavailable"].includes(value.disposition as string)) throw new Error("Invalid Knowledge coverage row");
      break;
  }
  return value as T;
}

// Escape keys as JSON strings: receipt keys contain NUL separators, and the
// SQLite text-column binding must never truncate their command identity.
class CatalogTable<T> {
  constructor(private readonly database: DatabaseSync, private readonly collection: CatalogCollection) {}
  get size(): number { return Number(this.database.prepare("SELECT count(*) AS count FROM entries WHERE collection = ?").get(this.collection)!.count); }
  get(key: string): T | undefined {
    const row = this.database.prepare("SELECT value FROM entries WHERE collection = ? AND key = ?").get(this.collection, JSON.stringify(key));
    return row ? catalogValue<T>(this.collection, String(row.value)) : undefined;
  }
  set(key: string, value: T): void {
    catalogValue<T>(this.collection, value);
    this.database.prepare("INSERT INTO entries(collection, key, value) VALUES (?, ?, ?) ON CONFLICT(collection, key) DO UPDATE SET value = excluded.value")
      .run(this.collection, JSON.stringify(key), JSON.stringify(value));
  }
  delete(key: string): void { this.database.prepare("DELETE FROM entries WHERE collection = ? AND key = ?").run(this.collection, JSON.stringify(key)); }
  *entries(): IterableIterator<[string, T]> {
    for (const row of this.database.prepare("SELECT key, value FROM entries WHERE collection = ? ORDER BY key").iterate(this.collection)) {
      yield [JSON.parse(String(row.key)) as string, catalogValue<T>(this.collection, String(row.value))];
    }
  }
  *values(): IterableIterator<T> { for (const [, value] of this.entries()) yield value; }
  *keys(): IterableIterator<string> {
    for (const row of this.database.prepare("SELECT key FROM entries WHERE collection = ? ORDER BY key").iterate(this.collection)) yield JSON.parse(String(row.key)) as string;
  }
}

export type KnowledgeTable<T> = Pick<CatalogTable<T>, keyof CatalogTable<T>>;

/** Canonical catalog, not a mirror/cache. Immutable bodies remain in records/.
 * The store's workspace mutex owns every connection/transaction through close,
 * including async record I/O; no reader can see an uncommitted catalog head.
 */
export class KnowledgeCatalog {
  private readonly database: DatabaseSync;
  private transaction = false;

  constructor(path: string, readOnly: boolean, initialize = false) {
    this.database = new DatabaseSync(path, { readOnly, enableForeignKeyConstraints: true, allowExtension: false });
    try {
      this.database.exec("PRAGMA trusted_schema = OFF; PRAGMA busy_timeout = 1000;");
      if (!readOnly) this.database.exec("PRAGMA synchronous = EXTRA; PRAGMA secure_delete = ON;");
      if (initialize) {
        this.database.exec(`
          PRAGMA journal_mode = DELETE;
          PRAGMA synchronous = EXTRA;
          PRAGMA secure_delete = ON;
          PRAGMA user_version = 1;
          CREATE TABLE control (id INTEGER PRIMARY KEY CHECK(id = 1), value TEXT NOT NULL CHECK(json_valid(value)));
          CREATE TABLE entries (collection TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL CHECK(json_valid(value)), PRIMARY KEY(collection, key)) WITHOUT ROWID;
          -- Include collection even in partial indexes: otherwise SQLite can
          -- prefer the primary key plus a corpus-wide temporary date sort.
          CREATE INDEX records_date ON entries(collection, json_extract(value, '$.sortAt') DESC, key) WHERE collection = 'records';
          CREATE INDEX records_kind_date ON entries(collection, json_extract(value, '$.kind'), json_extract(value, '$.sortAt') DESC, key) WHERE collection = 'records';
          CREATE INDEX records_scope_date ON entries(collection, json_extract(value, '$.scope'), json_extract(value, '$.sortAt') DESC, key) WHERE collection = 'records';
          CREATE INDEX records_kind_scope_date ON entries(collection, json_extract(value, '$.kind'), json_extract(value, '$.scope'), json_extract(value, '$.sortAt') DESC, key) WHERE collection = 'records';
          CREATE INDEX coverage_date ON entries(collection, json_extract(value, '$.recordedAt'), key) WHERE collection = 'coverage';
          CREATE INDEX coverage_scope ON entries(collection, json_extract(value, '$.range.sessionId'), json_extract(value, '$.range.branchId'), json_extract(value, '$.range.projectId'), json_extract(value, '$.range.fromEntryId')) WHERE collection = 'coverage';
          CREATE INDEX coverage_disposition ON entries(collection, json_extract(value, '$.disposition'), json_extract(value, '$.recordedAt')) WHERE collection = 'coverage';
          CREATE TABLE revision_owners (revision TEXT PRIMARY KEY, record TEXT NOT NULL);
          CREATE INDEX revision_record ON revision_owners(record);
        `);
      } else {
        const version = this.database.prepare("PRAGMA user_version").get()?.user_version;
        if (version !== 1) throw new Error("Unsupported Knowledge catalog version");
      }
    } catch (error) { this.database.close(); throw error; }
  }

  table<T>(collection: CatalogCollection): KnowledgeTable<T> { return new CatalogTable<T>(this.database, collection); }
  control<T>(): T {
    const row = this.database.prepare("SELECT value FROM control WHERE id = 1").get();
    if (!row) throw new Error("Knowledge catalog control is missing");
    return JSON.parse(String(row.value)) as T;
  }
  setControl(value: unknown): void {
    this.database.prepare("INSERT INTO control(id, value) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET value = excluded.value").run(JSON.stringify(value));
  }
  begin(): void { this.database.exec("BEGIN IMMEDIATE"); this.transaction = true; }
  commit(): void { this.database.exec("COMMIT"); this.transaction = false; }
  close(): void {
    try { if (this.transaction) this.database.exec("ROLLBACK"); }
    finally { this.transaction = false; this.database.close(); }
  }
  setRevisions(record: string, revisions: string[]): void {
    this.database.prepare("DELETE FROM revision_owners WHERE record = ?").run(record);
    const insert = this.database.prepare("INSERT INTO revision_owners(revision, record) VALUES (?, ?)");
    for (const revision of revisions) insert.run(revision, record);
  }
  revisionOwner(revision: string): string | undefined {
    const row = this.database.prepare("SELECT record FROM revision_owners WHERE revision = ?").get(revision);
    return row ? String(row.record) : undefined;
  }

  /** Callers supply fixed SQL fragments only; all user filters/cursors are bound. */
  rows<T>(collection: CatalogCollection, where: string, parameters: SQLInputValue[], order: string, limit?: number): Array<{ key: string; value: T }> {
    const query = `SELECT key, value FROM entries WHERE collection = '${collection}' ${where ? `AND (${where})` : ""} ORDER BY ${order}${limit === undefined ? "" : " LIMIT ?"}`;
    return this.database.prepare(query).all(...parameters, ...(limit === undefined ? [] : [limit]))
      .map(row => ({ key: JSON.parse(String(row.key)) as string, value: catalogValue<T>(collection, String(row.value)) }));
  }

  *scan<T>(collection: CatalogCollection, where: string, parameters: SQLInputValue[], order: string): IterableIterator<{ key: string; value: T }> {
    const query = `SELECT key, value FROM entries WHERE collection = '${collection}' ${where ? `AND (${where})` : ""} ORDER BY ${order}`;
    for (const row of this.database.prepare(query).iterate(...parameters)) {
      yield { key: JSON.parse(String(row.key)) as string, value: catalogValue<T>(collection, String(row.value)) };
    }
  }

  count(collection: CatalogCollection, where: string): number {
    return Number(this.database.prepare(`SELECT count(*) AS count FROM entries WHERE collection = '${collection}' AND (${where})`).get()!.count);
  }

  coverageCounts(): Record<string, number> {
    return Object.fromEntries(this.database.prepare("SELECT json_extract(value, '$.disposition') AS disposition, count(*) AS count FROM entries WHERE collection = 'coverage' GROUP BY disposition")
      .all().map(row => [String(row.disposition), Number(row.count)]));
  }
}
