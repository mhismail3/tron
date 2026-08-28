import { randomBytes } from "node:crypto";
import { mkdir, open, readdir, rename, rm } from "node:fs/promises";
import { dirname, join } from "node:path";
import { readJson, removeIfExists } from "../util/json.js";
import { AsyncMutex } from "../util/async-mutex.js";

export interface RunMarkerEvidence {
  operationId: string;
  acceptedAt: string;
  assistantCompletionId?: string;
  assistantCompletedAt?: string;
}

interface LegacyRunMarkerEvidence extends RunMarkerEvidence {
  version: 1;
  sessionId: string;
}

interface RunMarkerDocument {
  version: 2;
  sessionId: string;
  operations: RunMarkerEvidence[];
}

type StoredRunMarker = LegacyRunMarkerEvidence | RunMarkerDocument;

interface Lane {
  mutex: AsyncMutex;
  users: number;
}

interface RunMarkerFileSystem {
  mkdir: typeof mkdir;
  open: typeof open;
  rename: typeof rename;
  rm: typeof rm;
}

interface RunMarkerStoreOptions {
  fileSystem?: RunMarkerFileSystem;
}

const productionFileSystem: RunMarkerFileSystem = { mkdir, open, rename, rm };
export const MAXIMUM_RUN_MARKER_OPERATIONS = 16;
const MAXIMUM_RUN_MARKER_BYTES = 32 * 1_024;
const MAXIMUM_MARKER_IDENTIFIER_BYTES = 256;
const MAXIMUM_MARKER_TIMESTAMP_BYTES = 128;

/** One operation can never own two different canonical completions. */
export class RunMarkerCompletionConflictError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "RunMarkerCompletionConflictError";
  }
}

export class RunMarkerStore {
  private readonly directory: string;
  private readonly lanes = new Map<string, Lane>();
  private readonly fileSystem: RunMarkerFileSystem;

  constructor(tronHome: string, options: RunMarkerStoreOptions = {}) {
    this.directory = join(tronHome, "gateway", "runtime-markers");
    this.fileSystem = options.fileSystem ?? productionFileSystem;
  }

  /** Retain a lane for the whole queued operation, not just its execution. */
  private acquireLane(sessionId: string): Lane {
    const existing = this.lanes.get(sessionId);
    if (existing) {
      existing.users += 1;
      return existing;
    }
    const created: Lane = { mutex: new AsyncMutex(), users: 1 };
    this.lanes.set(sessionId, created);
    return created;
  }

  private releaseLane(sessionId: string, lane: Lane): void {
    lane.users -= 1;
    if (lane.users === 0 && this.lanes.get(sessionId) === lane) this.lanes.delete(sessionId);
  }

  private async withLane<T>(sessionId: string, operation: () => Promise<T>): Promise<T> {
    const lane = this.acquireLane(sessionId);
    try {
      return await lane.mutex.run(operation);
    } finally {
      this.releaseLane(sessionId, lane);
    }
  }

  async mark(sessionId: string, operationId: string): Promise<void> {
    if (!boundedString(operationId, MAXIMUM_MARKER_IDENTIFIER_BYTES)) {
      throw new Error("Run marker operation identifier exceeds its bound");
    }
    await this.withLane(sessionId, async () => {
      const path = join(this.directory, `${sessionId}.json`);
      const operations = await readOperations(path, sessionId);
      if (operations.some((operation) => operation.operationId === operationId)) return;
      if (operations.length >= MAXIMUM_RUN_MARKER_OPERATIONS) {
        throw new Error("Run marker operation bound reached before durable admission");
      }
      operations.push({ operationId, acceptedAt: new Date().toISOString() });
      await durableWriteRunMarker(path, { version: 2, sessionId, operations }, this.fileSystem);
    });
  }

  async markAssistantCompletion(
    sessionId: string,
    operationId: string,
    completionId: string,
    completedAt: string,
  ): Promise<void> {
    assertCompletionEvidence(operationId, completionId, completedAt);
    await this.withLane(sessionId, async () => {
      const path = join(this.directory, `${sessionId}.json`);
      const operations = await readOperations(path, sessionId);
      const operation = operations.find((candidate) => candidate.operationId === operationId);
      if (!operation) {
        throw new Error("Run marker ownership changed before assistant completion admission");
      }
      if (!applyAssistantCompletion(operation, completionId, completedAt)) return;
      await durableWriteRunMarker(path, { version: 2, sessionId, operations }, this.fileSystem);
    });
  }

  /** Atomically restores a live operation's exact marker and stamps its terminal
   * completion. Keeping both changes in one session lane prevents stale cleanup
   * from recreating a permanent missing-owner retry between two durable writes. */
  async reassertAssistantCompletion(
    sessionId: string,
    operationId: string,
    completionId: string,
    completedAt: string,
  ): Promise<void> {
    assertCompletionEvidence(operationId, completionId, completedAt);
    await this.withLane(sessionId, async () => {
      const path = join(this.directory, `${sessionId}.json`);
      const operations = await readOperations(path, sessionId);
      let operation = operations.find((candidate) => candidate.operationId === operationId);
      if (!operation) {
        if (operations.length >= MAXIMUM_RUN_MARKER_OPERATIONS) {
          throw new Error("Run marker operation bound reached before terminal ownership reassertion");
        }
        operation = { operationId, acceptedAt: new Date().toISOString() };
        operations.push(operation);
      }
      if (!applyAssistantCompletion(operation, completionId, completedAt)) return;
      await durableWriteRunMarker(path, { version: 2, sessionId, operations }, this.fileSystem);
    });
  }

  async evidenceFor(sessionId: string): Promise<RunMarkerEvidence[]> {
    return this.withLane(sessionId, async () => readOperations(join(this.directory, `${sessionId}.json`), sessionId));
  }

  async evidence(): Promise<Map<string, RunMarkerEvidence[]>> {
    try {
      const names = (await readdir(this.directory)).filter((name) => name.endsWith(".json"));
      const evidence = new Map<string, RunMarkerEvidence[]>();
      for (const name of names) {
        const sessionId = name.slice(0, -5);
        const operations = await readOperations(join(this.directory, name), sessionId);
        if (operations.length > 0) evidence.set(sessionId, operations);
      }
      return evidence;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return new Map();
      throw error;
    }
  }

  /** Clear only the record owned by operationId when one is supplied. */
  async clear(sessionId: string, operationId?: string): Promise<void> {
    await this.withLane(sessionId, async () => {
      const path = join(this.directory, `${sessionId}.json`);
      if (operationId === undefined) {
        await removeIfExists(path);
        return;
      }
      const operations = await readOperations(path, sessionId);
      const retained = operations.filter((operation) => operation.operationId !== operationId);
      if (retained.length === operations.length) return;
      if (retained.length === 0) {
        await removeIfExists(path);
        return;
      }
      await durableWriteRunMarker(path, { version: 2, sessionId, operations: retained }, this.fileSystem);
    });
  }

  async interruptedSessionIds(): Promise<Set<string>> {
    try {
      const names = await readdir(this.directory);
      return new Set(names.filter((name) => name.endsWith(".json")).map((name) => name.slice(0, -5)));
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return new Set();
      throw error;
    }
  }
}

async function readOperations(path: string, sessionId: string): Promise<RunMarkerEvidence[]> {
  const stored = await readJson<StoredRunMarker | undefined>(path, undefined, MAXIMUM_RUN_MARKER_BYTES);
  if (admitsLegacyMarker(stored, sessionId)) {
    const { operationId, acceptedAt, assistantCompletionId, assistantCompletedAt } = stored;
    return [{ operationId, acceptedAt, ...(assistantCompletionId === undefined ? {} : { assistantCompletionId }),
      ...(assistantCompletedAt === undefined ? {} : { assistantCompletedAt }) }];
  }
  if (!admitsMarkerDocument(stored, sessionId)) return [];
  return stored.operations.map((operation) => ({ ...operation }));
}

function boundedString(value: unknown, maximumBytes: number): value is string {
  return typeof value === "string" && value.length > 0 && Buffer.byteLength(value) <= maximumBytes;
}

function assertCompletionEvidence(operationId: string, completionId: string, completedAt: string): void {
  if (!boundedString(operationId, MAXIMUM_MARKER_IDENTIFIER_BYTES)
    || !boundedString(completionId, MAXIMUM_MARKER_IDENTIFIER_BYTES)
    || !boundedString(completedAt, MAXIMUM_MARKER_TIMESTAMP_BYTES)) {
    throw new Error("Run marker completion evidence exceeds its bound");
  }
}

function applyAssistantCompletion(
  operation: RunMarkerEvidence,
  completionId: string,
  completedAt: string,
): boolean {
  if (operation.assistantCompletionId !== undefined
    && (operation.assistantCompletionId !== completionId || operation.assistantCompletedAt !== completedAt)) {
    throw new RunMarkerCompletionConflictError("Run marker operation already owns a different assistant completion");
  }
  if (operation.assistantCompletionId === completionId && operation.assistantCompletedAt === completedAt) return false;
  operation.assistantCompletionId = completionId;
  operation.assistantCompletedAt = completedAt;
  return true;
}

function admitsOperation(operation: unknown): operation is RunMarkerEvidence {
  if (!operation || typeof operation !== "object") return false;
  const candidate = operation as Partial<RunMarkerEvidence>;
  if (!boundedString(candidate.operationId, MAXIMUM_MARKER_IDENTIFIER_BYTES)
    || !boundedString(candidate.acceptedAt, MAXIMUM_MARKER_TIMESTAMP_BYTES)) return false;
  const hasCompletionId = candidate.assistantCompletionId !== undefined;
  const hasCompletedAt = candidate.assistantCompletedAt !== undefined;
  return hasCompletionId === hasCompletedAt
    && (!hasCompletionId || (boundedString(candidate.assistantCompletionId, MAXIMUM_MARKER_IDENTIFIER_BYTES)
      && boundedString(candidate.assistantCompletedAt, MAXIMUM_MARKER_TIMESTAMP_BYTES)));
}

function admitsLegacyMarker(marker: StoredRunMarker | undefined, sessionId: string): marker is LegacyRunMarkerEvidence {
  return marker?.version === 1 && marker.sessionId === sessionId && admitsOperation(marker);
}

function admitsMarkerDocument(marker: StoredRunMarker | undefined, sessionId: string): marker is RunMarkerDocument {
  if (marker?.version !== 2 || marker.sessionId !== sessionId || !Array.isArray(marker.operations)
    || marker.operations.length === 0 || marker.operations.length > MAXIMUM_RUN_MARKER_OPERATIONS
    || !marker.operations.every(admitsOperation)) return false;
  return new Set(marker.operations.map((operation) => operation.operationId)).size === marker.operations.length;
}

async function durableWriteRunMarker(
  path: string,
  marker: RunMarkerDocument,
  fileSystem: RunMarkerFileSystem,
): Promise<void> {
  const directory = dirname(path);
  await fileSystem.mkdir(directory, { recursive: true, mode: 0o700 });
  const temporary = `${path}.${process.pid}.${randomBytes(6).toString("hex")}.tmp`;
  let temporaryExists = false;
  try {
    const handle = await fileSystem.open(temporary, "wx", 0o600);
    temporaryExists = true;
    try {
      await handle.writeFile(`${JSON.stringify(marker, null, 2)}\n`, "utf8");
      await handle.sync();
    } finally {
      await handle.close();
    }
    await fileSystem.rename(temporary, path);
    temporaryExists = false;
    const directoryHandle = await fileSystem.open(directory, "r");
    try {
      await directoryHandle.sync();
    } finally {
      await directoryHandle.close();
    }
  } catch (error) {
    if (temporaryExists) await fileSystem.rm(temporary, { force: true }).catch(() => {});
    throw error;
  }
}
