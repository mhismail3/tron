import { createHash } from "node:crypto";
import type { ProfileFile } from "../../knowledge/knowledge-notes.js";
import type { HomeProfileRead } from "./home-profile.js";

export const PROFILE_SECTION_HEADING = "## Learned profile";
export function profileIndex(read: HomeProfileRead, offset = 0): string {
  const files = new Set<ProfileFile>(["core", "home", ...read.items.flatMap(item => item.file === null ? [] : [item.file ?? "core"])]);
  const names = [...files].sort();
  return [PROFILE_SECTION_HEADING,
    "Structured Knowledge profile: Core, Home and named scopes. This is a metadata index, not selected instructions. Use profile read file=<name> to inspect exact content and provenance; Home decides relevance and what belongs in a worker brief.",
    "Existing explicitly binding safety and standing instructions retain their force; partitioning or absence from this index does not revoke them. Inspect the relevant records before acting. Confirmation is evidence of confirmation, not permission to infer new binding rules.",
    ...names.slice(offset, offset + 16).map(file => {
      const items = read.items.filter(item => item.file === file || (item.file === undefined && file === "core"));
      const version = createHash("sha256").update(items.map(item => `${item.id}:${item.revisionId}`).join("\n")).digest("hex").slice(0, 12);
      return `- ${file}: ${items.filter(item => item.status === "active").length} active / ${items.length} total; version ${version}; profile read file=${file}`;
    }),
    ...(read.diagnostics.length ? [`Profile diagnostics: ${read.diagnostics.length} notes need explicit metadata repair, not an inferred destination. Exact content remains available through Knowledge reads.`,
      ...read.diagnostics.slice(offset, offset + 16).map(item => `- ${item.issues.join("/")} labels: knowledge read id=${item.id} revisionId=${item.revisionId}`)] : []),
    ...(offset + 16 < Math.max(names.length, read.diagnostics.length) ? [`More metadata: profile read offset=${offset + 16}.`] : []),
  ].join("\n");
}
