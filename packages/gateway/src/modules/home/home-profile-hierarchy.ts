import { createHash } from "node:crypto";
import type { ProfileFile } from "../../knowledge/knowledge-notes.js";
import type { HomeProfileRead } from "./home-profile.js";

export const PROFILE_SECTION_HEADING = "## Learned profile";
export function profileIndex(read: HomeProfileRead, offset = 0): string {
  const files = new Set<ProfileFile>(["core", "home", ...read.items.map(item => item.file ?? "core")]);
  const names = [...files].sort();
  return [PROFILE_SECTION_HEADING,
    "Structured Knowledge profile: Core, Home and named scopes. This is a metadata index, not selected instructions. Use profile read file=<name> to inspect exact content and provenance; Home decides relevance and what belongs in a worker brief.",
    "Existing explicitly binding safety and standing instructions retain their force; partitioning or absence from this index does not revoke them. Inspect the relevant records before acting. Confirmation is evidence of confirmation, not permission to infer new binding rules.",
    ...names.slice(offset, offset + 16).map(file => {
      const items = read.items.filter(item => (item.file ?? "core") === file);
      const version = createHash("sha256").update(items.map(item => `${item.id}:${item.revisionId}`).join("\n")).digest("hex").slice(0, 12);
      return `- ${file}: ${items.filter(item => item.status === "active").length} active / ${items.length} total; version ${version}; profile read file=${file}`;
    }),
    ...(offset + 16 < names.length ? [`More files: profile read offset=${offset + 16}.`] : []),
    ...(read.unclassified ? [`Profile diagnostic: ${read.unclassified} notes need kind-label repair; their records remain in Knowledge.`] : []),
  ].join("\n");
}
