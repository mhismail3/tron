import { createHash } from "node:crypto";
import type { FileEntry } from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import type { HomeTaskRecord } from "./home-task-store.js";

/** Canonical entries are the event ledger. Reconstruct, never increment a
 * second ledger from transient SDK callbacks. The digest pins the deduped usage
 * identities and deltas whose cumulative projection the store publishes. */
export function homeTaskSpend(entries: readonly FileEntry[]): NonNullable<HomeTaskRecord["spend"]> {
  const usage = new Map<string, string>();
  let inputTokens = 0;
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
    inputTokens = count(inputTokens + count(message.usage.input) + count(message.usage.cacheRead) + count(message.usage.cacheWrite));
    outputTokens = count(outputTokens + count(message.usage.output));
  }
  const sourceDigest = createHash("sha256").update(JSON.stringify([...usage])).digest("hex");
  // Pi's usage.cost is model-price arithmetic, not authoritative billing
  // evidence, so no cost is recorded: spend is tokens only.
  return { inputTokens, outputTokens, sourceDigest };
}
