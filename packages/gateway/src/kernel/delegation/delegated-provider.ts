import { lstatSync, realpathSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { mkdir } from "node:fs/promises";
import { isAbsolute, join, relative, resolve, sep } from "node:path";
import type { Extension, ToolDefinition } from "../pi/coding-agent.js";
import { piHostPackageRoot } from "../pi/packages.js";
import type { ExtensionToolOrigin } from "../../protocol/types.js";
import { isManagedSubagentExtension, MANAGED_SUBAGENTS_VERSION } from "./managed-subagents.js";
import { attributedToolOwner } from "../host/extension-registration.js";
import { tronHomePath } from "../../foundation/tron-home-layout.js";

export const DELEGATED_PROVIDER_TOOL_NAME = "subagent";

export const DELEGATED_SUPERVISOR_TOOL_NAME = "subagent_supervisor";

const DELEGATED_PROVIDER_SOURCE = "pi-subagents";

const DELEGATED_ARTIFACT_FILES = [
  "status.json",
  "events.jsonl",
  "recovery-descriptor.json",
  "process-terminal.json",
] as const;

export const DELEGATED_PROVIDER_ROOT_ENV = "PI_SUBAGENTS_TEMP_ROOT";

const PI_HOST_PACKAGE_ROOT = piHostPackageRoot();

export function delegatedArtifactRoot(tronHome: string): string {
  return tronHomePath(resolve(tronHome), "state/subagents");
}

export function delegatedProviderEnvironment(root: string, environment: NodeJS.ProcessEnv = process.env): void {
  const canonicalRoot = resolve(root);
  if (!isAbsolute(canonicalRoot) || canonicalRoot === sep) throw new Error("delegated artifact root must be absolute");
  environment[DELEGATED_PROVIDER_ROOT_ENV] = canonicalRoot;
  environment.PI_SUBAGENTS_PI_CODING_AGENT_PACKAGE_ROOT = PI_HOST_PACKAGE_ROOT;
}

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

function canonical(value: string): string {
  try {
    return realpathSync(value);
  } catch {
    return resolve(value);
  }
}

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

export function delegatedProviderOrigin(extensions: readonly Extension[]): ExtensionToolOrigin {
  const extension = extensions.find(isManagedSubagentExtension);
  if (extension) {
    const owner = attributedToolOwner(extension.tools.get(DELEGATED_PROVIDER_TOOL_NAME));
    if (owner) return { source: owner.source, owner };
  }
  return { source: DELEGATED_PROVIDER_SOURCE };
}

const REVIEWED_HOME_TASK_PROVIDER_VERSION = "0.76.1-tron.16";

export function isVerifiedDelegatedProviderTool(extensions: readonly Extension[], toolName: string): boolean {
  return MANAGED_SUBAGENTS_VERSION === REVIEWED_HOME_TASK_PROVIDER_VERSION
    && extensions.some(candidate => isManagedSubagentExtension(candidate) && candidate.tools.has(toolName));
}

export function isInstalledDelegatedTool(
  toolName: string,
  origin: ExtensionToolOrigin | undefined,
  installedOwnerId: string | undefined,
): boolean {
  if (toolName !== DELEGATED_PROVIDER_TOOL_NAME || !origin?.owner) return false;
  return installedOwnerId !== undefined && installedOwnerId === origin.owner.id;
}

export function trustedDelegatedController(input: {
  toolName: string;
  origin: ExtensionToolOrigin | undefined;
  installedOwnerId: string | undefined;
  definitionFor: (toolName: string) => ToolDefinition | undefined;
}): ToolDefinition | undefined {
  if (!isInstalledDelegatedTool(input.toolName, input.origin, input.installedOwnerId)) return undefined;
  return input.definitionFor(input.toolName);
}
