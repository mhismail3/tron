import { lstatSync, readFileSync, realpathSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { mkdir } from "node:fs/promises";
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

/** Control receipts reference an existing run; they never own its lifecycle. */
export const DELEGATED_SUPERVISOR_TOOL_NAME = "subagent_supervisor";

/** Fallback source label used when no installed owner can be resolved. */
export const DELEGATED_PROVIDER_SOURCE = "pi-subagents";

/** Lifecycle files the provider may publish inside one run directory. */
export const DELEGATED_ARTIFACT_FILES = [
  "status.json",
  "events.jsonl",
  "recovery-descriptor.json",
  "process-terminal.json",
] as const;

/** One Gateway-admitted provider root per resolved Tron home. */
/** pi-subagents 0.59.0 reads this before deriving async/results/chain roots. */
export const DELEGATED_PROVIDER_ROOT_ENV = "PI_SUBAGENTS_TEMP_ROOT";

export function delegatedArtifactRoot(tronHome: string): string {
  return join(resolve(tronHome), "internal", "subagents");
}

/**
 * Propagates the provider's supported root contract to every child launch.
 * The installed extension remains provider-owned; this is intentionally an
 * environment contract rather than a settings or source rewrite.
 */
export function delegatedProviderEnvironment(root: string, environment: NodeJS.ProcessEnv = process.env): void {
  const canonicalRoot = resolve(root);
  if (!isAbsolute(canonicalRoot) || canonicalRoot === sep) throw new Error("delegated artifact root must be absolute");
  environment[DELEGATED_PROVIDER_ROOT_ENV] = canonicalRoot;
}

/** Prepare the admission root before the provider can publish a run. */
function rejectSymlinkPath(path: string): void {
  const canonicalPath = resolve(path);
  try {
    if (lstatSync(canonicalPath).isSymbolicLink()) throw new Error("delegated artifact path cannot contain symlinks");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }
}

export async function ensureDelegatedArtifactRoot(root: string): Promise<void> {
  const canonicalRoot = resolve(root);
  rejectSymlinkPath(canonicalRoot);
  await mkdir(canonicalRoot, { recursive: true, mode: 0o700 });
  rejectSymlinkPath(canonicalRoot);
  const owner = process.getuid?.();
  const metadata = statSync(canonicalRoot);
  if (!metadata.isDirectory() || owner !== undefined && metadata.uid !== owner || (metadata.mode & 0o077) !== 0) {
    throw new Error("delegated artifact root is not a private owner directory");
  }
}

const DELEGATED_ARTIFACT_FILE_SET: ReadonlySet<string> = new Set(DELEGATED_ARTIFACT_FILES);

/** Provider package directory marker used only to recognize an installed owner. */
const PROVIDER_PATH_SEGMENT = /(?:^|[\\/])pi-subagents(?:[\\/]|$)/u;

/** Pi keeps the configured npm spec in SourceInfo.source; derive its package name only. */
function isProviderNpmSource(source: string): boolean {
  if (!source.startsWith("npm:") || source.trim() !== source) return false;
  const match = /^(@?[^@]+(?:\/[^@]+)?)(?:@(.+))?$/u.exec(source.slice("npm:".length));
  if (match?.[1] !== "pi-subagents") return false;
  const specifier = match[2];
  if (specifier?.startsWith("@") || (specifier !== undefined && /[\0\r\n]/u.test(specifier))) return false;
  // Reject npm aliases and local directories; only explicit absolute tarballs
  // are an accepted local source for this installed provider.
  if (specifier?.startsWith("npm:")) return false;
  if (specifier?.startsWith("file:")) {
    const tarballPath = specifier.slice("file:".length);
    return isAbsolute(tarballPath) && /\.tgz$/iu.test(tarballPath);
  }
  return specifier === undefined || !specifier.includes("/") && !specifier.includes("\\");
}

function hasProviderPackageManifest(extension: Extension): boolean {
  const baseDir = extension.sourceInfo.baseDir;
  if (!baseDir || !PROVIDER_PATH_SEGMENT.test(baseDir)) return false;
  try {
    const manifest = JSON.parse(readFileSync(join(baseDir, "package.json"), "utf8")) as { name?: unknown };
    return manifest.name === "pi-subagents";
  } catch {
    return false;
  }
}

function canonical(value: string): string {
  try {
    return realpathSync(value);
  } catch {
    return resolve(value);
  }
}

/**
 * Accepts only the provider's own run directory or one of its direct lifecycle
 * files under the explicitly admitted Tron-home root. The optional legacy roots
 * are retained only for isolated pre-cutover callers; production passes the
 * resolved root and therefore has no dual writable authority. Lexical traversal
 * is rejected before canonicalization, and the canonical shape rejects symlinked
 * escapes.
 */
export function delegatedArtifactPathAllowed(asyncPath: string, cwd: string, admittedRoot?: string): boolean {
  if (!isAbsolute(asyncPath)) return false;
  const lexicalParts = asyncPath.split(/[\\/]/u).filter(Boolean);
  if (lexicalParts.some((part) => part === "." || part === "..")) return false;
  const temporaryRoot = canonical(tmpdir());
  const projectRoot = join(canonical(cwd), ".pi", "subagents", "async-subagent-runs");
  const ownedRoot = admittedRoot === undefined ? undefined : canonical(admittedRoot);
  const isAllowedShape = (value: string): boolean => {
    if (ownedRoot !== undefined) {
      const runsRoot = join(ownedRoot, "async-subagent-runs");
      const relativeToRuns = relative(runsRoot, value);
      if (relativeToRuns !== "" && !isAbsolute(relativeToRuns)
        && relativeToRuns !== ".." && !relativeToRuns.startsWith(`..${sep}`)) {
        const parts = relativeToRuns.split(/[\\/]/u).filter(Boolean);
        if (parts.length >= 1 && parts.length <= 2 && parts[0] !== ""
          && (parts.length === 1 || DELEGATED_ARTIFACT_FILE_SET.has(parts[1]!))) return true;
      }
      return false;
    }
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
    if (ownedRoot !== undefined) rejectSymlinkPath(ownedRoot);
    rejectSymlinkPath(candidate);
    const physical = realpathSync(candidate);
    if (ownedRoot !== undefined) {
      const rootStat = statSync(ownedRoot);
      const owner = process.getuid?.();
      if (!rootStat.isDirectory() || owner !== undefined && rootStat.uid !== owner || (rootStat.mode & 0o077) !== 0) return false;
    }
    return isAllowedShape(physical);
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
    // Path evidence narrows the candidate, but only finalized package identity
    // can authorize projection; local extensions cannot impersonate this npm owner.
    if (candidate.sourceInfo.origin !== "package"
      || !isProviderNpmSource(candidate.sourceInfo.source)
      || !hasProviderPackageManifest(candidate)) return false;
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
