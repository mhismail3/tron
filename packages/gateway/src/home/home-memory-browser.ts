import { GatewayError } from "../errors.js";
import type { EpisodicMessageRecord, EpisodicNodeRecord } from "../episodic/episodic-contract.js";
import type { HomeMemoryEvidence, HomeMemoryItem } from "../protocol/types.js";

export const HOME_MEMORY_PAGE_BYTES = 128 * 1024;
const TEXT_CHARS = 4096;

export interface HomeMemoryPageRequest { limit: number; cursor?: { revision: string; offset: number; limit: number } }

function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) invalid();
  return value as Record<string, unknown>;
}
function keys(value: Record<string, unknown>, allowed: string[]): void {
  if (Object.keys(value).some(key => !allowed.includes(key))) invalid();
}
function integer(value: unknown, min: number, max = Number.MAX_SAFE_INTEGER): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < min || value > max) invalid();
  return value as number;
}
function identity(value: unknown): string {
  if (typeof value !== "string" || !value.length || Buffer.byteLength(value) > 200) invalid();
  return value as string;
}
function digest(value: unknown): string {
  if (typeof value !== "string" || !/^[a-f0-9]{64}$/.test(value)) invalid();
  return value as string;
}
function invalid(): never { throw new GatewayError("invalid_request", "Invalid Home memory read parameters"); }

export function admitHomeMemoryPage(params: Record<string, unknown>): HomeMemoryPageRequest {
  keys(params, ["limit", "cursor"]);
  const limit = params.limit === undefined ? 20 : integer(params.limit, 1, 50);
  if (params.cursor === undefined) return { limit };
  if (typeof params.cursor !== "string" || params.cursor.length > 1024 || !/^[A-Za-z0-9_-]+$/.test(params.cursor)) invalid();
  let decoded: unknown;
  try { decoded = JSON.parse(Buffer.from(params.cursor, "base64url").toString("utf8")); } catch { invalid(); }
  const cursor = record(decoded);
  keys(cursor, ["revision", "offset", "limit"]);
  const admitted = { revision: digest(cursor.revision), offset: integer(cursor.offset, 1), limit: integer(cursor.limit, 1, 50) };
  if (admitted.limit !== limit || encodeHomeMemoryCursor(admitted) !== params.cursor) invalid();
  return { limit, cursor: admitted };
}

export function encodeHomeMemoryCursor(cursor: { revision: string; offset: number; limit: number }): string {
  return Buffer.from(JSON.stringify(cursor)).toString("base64url");
}

export function admitHomeMemoryEvidence(params: Record<string, unknown>): { evidence: HomeMemoryEvidence; offset: number } {
  keys(params, ["evidence", "offset"]);
  const source = record(params.evidence);
  keys(source, ["index", "sessionId", "entryId", "sourceDigest"]);
  return { evidence: { index: integer(source.index, 0), sessionId: identity(source.sessionId),
    entryId: identity(source.entryId), sourceDigest: digest(source.sourceDigest) },
  offset: params.offset === undefined ? 0 : integer(params.offset, 0) };
}

export function homeMemoryRevisionChanged(): GatewayError {
  return new GatewayError("conflict", "Home memory changed; reload the first page", true,
    { reason: "home-memory-revision-changed" }, "home-memory-revision-changed");
}

export function homeMemorySourceUnavailable(): GatewayError {
  return new GatewayError("busy", "Home memory canonical sources are unavailable", true,
    { reason: "home-memory-source-unavailable" }, "home-memory-source-unavailable");
}

function boundedText(text: string): string {
  const end = /[\uDC00-\uDFFF]/.test(text[TEXT_CHARS] ?? "") ? TEXT_CHARS - 1 : TEXT_CHARS;
  return text.slice(0, end);
}

/** Copy from the live catalog, with explicit browser-only omissions. Never turn
 * the model-facing zoom string into an alleged exact evidence response. */
export function homeMemoryItem(message: EpisodicMessageRecord, node: EpisodicNodeRecord | undefined): HomeMemoryItem {
  const text = boundedText(message.text);
  const summary = node ? boundedText(node.text) : undefined;
  return {
    index: message.index, kind: message.kind,
    attribution: ({ user: "user", talk: "assistant", echo: "tool", event: "event" } as const)[message.kind],
    ...(message.timestamp === undefined ? {} : { timestamp: message.timestamp }),
    evidence: { index: message.index, sessionId: message.sessionId, entryId: message.entryId, sourceDigest: message.sourceDigest },
    projection: { format: "memory-projection", text, omitted: message.omitted,
      omissions: [...message.omissions, ...(text.length < message.text.length ? ["browser-cap"] : [])] },
    summary: node ? { format: "memory-summary", text: summary!, truncated: summary!.length < node.text.length } : null,
  };
}
