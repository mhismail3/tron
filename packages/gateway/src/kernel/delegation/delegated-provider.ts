import { lstatSync, realpathSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { mkdir } from "node:fs/promises";
import { isAbsolute, join, resolve, sep } from "node:path";
import type { Extension, ToolDefinition } from "../pi/coding-agent.js";
import { piHostPackageRoot } from "../pi/packages.js";
import type { ExtensionToolOrigin } from "../../protocol/types.js";
import { isManagedSubagentExtension, MANAGED_SUBAGENTS_VERSION } from "./managed-subagents.js";
import { attributedToolOwner } from "../host/extension-registration.js";
import { tronHomePath } from "../../foundation/tron-home-layout.js";
import { core as pathShape, type Roots } from "../../core/security/path-shape/facade.js";

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

const ARTIFACT_NAMES: readonly string[] = [...DELEGATED_ARTIFACT_FILES, "async-subagent-runs"];

function canonical(value: string): string {
  try {
    return realpathSync(value);
  } catch {
    return resolve(value);
  }
}

function artifactShapeAllowed(physical: string, cwd: string, ownedRoot: string | undefined): boolean {
  const tokens = new Map(ARTIFACT_NAMES.map((name, index) => [name, index]));
  const token = (name: string): number => tokens.get(name) ?? tokens.set(name, tokens.size).size - 1;
  const components = (path: string) => path.split(sep).filter(Boolean);
  const root = (path: string) => components(path).map(token);
  const roots: Roots = ownedRoot === undefined
    ? { $: "Shared", temporary: root(canonical(tmpdir())), project: root(join(canonical(cwd), ".pi", "subagents", "async-subagent-runs")) }
    : { $: "Owned", runs: root(join(ownedRoot, "async-subagent-runs")) };
  return pathShape.ArtifactAllowed(roots, components(physical).map(name => ({
    name: token(name),
    pieces: name.split("\\").filter(Boolean).map(piece => ({ name: token(piece), scoped: piece.startsWith("pi-subagents-") })),
  })));
}

export function delegatedArtifactPathAllowed(asyncPath: string, cwd: string, admittedRoot?: string): boolean {
  if (!isAbsolute(asyncPath)) return false;
  const lexicalParts = asyncPath.split(/[\\/]/u).filter(Boolean);
  if (lexicalParts.some((part) => part === "." || part === "..")) return false;
  const ownedRoot = admittedRoot === undefined ? undefined : canonical(admittedRoot);
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
    return artifactShapeAllowed(physical, cwd, ownedRoot);
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

const REVIEWED_HOME_TASK_PROVIDER_VERSION = "0.76.1-tron.19";

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
