import type { FileEntry, SessionEntry } from "@earendil-works/pi-coding-agent";

export interface ParsedSessionBranch {
  sessionId: string;
  parentSession?: string;
  branch: SessionEntry[];
  leafEntryId?: string;
}

/** Select the leaf-to-root branch from a parsed canonical session. */
export function branchFromParsedSession(entries: FileEntry[]): ParsedSessionBranch | undefined {
  const header = entries[0];
  if (!header || header.type !== "session" || !header.id) return undefined;
  const sessionEntries = entries.slice(1).filter((entry): entry is SessionEntry => entry.type !== "session");
  const byID = new Map(sessionEntries.map((entry) => [entry.id, entry]));
  const leaf = sessionEntries[sessionEntries.length - 1];
  const reversed: SessionEntry[] = [];
  const seen = new Set<string>();
  let cursor = leaf;
  while (cursor) {
    if (seen.has(cursor.id)) return undefined;
    seen.add(cursor.id);
    reversed.push(cursor);
    cursor = cursor.parentId === null ? undefined : byID.get(cursor.parentId);
    if (reversed[reversed.length - 1]!.parentId !== null && cursor === undefined) return undefined;
  }
  return {
    sessionId: header.id,
    ...(header.parentSession ? { parentSession: header.parentSession } : {}),
    branch: reversed.reverse(),
    ...(leaf ? { leafEntryId: leaf.id } : {}),
  };
}
