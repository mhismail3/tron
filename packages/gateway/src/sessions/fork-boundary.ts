import type { FileEntry, SessionEntry } from "@earendil-works/pi-coding-agent";
import type { TranscriptForkBoundary } from "../protocol/types.js";

const MAX_FORK_BOUNDARY_ENTRIES = 100_000;

/** One disposable identity, not a copy of either session's transcript. */
export interface ForkBoundaryAnchor {
  kind: TranscriptForkBoundary["kind"];
  inheritedEntryId: string;
}

function validatedGraph(file: FileEntry[]): Map<string, SessionEntry> | undefined {
  if (file.length > MAX_FORK_BOUNDARY_ENTRIES || file[0]?.type !== "session") return undefined;
  const byID = new Map<string, SessionEntry>();
  for (const entry of file.slice(1)) {
    if (entry.type === "session" || typeof entry.id !== "string" || !entry.id
      || Buffer.byteLength(entry.id) > 512 || byID.has(entry.id)
      || (entry.parentId !== null && (typeof entry.parentId !== "string" || !entry.parentId))
      || typeof entry.timestamp !== "string") return undefined;
    byID.set(entry.id, entry);
  }
  const colors = new Map<string, 1 | 2>();
  for (const entry of byID.values()) {
    if (colors.has(entry.id)) continue;
    const path: string[] = [];
    let cursor: SessionEntry | undefined = entry;
    while (cursor) {
      const color = colors.get(cursor.id);
      if (color === 1) return undefined;
      if (color === 2) break;
      colors.set(cursor.id, 1);
      path.push(cursor.id);
      if (cursor.parentId === null) break;
      cursor = byID.get(cursor.parentId);
      if (!cursor) return undefined;
    }
    for (const id of path) colors.set(id, 2);
  }
  return byID;
}

/** Callers admit the immediate parent identity/path before supplying its full
 * tree. Pi copies entry identities, but regenerates/rechains labels and may
 * sanitize or summarize inherited payloads. Payload differences are NOT forks.
 * Validate a contiguous root-to-leaf inherited prefix, not mere ID membership.
 * Parent absence/ambiguity and header-only relationships cannot justify a pill. */
export function resolveForkBoundaryAnchor(
  childFile: FileEntry[],
  parentFile: FileEntry[],
  kind: ForkBoundaryAnchor["kind"],
  selectedLeaf?: string | null,
): ForkBoundaryAnchor | undefined {
  const header = childFile[0];
  const parentHeader = parentFile[0];
  if (header?.type !== "session" || !header.parentSession
    || parentHeader?.type !== "session" || header.id === parentHeader.id) return undefined;
  const child = validatedGraph(childFile);
  const parent = validatedGraph(parentFile);
  if (!child || !parent) return undefined;
  const leaf = selectedLeaf === undefined ? childFile.at(-1)?.id : selectedLeaf;
  if (!leaf || !child.has(leaf)) return undefined;
  const branch: SessionEntry[] = [];
  let cursor = child.get(leaf);
  while (cursor) {
    branch.push(cursor);
    cursor = cursor.parentId === null ? undefined : child.get(cursor.parentId);
  }
  branch.reverse();

  // Memoize only within this bounded scan so long label chains remain O(N).
  const parentByID = parent;
  const normalizedParents = new Map<string, string | null>();
  function withoutLabels(id: string | null): string | null {
    const labels: string[] = [];
    let result = id;
    while (result !== null && parentByID.get(result)?.type === "label") {
      if (normalizedParents.has(result)) { result = normalizedParents.get(result)!; break; }
      labels.push(result);
      result = parentByID.get(result)!.parentId;
    }
    for (const label of labels) normalizedParents.set(label, result);
    return result;
  }

  let inherited: string | null = null;
  let hasChildEntry = false;
  for (const entry of branch) {
    if (entry.type === "label") continue;
    const source = parent.get(entry.id);
    if (!source) { hasChildEntry = true; continue; }
    // Matching IDs after divergence, or with conflicting identity/ancestry,
    // are ambiguous grafts/collisions, not evidence for a guessed transition.
    if (hasChildEntry || source.type !== entry.type || source.timestamp !== entry.timestamp
      || withoutLabels(source.parentId) !== inherited) return undefined;
    inherited = entry.id;
  }
  return inherited ? { kind, inheritedEntryId: inherited } : undefined;
}

/** Locate the transition on the CURRENT selected branch. A retained anchor is
 * usable even before the child has appended anything; later snapshots need no
 * parent disk I/O. Hidden entries and labels are mapped by the projection's
 * actual displayable entries, keeping filtering policy in its existing owner. */
export function projectForkBoundary(
  branch: SessionEntry[],
  displayedEntries: SessionEntry[],
  anchor: ForkBoundaryAnchor | undefined,
): TranscriptForkBoundary | undefined {
  if (!anchor) return undefined;
  const inheritedIndex = branch.findIndex(entry => entry.id === anchor.inheritedEntryId);
  if (inheritedIndex < 0) return undefined;
  const firstChildIndex = branch.findIndex((entry, index) => index > inheritedIndex && entry.type !== "label");
  if (firstChildIndex < 0) return undefined;
  const displayedIDs = new Set(displayedEntries.map(entry => entry.id));
  const displayEntry = branch.slice(firstChildIndex).find(entry => displayedIDs.has(entry.id));
  return displayEntry ? {
    kind: anchor.kind,
    entryId: branch[firstChildIndex]!.id,
    displayEntryId: displayEntry.id,
  } : undefined;
}
