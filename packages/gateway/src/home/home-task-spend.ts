import { createHash } from "node:crypto";
import type { FileEntry } from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import type { HomeTaskRecord } from "./home-task-store.js";

export type HomeTaskSpend = NonNullable<HomeTaskRecord["spend"]>;

/** Canonical entries are the event ledger. Reconstruct, never increment a
 * second ledger from transient SDK callbacks. The digest pins the deduped usage
 * identities and deltas whose cumulative projection the store publishes.
 * `inputTokens` is fresh input only: a cache-read token is never fresh input
 * (#1250), and the cache counters are kept separately so cache health is visible. */
export function homeTaskSpend(entries: readonly FileEntry[]): HomeTaskSpend {
  const usage = new Map<string, string>();
  let inputTokens = 0;
  let cacheReadTokens = 0;
  let cacheWriteTokens = 0;
  let outputTokens = 0;
  const count = (value: number) => {
    if (!Number.isSafeInteger(value) || value < 0) throw new GatewayError("conflict", "Invalid canonical task usage tokens");
    return value;
  };
  for (const entry of entries) {
    if (entry.type !== "message" || entry.message.role !== "assistant") continue;
    const message = entry.message;
    const delta = JSON.stringify({ provider: message.provider, model: message.model, usage: message.usage });
    const prior = usage.get(entry.id);
    if (prior !== undefined) {
      if (prior !== delta) throw new GatewayError("conflict", "Contradictory canonical task usage identity");
      continue;
    }
    usage.set(entry.id, delta);
    inputTokens = count(inputTokens + count(message.usage.input));
    cacheReadTokens = count(cacheReadTokens + count(message.usage.cacheRead));
    cacheWriteTokens = count(cacheWriteTokens + count(message.usage.cacheWrite));
    outputTokens = count(outputTokens + count(message.usage.output));
  }
  const sourceDigest = createHash("sha256").update(JSON.stringify([...usage])).digest("hex");
  // Pi's usage.cost is model-price arithmetic, not authoritative billing
  // evidence, so no cost is recorded: spend is tokens only.
  return { inputTokens, cacheReadTokens, cacheWriteTokens, outputTokens, sourceDigest };
}

/** Every prompt token the provider processed: fresh input plus cache read and
 * write. The task budget ("cached included") and monotonic publication compare
 * this. A record written before #1250 has no cache fields and its
 * `inputTokens` already holds this total. */
export function homeTaskPromptTokens(spend: HomeTaskSpend): number {
  return spend.inputTokens + (spend.cacheReadTokens ?? 0) + (spend.cacheWriteTokens ?? 0);
}
