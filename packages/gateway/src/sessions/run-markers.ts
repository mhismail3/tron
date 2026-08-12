import { mkdir, readdir } from "node:fs/promises";
import { join } from "node:path";
import { atomicWriteJson, removeIfExists } from "../util/json.js";

interface Marker {
  version: 1;
  sessionId: string;
  operationId: string;
  acceptedAt: string;
}

export class RunMarkerStore {
  private readonly directory: string;

  constructor(tronHome: string) {
    this.directory = join(tronHome, "gateway", "runtime-markers");
  }

  async mark(sessionId: string, operationId: string): Promise<void> {
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    const marker: Marker = { version: 1, sessionId, operationId, acceptedAt: new Date().toISOString() };
    await atomicWriteJson(join(this.directory, `${sessionId}.json`), marker);
  }

  async clear(sessionId: string): Promise<void> {
    await removeIfExists(join(this.directory, `${sessionId}.json`));
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
