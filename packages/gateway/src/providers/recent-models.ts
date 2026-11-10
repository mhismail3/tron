import { AsyncMutex } from "../util/async-mutex.js";
import { durableAtomicWriteJson } from "../foundation/durable-json.js";
import { boundedString, boundedTimestamp, readJson } from "../foundation/json.js";
import { tronHomePath } from "../foundation/tron-home-layout.js";

const VERSION = 1;
const MAXIMUM_BYTES = 64 * 1_024;
export const MAXIMUM_RECENT_MODELS = 12;
const MAXIMUM_PROVIDER_BYTES = 120;
const MAXIMUM_MODEL_ID_BYTES = 300;

export interface RecentModelUsage {
  provider: string;
  id: string;
  lastUsedAt: string;
}

export interface RecentModelSignals {
  recentModelsChanged?: (() => void) | undefined;
  persistenceDiagnostic?: ((sessionId: string, code: string) => void) | undefined;
}

interface RecentModelsDocument {
  version: 1;
  models: RecentModelUsage[];
}

export class RecentModelStore {
  private readonly path: string;
  private readonly mutex = new AsyncMutex();
  private document: RecentModelsDocument;
  private closed = false;

  constructor(tronHome: string) {
    this.path = tronHomePath(tronHome, "gateway/model-recents.json");
    this.document = emptyDocument();
  }

  async initialize(): Promise<void> {
    let loaded: unknown;
    try {
      loaded = await readJson<unknown | undefined>(this.path, undefined, MAXIMUM_BYTES);
    } catch {
      await this.write(emptyDocument());
      return;
    }
    const admitted = admitDocument(loaded);
    this.document = admitted ?? emptyDocument();
    if (admitted === undefined && loaded !== undefined) await this.write(this.document);
  }

  async dispose(): Promise<void> {
    this.closed = true;
    await this.mutex.run(() => {});
  }

  entries(): RecentModelUsage[] {
    return this.document.models.map((model) => ({ ...model }));
  }

  async record(provider: string, id: string): Promise<boolean> {
    if (!boundedString(provider, MAXIMUM_PROVIDER_BYTES) || !boundedString(id, MAXIMUM_MODEL_ID_BYTES)) {
      throw new Error("Recent model identity exceeds its bound");
    }
    return this.mutex.run(async () => {
      if (this.closed) return false;
      const previous = this.document.models;
      const next: RecentModelUsage[] = [
        { provider, id, lastUsedAt: new Date().toISOString() },
        ...previous.filter((model) => model.provider !== provider || model.id !== id),
      ].slice(0, MAXIMUM_RECENT_MODELS);
      const changed = next.length !== previous.length
        || next.some((model, index) => model.provider !== previous[index]?.provider || model.id !== previous[index]?.id);
      await this.write({ version: VERSION, models: next });
      return changed;
    });
  }

  private async write(document: RecentModelsDocument): Promise<void> {
    await durableAtomicWriteJson(this.path, document);
    this.document = document;
  }
}

function emptyDocument(): RecentModelsDocument {
  return { version: VERSION, models: [] };
}

function admitDocument(value: unknown): RecentModelsDocument | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const root = value as Record<string, unknown>;
  if (root.version !== VERSION || !Array.isArray(root.models) || root.models.length > MAXIMUM_RECENT_MODELS) return undefined;
  const models: RecentModelUsage[] = [];
  const seen = new Set<string>();
  for (const raw of root.models) {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) return undefined;
    const model = raw as Record<string, unknown>;
    if (!boundedString(model.provider, MAXIMUM_PROVIDER_BYTES) || !boundedString(model.id, MAXIMUM_MODEL_ID_BYTES)
      || !boundedTimestamp(model.lastUsedAt)) return undefined;
    const key = `${model.provider}\0${model.id}`;
    if (seen.has(key)) return undefined;
    seen.add(key);
    models.push({ provider: model.provider, id: model.id, lastUsedAt: model.lastUsedAt });
  }
  return { version: VERSION, models };
}

