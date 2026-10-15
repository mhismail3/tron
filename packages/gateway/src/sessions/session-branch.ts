import type { FileEntry, SessionEntry } from "@earendil-works/pi-coding-agent";

interface ParsedSessionBranch {
  sessionId: string;
  parentSession?: string;
  branch: SessionEntry[];
  leafEntryId?: string;
}

/** Select the leaf-to-root branch after the caller has proved file identity. */
export function branchFromSessionEntries(entries: readonly SessionEntry[]): SessionEntry[] | undefined {
  const byID = new Map(entries.map(entry => [entry.id, entry]));
  const reversed: SessionEntry[] = [];
  const seen = new Set<string>();
  let cursor = entries[entries.length - 1];
  while (cursor) {
    if (seen.has(cursor.id)) return undefined;
    seen.add(cursor.id);
    reversed.push(cursor);
    cursor = cursor.parentId === null ? undefined : byID.get(cursor.parentId);
    if (reversed[reversed.length - 1]!.parentId !== null && cursor === undefined) return undefined;
  }
  return reversed.reverse();
}

/** A parsed file supplies its own header identity; evidence readers may instead
 * validate that identity before returning entries without the header. */
export function branchFromParsedSession(entries: FileEntry[]): ParsedSessionBranch | undefined {
  const header = entries[0];
  if (!header || header.type !== "session" || !header.id) return undefined;
  const branch = branchFromSessionEntries(entries.slice(1).filter((entry): entry is SessionEntry => entry.type !== "session"));
  if (!branch) return undefined;
  const leaf = branch[branch.length - 1];
  return {
    sessionId: header.id,
    ...(header.parentSession ? { parentSession: header.parentSession } : {}),
    branch,
    ...(leaf ? { leafEntryId: leaf.id } : {}),
  };
}
