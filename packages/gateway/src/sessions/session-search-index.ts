import { DatabaseSync } from "node:sqlite";
import { chmod, mkdir, rm } from "node:fs/promises";
import { chmodSync, rmSync, statSync } from "node:fs";
import { dirname } from "node:path";
import { createHash } from "node:crypto";
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

export interface SearchIndexCandidate {
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

export interface SearchIndexStats {
  indexRevision: string;
  sessionsIndexed: number;
  passagesIndexed: number;
  vectorsIndexed: number;
  vectorsTotal: number;
  bytes: number;
  state: "complete" | "indexing" | "partial" | "unavailable";
  reason?: string;
}

const INDEX_STORAGE_HEADROOM = 4;

function finiteText(value: unknown, maximum = 4_096): string {
  if (typeof value !== "string" || !value || Buffer.byteLength(value, "utf8") > maximum) throw new Error("Invalid search index text");
  return value;
}

function rowID(document: SearchIndexDocument, entry: SearchTextEntry): string {
  // SQLite text bindings are NUL-terminated on some supported Node builds.
  // IDs are already bounded and validated, so a visible delimiter is safer.
  return `${document.sessionId}::${entry.id}::${entry.ordinal}`;
}

/** Disposable contentless lexical acceleration. Canonical text never enters
 * this database; callers reread the owning canonical cut before publication. */
export class SessionSearchIndex {
  private database: DatabaseSync;
  private closed = false;
  private indexRevision = "empty";

  constructor(private readonly path: string, private readonly maxStorageBytes = SESSION_SEARCH_MAX_INDEX_BYTES) {
    this.database = new DatabaseSync(path, { allowExtension: false, enableForeignKeyConstraints: true });
    this.configureDatabase();
  }

  private configureDatabase(): void {
    this.database.exec("PRAGMA trusted_schema = OFF; PRAGMA busy_timeout = 1000; PRAGMA journal_mode = DELETE; PRAGMA synchronous = EXTRA; PRAGMA secure_delete = ON;");
    this.database.exec(`
      CREATE TABLE IF NOT EXISTS control (id INTEGER PRIMARY KEY CHECK(id = 1), value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS sessions (
        session_id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        cwd TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        file_identity TEXT NOT NULL,
        branch_digest TEXT NOT NULL,
        leaf_entry_id TEXT,
        fork_boundary TEXT
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
    const control = this.database.prepare("SELECT value FROM control WHERE id = 1").get() as { value?: string } | undefined;
    this.indexRevision = typeof control?.value === "string" ? control.value : "empty";
  }

  static async open(path: string, options: { maxStorageBytes?: number } = {}): Promise<SessionSearchIndex> {
    await mkdir(dirname(path), { recursive: true, mode: 0o700 });
    await Promise.all([path, `${path}-wal`, `${path}-shm`].map(file => rm(file, { force: true })));
    const index = new SessionSearchIndex(path, options.maxStorageBytes);
    if (index.storageBytes() > index.maxStorageBytes) index.recreate();
    await chmod(path, 0o600);
    return index;
  }

  replace(document: SearchIndexDocument): void {
    this.assertOpen();
    if (document.entries.length > SESSION_SEARCH_MAX_INDEX_PASSAGES) throw new Error("Session search index passage bound exceeded");
    const sessionID = finiteText(document.sessionId, 512);
    const title = finiteText(document.title, 8_192);
    const cwd = finiteText(document.cwd, 8_192);
    const current = this.currentBudget(sessionID);
    const incoming = this.documentBudget(document);
    if (current.sessions - (current.hasSession ? 1 : 0) + 1 > SESSION_SEARCH_MAX_INDEX_SESSIONS
      || current.passages - current.sessionPassages + incoming.passages > SESSION_SEARCH_MAX_INDEX_PASSAGES
      || (current.bytes - current.sessionBytes + incoming.bytes) * INDEX_STORAGE_HEADROOM > this.maxStorageBytes) {
      throw new Error("Session search index bounds exceeded");
    }
    this.database.exec("BEGIN IMMEDIATE");
    try {
      this.database.prepare("DELETE FROM sessions WHERE session_id = ?").run(sessionID);
      this.database.prepare("INSERT INTO sessions(session_id,title,cwd,updated_at,file_identity,branch_digest,leaf_entry_id,fork_boundary) VALUES (?,?,?,?,?,?,?,?)")
        .run(sessionID, title, cwd, finiteText(document.updatedAt, 128), finiteText(document.fileIdentity, 512), finiteText(document.branchDigest, 128), document.leafEntryId ?? null, document.forkBoundary ? JSON.stringify(document.forkBoundary) : null);
      const passage = this.database.prepare("INSERT INTO passages(row_id,session_id,entry_id,parent_entry_id,ordinal,role) VALUES (?,?,?,?,?,?)");
      const term = this.database.prepare("INSERT OR IGNORE INTO passage_terms(term,row_id) VALUES (?,?)");
      const gram = this.database.prepare("INSERT OR IGNORE INTO passage_trigrams(gram,row_id) VALUES (?,?)");
      for (const entry of document.entries) {
        const id = rowID(document, entry);
        passage.run(id, sessionID, finiteText(entry.id, 512), entry.parentId, entry.ordinal, entry.role);
        for (const value of terms(entry.text)) term.run(value, id);
        for (const value of trigrams(entry.text)) gram.run(value, id);
      }
      this.indexRevision = digest({ previous: this.indexRevision, sessionID, fileIdentity: document.fileIdentity, branchDigest: document.branchDigest, count: document.entries.length });
      this.database.prepare("INSERT INTO control(id,value) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value").run(this.indexRevision);
      this.database.exec("COMMIT");
      if (this.storageBytes() > this.maxStorageBytes) {
        this.recreate();
        throw new Error("Session search index storage bound exceeded; disposable index was recreated");
      }
    } catch (error) {
      try { this.database.exec("ROLLBACK"); } catch { /* preserve original */ }
      throw error;
    }
  }

  clear(): void {
    this.assertOpen();
    this.recreate();
  }

  remove(sessionID: string): void {
    this.assertOpen();
    this.database.prepare("DELETE FROM sessions WHERE session_id = ?").run(sessionID);
    if (this.storageBytes() > this.maxStorageBytes) {
      this.recreate();
      return;
    }
    this.indexRevision = digest({ previous: this.indexRevision, removed: sessionID });
    this.database.prepare("INSERT INTO control(id,value) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value").run(this.indexRevision);
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

  private currentBudget(sessionID: string): { sessions: number; passages: number; bytes: number; hasSession: boolean; sessionPassages: number; sessionBytes: number } {
    const sessions = Number((this.database.prepare("SELECT count(*) AS n FROM sessions").get() as { n: number }).n);
    const passages = Number((this.database.prepare("SELECT count(*) AS n FROM passages").get() as { n: number }).n);
    const bytes = Number((this.database.prepare("SELECT ifnull(sum(length(term)+length(row_id)),0) AS n FROM passage_terms").get() as { n: number }).n)
      + Number((this.database.prepare("SELECT ifnull(sum(length(gram)+length(row_id)),0) AS n FROM passage_trigrams").get() as { n: number }).n);
    const sessionPassages = Number((this.database.prepare("SELECT count(*) AS n FROM passages WHERE session_id = ?").get(sessionID) as { n: number }).n);
    const sessionBytes = Number((this.database.prepare("SELECT ifnull((SELECT sum(length(t.term)+length(t.row_id)) FROM passage_terms t WHERE t.row_id IN (SELECT row_id FROM passages WHERE session_id = ?)),0) + ifnull((SELECT sum(length(g.gram)+length(g.row_id)) FROM passage_trigrams g WHERE g.row_id IN (SELECT row_id FROM passages WHERE session_id = ?)),0) AS n").get(sessionID, sessionID) as { n: number }).n);
    return { sessions, passages, bytes, hasSession: Number((this.database.prepare("SELECT count(*) AS n FROM sessions WHERE session_id = ?").get(sessionID) as { n: number }).n) > 0, sessionPassages, sessionBytes };
  }

  private documentBudget(document: SearchIndexDocument): { passages: number; bytes: number } {
    let bytes = 0;
    for (const entry of document.entries) {
      const row = rowID(document, entry);
      bytes += [...terms(entry.text)].reduce((sum, value) => sum + Buffer.byteLength(value) + Buffer.byteLength(row), 0);
      bytes += [...trigrams(entry.text)].reduce((sum, value) => sum + Buffer.byteLength(value) + Buffer.byteLength(row), 0);
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
    return { indexRevision: this.indexRevision, sessionsIndexed: sessions, passagesIndexed: passages, vectorsIndexed: 0, vectorsTotal: 0, bytes, state };
  }

  close(): void { if (!this.closed) { this.closed = true; this.database.close(); } }

  private recreate(): void {
    this.database.close();
    for (const file of [this.path, `${this.path}-wal`, `${this.path}-shm`]) rmSync(file, { force: true });
    this.database = new DatabaseSync(this.path, { allowExtension: false, enableForeignKeyConstraints: true });
    this.configureDatabase();
    chmodSync(this.path, 0o600);
    this.indexRevision = "empty";
  }

  private assertOpen(): void { if (this.closed) throw new Error("Session search index is closed"); }
}
