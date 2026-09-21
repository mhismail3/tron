import type { FileEntry, SessionEntry } from "@earendil-works/pi-coding-agent";
import {
  SESSION_SEARCH_MAX_ENTRY_BYTES,
  SESSION_SEARCH_MAX_SNIPPET_BYTES,
  normalizeForSearch,
  type SessionSearchForkBoundary,
} from "./session-search-contract.js";

export interface SearchTextEntry {
  id: string;
  parentId: string | null;
  timestamp: string;
  role: "user" | "assistant";
  text: string;
  ordinal: number;
}

export interface ValidatedSearchBranch {
  header: FileEntry & { type: "session" };
  entries: SessionEntry[];
  leafEntryId?: string;
  forkBoundary?: SessionSearchForkBoundary;
}

function isValidID(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && Buffer.byteLength(value, "utf8") <= 512 && !/[\u0000-\u001f\u007f]/u.test(value);
}

function validateGraph(file: readonly FileEntry[]): Map<string, SessionEntry> {
  if (file.length > 100_000 || file[0]?.type !== "session") throw new Error("Session search file graph is invalid");
  const byID = new Map<string, SessionEntry>();
  for (const entry of file.slice(1)) {
    if (entry.type === "session" || !isValidID(entry.id) || byID.has(entry.id)
      || (entry.parentId !== null && !isValidID(entry.parentId))
      || typeof entry.timestamp !== "string" || Buffer.byteLength(entry.timestamp, "utf8") > 128) {
      throw new Error("Session search file graph is invalid");
    }
    byID.set(entry.id, entry);
  }
  const complete = new Set<string>();
  for (const entry of byID.values()) {
    if (complete.has(entry.id)) continue;
    const path: string[] = [];
    const visiting = new Set<string>();
    let cursor: SessionEntry | undefined = entry;
    while (cursor) {
      if (visiting.has(cursor.id)) throw new Error("Session search file graph contains a cycle");
      if (complete.has(cursor.id)) break;
      visiting.add(cursor.id); path.push(cursor.id);
      if (cursor.parentId === null) break;
      cursor = byID.get(cursor.parentId);
      if (!cursor) throw new Error("Session search file graph has a missing parent");
    }
    for (const id of path) complete.add(id);
  }
  return byID;
}

/** Full-file validation before branch selection; unlike the older helper this
 * rejects malformed disconnected records and duplicate IDs too. */
export function validateSearchBranch(
  file: readonly FileEntry[],
  forkBoundary?: SessionSearchForkBoundary,
  selectedLeafId?: string,
): ValidatedSearchBranch {
  const header = file[0];
  if (!header || header.type !== "session") throw new Error("Session search header is invalid");
  const byID = validateGraph(file);
  const physical = [...byID.values()];
  const leaf = selectedLeafId ? byID.get(selectedLeafId) : physical[physical.length - 1];
  if (selectedLeafId && !leaf) throw new Error("Session search selected leaf is missing from the graph");
  const selected: SessionEntry[] = [];
  const seen = new Set<string>();
  let cursor = leaf;
  while (cursor) {
    if (seen.has(cursor.id)) throw new Error("Session search branch contains a cycle");
    seen.add(cursor.id); selected.push(cursor);
    if (cursor.parentId === null) break;
    const parent = byID.get(cursor.parentId);
    if (!parent) throw new Error("Session search branch has a missing parent");
    cursor = parent;
  }
  selected.reverse();
  let ownEntries = selected;
  if (forkBoundary) {
    const inheritedIndex = selected.findIndex(entry => entry.id === forkBoundary.inheritedEntryId);
    if (inheritedIndex < 0) throw new Error("Fork search boundary is not on the selected branch");
    ownEntries = selected.slice(inheritedIndex + 1);
  }
  return {
    header,
    entries: ownEntries,
    ...(leaf ? { leafEntryId: leaf.id } : {}),
    ...(forkBoundary ? { forkBoundary } : {}),
  };
}

function textFromContent(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.flatMap(part => {
    if (!part || typeof part !== "object" || Array.isArray(part)) return [];
    const value = part as Record<string, unknown>;
    return value.type === "text" && typeof value.text === "string" ? [value.text] : [];
  }).join("\n");
}

/** Search-only extractor. It intentionally does not use UI/history flatteners. */
export function extractSearchText(entry: SessionEntry, ordinal: number): SearchTextEntry | undefined {
  if (entry.type !== "message" || !entry.message || typeof entry.message !== "object" || Array.isArray(entry.message)) return undefined;
  const message = entry.message as unknown as Record<string, unknown>;
  if (message.role !== "user" && message.role !== "assistant") return undefined;
  const text = textFromContent(message.content).normalize("NFC").trim();
  if (!text || Buffer.byteLength(text, "utf8") > SESSION_SEARCH_MAX_ENTRY_BYTES) return undefined;
  return {
    id: entry.id,
    parentId: entry.parentId,
    timestamp: entry.timestamp,
    role: message.role,
    text,
    ordinal,
  };
}

export function excerpt(text: string, query: string, maximumBytes = SESSION_SEARCH_MAX_SNIPPET_BYTES): string {
  const normalizedText = text.replace(/\s+/gu, " ").trim();
  const normalizedQuery = normalizeForSearch(query.replace(/^"|"$/gu, "").trim());
  const lowered = normalizeForSearch(normalizedText);
  const location = normalizedQuery ? lowered.indexOf(normalizedQuery) : -1;
  const limit = Math.max(64, maximumBytes);
  if (Buffer.byteLength(normalizedText, "utf8") <= limit) return normalizedText;
  const chars = Math.max(32, Math.floor(limit / 2));
  const start = location >= 0 ? Math.max(0, location - chars) : 0;
  const candidate = normalizedText.slice(start, start + chars * 2);
  return `${start > 0 ? "…" : ""}${candidate}${start + candidate.length < normalizedText.length ? "…" : ""}`;
}

export function terms(value: string): string[] {
  return [...new Set(normalizeForSearch(value).match(/[\p{L}\p{N}_-]+/gu) ?? [])].filter(Boolean);
}

/** Bounded substring grams. One- and two-character identifiers are indexed
 * deliberately; exact canonical reread still proves the final match. */
export function trigrams(value: string): string[] {
  const normalized = normalizeForSearch(value).replace(/\s+/gu, " ");
  const output = new Set<string>();
  for (let width = 1; width <= Math.min(3, normalized.length); width += 1) {
    for (let index = 0; index <= normalized.length - width; index += 1) {
      const gram = normalized.slice(index, index + width);
      if (/\S/u.test(gram)) output.add(gram);
    }
  }
  return [...output];
}
