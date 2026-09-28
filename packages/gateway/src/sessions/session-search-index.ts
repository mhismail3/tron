import { DatabaseSync } from "node:sqlite";
import { chmod, mkdir, rm } from "node:fs/promises";
import { chmodSync, rmSync, statSync } from "node:fs";
import { dirname } from "node:path";
import { yieldToEventLoop } from "../util/event-loop-yield.js";
import {
  SESSION_SEARCH_MAX_INDEX_BYTES,
  SESSION_SEARCH_MAX_INDEX_PASSAGES,
  SESSION_SEARCH_MAX_INDEX_SESSIONS,
  digest,
  normalizeForSearch,
  type SessionSearchAnchorRevision,
} from "./session-search-contract.js";
import { terms, trigrams, type SearchTextEntry } from "./session-search-text.js";

export interface SearchIndexDocument {
  sessionId: string;
  title: string;
  cwd: string;
  updatedAt: string;
  fileIdentity: string;
  branchDigest: string;
  leafEntryId?: string;
  forkBoundary?: SessionSearchAnchorRevision["forkBoundary"];
  entries: SearchTextEntry[];
}

/** The catalog owner's verified facts for one canonical file (session-catalog.ts
 * `SessionCatalogIdentity`). A row is stamped with the facts observed before its
 * transcript read and is reused only while the catalog still reports exactly
 * those facts: the catalog is the one owner of what a canonical file is, and a
 * durable catalog row that no complete cut has re-verified proves nothing about
 * a file that changed while the Gateway was down. */
export interface SearchIndexStamp {
  fileIdentity: string;
  size: number;
  mtimeMs: number;
}

/** One indexed session's stored facts, for the owner's warm-up decision. */
export interface SearchIndexSessionFacts {
  sessionId: string;
  fileIdentity: string;
  branchDigest: string;
  /** Null for a row written without a verified catalog cut (an on-demand dirty
   * refresh): it is re-derived on the next start instead of trusted. */
  reuse: SearchIndexStamp | null;
}

/** The persisted table shape of this index. These rows are durable state, so a
 * build that cannot read them as its own discards them instead of guessing. */
const SESSION_SEARCH_INDEX_TABLE_VERSION = "session-search-index-2";
/** How a row's postings, branch digest and anchors are derived from a canonical
 * cut, independent of the table shape. A durable row is only this build's own
 * while both versions match, so a change to `terms()`, `trigrams()`,
 * `extractSearchText` or the branch digest must bump this: otherwise stale
 * postings are reused for every unchanged session and queries derived the new
 * way never match them. */
const SESSION_SEARCH_INDEX_DERIVATION_VERSION = "session-search-derivation-1";
const SESSION_SEARCH_INDEX_SCHEMA = `${SESSION_SEARCH_INDEX_TABLE_VERSION}:${SESSION_SEARCH_INDEX_DERIVATION_VERSION}`;

interface SearchIndexCandidate {
  rowID: string;
  sessionId: string;
  title: string;
  cwd: string;
  updatedAt: string;
  entryId: string;
  parentEntryId: string | null;
  ordinal: number;
  role: "user" | "assistant";
  anchorRevision: SessionSearchAnchorRevision;
  lexicalScore: number;
}

interface SearchIndexStats {
  indexRevision: string;
  sessionsIndexed: number;
  passagesIndexed: number;
  bytes: number;
  state: "complete" | "indexing" | "partial" | "unavailable";
  reason?: string;
}

const INDEX_STORAGE_HEADROOM = 4;
/** Longest stretch of posting insertion or deletion before the loop is handed
 * back. One large transcript measured 565-821 ms of synchronous inserts and
 * 491 ms of synchronous removal (G-11 profile), which is the event-loop stall
 * these slices bound. */
const INDEX_WRITE_SLICE_MS = 20;
/** Passages removed per statement inside a delete slice. One batch's postings
 * stay inside `INDEX_WRITE_SLICE_MS` on a loaded host (measured p50 11 ms,
 * p95 33 ms for a 3,000-passage session), and a smaller batch only pays more
 * statement overhead across the same rows. */
const INDEX_DELETE_BATCH_ROWS = 25;

function finiteText(value: unknown, maximum = 4_096): string {
  if (typeof value !== "string" || !value || Buffer.byteLength(value, "utf8") > maximum) throw new Error("Invalid search index text");
  return value;
}

function rowID(document: SearchIndexDocument, entry: SearchTextEntry): string {
  // SQLite text bindings are NUL-terminated on some supported Node builds.
  // IDs are already bounded and validated, so a visible delimiter is safer.
  return `${document.sessionId}::${entry.id}::${entry.ordinal}`;
}

/** Persisted, contentless lexical acceleration. Canonical text never enters this
 * database; callers reread the owning canonical cut before publication. A row
 * is reused on a later start only while the catalog owner still reports the
 * file facts the row was indexed from, so an unchanged corpus is warmed
 * without reading a transcript again. */
export class SessionSearchIndex {
  private database: DatabaseSync;
  private closed = false;
  private indexRevision = "empty";
  private schemaMatches = false;
  // One write lane for this file. A replace holds its transaction across the
  // yields that bound each insert and delete slice, and SQLite refuses a nested
  // transaction on one connection, so writers must not overlap each other.
  private writeTail: Promise<void> = Promise.resolve();

  constructor(private readonly path: string, private readonly maxStorageBytes = SESSION_SEARCH_MAX_INDEX_BYTES) {
    this.database = new DatabaseSync(path, { allowExtension: false, enableForeignKeyConstraints: true });
    this.configureDatabase();
  }

  private configureDatabase(): void {
    this.database.exec("PRAGMA trusted_schema = OFF; PRAGMA busy_timeout = 1000; PRAGMA journal_mode = DELETE; PRAGMA synchronous = EXTRA; PRAGMA secure_delete = ON;");
    this.database.exec(`
      CREATE TABLE IF NOT EXISTS control (id INTEGER PRIMARY KEY CHECK(id = 1), value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS schema (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
      CREATE TABLE IF NOT EXISTS sessions (
        session_id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        cwd TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        file_identity TEXT NOT NULL,
        branch_digest TEXT NOT NULL,
        leaf_entry_id TEXT,
        fork_boundary TEXT,
        reuse_identity TEXT,
        reuse_size INTEGER,
        reuse_mtime REAL,
        posting_bytes INTEGER NOT NULL DEFAULT 0
      ) WITHOUT ROWID;
      CREATE TABLE IF NOT EXISTS passages (
        row_id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
        entry_id TEXT NOT NULL,
        parent_entry_id TEXT,
        ordinal INTEGER NOT NULL,
        role TEXT NOT NULL CHECK(role IN ('user','assistant')),
        UNIQUE(session_id, entry_id, ordinal)
      ) WITHOUT ROWID;
      CREATE TABLE IF NOT EXISTS passage_terms (term TEXT NOT NULL, row_id TEXT NOT NULL REFERENCES passages(row_id) ON DELETE CASCADE, PRIMARY KEY(term, row_id)) WITHOUT ROWID;
      CREATE TABLE IF NOT EXISTS passage_trigrams (gram TEXT NOT NULL, row_id TEXT NOT NULL REFERENCES passages(row_id) ON DELETE CASCADE, PRIMARY KEY(gram, row_id)) WITHOUT ROWID;
      CREATE INDEX IF NOT EXISTS passages_session ON passages(session_id, ordinal, row_id);
      CREATE INDEX IF NOT EXISTS terms_row ON passage_terms(row_id, term);
      CREATE INDEX IF NOT EXISTS trigrams_row ON passage_trigrams(row_id, gram);
    `);
    this.schemaMatches = (this.database.prepare("SELECT value FROM schema WHERE key = 'schema'").get() as { value?: string } | undefined)?.value === SESSION_SEARCH_INDEX_SCHEMA;
    const control = this.database.prepare("SELECT value FROM control WHERE id = 1").get() as { value?: string } | undefined;
    this.indexRevision = typeof control?.value === "string" ? control.value : "empty";
  }

  /** Records this build's derivation stamp. It is written only once the tables
   * have actually been created for this schema: marking a file current before
   * `recreate()` runs would leave an old-shaped table stamped as this build's
   * own if the process died in between, and every later read would fail on a
   * missing column until someone deleted the file by hand. */
  private stampSchema(): void {
    this.database.prepare("INSERT INTO schema(key,value) VALUES('schema',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value").run(SESSION_SEARCH_INDEX_SCHEMA);
  }

  static async open(path: string, options: { maxStorageBytes?: number } = {}): Promise<SessionSearchIndex> {
    await mkdir(dirname(path), { recursive: true, mode: 0o700 });
    let index: SessionSearchIndex;
    try {
      index = new SessionSearchIndex(path, options.maxStorageBytes);
    } catch {
      // A file this build cannot open as its own index proves nothing: it is
      // discarded, and the next warm-up fills the empty index from canonical
      // JSONL rather than failing the capability.
      await SessionSearchIndex.discard(path);
      index = new SessionSearchIndex(path, options.maxStorageBytes);
    }
    // The persisted rows are reused only when this build's schema wrote them.
    if (!index.schemaMatches || index.storageBytes() > index.maxStorageBytes) index.recreate();
    await chmod(path, 0o600);
    return index;
  }

  private static async discard(path: string): Promise<void> {
    await Promise.all([path, `${path}-wal`, `${path}-shm`].map(file => rm(file, { force: true })));
  }

  /** Replace one session's rows. `stamp` is the catalog facts observed before a
   * read of the canonical *file*, or omitted for a read those facts do not
   * describe (an on-demand refresh of a session that changed while running, or
   * an open session's in-memory branch): an unstamped row is re-derived on the
   * next start instead of reused. */
  async replace(document: SearchIndexDocument, stamp?: SearchIndexStamp): Promise<void> {
    this.assertOpen();
    return await this.enqueueWrite(() => this.replaceOwned(document, stamp));
  }

  private async replaceOwned(document: SearchIndexDocument, stamp?: SearchIndexStamp): Promise<void> {
    this.assertOpen();
    if (document.entries.length > SESSION_SEARCH_MAX_INDEX_PASSAGES) throw new Error("Session search index passage bound exceeded");
    const sessionID = finiteText(document.sessionId, 512);
    const title = finiteText(document.title, 8_192);
    const cwd = finiteText(document.cwd, 8_192);
    const current = this.currentBudget(sessionID);
    const incoming = await this.documentBudget(document);
    if (current.sessions - (current.hasSession ? 1 : 0) + 1 > SESSION_SEARCH_MAX_INDEX_SESSIONS
      || current.passages - current.sessionPassages + incoming.passages > SESSION_SEARCH_MAX_INDEX_PASSAGES
      || (current.bytes - current.sessionBytes + incoming.bytes) * INDEX_STORAGE_HEADROOM > this.maxStorageBytes) {
      throw new Error("Session search index bounds exceeded");
    }
    this.database.exec("BEGIN IMMEDIATE");
    try {
      await this.deleteSessionRows(sessionID);
      this.database.prepare("DELETE FROM sessions WHERE session_id = ?").run(sessionID);
      this.database.prepare("INSERT INTO sessions(session_id,title,cwd,updated_at,file_identity,branch_digest,leaf_entry_id,fork_boundary,reuse_identity,reuse_size,reuse_mtime,posting_bytes) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)")
        .run(sessionID, title, cwd, finiteText(document.updatedAt, 128), finiteText(document.fileIdentity, 512), finiteText(document.branchDigest, 128), document.leafEntryId ?? null, document.forkBoundary ? JSON.stringify(document.forkBoundary) : null,
          stamp ? finiteText(stamp.fileIdentity, 512) : null, stamp ? stamp.size : null, stamp ? stamp.mtimeMs : null, incoming.bytes);
      const passage = this.database.prepare("INSERT INTO passages(row_id,session_id,entry_id,parent_entry_id,ordinal,role) VALUES (?,?,?,?,?,?)");
      const term = this.database.prepare("INSERT OR IGNORE INTO passage_terms(term,row_id) VALUES (?,?)");
      const gram = this.database.prepare("INSERT OR IGNORE INTO passage_trigrams(gram,row_id) VALUES (?,?)");
      // The transaction stays open across these yields: one connection owns this
      // file, the write lane keeps a second writer out of it, and a reader that
      // arrives mid-insert sees fewer postings for the session, never a wrong
      // one (every candidate is re-validated against its canonical cut before
      // publication).
      let sliceStartedAt = performance.now();
      for (const entry of document.entries) {
        const id = rowID(document, entry);
        passage.run(id, sessionID, finiteText(entry.id, 512), entry.parentId, entry.ordinal, entry.role);
        for (const value of terms(entry.text)) term.run(value, id);
        for (const value of trigrams(entry.text)) gram.run(value, id);
        if (performance.now() - sliceStartedAt < INDEX_WRITE_SLICE_MS) continue;
        await yieldToEventLoop();
        sliceStartedAt = performance.now();
      }
      this.indexRevision = digest({ previous: this.indexRevision, sessionID, fileIdentity: document.fileIdentity, branchDigest: document.branchDigest, count: document.entries.length });
      this.database.prepare("INSERT INTO control(id,value) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value").run(this.indexRevision);
      this.database.exec("COMMIT");
      if (this.storageBytes() > this.maxStorageBytes) {
        this.recreate();
        throw new Error("Session search index storage bound exceeded; the index was recreated");
      }
    } catch (error) {
      try { this.database.exec("ROLLBACK"); } catch { /* preserve original */ }
      throw error;
    }
  }

  /** Every indexed session's stored facts, for the warm-up's reuse decision. */
  sessionFacts(): SearchIndexSessionFacts[] {
    this.assertOpen();
    const rows = this.database.prepare("SELECT session_id, file_identity, branch_digest, reuse_identity, reuse_size, reuse_mtime FROM sessions").all() as Array<Record<string, unknown>>;
    return rows.map(row => ({
      sessionId: String(row.session_id),
      fileIdentity: String(row.file_identity),
      branchDigest: String(row.branch_digest),
      reuse: row.reuse_identity === null || row.reuse_size === null || row.reuse_mtime === null
        ? null
        : { fileIdentity: String(row.reuse_identity), size: Number(row.reuse_size), mtimeMs: Number(row.reuse_mtime) },
    }));
  }

  /** Delete one session's rows in bounded batches, on the same write lane as
   * `replace()`: a remove that ran during another writer's transaction would
   * silently join it and be undone by its rollback. */
  async remove(sessionID: string): Promise<void> {
    this.assertOpen();
    return await this.enqueueWrite(() => this.removeOwned(sessionID));
  }

  private async removeOwned(sessionID: string): Promise<void> {
    this.assertOpen();
    this.database.exec("BEGIN IMMEDIATE");
    try {
      await this.deleteSessionRows(sessionID);
      this.database.prepare("DELETE FROM sessions WHERE session_id = ?").run(sessionID);
      this.database.exec("COMMIT");
    } catch (error) {
      try { this.database.exec("ROLLBACK"); } catch { /* preserve original */ }
      throw error;
    }
    if (this.storageBytes() > this.maxStorageBytes) {
      this.recreate();
      return;
    }
    this.indexRevision = digest({ previous: this.indexRevision, removed: sessionID });
    this.database.prepare("INSERT INTO control(id,value) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value").run(this.indexRevision);
  }

  /** One writer at a time, in arrival order. */
  private enqueueWrite(operation: () => Promise<void>): Promise<void> {
    const run = this.writeTail.then(operation, operation);
    this.writeTail = run.then(() => undefined, () => undefined);
    return run;
  }

  /** Removes one session's passages and postings in bounded batches, handing the
   * loop back between them. `DELETE FROM sessions WHERE session_id = ?` alone
   * cascades the whole session in one statement, which is the 491 ms stall
   * G-11 profiled; this walks the same rows `INDEX_DELETE_BATCH_ROWS` at a
   * time, keyed by explicit row ids so each delete is an index probe instead of
   * a scan of every posting. The trailing sessions delete then has no cascade
   * work left. */
  private async deleteSessionRows(sessionID: string): Promise<void> {
    const selectRows = this.database.prepare("SELECT row_id FROM passages WHERE session_id = ? LIMIT ?");
    let sliceStartedAt = performance.now();
    for (;;) {
      const ids = (selectRows.all(sessionID, INDEX_DELETE_BATCH_ROWS) as Array<{ row_id: string }>).map(row => row.row_id);
      if (ids.length === 0) return;
      const placeholders = ids.map(() => "?").join(",");
      this.database.prepare(`DELETE FROM passage_terms WHERE row_id IN (${placeholders})`).run(...ids);
      this.database.prepare(`DELETE FROM passage_trigrams WHERE row_id IN (${placeholders})`).run(...ids);
      this.database.prepare(`DELETE FROM passages WHERE row_id IN (${placeholders})`).run(...ids);
      if (performance.now() - sliceStartedAt < INDEX_WRITE_SLICE_MS) continue;
      await yieldToEventLoop();
      sliceStartedAt = performance.now();
    }
  }

  candidates(query: string, limit: number): SearchIndexCandidate[] {
    this.assertOpen();
    const normalized = normalizeForSearch(query);
    const queryTerms = terms(normalized);
    const queryGrams = trigrams(normalized);
    if (!queryTerms.length && !queryGrams.length) return [];
    const values = [...queryTerms, ...queryGrams];
    const placeholders = values.map(() => "?").join(",");
    const rows = this.database.prepare(`
      SELECT p.row_id AS row_id, p.session_id AS session_id, p.entry_id AS entry_id,
        p.parent_entry_id AS parent_entry_id, p.ordinal AS ordinal, p.role AS role,
        s.title AS title, s.cwd AS cwd, s.updated_at AS updated_at,
        s.file_identity AS file_identity, s.branch_digest AS branch_digest,
        s.leaf_entry_id AS leaf_entry_id, s.fork_boundary AS fork_boundary,
        (SELECT count(*) FROM passage_terms t WHERE t.row_id = p.row_id AND t.term IN (${placeholders}))
          + (SELECT count(*) FROM passage_trigrams g WHERE g.row_id = p.row_id AND g.gram IN (${placeholders})) AS score
      FROM passages p JOIN sessions s ON s.session_id = p.session_id
      WHERE p.row_id IN (SELECT row_id FROM passage_terms WHERE term IN (${placeholders}) UNION SELECT row_id FROM passage_trigrams WHERE gram IN (${placeholders}))
      ORDER BY score DESC, p.session_id ASC, p.entry_id ASC
      LIMIT ?
    `).all(...values, ...values, ...values, ...values, limit) as Array<Record<string, unknown>>;
    return rows.map(row => ({
      rowID: String(row.row_id), sessionId: String(row.session_id), title: String(row.title), cwd: String(row.cwd), updatedAt: String(row.updated_at),
      entryId: String(row.entry_id), parentEntryId: row.parent_entry_id === null ? null : String(row.parent_entry_id), ordinal: Number(row.ordinal), role: row.role as "user" | "assistant",
      anchorRevision: {
        indexRevision: this.indexRevision, fileIdentity: String(row.file_identity), branchDigest: String(row.branch_digest),
        ...(row.leaf_entry_id ? { leafEntryId: String(row.leaf_entry_id) } : {}), entryOrdinal: Number(row.ordinal),
        ...(row.fork_boundary ? { forkBoundary: JSON.parse(String(row.fork_boundary)) } : {}),
      }, lexicalScore: Number(row.score) / Math.max(1, queryTerms.length + queryGrams.length),
    }));
  }

  /** One session's rows and bytes, priced from the stored per-row posting total
   * instead of scanning every posting: the byte total is the same column the
   * insert estimated (`documentBudget`), and this runs before every document
   * insert (G-11 profile). */
  private currentBudget(sessionID: string): { sessions: number; passages: number; bytes: number; hasSession: boolean; sessionPassages: number; sessionBytes: number } {
    const sessions = Number((this.database.prepare("SELECT count(*) AS n FROM sessions").get() as { n: number }).n);
    const passages = Number((this.database.prepare("SELECT count(*) AS n FROM passages").get() as { n: number }).n);
    const bytes = Number((this.database.prepare("SELECT ifnull(sum(posting_bytes),0) AS n FROM sessions").get() as { n: number }).n);
    const session = this.database.prepare("SELECT posting_bytes AS bytes FROM sessions WHERE session_id = ?").get(sessionID) as { bytes: number } | undefined;
    return { sessions, passages, bytes, hasSession: session !== undefined, sessionPassages: Number((this.database.prepare("SELECT count(*) AS n FROM passages WHERE session_id = ?").get(sessionID) as { n: number }).n), sessionBytes: Number(session?.bytes ?? 0) };
  }

  /** The postings byte estimate for one document, computed in the same slices as
   * the insert so one large transcript cannot hold the event loop to price it. */
  private async documentBudget(document: SearchIndexDocument): Promise<{ passages: number; bytes: number }> {
    let bytes = 0;
    let sliceStartedAt = performance.now();
    for (const entry of document.entries) {
      const row = rowID(document, entry);
      bytes += [...terms(entry.text)].reduce((sum, value) => sum + Buffer.byteLength(value) + Buffer.byteLength(row), 0);
      bytes += [...trigrams(entry.text)].reduce((sum, value) => sum + Buffer.byteLength(value) + Buffer.byteLength(row), 0);
      if (performance.now() - sliceStartedAt < INDEX_WRITE_SLICE_MS) continue;
      await yieldToEventLoop();
      sliceStartedAt = performance.now();
    }
    return { passages: document.entries.length, bytes };
  }

  private storageBytes(): number {
    try { return statSync(this.path).size; } catch { return Number.MAX_SAFE_INTEGER; }
  }

  stats(): SearchIndexStats {
    this.assertOpen();
    const sessions = Number((this.database.prepare("SELECT count(*) AS n FROM sessions").get() as { n: number }).n);
    const passages = Number((this.database.prepare("SELECT count(*) AS n FROM passages").get() as { n: number }).n);
    const bytes = this.storageBytes();
    const state = sessions > SESSION_SEARCH_MAX_INDEX_SESSIONS || passages > SESSION_SEARCH_MAX_INDEX_PASSAGES || bytes > this.maxStorageBytes ? "partial" : "complete";
    return { indexRevision: this.indexRevision, sessionsIndexed: sessions, passagesIndexed: passages, bytes, state };
  }

  close(): void { if (!this.closed) { this.closed = true; this.database.close(); } }

  private recreate(): void {
    this.database.close();
    for (const file of [this.path, `${this.path}-wal`, `${this.path}-shm`]) rmSync(file, { force: true });
    this.database = new DatabaseSync(this.path, { allowExtension: false, enableForeignKeyConstraints: true });
    this.configureDatabase();
    this.stampSchema();
    this.schemaMatches = true;
    chmodSync(this.path, 0o600);
    this.indexRevision = "empty";
  }

  private assertOpen(): void { if (this.closed) throw new Error("Session search index is closed"); }
}
