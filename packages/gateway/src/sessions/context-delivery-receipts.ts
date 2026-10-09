import type { SessionEntry } from "@earendil-works/pi-coding-agent";
import type { ContextDeliveryMetadata, ExtensionToolOrigin } from "../protocol/types.js";

import { invocationProjection, invocationReceipts } from "./invocation-receipts.js";
import { classifyCapturedExtensionOwner } from "./extension-activity-history.js";

export const CONTEXT_DELIVERY_RECEIPT_TYPE = "tron.context-delivery.v4";
const HISTORICAL_CONTEXT_DELIVERY_RECEIPT_TYPE = "tron.session-input.v1";

interface ContextDeliveryReceiptData {
  writer: "gateway";
  version: 4;
  targetEntryId: string;
  source: "extension";
  delivery: "stored" | "triggeredTurn";
  origin?: ExtensionToolOrigin;
  wakeOperationId?: string;
}

function boundedText(value: unknown, maximumBytes: number): value is string {
  return typeof value === "string"
    && value.length > 0
    && Buffer.byteLength(value) <= maximumBytes
    && !/[\u0000-\u001f\u007f]/u.test(value);
}

function parseOrigin(value: unknown): ExtensionToolOrigin | undefined {
  if (value === undefined) return undefined;
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const record = value as Record<string, unknown>;
  if (!boundedText(record.source, 256)) return undefined;
  if (record.owner === undefined) return { source: record.source };
  if (!record.owner || typeof record.owner !== "object" || Array.isArray(record.owner)) return undefined;
  const owner = record.owner as Record<string, unknown>;
  if (!boundedText(owner.id, 256) || !boundedText(owner.title, 256)
      || !boundedText(owner.source, 256)
      || (owner.kind !== undefined && owner.kind !== "subagent" && owner.kind !== "extension")) return undefined;
  return {
    source: record.source,
    owner: classifyCapturedExtensionOwner({ id: owner.id, title: owner.title, source: owner.source,
      ...(owner.kind === "subagent" || owner.kind === "extension" ? { kind: owner.kind } : {}),
    }),
  };
}

export function makeContextDeliveryReceipt(
  targetEntryId: string,
  delivery: ContextDeliveryReceiptData["delivery"],
  origin?: ExtensionToolOrigin,
  wakeOperationId?: string,
): ContextDeliveryReceiptData {
  return {
    writer: "gateway",
    version: 4,
    targetEntryId,
    source: "extension",
    delivery,
    ...(origin ? { origin } : {}),
    ...(wakeOperationId ? { wakeOperationId } : {}),
  };
}

function parseReceipt(value: unknown, historical: boolean): ContextDeliveryReceiptData | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const record = value as Record<string, unknown>;
  if ((!historical && (record.writer !== "gateway" || record.version !== 4))
      || (historical && record.version !== 1)
      || record.source !== "extension"
      || (!historical && record.delivery !== "stored" && record.delivery !== "triggeredTurn")
      || (historical && record.trigger !== "turn")
      || !boundedText(record.targetEntryId, 256)) return undefined;
  const origin = parseOrigin(record.origin);
  if (record.origin !== undefined && !origin) return undefined;
  if (record.wakeOperationId !== undefined && (historical || record.delivery !== "stored"
      || !boundedText(record.wakeOperationId, 256))) return undefined;
  const allowed = new Set([
    "writer", "version", "targetEntryId", "source",
    historical ? "trigger" : "delivery", "origin", ...(!historical ? ["wakeOperationId"] : []),
  ]);
  if (Object.keys(record).some(key => !allowed.has(key))) return undefined;
  if (!historical && Buffer.byteLength(JSON.stringify(record), "utf8") > 8_192) return undefined;
  return {
    writer: "gateway",
    version: 4,
    targetEntryId: record.targetEntryId,
    source: "extension",
    delivery: historical ? "triggeredTurn" : record.delivery as ContextDeliveryReceiptData["delivery"],
    ...(typeof record.wakeOperationId === "string" ? { wakeOperationId: record.wakeOperationId } : {}),
    ...(origin ? { origin } : {}),
  };
}

function isCustomMessageEntry(entry: SessionEntry | undefined): boolean {
  return entry?.type === "custom_message"
    || (entry?.type === "message" && entry.message.role === "custom");
}

/**
 * Joins Gateway delivery receipts to an earlier canonical custom message. The
 * historical v1 shape is normalized at this canonical-data boundary; v4 is the
 * only wire model. Duplicate contradictory receipts fail closed.
 */
export function contextDeliveryMetadataByEntry(
  entries: readonly SessionEntry[],
): ReadonlyMap<string, ContextDeliveryMetadata> {
  // Most branches hold no delivery receipt, and a snapshot projection runs this
  // over the whole branch on every build: with nothing to join, do not index
  // every entry twice for a map that stays empty (G-2). The `some` pass is one
  // cheap scan that stops at the first receipt.
  if (!entries.some((entry) => entry.type === "custom"
    && (entry.customType === CONTEXT_DELIVERY_RECEIPT_TYPE
      || entry.customType === HISTORICAL_CONTEXT_DELIVERY_RECEIPT_TYPE))) {
    return new Map();
  }
  const byId = new Map(entries.map((entry) => [entry.id, entry]));
  const wakeBindings = new Map(invocationProjection(invocationReceipts(entries))
    .filter(invocation => invocation.source === "subagentWake" && invocation.canonicalEntryId !== undefined)
    .map(invocation => [invocation.operationId, invocation]));
  const position = new Map(entries.map((entry, index) => [entry.id, index]));
  const admitted = new Map<string, ContextDeliveryMetadata>();
  const contradicted = new Set<string>();
  for (const entry of entries) {
    if (entry.type !== "custom" || (entry.customType !== CONTEXT_DELIVERY_RECEIPT_TYPE
      && entry.customType !== HISTORICAL_CONTEXT_DELIVERY_RECEIPT_TYPE)) continue;
    const receipt = parseReceipt(
      entry.data,
      entry.customType === HISTORICAL_CONTEXT_DELIVERY_RECEIPT_TYPE,
    );
    if (!receipt || !isCustomMessageEntry(byId.get(receipt.targetEntryId))
        || (position.get(receipt.targetEntryId) ?? Number.MAX_SAFE_INTEGER)
          >= (position.get(entry.id) ?? -1)) continue;
    const wake = receipt.wakeOperationId ? wakeBindings.get(receipt.wakeOperationId) : undefined;
    const wakeEntry = wake?.canonicalEntryId ? byId.get(wake.canonicalEntryId) : undefined;
    // Admission alone is not a turn: handled/abandoned inputs have no binding.
    // Exact canonical binding survives queue consumption and cold reconstruction.
    const wakeEntryId = wakeEntry?.type === "message" && wakeEntry.message.role === "user"
      && wake?.origin.kind === "subagent" && wake.origin.ownerId === receipt.origin?.owner?.id
      ? wakeEntry.id : undefined;
    const metadata: ContextDeliveryMetadata = {
      source: receipt.source,
      delivery: wakeEntryId ? "triggeredTurn" : receipt.delivery,
      ...(wakeEntryId ? { wakeEntryId } : {}),
      ...(receipt.origin ? { origin: receipt.origin } : {}),
    };
    const previous = admitted.get(receipt.targetEntryId);
    if (previous && JSON.stringify(previous) !== JSON.stringify(metadata)) {
      admitted.delete(receipt.targetEntryId);
      contradicted.add(receipt.targetEntryId);
    } else if (!contradicted.has(receipt.targetEntryId)) {
      admitted.set(receipt.targetEntryId, metadata);
    }
  }
  return admitted;
}
