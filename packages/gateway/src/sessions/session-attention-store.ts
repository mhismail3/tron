import { join } from "node:path";
import { AsyncMutex } from "../util/async-mutex.js";
import { durablePublishBoundedJson } from "../util/durable-json.js";
import { boundedString, boundedTimestamp, cloneDictionary, ownRecord, readJsonDocument } from "../util/json.js";

const VERSION = 1;
const MAXIMUM_BYTES = 2 * 1_048_576;
const MAXIMUM_SESSIONS = 50_000;
const MAXIMUM_ID_BYTES = 200;
const MAXIMUM_COMPLETION_ID_BYTES = 240;
const MAXIMUM_RECENT_COMPLETIONS = 16;

type AttentionDictionary = Record<string, SessionAttentionRecord>;

interface SessionAttentionRecord {
  completionRevision: number;
  readThroughRevision: number;
  manualUnread: boolean;
  recentCompletionIds: string[];
  attentionRevision: number;
}

interface SessionAttentionDocument {
  version: 1;
  /** Canonical session files at or before this cursor have been reconciled. */
  reconciledThrough: string;
  sessions: AttentionDictionary;
}

export interface SessionAttentionProjection {
  completionRevision: number;
  attentionRevision: number;
  isUnread: boolean;
}

export interface SessionAttentionMutation {
  changed: boolean;
  projection: SessionAttentionProjection;
}

interface SessionAttentionStoreOptions {
  write?: (path: string, value: unknown) => Promise<void>;
  now?: () => Date;
}

export class SessionAttentionStore {
  private readonly path: string;
  private readonly mutex = new AsyncMutex();
  private readonly write: ((path: string, value: unknown) => Promise<void>) | undefined;
  private readonly now: () => Date;
  /** Undefined until `initialize` admits the stored document. Read-only
   * projections stay safe before that; every mutation is gated, so a change can
   * never replace a document this owner has not read. */
  private document: SessionAttentionDocument | undefined;

  constructor(tronHome: string, options: SessionAttentionStoreOptions = {}) {
    this.path = join(tronHome, "gateway", "session-attention.json");
    this.write = options.write;
    this.now = options.now ?? (() => new Date());
  }

  async initialize(): Promise<void> {
    const loaded = await readJsonDocument(this.path, admitDocument, MAXIMUM_BYTES);
    if (loaded === undefined) {
      await this.commit(emptyDocument(this.now().toISOString()));
      return;
    }
    this.document = loaded;
  }

  reconciliationCursor(): string {
    return this.document?.reconciledThrough ?? "";
  }

  projection(sessionId: string): SessionAttentionProjection {
    const document = this.document;
    return projection(document === undefined ? undefined : ownRecord(document.sessions, sessionId));
  }

  /** Admit an exact canonical successful assistant completion once. A
   * foreground-observed completion advances read-through in the same durable
   * replacement, so no intermediate unread projection can escape. */
  async complete(
    sessionId: string,
    completionId: string,
    observed = false,
  ): Promise<SessionAttentionMutation> {
    return this.mutex.run(async () => {
      const document = this.requireDocument();
      const existing = ownRecord(document.sessions, sessionId);
      const current = existing ?? emptyRecord();
      if (current.recentCompletionIds.includes(completionId)) {
        return { changed: false, projection: projection(current) };
      }
      const completionRevision = current.completionRevision + 1;
      const next: SessionAttentionRecord = {
        ...current,
        completionRevision,
        readThroughRevision: observed ? completionRevision : current.readThroughRevision,
        manualUnread: observed ? false : current.manualUnread,
        attentionRevision: current.attentionRevision + 1,
        recentCompletionIds: [...current.recentCompletionIds, completionId].slice(-MAXIMUM_RECENT_COMPLETIONS),
      };
      await this.replace(sessionId, next);
      return { changed: true, projection: projection(next) };
    });
  }

  async set(sessionId: string, unread: boolean, throughCompletionRevision?: number): Promise<SessionAttentionMutation> {
    return this.mutex.run(async () => {
      const document = this.requireDocument();
      const existing = ownRecord(document.sessions, sessionId);
      const current = existing ?? emptyRecord();
      const acknowledged = unread ? current.readThroughRevision : Math.max(
        current.readThroughRevision,
        Math.min(throughCompletionRevision ?? current.completionRevision, current.completionRevision),
      );
      if (current.manualUnread === unread && current.readThroughRevision === acknowledged) {
        return { changed: false, projection: projection(current) };
      }
      const next: SessionAttentionRecord = {
        ...current,
        readThroughRevision: acknowledged,
        manualUnread: unread,
        attentionRevision: current.attentionRevision + 1,
      };
      await this.replace(sessionId, next);
      return { changed: true, projection: projection(next) };
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
      if (ownRecord(document.sessions, nextId)) throw new Error("Replacement session already has attention state");
      const sessions = cloneDictionary(document.sessions);
      sessions[nextId] = previous;
      delete sessions[previousId];
      await this.commit({ ...document, sessions });
      return true;
    });
  }

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
        throw new Error("New session identity already has attention state");
      }
    });
  }

  /** Advance only after every canonical file through the scan boundary was admitted. */
  async advanceReconciliationCursor(through: string): Promise<void> {
    await this.mutex.run(async () => {
      const document = this.requireDocument();
      if (through <= document.reconciledThrough) return;
      await this.commit({ ...document, reconciledThrough: through });
    });
  }

  private async replace(sessionId: string, record: SessionAttentionRecord): Promise<void> {
    const document = this.requireDocument();
    if (!ownRecord(document.sessions, sessionId) && Object.keys(document.sessions).length >= MAXIMUM_SESSIONS) {
      throw new Error("Session attention capacity exceeded");
    }
    const sessions = cloneDictionary(document.sessions);
    sessions[sessionId] = record;
    await this.commit({ ...document, sessions });
  }

  private async commit(document: SessionAttentionDocument): Promise<void> {
    if (this.write) {
      const persisted = `${JSON.stringify(document, null, 2)}\n`;
      if (Buffer.byteLength(persisted) > MAXIMUM_BYTES) {
        throw new Error("Session attention document exceeds its byte limit");
      }
      await this.write(this.path, document);
    } else {
      await durablePublishBoundedJson(this.path, document, MAXIMUM_BYTES);
    }
    this.document = document;
  }

  /** Mutations never run against an unread document: a change admitted before
   * `initialize` would otherwise replace the stored file blind. */
  private requireDocument(): SessionAttentionDocument {
    if (this.document === undefined) throw new Error("Session attention store is not initialized");
    return this.document;
  }
}

function emptyDocument(reconciledThrough: string): SessionAttentionDocument {
  return { version: VERSION, reconciledThrough, sessions: Object.create(null) as AttentionDictionary };
}

function emptyRecord(): SessionAttentionRecord {
  return { completionRevision: 0, readThroughRevision: 0, manualUnread: false, recentCompletionIds: [], attentionRevision: 0 };
}

function projection(record: SessionAttentionRecord | undefined): SessionAttentionProjection {
  if (!record) return { completionRevision: 0, attentionRevision: 0, isUnread: false };
  return {
    completionRevision: record.completionRevision,
    attentionRevision: record.attentionRevision,
    isUnread: record.manualUnread || record.completionRevision > record.readThroughRevision,
  };
}

function boundedRevision(value: unknown): value is number {
  return Number.isSafeInteger(value) && (value as number) >= 0;
}

function admitDocument(value: unknown): SessionAttentionDocument {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid session attention document");
  const root = value as Record<string, unknown>;
  if (root.version !== VERSION || !boundedTimestamp(root.reconciledThrough)
    || !root.sessions || typeof root.sessions !== "object" || Array.isArray(root.sessions)) {
    throw new Error("Invalid session attention document");
  }
  const entries = Object.entries(root.sessions as Record<string, unknown>);
  if (entries.length > MAXIMUM_SESSIONS) throw new Error("Session attention document exceeds capacity");
  const sessions = Object.create(null) as AttentionDictionary;
  for (const [sessionId, raw] of entries) {
    if (!boundedString(sessionId, MAXIMUM_ID_BYTES) || !raw || typeof raw !== "object" || Array.isArray(raw)) {
      throw new Error("Invalid session attention record");
    }
    const record = raw as Record<string, unknown>;
    if (!boundedRevision(record.completionRevision) || !boundedRevision(record.readThroughRevision)
      || !boundedRevision(record.attentionRevision) || record.readThroughRevision > record.completionRevision
      || typeof record.manualUnread !== "boolean" || !Array.isArray(record.recentCompletionIds)
      || record.recentCompletionIds.length > MAXIMUM_RECENT_COMPLETIONS
      || record.recentCompletionIds.some((id) => !boundedString(id, MAXIMUM_COMPLETION_ID_BYTES))
      || new Set(record.recentCompletionIds).size !== record.recentCompletionIds.length) {
      throw new Error("Invalid session attention record");
    }
    sessions[sessionId] = {
      completionRevision: record.completionRevision,
      readThroughRevision: record.readThroughRevision,
      manualUnread: record.manualUnread,
      recentCompletionIds: [...record.recentCompletionIds] as string[],
      attentionRevision: record.attentionRevision,
    };
  }
  return { version: VERSION, reconciledThrough: root.reconciledThrough, sessions };
}
