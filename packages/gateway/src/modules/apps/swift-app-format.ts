import { createHash } from "node:crypto";
import { GatewayError } from "../../errors.js";

interface ManifestFields {
  id: string; name: string; icon?: string; revision: number;
  sourceSha256: string; sourceBytes: number; updatedAt: string;
}
export interface SwiftAppManifestV1 extends ManifestFields { version: 1 }
export interface SwiftAppManifestV2 extends ManifestFields {
  version: 2;
  instanceId: string;
  feeds: string[];
  /** Exact source/config revisions; old v1 attribution is deliberately unknown. */
  history: SwiftAppRevision[];
}
export type SwiftAppManifest = SwiftAppManifestV1 | SwiftAppManifestV2;
export interface SwiftAppActor { kind: "session" | "device" | "unknown"; id?: string }
export interface SwiftAppRevision extends ManifestFields { feeds: string[]; actor: SwiftAppActor }
export interface SwiftAppDisplayReference { sessionId: string; artifactId: string }
export interface SwiftAppOffer {
  reference: SwiftAppDisplayReference;
  version: 1; id: string; appId: string; name: string; icon?: string;
  sourceSha256: string; sourceBytes: number; feeds: string[]; actor: SwiftAppActor;
}
export const SOURCE_BYTES = 320_000;
export const MANIFEST_BYTES = 32_768;
const fields = ["id", "name", "icon", "revision", "sourceSha256", "sourceBytes", "updatedAt"];
const hashPattern = /^[a-f0-9]{64}$/;
export function digest(value: string): string { return createHash("sha256").update(value).digest("hex"); }
export function admitDigest(value: unknown): string {
  if (typeof value !== "string" || !hashPattern.test(value)) throw new GatewayError("invalid_request", "A source or offer digest must be 64 lowercase hex characters");
  return value;
}
export function admitFeeds(value: unknown): string[] {
  if (!Array.isArray(value) || value.length > 1 || value.some(id => id !== "ios-builds") || new Set(value).size !== value.length) {
    throw new GatewayError("invalid_request", "Only the declared read-only ios-builds feed is supported");
  }
  return [...value] as string[];
}
function exact(record: Record<string, unknown>, keys: string[]): boolean { return Object.keys(record).every(key => keys.includes(key)); }
function validFields(record: Record<string, unknown>, id: string): boolean {
  return record.id === id && typeof record.name === "string" && record.name.trim().length > 0 && Buffer.byteLength(record.name) <= 80
    && (record.icon === undefined || typeof record.icon === "string" && Buffer.byteLength(record.icon) <= 80)
    && Number.isSafeInteger(record.revision) && (record.revision as number) >= 1
    && typeof record.sourceSha256 === "string" && hashPattern.test(record.sourceSha256)
    && Number.isSafeInteger(record.sourceBytes) && (record.sourceBytes as number) > 0 && (record.sourceBytes as number) <= SOURCE_BYTES
    && typeof record.updatedAt === "string" && Number.isFinite(Date.parse(record.updatedAt));
}
function unreadable(id: string): never { throw new GatewayError("conflict", `App ${id} has an unreadable or newer manifest; it was left unchanged`); }
/** Named persisted consumer: never adds feeds, upgrades, or rewrites v1 on read. */
export function readSwiftAppManifestV1(record: Record<string, unknown>, id: string): SwiftAppManifestV1 {
  if (record.version !== 1 || !exact(record, ["version", ...fields]) || !validFields(record, id)) unreadable(id);
  return record as unknown as SwiftAppManifestV1;
}
export function readSwiftAppManifest(value: unknown, id: string): SwiftAppManifest {
  if (!value || typeof value !== "object" || Array.isArray(value)) unreadable(id);
  const record = value as Record<string, unknown>;
  if (record.version === 1) return readSwiftAppManifestV1(record, id);
  if (record.version !== 2 || !exact(record, ["version", ...fields, "instanceId", "feeds", "history"]) || !validFields(record, id)
    || typeof record.instanceId !== "string" || !/^[a-f0-9-]{36}$/.test(record.instanceId)
    || !Array.isArray(record.history) || record.history.length < 1 || record.history.length > 20) unreadable(id);
  try { admitFeeds(record.feeds); } catch { unreadable(id); }
  let previous = 0;
  for (const raw of record.history) {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) unreadable(id);
    const item = raw as Record<string, unknown>;
    if (!exact(item, [...fields, "feeds", "actor"]) || !validFields(item, id) || (item.revision as number) <= previous) unreadable(id);
    previous = item.revision as number;
    try { admitFeeds(item.feeds); } catch { unreadable(id); }
    const actor = item.actor as Record<string, unknown> | undefined;
    if (!actor || !exact(actor, ["kind", "id"]) || !["unknown", "session", "device"].includes(actor.kind as string)
      || (actor.kind === "unknown" ? actor.id !== undefined : typeof actor.id !== "string" || actor.id.length > 256)) unreadable(id);
  }
  const last = record.history.at(-1) as Record<string, unknown>;
  if (last.revision !== record.revision || last.sourceSha256 !== record.sourceSha256 || last.sourceBytes !== record.sourceBytes
    || JSON.stringify(last.feeds) !== JSON.stringify(record.feeds)) unreadable(id);
  return record as unknown as SwiftAppManifestV2;
}

export function offerIdentity(input: Omit<SwiftAppOffer, "version" | "id" | "actor">): string {
  return digest(JSON.stringify([input.reference.sessionId, input.reference.artifactId, input.appId, input.name, input.icon ?? null, input.sourceSha256, input.sourceBytes, input.feeds]));
}
export function referenceKey(reference: SwiftAppDisplayReference): string {
  if (!reference || ![reference.sessionId, reference.artifactId].every(value => typeof value === "string" && value.length > 0 && value.length <= 256)) {
    throw new GatewayError("invalid_request", "An app offer requires its exact session/artifact reference");
  }
  return digest(JSON.stringify([reference.sessionId, reference.artifactId]));
}
export function readSwiftAppOffer(value: unknown): SwiftAppOffer {
  const offer = value as SwiftAppOffer;
  if (!offer || offer.version !== 1 || typeof offer.appId !== "string" || !/^[a-z0-9][a-z0-9-]{0,62}$/.test(offer.appId)
    || !exact(offer as unknown as Record<string, unknown>, ["version", "id", "reference", "appId", "name", "icon", "sourceSha256", "sourceBytes", "feeds", "actor"])
    || !validFields({ ...offer, id: offer.appId, revision: 1, updatedAt: "2026-01-01T00:00:00Z" }, offer.appId)) {
    throw new GatewayError("conflict", "The app offer is unreadable; ask Tron to prepare it again");
  }
  admitFeeds(offer.feeds);
  referenceKey(offer.reference);
  if (!exact(offer.reference as unknown as Record<string, unknown>, ["sessionId", "artifactId"])
    || offer.actor?.kind !== "session" || offer.actor.id !== offer.reference.sessionId) {
    throw new GatewayError("conflict", "The app offer is not bound to its producing session/artifact");
  }
  if (offerIdentity(offer) !== offer.id) throw new GatewayError("conflict", "The app offer does not match its reviewed identity");
  return offer;
}
