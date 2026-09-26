import { createRequire } from "node:module";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { DefaultPackageManager, type SettingsManager } from "@earendil-works/pi-coding-agent";
import type { ResourceDistribution } from "../protocol/types.js";

/** The third-party package that owns subagent discovery. */
export const SUBAGENT_PACKAGE = "pi-subagents";
/** Presentation projection only: the available-subagent list is capped so an
 * unbounded agent directory cannot enlarge `session.resources`. */
export const MAX_SUBAGENTS = 128;
const MAX_DIAGNOSTIC_CHARACTERS = 512;
const DISCOVERY_SOURCES = ["builtin", "package", "user", "project"] as const;

export type SubagentDiscoverySource = (typeof DISCOVERY_SOURCES)[number];

export interface AvailableSubagent {
  name: string;
  description?: string;
  model?: string;
  thinking?: string;
  source: SubagentDiscoverySource;
  distribution: ResourceDistribution;
}

export interface SubagentCatalog {
  subagents: AvailableSubagent[];
  diagnostic?: string;
}

export interface SubagentCatalogRequest {
  agentDir: string;
  cwd: string;
  settingsManager: SettingsManager;
  /** Overrides loading pi-subagents' own discovery module (used by tests). */
  loadDiscovery?: (packageRoot: string) => Promise<unknown>;
}

function isDiscoverySource(value: unknown): value is SubagentDiscoverySource {
  return typeof value === "string" && (DISCOVERY_SOURCES as readonly string[]).includes(value);
}

/** builtin and package agents ship inside the pi-subagents package, so they are
 * External; user and project agents are Local. */
export function subagentDistribution(source: SubagentDiscoverySource): ResourceDistribution {
  return source === "builtin" || source === "package" ? "external" : "local";
}

/** Normalizes pi-subagents' discovery output into bounded presentation rows.
 * Grouped objects (`{ builtin: [...], user: [...] }`), a flat array, and a
 * `{ agents: [...] }` object are all admitted; unknown sources are dropped. A
 * duplicate name keeps the more specific scope (project > user > package >
 * builtin), matching the package's own merge precedence. */
export function collectSubagents(raw: unknown): AvailableSubagent[] {
  const groups: Array<{ source?: SubagentDiscoverySource; records: unknown[] }> = [];
  if (Array.isArray(raw)) {
    groups.push({ records: raw });
  } else if (raw !== null && typeof raw === "object") {
    const container = raw as Record<string, unknown>;
    for (const source of DISCOVERY_SOURCES) {
      if (Array.isArray(container[source])) groups.push({ source, records: container[source] });
    }
    if (Array.isArray(container.agents)) groups.push({ records: container.agents });
  }
  const byName = new Map<string, { entry: AvailableSubagent; rank: number }>();
  for (const group of groups) {
    for (const value of group.records) {
      const entry = projectSubagent(value, group.source);
      if (!entry) continue;
      const rank = DISCOVERY_SOURCES.indexOf(entry.source);
      const existing = byName.get(entry.name);
      if (!existing || existing.rank <= rank) byName.set(entry.name, { entry, rank });
    }
  }
  return [...byName.values()].map(({ entry }) => entry).slice(0, MAX_SUBAGENTS);
}

function projectSubagent(value: unknown, groupSource?: SubagentDiscoverySource): AvailableSubagent | undefined {
  if (value === null || typeof value !== "object") return undefined;
  const record = value as Record<string, unknown>;
  const name = typeof record.name === "string" ? record.name : undefined;
  const source = isDiscoverySource(record.source) ? record.source : groupSource;
  if (!name || !source) return undefined;
  const description = typeof record.description === "string" ? record.description : undefined;
  const model = typeof record.model === "string" ? record.model : undefined;
  const thinking = typeof record.thinking === "string" ? record.thinking : undefined;
  return {
    name,
    ...(description ? { description } : {}),
    ...(model ? { model } : {}),
    ...(thinking ? { thinking } : {}),
    source,
    distribution: subagentDistribution(source),
  };
}

/** Resolves the installed pi-subagents root from the packages the agent home's
 * settings (user first, then the current project's) configure; undefined when it
 * is not installed. Only the matching entry is resolved, so an unrelated broken
 * package cannot slow this read down. */
export function installedSubagentPackageRoot(settingsManager: SettingsManager, agentDir: string, cwd: string): string | undefined {
  const candidates: Array<{ source: string; scope: "user" | "project" }> = [
    ...settingsManager.getPackages().map((pkg) => ({ source: packageSourceString(pkg), scope: "user" as const })),
    ...projectPackages(settingsManager).map((pkg) => ({ source: packageSourceString(pkg), scope: "project" as const })),
  ];
  const match = candidates.find((candidate) => packageName(candidate.source) === SUBAGENT_PACKAGE);
  if (!match) return undefined;
  return new DefaultPackageManager({ cwd, agentDir, settingsManager }).getInstalledPath(match.source, match.scope);
}

/** Untrusted project settings are not loaded; project packages cannot apply. */
function projectPackages(settingsManager: SettingsManager): Array<string | { source: string }> {
  try {
    return settingsManager.getProjectSettings().packages ?? [];
  } catch {
    return [];
  }
}

function packageSourceString(source: string | { source: string }): string {
  return typeof source === "string" ? source : source.source;
}

function packageName(source: string): string {
  const withoutProtocol = source.replace(/^[a-z][a-z0-9+.-]*:/i, "");
  const withoutVersion = withoutProtocol.replace(/@[^/]*$/, "").replace(/\/+$/, "");
  return withoutVersion.split("/").pop() ?? "";
}

/** pi-subagents declares `jiti` but exposes no public discovery entry point, so
 * load its own `src/agents/agents.ts` through that declared dependency. The
 * imported module reads agent definitions and settings only; it spawns nothing. */
export async function loadPiSubagentsDiscovery(packageRoot: string): Promise<unknown> {
  const require = createRequire(join(packageRoot, "package.json"));
  const jitiEntry = require.resolve("jiti");
  const loaded = await import(pathToFileURL(jitiEntry).href) as {
    createJiti?: (base: string) => { import: (id: string) => Promise<unknown> };
    default?: { createJiti?: (base: string) => { import: (id: string) => Promise<unknown> } };
  };
  const createJiti = loaded.createJiti ?? loaded.default?.createJiti;
  if (typeof createJiti !== "function") throw new Error("jiti did not expose createJiti");
  return createJiti(import.meta.url).import(join(packageRoot, "src", "agents", "agents.ts"));
}

async function discoverAgents(module: unknown, cwd: string): Promise<unknown> {
  const discovery = module as {
    discoverAgentsAll?: (cwd: string) => unknown;
    discoverAgents?: (cwd: string, scope: string) => unknown;
  };
  if (typeof discovery.discoverAgentsAll === "function") return await discovery.discoverAgentsAll(cwd);
  if (typeof discovery.discoverAgents === "function") return await discovery.discoverAgents(cwd, "both");
  throw new Error(`${SUBAGENT_PACKAGE} exposes no agent discovery`);
}

/** Fail-soft discovery for `session.resources`. A missing package, a failed
 * import, or an unexpected export shape returns an empty list plus one bounded
 * diagnostic; it never rejects, so subagents cannot take down the response. */
export async function loadSubagentCatalog(request: SubagentCatalogRequest): Promise<SubagentCatalog> {
  try {
    const packageRoot = installedSubagentPackageRoot(request.settingsManager, request.agentDir, request.cwd);
    if (!packageRoot) return unavailable(`${SUBAGENT_PACKAGE} is not installed`);
    const module = await (request.loadDiscovery ?? loadPiSubagentsDiscovery)(packageRoot);
    return { subagents: collectSubagents(await discoverAgents(module, request.cwd)) };
  } catch (error) {
    return unavailable(error instanceof Error ? error.message : String(error));
  }
}

function unavailable(reason: string): SubagentCatalog {
  const bounded = reason.length <= MAX_DIAGNOSTIC_CHARACTERS ? reason : `${reason.slice(0, MAX_DIAGNOSTIC_CHARACTERS)}…`;
  return { subagents: [], diagnostic: `subagent catalog unavailable: ${bounded}` };
}
