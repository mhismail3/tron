import type { SessionEntry } from "@earendil-works/pi-coding-agent";
import type { ExtensionToolOrigin, SessionInputMetadata } from "../protocol/types.js";

export const SESSION_INPUT_RECEIPT_TYPE = "tron.session-input.v1";

export interface SessionInputReceiptData {
  version: 1;
  targetEntryId: string;
  source: "extension";
  trigger: "turn";
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

export function makeSessionInputReceipt(
  targetEntryId: string,
  origin?: ExtensionToolOrigin,
): SessionInputReceiptData {
  return {
    version: 1,
    targetEntryId,
    source: "extension",
    trigger: "turn",
    ...(origin ? { origin } : {}),
  };
}

function parseReceipt(value: unknown): SessionInputReceiptData | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const record = value as Record<string, unknown>;
  if (record.version !== 1 || record.source !== "extension" || record.trigger !== "turn"
      || !boundedText(record.targetEntryId, 256)) return undefined;
  const origin = parseOrigin(record.origin);
  if (record.origin !== undefined && !origin) return undefined;
  return {
    version: 1,
    targetEntryId: record.targetEntryId,
    source: "extension",
    trigger: "turn",
    ...(origin ? { origin } : {}),
  };
}

function isCustomMessageEntry(entry: SessionEntry | undefined): boolean {
  return entry?.type === "custom_message"
    || (entry?.type === "message" && entry.message.role === "custom");
}

/**
 * Resolves only producer-authored receipts that are the immediate canonical
 * child of their target custom message. Duplicate contradictory receipts fail
 * closed instead of assigning plausible provenance.
 */
export function sessionInputMetadataByEntry(
  entries: readonly SessionEntry[],
): ReadonlyMap<string, SessionInputMetadata> {
  const byId = new Map(entries.map((entry) => [entry.id, entry]));
  const admitted = new Map<string, SessionInputMetadata>();
  const contradicted = new Set<string>();
  for (const entry of entries) {
    if (entry.type !== "custom" || entry.customType !== SESSION_INPUT_RECEIPT_TYPE) continue;
    const receipt = parseReceipt(entry.data);
    if (!receipt || entry.parentId !== receipt.targetEntryId
        || !isCustomMessageEntry(byId.get(receipt.targetEntryId))) continue;
    const metadata: SessionInputMetadata = {
      source: receipt.source,
      trigger: receipt.trigger,
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
