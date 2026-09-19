import { realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { isAbsolute, join, relative, resolve, sep } from "node:path";
import type { Extension, ToolDefinition } from "@earendil-works/pi-coding-agent";
import type { ExtensionToolOrigin } from "../protocol/types.js";
import { attributedToolOwner } from "../extensions/owner-attribution.js";

/**
 * The delegated-work provider boundary.
 *
 * Tron projects an installed third-party delegated-work provider (currently
 * `pi-subagents`) without owning its execution: the provider keeps its own
 * lifecycle, child sessions, and terminal proof, while the Gateway admits only
 * observations it can prove belong to one installed provider. Every
 * provider-specific convention — the tool name, the artifact directory shape,
 * the lifecycle file names, and the identity used to authorize controls — lives
 * here so the session runtime depends on this narrow contract instead of
 * embedding package knowledge in its own owners.
 *
 * Nothing in this module grants authority by itself: callers must still prove
 * canonical tool/run ownership before projecting or controlling work.
 */

/** The provider tool whose results can own delegated work. */
export const DELEGATED_PROVIDER_TOOL_NAME = "subagent";

/** Fallback source label used when no installed owner can be resolved. */
export const DELEGATED_PROVIDER_SOURCE = "pi-subagents";

/** Lifecycle files the provider may publish inside one run directory. */
export const DELEGATED_ARTIFACT_FILES = [
  "status.json",
  "events.jsonl",
  "recovery-descriptor.json",
  "process-terminal.json",
] as const;

export type DelegatedArtifactFileName = (typeof DELEGATED_ARTIFACT_FILES)[number];

const DELEGATED_ARTIFACT_FILE_SET: ReadonlySet<string> = new Set(DELEGATED_ARTIFACT_FILES);

/** Provider package directory marker used only to recognize an installed owner. */
const PROVIDER_PATH_SEGMENT = /(?:^|[\\/])pi-subagents(?:[\\/]|$)/u;

function canonical(value: string): string {
  try {
    return realpathSync(value);
  } catch {
    return resolve(value);
  }
}

/**
 * Accepts only the provider's own run directory or one of its direct lifecycle
 * files, under either the provider's temporary root or the project-local
 * `.pi/subagents/async-subagent-runs` root. Lexical traversal is rejected before
 * canonicalization, and the canonical shape rejects symlinked escapes.
 */
export function delegatedArtifactPathAllowed(asyncPath: string, cwd: string): boolean {
  if (!isAbsolute(asyncPath)) return false;
  const lexicalParts = asyncPath.split(/[\\/]/u).filter(Boolean);
  if (lexicalParts.some((part) => part === "." || part === "..")) return false;
  const temporaryRoot = canonical(tmpdir());
  const projectRoot = join(canonical(cwd), ".pi", "subagents", "async-subagent-runs");
  const isAllowedShape = (value: string): boolean => {
    const temporaryParts = relative(temporaryRoot, value).split(/[\\/]/u).filter(Boolean);
    const temporaryRun = temporaryParts[0]?.startsWith("pi-subagents-")
      && temporaryParts[1] === "async-subagent-runs"
      && temporaryParts.length >= 3
      && temporaryParts.length <= 4
      && temporaryParts[2] !== ""
      && (temporaryParts.length === 3 || DELEGATED_ARTIFACT_FILE_SET.has(temporaryParts[3]!));
    if (temporaryRun) return true;

    const projectRelative = relative(projectRoot, value);
    if (projectRelative === "" || isAbsolute(projectRelative)
      || projectRelative === ".." || projectRelative.startsWith(`..${sep}`)) return false;
    const projectParts = projectRelative.split(/[\\/]/u).filter(Boolean);
    return projectParts.length >= 1
      && projectParts.length <= 2
      && projectParts[0] !== ""
      && (projectParts.length === 1 || DELEGATED_ARTIFACT_FILE_SET.has(projectParts[1]!));
  };
  const candidate = resolve(asyncPath);
  try {
    return isAllowedShape(realpathSync(candidate));
  } catch {
    return false;
  }
}

/**
 * Resolves the installed provider's own origin. Identity comes from the
 * finalized extension owner of its tool, never from a path containing the
 * package name in an unrelated location.
 */
export function delegatedProviderOrigin(extensions: readonly Extension[]): ExtensionToolOrigin {
  const extension = extensions.find((candidate) => {
    // Path evidence narrows the candidate, but only the finalized package
    // identity can authorize provider projection. A project extension under a
    // directory named pi-subagents must not impersonate the installed package.
    if (candidate.sourceInfo.source !== "npm:pi-subagents") return false;
    const paths = [candidate.path, candidate.resolvedPath, candidate.sourceInfo.path, candidate.sourceInfo.baseDir]
      .filter((value): value is string => typeof value === "string");
    return paths.some((value) => PROVIDER_PATH_SEGMENT.test(value));
  });
  if (extension) {
    const owner = attributedToolOwner(extension.tools.get(DELEGATED_PROVIDER_TOOL_NAME));
    if (owner) return { source: owner.source, owner };
  }
  return { source: DELEGATED_PROVIDER_SOURCE };
}

/** True only for the exact installed provider owner, never a same-named tool. */
export function isInstalledDelegatedTool(
  toolName: string,
  origin: ExtensionToolOrigin | undefined,
  installedOwnerId: string | undefined,
): boolean {
  if (toolName !== DELEGATED_PROVIDER_TOOL_NAME || !origin?.owner) return false;
  return installedOwnerId !== undefined && installedOwnerId === origin.owner.id;
}

/**
 * Returns the installed provider's controller definition for one tool name, but
 * only when the caller observed the exact installed owner for that name. Pi can
 * reload a package through its resolved local path, so the opaque owner
 * identity — not the mutable source label — is the authority boundary.
 */
export function trustedDelegatedController(input: {
  toolName: string;
  origin: ExtensionToolOrigin | undefined;
  installedOwnerId: string | undefined;
  definitionFor: (toolName: string) => ToolDefinition | undefined;
}): ToolDefinition | undefined {
  if (!isInstalledDelegatedTool(input.toolName, input.origin, input.installedOwnerId)) return undefined;
  return input.definitionFor(input.toolName);
}
