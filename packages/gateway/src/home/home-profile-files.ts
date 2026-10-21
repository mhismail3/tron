import { GatewayError } from "../errors.js";
import type { HomeProfileItem, HomeProfileRead } from "./home-profile.js";

/** Files are partitions of canonical Knowledge notes, not second copies of their text. */
export const PROFILE_FILE_TAG = "home-file-";
export const PROFILE_FILE_CAPS = { core: 4_096, home: 4_096, scope: 4_096 } as const;
export const PROFILE_SCOPE_LIMIT = 16;
export const HOME_PROFILE_HEADROOM_BYTES = PROFILE_FILE_CAPS.core + PROFILE_FILE_CAPS.home + PROFILE_SCOPE_LIMIT * 150 + 1_024;
export type ProfileFile = "core" | "home" | `scopes/${string}`;
export function validProfileFile(value: string): value is ProfileFile {
  return value === "core" || value === "home" || /^scopes\/[a-z][a-z0-9-]{0,47}$/.test(value);
}
export function profileFile(tags: readonly string[] = []): ProfileFile | undefined {
  const files = tags.filter(tag => tag.startsWith(PROFILE_FILE_TAG)).map(tag => tag.slice(PROFILE_FILE_TAG.length).replace(/^scopes-/, "scopes/"));
  if (!files.length) return undefined; // The real persisted consumer: a pre-migration note.
  if (files.length !== 1 || !validProfileFile(files[0]!)) throw new GatewayError("invalid_request", "Profile note has corrupt file labels");
  return files[0]!;
}
export function profileFileTags(tags: readonly string[] | undefined, file?: ProfileFile): string[] {
  return [...(tags ?? []).filter(tag => !tag.startsWith(PROFILE_FILE_TAG)), ...(file ? [PROFILE_FILE_TAG + file.replace("/", "-")] : [])];
}
export function profileConfirmationTags(tags: readonly string[], date: string | null): string[] {
  return [...tags.filter(tag => !tag.startsWith("home-confirmed-")), ...(date ? [`home-confirmed-${date}`] : [])];
}
export function profileFileCap(file: ProfileFile): number {
  return file === "core" ? PROFILE_FILE_CAPS.core : file === "home" ? PROFILE_FILE_CAPS.home : PROFILE_FILE_CAPS.scope;
}
export function profileRuleLine(item: HomeProfileItem): string {
  return `- note ${item.id} (${item.kind}, ${item.confirmed ? "confirmed" : "inferred"}): ${item.text}`;
}
export function profileFileBytes(items: readonly HomeProfileItem[], file: ProfileFile): number {
  return items.filter(item => item.status === "active" && (item.file ?? "core") === file)
    .reduce((sum, item) => sum + Buffer.byteLength(profileRuleLine(item) + "\n"), 0);
}
export function renderProfileFiles(read: HomeProfileRead, scopes?: readonly string[]): { text: string; notes: number; diagnostics: string[]; ids: string[] } {
  const active = read.items.filter(item => item.status === "active");
  const files = new Set(active.map(item => item.file ?? "core"));
  const selected = new Set<ProfileFile>(scopes === undefined ? ["core", "home"] : ["core"]);
  const diagnostics = [...read.diagnostics];
  for (const scope of scopes ?? []) {
    const file = `scopes/${scope}`;
    if (!validProfileFile(file) || !files.has(file)) diagnostics.push(`Profile diagnostic: ${file} is unknown or missing; core remains applied.`);
    else selected.add(file);
  }
  for (const file of selected) {
    const bytes = profileFileBytes(active, file);
    const cap = profileFileCap(file);
    if (bytes > cap) diagnostics.push(`Profile diagnostic: ${file} is ${bytes} bytes, over its ${cap}-byte cap. All accepted rules remain applied; shorten or reorganize this file before adding to it.`);
  }
  // Specificity first, confirmed first within a file. Rules are never silently deduplicated.
  const order = (item: HomeProfileItem) => item.file?.startsWith("scopes/") ? 0 : item.file === "home" ? 1 : 2;
  const applied = active.filter(item => selected.has(item.file ?? "core"))
    .sort((a, b) => order(a) - order(b) || Number(b.confirmed) - Number(a.confirmed));
  const index = [...files].filter(file => file.startsWith("scopes/")).sort()
    .map(file => `- ${file}: select for ${file.slice(7)} work; read with profile read file=${file}.`);
  const text = [scopes === undefined ? "## Learned profile" : "## Preferences applied",
    "Scope > home > core; confirmed beats inferred. Conflicts require review, never silently discard a rule.",
    ...diagnostics, ...applied.map(profileRuleLine),
    ...(scopes === undefined ? ["### Scope index", ...(index.length ? index : ["No scoped files yet."])] : []),
    ...(read.unclassified ? [`Profile diagnostic: ${read.unclassified} note(s) without exactly one kind label require repair.`] : []),
  ].join("\n");
  return { text, notes: applied.length, diagnostics, ids: applied.map(item => item.id) };
}
