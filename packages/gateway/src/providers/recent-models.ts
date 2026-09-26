import { join } from "node:path";
import { AsyncMutex } from "../util/async-mutex.js";
import { durableAtomicWriteJson } from "../util/durable-json.js";
import { readJson } from "../util/json.js";

const VERSION = 1;
const MAXIMUM_BYTES = 64 * 1_024;
/** Bounded preference projection. The picker's Recent rail shows far fewer. */
export const MAXIMUM_RECENT_MODELS = 12;
/** Same field bounds the model RPCs accept for a provider and model identity. */
const MAXIMUM_PROVIDER_BYTES = 120;
const MAXIMUM_MODEL_ID_BYTES = 300;

export interface RecentModelUsage {
  provider: string;
  id: string;
  /** ISO-8601 instant of the newest admitted run that used this model. */
  lastUsedAt: string;
}

interface RecentModelsDocument {
  version: 1;
  /** Newest first, unique by provider/id. */
  models: RecentModelUsage[];
}

/**
 * Gateway-wide recency of models the user actually ran, for the shared model
 * picker. Recency is a bounded presentation preference, never a canonical
 * fact: nothing else derives session state from it, and a malformed document is
 * replaced with an empty one rather than failing Gateway startup.
 */
export class RecentModelStore {
  private readonly path: string;
  private readonly mutex = new AsyncMutex();
  private document: RecentModelsDocument;

  constructor(tronHome: string) {
    this.path = join(tronHome, "gateway", "model-recents.json");
    this.document = emptyDocument();
  }

  async initialize(): Promise<void> {
    let loaded: unknown;
    try {
      loaded = await readJson<unknown | undefined>(this.path, undefined, MAXIMUM_BYTES);
    } catch {
      // Unreadable, oversized, or malformed. Recency has no canonical evidence
      // to rebuild from, so it is replaced rather than failing Gateway startup.
      await this.write(emptyDocument());
      return;
    }
    const admitted = admitDocument(loaded);
    this.document = admitted ?? emptyDocument();
    if (admitted === undefined && loaded !== undefined) await this.write(this.document);
  }

  /** Newest-first copy; callers never mutate stored order. */
  entries(): RecentModelUsage[] {
    return this.document.models.map((model) => ({ ...model }));
  }

  /** Record one admitted user run. Returns whether the visible order changed. */
  async record(provider: string, id: string): Promise<boolean> {
    if (!boundedString(provider, MAXIMUM_PROVIDER_BYTES) || !boundedString(id, MAXIMUM_MODEL_ID_BYTES)) {
      throw new Error("Recent model identity exceeds its bound");
    }
    return this.mutex.run(async () => {
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

/** Admit a stored document, or undefined for anything unusable. Recency has no
 * canonical evidence to rebuild from, so corruption self-heals to empty. */
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

function boundedString(value: unknown, maximum: number): value is string {
  return typeof value === "string" && value.length > 0 && Buffer.byteLength(value) <= maximum;
}

function boundedTimestamp(value: unknown): value is string {
  return typeof value === "string" && value.length <= 40 && Number.isFinite(Date.parse(value));
}
