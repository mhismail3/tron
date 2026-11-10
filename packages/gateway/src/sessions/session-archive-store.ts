import { AsyncMutex } from "../util/async-mutex.js";
import { durablePublishBoundedJson } from "../foundation/durable-json.js";
import { boundedString, boundedTimestamp, cloneDictionary, ownRecord, readJsonDocument } from "../foundation/json.js";
import { tronHomePath } from "../foundation/tron-home-layout.js";

const VERSION = 1;
const MAXIMUM_BYTES = 2 * 1_048_576;
const MAXIMUM_SESSIONS = 50_000;
const MAXIMUM_ID_BYTES = 200;

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
  now?: () => Date;
}

export class SessionArchiveStore {
  private readonly path: string;
  private readonly mutex = new AsyncMutex();
  private readonly now: () => Date;
  private document: SessionArchiveDocument | undefined;
  private changeRevision = 0;

  constructor(tronHome: string, options: SessionArchiveStoreOptions = {}) {
    this.path = tronHomePath(tronHome, "gateway/session-archive.json");
    this.now = options.now ?? (() => new Date());
  }

  async initialize(): Promise<void> {
    const loaded = await readJsonDocument(this.path, admitDocument, MAXIMUM_BYTES);
    if (loaded === undefined) {
      await this.commit(emptyDocument());
      return;
    }
    this.document = loaded;
  }

  get revision(): number {
    return this.changeRevision;
  }

  archivedAt(sessionId: string): string | undefined {
    const document = this.document;
    return document === undefined ? undefined : ownRecord(document.sessions, sessionId)?.archivedAt;
  }

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

  async prune(retainedSessionIds: ReadonlySet<string>): Promise<readonly string[]> {
    return this.mutex.run(async () => {
      const document = this.requireDocument();
      const stale = Object.keys(document.sessions).filter((sessionId) => !retainedSessionIds.has(sessionId));
      if (stale.length === 0) return [];
      const sessions = cloneDictionary(document.sessions);
      stale.forEach((sessionId) => { delete sessions[sessionId]; });
      await this.commit({ ...document, sessions });
      return stale;
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
    await durablePublishBoundedJson(this.path, document, MAXIMUM_BYTES);
    this.document = document;
    this.changeRevision += 1;
  }

  private requireDocument(): SessionArchiveDocument {
    if (this.document === undefined) throw new Error("Session archive store is not initialized");
    return this.document;
  }
}

function emptyDocument(): SessionArchiveDocument {
  return { version: VERSION, sessions: Object.create(null) as ArchiveDictionary };
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
