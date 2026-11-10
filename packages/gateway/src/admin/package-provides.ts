import { isManagedSubagentExtension, isUserSubagentsPackage, IGNORED_SUBAGENTS_MESSAGE, MANAGED_SUBAGENTS_SOURCE, type ManagedSubagents } from "../kernel/delegation/managed-subagents.js";
import { readFile, stat } from "node:fs/promises";
import { basename, dirname, join, sep } from "node:path";
import semver from "semver";
import type {
  Extension,
  ResolvedPaths,
  ResolvedResource,
  SettingsManager,
} from "../kernel/pi/coding-agent.js";
import type { PackageProvides, PackageConflict, PackageNodeRequirement } from "../protocol/types.js";
import {
  loadSubagentCatalog,
  type AvailableSubagent,
} from "../kernel/delegation/subagent-catalog.js";
import {
  loadSessionFreeExtensions,
  type SessionFreeExtensionLoad,
} from "./session-free-extensions.js";
import type { TrustService } from "../kernel/resources/trust-service.js";

const MAX_PROVIDES_NAMES_PER_KIND = 256;
const MAX_PROVIDES_DIAGNOSTIC_CHARACTERS = 512;
const SKILL_FILE_NAME = "SKILL.md";
const MAX_PACKAGE_MANIFEST_BYTES = 1_024 * 1_024;
const MAX_NODE_RANGE_CHARACTERS = 128;

export interface InstalledPackage {
  source: string;
  scope: "user" | "project";
  filtered: boolean;
  installedPath?: string;
}

type PackageProvidesEntry = InstalledPackage & {
  provides: PackageProvides;
  conflict?: PackageConflict;
  nodeRequirement?: PackageNodeRequirement;
};

async function packageNodeRequirement(
  installedPath: string | undefined,
  runtime: string = process.versions.node,
): Promise<PackageNodeRequirement | undefined> {
  if (installedPath === undefined) return undefined;
  const manifestPath = join(installedPath, "package.json");
  let manifest: unknown;
  try {
    if ((await stat(manifestPath)).size > MAX_PACKAGE_MANIFEST_BYTES) return undefined;
    manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  } catch { return undefined; }
  const engines = (manifest as { engines?: unknown } | null)?.engines;
  const declared = engines !== null && typeof engines === "object" ? (engines as { node?: unknown }).node : undefined;
  if (declared === undefined) return undefined;
  if (typeof declared !== "string" || semver.validRange(declared) === null) {
    return { range: boundedRange(typeof declared === "string" ? declared : JSON.stringify(declared) ?? ""), runtime, status: "invalid" };
  }
  return {
    range: boundedRange(declared),
    runtime,
    status: semver.satisfies(runtime, declared, { includePrerelease: true }) ? "satisfied" : "unsatisfied",
  };
}

function boundedRange(range: string): string {
  return range.length <= MAX_NODE_RANGE_CHARACTERS ? range : `${range.slice(0, MAX_NODE_RANGE_CHARACTERS - 1)}…`;
}

type ResourceKind = "skills" | "prompts" | "themes";

function providesResourceName(kind: ResourceKind, path: string): string {
  const name = basename(path);
  if (kind === "skills") return name === SKILL_FILE_NAME ? basename(dirname(path)) : name.replace(/\.md$/, "");
  return kind === "prompts" ? name.replace(/\.md$/, "") : name.replace(/\.json$/, "");
}

function boundedNames(names: Iterable<string>): string[] {
  const unique = new Set<string>();
  for (const name of names) if (name) unique.add(name);
  return [...unique].sort().slice(0, MAX_PROVIDES_NAMES_PER_KIND);
}

function isPackageOwned(sourceInfo: { source: string; scope: string; origin: string }, pkg: InstalledPackage): boolean {
  return sourceInfo.source === pkg.source && (pkg.source === MANAGED_SUBAGENTS_SOURCE || sourceInfo.origin === "package" && sourceInfo.scope === pkg.scope);
}

function resourceNames(kind: ResourceKind, resources: ResolvedResource[], pkg: InstalledPackage): string[] {
  return boundedNames(resources
    .filter((resource) => resource.enabled && isPackageOwned(resource.metadata, pkg))
    .map((resource) => providesResourceName(kind, resource.path)));
}

function extensionNames(extensions: Extension[], pkg: InstalledPackage): Pick<PackageProvides, "tools" | "commands"> {
  const owned = extensions.filter((extension) => isPackageOwned(extension.sourceInfo, pkg)
    || pkg.source === MANAGED_SUBAGENTS_SOURCE && isManagedSubagentExtension(extension));
  return {
    tools: boundedNames(owned.flatMap((extension) => [...extension.tools.keys()])),
    commands: boundedNames(owned.flatMap((extension) => [...extension.commands.keys()])),
  };
}

function subagentNames(subagents: AvailableSubagent[], pkg: InstalledPackage): string[] {
  if (pkg.installedPath === undefined) return [];
  const prefix = pkg.installedPath.endsWith(sep) ? pkg.installedPath : `${pkg.installedPath}${sep}`;
  return boundedNames(subagents
    .filter((subagent) => subagent.filePath?.startsWith(prefix) === true)
    .map((subagent) => subagent.name));
}

interface PackageProvidesInput {
  pkg: InstalledPackage;
  resources: ResolvedPaths;
  extensions: Extension[];
  subagents: AvailableSubagent[];
}

function packageProvides(input: PackageProvidesInput): PackageProvides {
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

interface PackageProvidesRequest {
  agentDir: string;
  managedSubagents?: ManagedSubagents;
  trust: TrustService;
  cwd: string;
  settingsManager: SettingsManager;
  packages: InstalledPackage[];
  resources: ResolvedPaths;
  loadExtensions?: (agentDir: string, trust: TrustService, cwd?: string) => Promise<SessionFreeExtensionLoad>;
  loadDiscovery?: (packageRoot: string) => Promise<unknown>;
}

interface PackageProvidesResult {
  resources: ResolvedPaths;
  entries: PackageProvidesEntry[];
  diagnostic?: string;
}

export async function loadPackageProvides(request: PackageProvidesRequest): Promise<PackageProvidesResult> {
  const diagnostics: string[] = [];
  let extensions: Extension[] = [];
  let resources = request.resources;
  if (request.managedSubagents) {
    try {
      const managed = await request.managedSubagents.resources();
      resources = { extensions: [...resources.extensions, ...managed.extensions], skills: [...resources.skills, ...managed.skills],
        prompts: [...resources.prompts, ...managed.prompts], themes: resources.themes };
    } catch (error) { diagnostics.push(`managed resources are unavailable: ${errorText(error)}`); }
  }
  try {
    const loaded = await (request.loadExtensions ?? loadSessionFreeExtensions)(
      request.agentDir,
      request.trust,
      request.cwd,
      request.managedSubagents,
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
    ...(request.managedSubagents ? { managedSubagents: request.managedSubagents } : {}),
    ...(request.loadDiscovery ? { loadDiscovery: request.loadDiscovery } : {}),
  });
  if (catalog.diagnostic) diagnostics.push(catalog.diagnostic);
  return {
    resources,
    entries: await Promise.all([...request.packages, ...managedPackage(request)].map(async (pkg) => {
      const nodeRequirement = await packageNodeRequirement(pkg.installedPath);
      return {
        ...pkg,
        ...(request.managedSubagents && isUserSubagentsPackage(pkg.source) ? {
          conflict: { code: "managed-provider" as const, message: IGNORED_SUBAGENTS_MESSAGE },
          provides: { skills: [], prompts: [], themes: [], subagents: [], tools: [], commands: [] },
        } : { provides: packageProvides({ pkg, resources, extensions, subagents: catalog.subagents }) }),
        ...(nodeRequirement ? { nodeRequirement } : {}),
      };
    })),
    ...(diagnostics.length > 0 ? { diagnostic: boundedDiagnostic(diagnostics.join("; ")) } : {}),
  };
}

function managedPackage(request: PackageProvidesRequest): InstalledPackage[] {
  try {
    const installedPath = request.managedSubagents?.verify();
    return installedPath ? [{ source: MANAGED_SUBAGENTS_SOURCE, scope: "user", filtered: false, installedPath }] : [];
  } catch { return []; }
}

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function boundedDiagnostic(value: string): string {
  return value.length <= MAX_PROVIDES_DIAGNOSTIC_CHARACTERS
    ? value
    : `${value.slice(0, MAX_PROVIDES_DIAGNOSTIC_CHARACTERS)}…`;
}
