import type { FileEntry, SessionEntry } from "../kernel/pi/coding-agent.js";

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

export interface SessionSearchForkBoundary {
  kind: "sessionFork" | "subagentFork";
  inheritedEntryId: string;
  gapOrdinal: number;
}

interface ValidatedSearchBranch {
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
