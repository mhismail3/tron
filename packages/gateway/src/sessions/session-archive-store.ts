import { randomBytes } from "node:crypto";
import { mkdir, open, rename, rm } from "node:fs/promises";
import { dirname, join } from "node:path";
import { AsyncMutex } from "../util/async-mutex.js";
import { readJson } from "../util/json.js";

const VERSION = 1;
const MAXIMUM_BYTES = 2 * 1_048_576;
const MAXIMUM_SESSIONS = 50_000;
const MAXIMUM_ID_BYTES = 200;

/** Advertised by a Gateway that owns archive state and can hide archived rows
 * from `session.list`. */
export const SESSION_ARCHIVE_CAPABILITY = "session-archive.v1";

type ArchiveDictionary = Record<string, SessionArchiveRecord>;

interface SessionArchiveRecord {
  archivedAt: string;
}

interface SessionArchiveDocument {
  version: 1;
  sessions: ArchiveDictionary;
}

interface SessionArchiveStoreOptions {
  write?: (path: string, value: unknown) => Promise<void>;
  now?: () => Date;
}

/**
 * Tron-owned archive state for canonical sessions. Archiving is a dashboard
 * projection: it never rewrites a session file, and the record follows the
 * canonical session through delete, rebind and restart recovery. A document
 * that cannot be admitted fails instead of resetting to empty, because an empty
 * store would silently make every archived session visible again.
 */
export class SessionArchiveStore {
  private readonly path: string;
  private readonly mutex = new AsyncMutex();
  private readonly write: ((path: string, value: unknown) => Promise<void>) | undefined;
  private readonly now: () => Date;
  private document: SessionArchiveDocument;
  private changeRevision = 0;

  constructor(tronHome: string, options: SessionArchiveStoreOptions = {}) {
    this.path = join(tronHome, "gateway", "session-archive.json");
    this.write = options.write;
    this.now = options.now ?? (() => new Date());
    // Read-only projections are safe before initialize() in catalog-only test
    // and diagnostic paths. Production mutation remains initialize-gated by the
    // RuntimeRegistry lifecycle.
    this.document = emptyDocument();
  }

  async initialize(): Promise<void> {
    const loaded = await readJson<unknown | undefined>(this.path, undefined, MAXIMUM_BYTES);
    if (loaded === undefined) {
      await this.commit(emptyDocument());
      return;
    }
    this.document = admitDocument(loaded);
  }

  /** Monotonic count of committed changes. It joins the catalog page-source
   * generation so one pagination lease cannot mix archive states. */
  get revision(): number {
    return this.changeRevision;
  }

  archivedAt(sessionId: string): string | undefined {
    return ownRecord(this.document.sessions, sessionId)?.archivedAt;
  }

  /** Archive once. An already-archived session keeps its original timestamp, so
   * a replayed command cannot reorder the archived list. */
  async archive(sessionId: string): Promise<string> {
    return this.mutex.run(async () => {
      const document = this.requireDocument();
      const existing = ownRecord(document.sessions, sessionId);
      if (existing) return existing.archivedAt;
      if (Object.keys(document.sessions).length >= MAXIMUM_SESSIONS) {
        throw new Error("Session archive capacity exceeded");
      }
      const archivedAt = this.now().toISOString();
      const sessions = cloneDictionary(document.sessions);
      sessions[sessionId] = { archivedAt };
      await this.commit({ ...document, sessions });
      return archivedAt;
    });
  }

  async remove(sessionId: string): Promise<boolean> {
    return this.mutex.run(async () => {
      const document = this.requireDocument();
      if (!ownRecord(document.sessions, sessionId)) return false;
      const sessions = cloneDictionary(document.sessions);
      delete sessions[sessionId];
      await this.commit({ ...document, sessions });
      return true;
    });
  }

  /** Migrate only a true canonical identity replacement; never overwrite a target. */
  async rekey(previousId: string, nextId: string): Promise<boolean> {
    return this.mutex.run(async () => {
      const document = this.requireDocument();
      const previous = ownRecord(document.sessions, previousId);
      if (!previous || previousId === nextId) return false;
      if (ownRecord(document.sessions, nextId)) throw new Error("Replacement session already has archive state");
      const sessions = cloneDictionary(document.sessions);
      sessions[nextId] = previous;
      delete sessions[previousId];
      await this.commit({ ...document, sessions });
      return true;
    });
  }

  /** Drop records with no canonical owner. Callers must pass a retained set
   * derived from complete structural evidence; a partial scan cannot prove that
   * a session disappeared. */
  async prune(retainedSessionIds: ReadonlySet<string>): Promise<boolean> {
    return this.mutex.run(async () => {
      const document = this.requireDocument();
      const stale = Object.keys(document.sessions).filter((sessionId) => !retainedSessionIds.has(sessionId));
      if (stale.length === 0) return false;
      const sessions = cloneDictionary(document.sessions);
      stale.forEach((sessionId) => { delete sessions[sessionId]; });
      await this.commit({ ...document, sessions });
      return true;
    });
  }

  async assertAbsent(sessionId: string): Promise<void> {
    await this.mutex.run(async () => {
      if (ownRecord(this.requireDocument().sessions, sessionId)) {
        throw new Error("New session identity already has archive state");
      }
    });
  }

  private async commit(document: SessionArchiveDocument): Promise<void> {
    const persisted = `${JSON.stringify(document, null, 2)}\n`;
    if (Buffer.byteLength(persisted) > MAXIMUM_BYTES) {
      throw new Error("Session archive document exceeds its byte limit");
    }
    if (this.write) await this.write(this.path, document);
    else await durableWriteArchive(this.path, persisted);
    this.document = document;
    this.changeRevision += 1;
  }

  private requireDocument(): SessionArchiveDocument {
    return this.document;
  }
}

async function durableWriteArchive(path: string, encoded: string): Promise<void> {
  const directory = dirname(path);
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const temporary = `${path}.${process.pid}.${randomBytes(6).toString("hex")}.tmp`;
  let temporaryExists = false;
  try {
    const handle = await open(temporary, "wx", 0o600);
    temporaryExists = true;
    try {
      await handle.writeFile(encoded, "utf8");
      await handle.sync();
    } finally {
      await handle.close();
    }
    await rename(temporary, path);
    temporaryExists = false;
    const directoryHandle = await open(directory, "r");
    try {
      await directoryHandle.sync();
    } finally {
      await directoryHandle.close();
    }
  } catch (error) {
    if (temporaryExists) await rm(temporary, { force: true }).catch(() => {});
    throw error;
  }
}

function emptyDocument(): SessionArchiveDocument {
  return { version: VERSION, sessions: Object.create(null) as ArchiveDictionary };
}

function ownRecord(dictionary: ArchiveDictionary, sessionId: string): SessionArchiveRecord | undefined {
  return Object.prototype.hasOwnProperty.call(dictionary, sessionId) ? dictionary[sessionId] : undefined;
}

function cloneDictionary(dictionary: ArchiveDictionary): ArchiveDictionary {
  return Object.assign(Object.create(null) as ArchiveDictionary, dictionary);
}

function boundedString(value: unknown, maximum: number): value is string {
  return typeof value === "string" && value.length > 0 && Buffer.byteLength(value) <= maximum;
}

function boundedTimestamp(value: unknown): value is string {
  return typeof value === "string" && value.length <= 40 && Number.isFinite(Date.parse(value));
}

function admitDocument(value: unknown): SessionArchiveDocument {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid session archive document");
  const root = value as Record<string, unknown>;
  if (root.version !== VERSION
    || !root.sessions || typeof root.sessions !== "object" || Array.isArray(root.sessions)) {
    throw new Error("Invalid session archive document");
  }
  const entries = Object.entries(root.sessions as Record<string, unknown>);
  if (entries.length > MAXIMUM_SESSIONS) throw new Error("Session archive document exceeds capacity");
  const sessions = Object.create(null) as ArchiveDictionary;
  for (const [sessionId, raw] of entries) {
    if (!boundedString(sessionId, MAXIMUM_ID_BYTES) || !raw || typeof raw !== "object" || Array.isArray(raw)) {
      throw new Error("Invalid session archive record");
    }
    const record = raw as Record<string, unknown>;
    if (Object.keys(record).length !== 1 || !boundedTimestamp(record.archivedAt)) {
      throw new Error("Invalid session archive record");
    }
    sessions[sessionId] = { archivedAt: record.archivedAt };
  }
  return { version: VERSION, sessions };
}
