import type { ContextEditEntry, SessionEntry } from "../kernel/pi/coding-agent.js";
import { redactCredentials } from "../util/credential-redaction.js";
import {
  SESSION_SEARCH_MAX_ENTRY_BYTES,
  SESSION_SEARCH_MAX_SNIPPET_BYTES,
  normalizeForSearch,
} from "./session-search-contract.js";

export interface SearchTextEntry {
  id: string;
  parentId: string | null;
  timestamp: string;
  role: "user" | "assistant";
  text: string;
  ordinal: number;
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

/** Search-only extractor. It intentionally does not use UI/history flatteners.
 * Changing what this derives requires bumping
 * `SESSION_SEARCH_INDEX_DERIVATION_VERSION` in session-search-index.ts, or
 * durable rows keep postings that no longer match this extractor. */
export function extractSearchTexts(branch: readonly SessionEntry[]): SearchTextEntry[] {
  const edits = new Map<string, ContextEditEntry["replacement"]>();
  for (const entry of branch) {
    if (entry.type === "context_edit") edits.set(entry.targetId, entry.replacement);
  }
  return branch.flatMap((entry, ordinal) => {
    if (entry.type !== "message" || !entry.message || typeof entry.message !== "object" || Array.isArray(entry.message)) return [];
    const message = entry.message as unknown as Record<string, unknown>;
    if (message.role !== "user" && message.role !== "assistant") return [];
    // Like the cited reader's projection, the selected branch's last edit
    // wins. Redact whole text before bounds/postings/embeddings or excerpts;
    // truncating a credential first can leave an unrecognizable secret tail.
    const content = edits.has(entry.id) ? edits.get(entry.id)?.content : message.content;
    const text = redactCredentials(textFromContent(content)).normalize("NFC").trim();
    if (!text || Buffer.byteLength(text, "utf8") > SESSION_SEARCH_MAX_ENTRY_BYTES) return [];
    return [{
      id: entry.id, parentId: entry.parentId, timestamp: entry.timestamp,
      role: message.role, text, ordinal,
    }];
  });
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
 * deliberately; exact canonical reread still proves the final match. Both this
 * and `terms()` feed durable postings: changing how they tokenize requires
 * bumping `SESSION_SEARCH_INDEX_DERIVATION_VERSION` in session-search-index.ts. */
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
