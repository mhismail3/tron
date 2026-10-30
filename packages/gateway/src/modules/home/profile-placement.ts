import type { ProfileNoteRecord } from "./profile-note-contract.js";

/** Placement is organization only. These are the seven personal roots; inferred
 * is deliberately separate, and prior organization is never a writable root. */
export const PROFILE_AREAS = {
  life: "Life & people",
  routines: "Routines & wellbeing",
  communication: "Communication",
  engineering: "Engineering",
  resources: "Machines, devices & services",
  projects: "Projects",
  corrections: "Corrections",
} as const;
export interface ProfileMetadata { version: 2; path: string[] }
/** Rebuildable SQL-head projection, written only with its canonical note. */
export interface ProfileNoteRow {
  title: string; confirmed: boolean; tags: string[]; retired: boolean;
  profile?: ProfileMetadata; supersedes: string[];
}
export interface ProfileRecordRow extends ProfileNoteRow { id: string; revisionId: string; createdAt: string; updatedAt: string }
export function profileNoteRow(record: ProfileNoteRecord): ProfileNoteRow | null {
  if (record.kind !== "note" || record.scope !== "personal" || !record.content.tags?.includes("home-profile")) return null;
  return { title: record.content.title, confirmed: record.content.confirmed, tags: record.content.tags, retired: record.content.retired === true,
    ...(record.content.profile ? { profile: record.content.profile } : {}), supersedes: record.relations.filter(relation => relation.type === "supersedes").map(relation => relation.recordId) };
}
const HOLDING = new Set(["review", "needs-split", "project-rules", "procedures", "uncertain"]);
const SEGMENT = /^[a-z][a-z0-9-]{0,31}$/;

export function profilePath(path: string): ProfileMetadata {
  const profile = { version: 2 as const, path: path.split("/") };
  validateProfileMetadata(profile);
  return profile;
}
export function validateProfileMetadata(raw: unknown): asserts raw is ProfileMetadata {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw new Error("Invalid profile placement");
  const value = raw as ProfileMetadata;
  if (Object.keys(value).some(key => !["version", "path"].includes(key)) || value.version !== 2
    || !Array.isArray(value.path) || value.path.length < 1 || value.path.length > 4
    || value.path.some(segment => typeof segment !== "string" || !SEGMENT.test(segment))
    || (value.path[0] === "inferred" ? value.path.length !== 2 || !HOLDING.has(value.path[1]!) : !Object.hasOwn(PROFILE_AREAS, value.path[0]!))) {
    throw new Error("Profile path must use one of seven personal roots (depth 1–4), or an explicit unsorted bucket");
  }
}

type Note = Pick<Extract<ProfileNoteRecord, { kind: "note" }>, "id" | "relations"> & { content: Pick<Extract<ProfileNoteRecord, { kind: "note" }>["content"], "profile" | "retired"> };
/** Supersession includes retired successors, matching the canonical profile reader. */
function occupancy(notes: readonly Note[]): Map<string, number> {
  const superseded = new Set(notes.flatMap(note => note.relations.filter(relation => relation.type === "supersedes").map(relation => relation.recordId)));
  const counts = new Map<string, number>();
  const add = (key: string) => counts.set(key, (counts.get(key) ?? 0) + 1);
  const prefixes = new Set<string>();
  for (const note of notes) {
    if (note.content.retired || superseded.has(note.id) || !note.content.profile) continue;
    const path = note.content.profile.path;
    if (path[0] === "inferred") {
      add("unsorted");
    } else {
      add("personal");
      add(`leaf:${path.join("/")}`);
      for (let depth = 2; depth <= path.length; depth++) prefixes.add(path.slice(0, depth).join("/"));
    }
  }
  counts.set("sub-areas", prefixes.size);
  return counts;
}
/** Called inside the admitted ProfileNote transaction, including direct note
 * writers. Restored over-cap data remains readable; only net growth is refused. */
export function assertProfileCapacity(before: readonly Note[], after: readonly Note[]): void {
  const prior = occupancy(before), next = occupancy(after);
  for (const [key, count] of next) {
    const cap = key === "personal" ? 256 : key === "unsorted" || key === "sub-areas" ? 128 : 32;
    if (count > cap && count > (prior.get(key) ?? 0)) throw new Error(`Profile ${key} limit ${cap} exceeded (${count}); no notes were deleted`);
  }
}
