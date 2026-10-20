import { createHash } from "node:crypto";
import { dirname, join } from "node:path";
import type { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { projectionSource } from "../src/providers/model-queue-extension.js";
import { ModelQueueOwner, modelQueueProjectionPath } from "../src/providers/model-queue.js";
import type { ProviderUsageResponse } from "../src/providers/provider-usage.js";
import { ModelReleaseDateCatalog } from "../src/providers/model-release-date-catalog.js";
import { SessionSearchIndex } from "../src/sessions/session-search-index.js";
import { CORPUS_EPOCH } from "./fixed-recording.js";
import { CORPUS_IDS, type StoreSpec } from "./tron-store-specs.js";

/**
 * Derived and rebuildable stores in the persisted-store corpus (restructure plan §6.5,
 * V4): the Gateway can regenerate them, but a build still reads what an earlier one
 * wrote (the search index, the release-date cache) or a child process reads what the
 * Gateway wrote (the model-queue projection), so their bytes are a contract too.
 */

const SEARCH_INDEX = "gateway/session-search.sqlite";

function searchDocument(sessionId: string, title: string, texts: readonly string[]) {
  return {
    sessionId, title, cwd: "/corpus/project", updatedAt: "2026-01-01T00:00:00.000Z",
    fileIdentity: `corpus-file-${sessionId.slice(-4)}`, branchDigest: `corpus-branch-${sessionId.slice(-4)}`,
    leafEntryId: `entry-${texts.length}`,
    entries: texts.map((text, index) => ({
      id: `entry-${index + 1}`, parentId: index === 0 ? null : `entry-${index}`, timestamp: "2026-01-01T00:00:00.000Z",
      role: index % 2 === 0 ? "user" as const : "assistant" as const, text, ordinal: index,
    })),
  };
}

/** The model registry and credentials the corpus queue sees: two providers, one without credentials. */
const queueRuntime = {
  getModel: (provider: string, id: string) => provider.startsWith("corpus-") && id !== "corpus-unregistered"
    ? { provider, id, api: "openai-completions" } : undefined,
  hasConfiguredAuth: (provider: string) => provider !== "corpus-nocreds",
  checkAuth: async () => undefined,
} as unknown as ModelRuntime;

/** A fresh usage read that puts `corpus-full` at its weekly limit. */
async function queueUsage(_runtime: ModelRuntime, provider: string | undefined): Promise<ProviderUsageResponse> {
  return { providers: provider === "corpus-full" ? [{
    providerId: provider, status: "available", source: "corpus", scope: "account", updatedAt: null, retryAt: null, stale: false, message: null,
    windows: [{ id: "weekly", label: "Weekly", usedPercent: 97, used: null, limit: null, remaining: null, unit: null, resetsAt: null, windowSeconds: null }],
    balances: [],
  }] : [] };
}

const SUBAGENT_QUEUE = ["corpus-provider/corpus-a", "corpus-limited/corpus-b", "corpus-full/corpus-c",
  "corpus-nocreds/corpus-d", "corpus-provider/corpus-unregistered"];
const TASK_QUEUE = ["corpus-limited/corpus-b", "corpus-provider/corpus-a"];

/** Where a task's projection lives: `model-queue.ts` names it by the session id's digest. */
function taskProjectionPath(home: string): string {
  return join(dirname(modelQueueProjectionPath(home)), "model-queue-sessions",
    `${createHash("sha256").update(CORPUS_IDS.session).digest("hex")}.json`);
}

const RELEASE_BASELINE = { "corpus-provider/corpus-a": "2024-01-01", "corpus-provider/corpus-baseline": "2024-02-02" };
const RELEASE_ALIASES = { "corpus-alias": "corpus-provider" };

function releaseCatalog(home: string): ModelReleaseDateCatalog {
  return new ModelReleaseDateCatalog({ tronHome: home, baseline: RELEASE_BASELINE, aliases: RELEASE_ALIASES,
    providers: () => ["corpus-provider"], log: () => {} });
}

export const DERIVED_STORES: readonly StoreSpec[] = [
  {
    module: "gateway/session-search", name: "store-session-search",
    paths: [SEARCH_INDEX],
    reproducible: true,
    async record(home) {
      const index = await SessionSearchIndex.open(join(home, SEARCH_INDEX));
      try {
        // One row stamped with catalog facts (reused on the next start), one unstamped
        // (re-derived), and one removed again.
        await index.replace(searchDocument(CORPUS_IDS.session, "Corpus planning", [
          "Plan the corpus garden layout", "Tomatoes along the south fence", "And basil beside them"]),
        { fileIdentity: "corpus-file-c0a1", size: 2_048, mtimeMs: CORPUS_EPOCH });
        await index.replace(searchDocument(CORPUS_IDS.otherSession, "Corpus travel", ["Pack the garden gloves for travel"]));
        await index.replace(searchDocument("01a00000-0000-7000-8000-00000000c0a9", "Corpus removed", ["Removed garden notes"]));
        await index.remove("01a00000-0000-7000-8000-00000000c0a9");
      } finally {
        index.close();
      }
    },
    async read(home) {
      const index = await SessionSearchIndex.open(join(home, SEARCH_INDEX));
      try {
        return { stats: index.stats(), sessions: index.sessionFacts(), garden: index.candidates("garden", 10), basil: index.candidates("basil", 10) };
      } finally {
        index.close();
      }
    },
  },
  {
    module: "gateway/providers", name: "store-model-queue",
    paths: ["gateway/model-queue.json", "gateway/model-queue-sessions"],
    reproducible: true,
    async record(home) {
      const owner = new ModelQueueOwner({ runtime: queueRuntime, usage: { read: queueUsage }, now: () => CORPUS_EPOCH,
        queue: async () => SUBAGENT_QUEUE, projectionPath: modelQueueProjectionPath(home) });
      owner.recordUsageLimit("subagent", "corpus-limited/corpus-b", "usage limit reached");
      await owner.publishProjection();
      await owner.publishProjection({ sessionId: CORPUS_IDS.session, queue: TASK_QUEUE });
    },
    async read(home) {
      // A child reads its projection as of its own clock: a skip ends exactly at its expiry
      // (ten minutes for a projected read, fifteen for a recorded usage limit).
      const at = async (path: string, ms: number) => projectionSource(path, () => CORPUS_EPOCH + ms).availability("subagent");
      return {
        mac: { now: await at(modelQueueProjectionPath(home), 0), at10Minutes: await at(modelQueueProjectionPath(home), 10 * 60_000),
          at15Minutes: await at(modelQueueProjectionPath(home), 15 * 60_000) },
        task: { now: await at(taskProjectionPath(home), 0), at15Minutes: await at(taskProjectionPath(home), 15 * 60_000) },
      };
    },
  },
  {
    module: "gateway/providers", name: "store-model-release-dates",
    paths: ["gateway/model-release-dates.json"],
    reproducible: true,
    async record(home) {
      const catalog = releaseCatalog(home);
      const fetch = globalThis.fetch;
      const offline = process.env.PI_OFFLINE;
      // models.dev is the only party replaced: the catalog fetches, validates and persists.
      globalThis.fetch = async () => new Response(JSON.stringify({ "corpus-provider": { models: {
        "corpus-a": { release_date: "2025-03-04" }, "corpus-fetched": { release_date: "2025-05-06" } } } }),
      { headers: { etag: "\"corpus-etag\"", "last-modified": "Wed, 31 Dec 2025 00:00:00 GMT" } });
      delete process.env.PI_OFFLINE;
      try {
        const result = await catalog.refresh({ force: true });
        if (result.error) throw new Error(`The corpus release-date refresh failed: ${result.error}`);
      } finally {
        globalThis.fetch = fetch;
        if (offline !== undefined) process.env.PI_OFFLINE = offline;
        catalog.dispose();
      }
    },
    async read(home) {
      const catalog = releaseCatalog(home);
      const keys = [["corpus-provider", "corpus-a"], ["corpus-provider", "corpus-fetched"], ["corpus-provider", "corpus-baseline"],
        ["corpus-alias", "corpus-fetched"], ["corpus-provider", "corpus-missing"]] as const;
      const dates: Record<string, string | null> = {};
      for (const [provider, id] of keys) dates[`${provider}/${id}`] = await catalog.modelReleaseDate(provider, id) ?? null;
      catalog.dispose();
      return { dates };
    },
  },
];
