import { randomBytes } from "node:crypto";
import { mkdir, open, readdir, rename, rm } from "node:fs/promises";
import { dirname, join } from "node:path";
import { readJson, removeIfExists } from "../util/json.js";
import { AsyncMutex } from "../util/async-mutex.js";

export interface RunMarkerEvidence {
  version: 1;
  sessionId: string;
  operationId: string;
  acceptedAt: string;
  assistantCompletionId?: string;
  assistantCompletedAt?: string;
}

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
    // Do not remove a replacement lane created after this lane was released.
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
    await this.withLane(sessionId, async () => {
      const marker: RunMarkerEvidence = { version: 1, sessionId, operationId, acceptedAt: new Date().toISOString() };
      await durableWriteRunMarker(join(this.directory, `${sessionId}.json`), marker, this.fileSystem);
    });
  }

  async markAssistantCompletion(
    sessionId: string,
    operationId: string,
    completionId: string,
    completedAt: string,
  ): Promise<void> {
    await this.withLane(sessionId, async () => {
      const path = join(this.directory, `${sessionId}.json`);
      const marker = await readJson<RunMarkerEvidence | undefined>(path, undefined, 4_096);
      if (!marker || marker.operationId !== operationId) {
        throw new Error("Run marker ownership changed before assistant completion admission");
      }
      await durableWriteRunMarker(path, {
        ...marker,
        assistantCompletionId: completionId,
        assistantCompletedAt: completedAt,
      } satisfies RunMarkerEvidence, this.fileSystem);
    });
  }

  async evidenceFor(sessionId: string): Promise<RunMarkerEvidence | undefined> {
    return this.withLane(sessionId, async () => {
      const marker = await readJson<RunMarkerEvidence | undefined>(
        join(this.directory, `${sessionId}.json`),
        undefined,
        4_096,
      );
      return admitsMarker(marker, sessionId) ? marker : undefined;
    });
  }

  async evidence(): Promise<Map<string, RunMarkerEvidence>> {
    try {
      const names = (await readdir(this.directory)).filter((name) => name.endsWith(".json"));
      const evidence = new Map<string, RunMarkerEvidence>();
      for (const name of names) {
        const sessionId = name.slice(0, -5);
        const marker = await readJson<RunMarkerEvidence | undefined>(join(this.directory, name), undefined, 4_096);
        if (admitsMarker(marker, sessionId)) evidence.set(sessionId, marker);
      }
      return evidence;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return new Map();
      throw error;
    }
  }

  /** Clear only the marker owned by operationId when one is supplied. */
  async clear(sessionId: string, operationId?: string): Promise<void> {
    await this.withLane(sessionId, async () => {
      const path = join(this.directory, `${sessionId}.json`);
      if (operationId !== undefined) {
        const marker = await readJson<RunMarkerEvidence | undefined>(path, undefined, 4_096);
        if (marker?.operationId !== operationId) return;
      }
      await removeIfExists(path);
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

function admitsMarker(marker: RunMarkerEvidence | undefined, sessionId: string): marker is RunMarkerEvidence {
  return marker?.version === 1 && marker.sessionId === sessionId
    && typeof marker.operationId === "string" && typeof marker.acceptedAt === "string";
}

async function durableWriteRunMarker(
  path: string,
  marker: RunMarkerEvidence,
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
