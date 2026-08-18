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

export class RunMarkerStore {
  private readonly directory: string;
  private readonly lanes = new Map<string, AsyncMutex>();

  constructor(tronHome: string) {
    this.directory = join(tronHome, "gateway", "runtime-markers");
  }

  private lane(sessionId: string): AsyncMutex {
    const existing = this.lanes.get(sessionId);
    if (existing) return existing;
    const created = new AsyncMutex();
    this.lanes.set(sessionId, created);
    return created;
  }

  async mark(sessionId: string, operationId: string): Promise<void> {
    await this.lane(sessionId).run(async () => {
      await mkdir(this.directory, { recursive: true, mode: 0o700 });
      const marker: Marker = { version: 1, sessionId, operationId, acceptedAt: new Date().toISOString() };
      await atomicWriteJson(join(this.directory, `${sessionId}.json`), marker);
    });
  }

  /** Clear only the marker owned by operationId when one is supplied. */
  async clear(sessionId: string, operationId?: string): Promise<void> {
    await this.lane(sessionId).run(async () => {
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
