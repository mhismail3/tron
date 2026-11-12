import { createHash } from "node:crypto";
import { PROFILE_AREAS } from "./profile-placement.js";
import type { HomeProfileIndexRead } from "./home-profile.js";

export const PROFILE_SECTION_HEADING = "## Learned profile";
const AREA_NAMES = [...Object.keys(PROFILE_AREAS), "inferred", "prior"];
type IndexRead = Pick<HomeProfileIndexRead, "diagnostics" | "sorting"> & { items: Array<Pick<HomeProfileIndexRead["items"][number], "id" | "revisionId" | "path" | "status">> };

function areaLabel(path: string): string {
  return path === "inferred" ? "Unsorted" : path === "prior" ? "Prior organization" : PROFILE_AREAS[path as keyof typeof PROFILE_AREAS];
}

function indexFacts(read: IndexRead, activation?: "user" | "wake") {
  const areas = AREA_NAMES.map(path => {
    const items = read.items.filter(item => item.path === path || item.path.startsWith(path + "/"));
    const version = createHash("sha256").update(items.map(item => `${item.id}:${item.revisionId}`).sort().join("\n")).digest("hex").slice(0, 12);
    return { path, counts: `${items.filter(item => item.status === "active").length} active / ${items.length} total; version ${version}` };
  });
  const diagnostics = read.diagnostics.map(item => `- ${item.issues.join("/")} metadata: knowledge read id=${item.id} revisionId=${item.revisionId}`);
  const personal = read.items.filter(item => item.status === "active" && !["inferred", "prior"].includes(item.path.split("/")[0]!));
  const subareas = new Set(personal.flatMap(item => item.path.split("/").slice(1).map((_, index) => item.path.split("/").slice(0, index + 2).join("/"))));
  const leaves = new Map<string, number>(); for (const item of personal) leaves.set(item.path, (leaves.get(item.path) ?? 0) + 1);
  const unsorted = read.items.filter(item => item.status === "active" && item.path.startsWith("inferred/")).length;
  const nearLeaves = [...leaves.values()].filter(count => count >= Math.ceil(32 * 0.8)).length;
  const nearCapacity = personal.length >= Math.ceil(256 * 0.8) || unsorted >= Math.ceil(128 * 0.8) || subareas.size >= Math.ceil(128 * 0.8) || nearLeaves > 0;
  return {
    areas, diagnostics, unsorted,
    capacity: `${personal.length}/256 personal, ${unsorted}/128 unsorted, ${subareas.size}/128 subareas; ${nearLeaves} leaf groups at ≥80% of 32.${nearCapacity ? " Warning: review capacity before adding; nothing is automatically evicted." : ""}`,
    offer: activation !== "user" ? "on-demand only; not a maintainer turn start" : read.sorting.deferred ? "deferred until a NEW note arrives" : unsorted >= 8 ? "eligible at this maintainer turn start; offer at most 8 notes" : "below 8 Unsorted; no automatic offer",
  };
}

function bounded(header: readonly string[], rows: readonly string[], offset: number): string {
  const selected: string[] = [];
  let consumed = 0;
  for (const row of rows.slice(offset, offset + 16)) {
    const continuation = `More metadata: profile read offset=${offset + consumed + 1}.`;
    if (Buffer.byteLength([...header, ...selected, row, continuation].join("\n")) > 8 * 1024) break;
    selected.push(row); consumed++;
  }
  return [...header, ...selected, ...(offset + consumed < rows.length ? [`More metadata: profile read offset=${offset + consumed}.`] : [])].join("\n");
}

export function profileIndex(read: IndexRead, offset = 0): string {
  const facts = indexFacts(read);
  const rows = [...facts.areas.map(area => `- ${areaLabel(area.path)} (${area.path}): ${area.counts}; profile read path=${area.path}`), ...facts.diagnostics];
  return bounded([PROFILE_SECTION_HEADING,
    `Capacity: ${facts.capacity}`,
    "Personal profile: seven areas, separate Unsorted holding notes, and read-only Prior organization for historical placement. This is metadata, not selected instructions. Use profile read path=<path> for exact content and provenance; Home decides relevance and worker briefs.",
    "Confirmed by you and Inferred describe evidence, not execution permission. Existing explicitly binding safety and standing instructions retain their force wherever placed; inspect and respect them before acting.",
    `Sorting arrival version: ${read.sorting.version}. Use profile defer version=<version> only for his Not now on a maintainer turn; the Knowledge receipt owns suppression.`,
    `Unsorted active: ${facts.unsorted}. Sorting offer: ${facts.offer}. Edits, moves, time and restarts do not reset Not now; no timers or polling.`,
    `Profile diagnostics: ${read.diagnostics.length}; exact records remain available through Knowledge.`,
  ], rows, offset);
}

export const PROFILE_AREAS_SECTION = [PROFILE_SECTION_HEADING,
  "Personal profile: seven areas, separate Unsorted holding notes, and read-only Prior organization for historical placement. This is metadata, not selected instructions. Use profile read path=<path> for exact content and provenance; Home decides relevance and worker briefs.",
  "Confirmed by you and Inferred describe evidence, not execution permission. Existing explicitly binding safety and standing instructions retain their force wherever placed; inspect and respect them before acting.",
  "Use profile defer version=<version> only for his Not now on a maintainer turn; the Knowledge receipt owns suppression. Edits, moves, time and restarts do not reset Not now; no timers or polling.",
  "Counts, versions, the sorting offer and diagnostics for this turn are in the turn state after the memory view.",
  ...AREA_NAMES.map(path => `- ${areaLabel(path)} (${path}): profile read path=${path}`),
].join("\n");

export function profileTurnState(read: IndexRead, activation: "user" | "wake"): string {
  const facts = indexFacts(read, activation);
  return bounded([
    `Profile capacity: ${facts.capacity}`,
    `Sorting arrival version: ${read.sorting.version}.`,
    `Unsorted active: ${facts.unsorted}. Sorting offer: ${facts.offer}.`,
    `Profile diagnostics: ${read.diagnostics.length}; exact records remain available through Knowledge.`,
  ], [...facts.areas.map(area => `- ${area.path}: ${area.counts}`), ...facts.diagnostics], 0);
}
