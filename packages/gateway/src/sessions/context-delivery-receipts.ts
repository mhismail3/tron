import type { SessionEntry } from "@earendil-works/pi-coding-agent";
import type { ContextDeliveryMetadata, ExtensionToolOrigin } from "../protocol/types.js";

export const CONTEXT_DELIVERY_RECEIPT_TYPE = "tron.context-delivery.v4";
const HISTORICAL_CONTEXT_DELIVERY_RECEIPT_TYPE = "tron.session-input.v1";

export interface ContextDeliveryReceiptData {
  writer: "gateway";
  version: 4;
  targetEntryId: string;
  source: "extension";
  delivery: "stored" | "triggeredTurn";
  origin?: ExtensionToolOrigin;
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
      || !boundedText(owner.source, 256)) return undefined;
  return {
    source: record.source,
    owner: { id: owner.id, title: owner.title, source: owner.source },
  };
}

export function makeContextDeliveryReceipt(
  targetEntryId: string,
  delivery: ContextDeliveryReceiptData["delivery"],
  origin?: ExtensionToolOrigin,
): ContextDeliveryReceiptData {
  return {
    writer: "gateway",
    version: 4,
    targetEntryId,
    source: "extension",
    delivery,
    ...(origin ? { origin } : {}),
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
  const allowed = new Set([
    "writer", "version", "targetEntryId", "source",
    historical ? "trigger" : "delivery", "origin",
  ]);
  if (Object.keys(record).some(key => !allowed.has(key))) return undefined;
  if (!historical && Buffer.byteLength(JSON.stringify(record), "utf8") > 8_192) return undefined;
  return {
    writer: "gateway",
    version: 4,
    targetEntryId: record.targetEntryId,
    source: "extension",
    delivery: historical ? "triggeredTurn" : record.delivery as ContextDeliveryReceiptData["delivery"],
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
  const byId = new Map(entries.map((entry) => [entry.id, entry]));
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
    const metadata: ContextDeliveryMetadata = {
      source: receipt.source,
      delivery: receipt.delivery,
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
