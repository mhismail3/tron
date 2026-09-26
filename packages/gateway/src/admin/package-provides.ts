import { basename, dirname, sep } from "node:path";
import type {
  Extension,
  ResolvedPaths,
  ResolvedResource,
  SettingsManager,
} from "@earendil-works/pi-coding-agent";
import type { PackageProvides } from "../protocol/types.js";
import {
  loadSubagentCatalog,
  type AvailableSubagent,
} from "../sessions/subagent-catalog.js";
import {
  loadSessionFreeExtensions,
  type SessionFreeExtensionLoad,
} from "./session-free-extensions.js";
import type { TrustService } from "./trust-service.js";

/** Per-kind cap on the names one installed package reports. `provides` is a
 * presentation summary; the flat `resources` inventory stays authoritative for
 * every resolved path. */
export const MAX_PROVIDES_NAMES_PER_KIND = 256;
const MAX_PROVIDES_DIAGNOSTIC_CHARACTERS = 512;
const SKILL_FILE_NAME = "SKILL.md";

/** One installed package as the package owner reports it: the configured source
 * and scope, whether a resource filter applies, and the installed root when the
 * package is present on disk. */
export interface InstalledPackage {
  source: string;
  scope: "user" | "project";
  filtered: boolean;
  installedPath?: string;
}

/** An installed-package row with the names it provides. */
export type PackageProvidesEntry = InstalledPackage & { provides: PackageProvides };

type ResourceKind = "skills" | "prompts" | "themes";

/** The name a resolved package resource presents under: a skill is the directory
 * holding its `SKILL.md` (or a root-level `.md` file's own name), a prompt and a
 * theme are their file names without the extension. Pi derives the same names
 * when it loads them. */
export function providesResourceName(kind: ResourceKind, path: string): string {
  const name = basename(path);
  if (kind === "skills") return name === SKILL_FILE_NAME ? basename(dirname(path)) : name.replace(/\.md$/, "");
  return kind === "prompts" ? name.replace(/\.md$/, "") : name.replace(/\.json$/, "");
}

function boundedNames(names: Iterable<string>): string[] {
  const unique = new Set<string>();
  for (const name of names) if (name) unique.add(name);
  return [...unique].sort().slice(0, MAX_PROVIDES_NAMES_PER_KIND);
}

/** Pi records an installed package's configured source and scope on each
 * resource and extension it contributes, so the resolution `packages.list`
 * already performs — and the extension load — pair with a package entry without
 * resolving anything a second time. */
function isPackageOwned(sourceInfo: { source: string; scope: string; origin: string }, pkg: InstalledPackage): boolean {
  return sourceInfo.origin === "package" && sourceInfo.source === pkg.source && sourceInfo.scope === pkg.scope;
}

/** Only resources the package filter left enabled are provided: a pattern that
 * turns a resource off means the install does not contribute it. */
function resourceNames(kind: ResourceKind, resources: ResolvedResource[], pkg: InstalledPackage): string[] {
  return boundedNames(resources
    .filter((resource) => resource.enabled && isPackageOwned(resource.metadata, pkg))
    .map((resource) => providesResourceName(kind, resource.path)));
}

function extensionNames(extensions: Extension[], pkg: InstalledPackage): Pick<PackageProvides, "tools" | "commands"> {
  const owned = extensions.filter((extension) => isPackageOwned(extension.sourceInfo, pkg));
  return {
    tools: boundedNames(owned.flatMap((extension) => [...extension.tools.keys()])),
    commands: boundedNames(owned.flatMap((extension) => [...extension.commands.keys()])),
  };
}

/** pi-subagents' own agents ship inside the pi-subagents package, and a package
 * may declare agent directories of its own, so the definition file's location
 * under the package's installed root is the attribution evidence. An agent
 * without a reported file is attributed to no package. */
function subagentNames(subagents: AvailableSubagent[], pkg: InstalledPackage): string[] {
  if (pkg.installedPath === undefined) return [];
  const prefix = pkg.installedPath.endsWith(sep) ? pkg.installedPath : `${pkg.installedPath}${sep}`;
  return boundedNames(subagents
    .filter((subagent) => subagent.filePath?.startsWith(prefix) === true)
    .map((subagent) => subagent.name));
}

export interface PackageProvidesInput {
  pkg: InstalledPackage;
  resources: ResolvedPaths;
  extensions: Extension[];
  subagents: AvailableSubagent[];
}

/** The `provides` object for one installed package: names only, every kind
 * capped, and empty when the package contributes nothing of that kind. */
export function packageProvides(input: PackageProvidesInput): PackageProvides {
  const { pkg, resources, extensions, subagents } = input;
  const registered = extensionNames(extensions, pkg);
  return {
    skills: resourceNames("skills", resources.skills, pkg),
    prompts: resourceNames("prompts", resources.prompts, pkg),
    themes: resourceNames("themes", resources.themes, pkg),
    subagents: subagentNames(subagents, pkg),
    tools: registered.tools,
    commands: registered.commands,
  };
}

export interface PackageProvidesRequest {
  agentDir: string;
  trust: TrustService;
  cwd: string;
  settingsManager: SettingsManager;
  packages: InstalledPackage[];
  resources: ResolvedPaths;
  /** Overrides the shared session-free extension load (used by tests). */
  loadExtensions?: (agentDir: string, trust: TrustService, cwd?: string) => Promise<SessionFreeExtensionLoad>;
  /** Overrides loading pi-subagents' own discovery module (used by tests). */
  loadDiscovery?: (packageRoot: string) => Promise<unknown>;
}

export interface PackageProvidesResult {
  entries: PackageProvidesEntry[];
  diagnostic?: string;
}

/** Builds every installed package's `provides` for `packages.list`, failing soft
 * per kind: failed extension loading or failed subagent discovery leaves the
 * kinds that did resolve in place and returns one bounded `providesDiagnostic`,
 * so the package read itself never fails because of `provides`. */
export async function loadPackageProvides(request: PackageProvidesRequest): Promise<PackageProvidesResult> {
  const diagnostics: string[] = [];
  let extensions: Extension[] = [];
  try {
    const loaded = await (request.loadExtensions ?? loadSessionFreeExtensions)(
      request.agentDir,
      request.trust,
      request.cwd,
    );
    extensions = loaded.extensions;
    if (loaded.errors.length > 0) {
      diagnostics.push(`${loaded.errors.length} extension(s) failed to load: ${loaded.errors[0]!.error}`);
    }
  } catch (error) {
    diagnostics.push(`tools and commands are unavailable: ${errorText(error)}`);
  }
  const catalog = await loadSubagentCatalog({
    agentDir: request.agentDir,
    cwd: request.cwd,
    settingsManager: request.settingsManager,
    ...(request.loadDiscovery ? { loadDiscovery: request.loadDiscovery } : {}),
  });
  if (catalog.diagnostic) diagnostics.push(catalog.diagnostic);
  return {
    entries: request.packages.map((pkg) => ({
      ...pkg,
      provides: packageProvides({ pkg, resources: request.resources, extensions, subagents: catalog.subagents }),
    })),
    ...(diagnostics.length > 0 ? { diagnostic: boundedDiagnostic(diagnostics.join("; ")) } : {}),
  };
}

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function boundedDiagnostic(value: string): string {
  return value.length <= MAX_PROVIDES_DIAGNOSTIC_CHARACTERS
    ? value
    : `${value.slice(0, MAX_PROVIDES_DIAGNOSTIC_CHARACTERS)}…`;
}
