import { mkdir, readdir } from "node:fs/promises";
import { join } from "node:path";
import { atomicWriteJson, readJson, removeIfExists } from "../util/json.js";
import { AsyncMutex } from "../util/async-mutex.js";

interface Marker {
  version: 1;
  sessionId: string;
  operationId: string;
  acceptedAt: string;
}

interface Lane {
  mutex: AsyncMutex;
  users: number;
}

export class RunMarkerStore {
  private readonly directory: string;
  private readonly lanes = new Map<string, Lane>();

  constructor(tronHome: string) {
    this.directory = join(tronHome, "gateway", "runtime-markers");
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
      await mkdir(this.directory, { recursive: true, mode: 0o700 });
      const marker: Marker = { version: 1, sessionId, operationId, acceptedAt: new Date().toISOString() };
      await atomicWriteJson(join(this.directory, `${sessionId}.json`), marker);
    });
  }

  /** Clear only the marker owned by operationId when one is supplied. */
  async clear(sessionId: string, operationId?: string): Promise<void> {
    await this.withLane(sessionId, async () => {
      const path = join(this.directory, `${sessionId}.json`);
      if (operationId !== undefined) {
        const marker = await readJson<Marker | undefined>(path, undefined, 4_096);
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
