import { type SettingsManager } from "../pi/coding-agent.js";
import type { ManagedSubagents } from "./managed-subagents.js";
import type { ResourceDistribution } from "../../protocol/types.js";
import { boundCommandContent } from "../projection/projection.js";
import { redactCredentials } from "../../util/credential-redaction.js";
import { GatewayError } from "../../errors.js";

const SUBAGENT_PACKAGE = "pi-subagents";
const MAX_SUBAGENTS = 128;
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
  filePath?: string;
  systemPrompt?: string;
}

export interface SubagentCatalog {
  subagents: AvailableSubagent[];
  diagnostic?: string;
  invalidDefinitionCount?: number;
}

interface SubagentCatalogRequest {
  agentDir: string;
  cwd: string;
  settingsManager: SettingsManager;
  managedSubagents?: ManagedSubagents;
  loadDiscovery?: (packageRoot: string) => Promise<unknown>;
}

function isDiscoverySource(value: unknown): value is SubagentDiscoverySource {
  return typeof value === "string" && (DISCOVERY_SOURCES as readonly string[]).includes(value);
}

function subagentDistribution(source: SubagentDiscoverySource): ResourceDistribution {
  return source === "builtin" || source === "package" ? "external" : "local";
}

function collectSubagents(raw: unknown): AvailableSubagent[] {
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
  if (record.disabled === true) return undefined;
  const name = typeof record.name === "string" ? record.name : undefined;
  const source = isDiscoverySource(record.source) ? record.source : groupSource;
  if (!name || !source) return undefined;
  const description = typeof record.description === "string" ? record.description : undefined;
  const model = typeof record.model === "string" ? record.model : undefined;
  const thinking = typeof record.thinking === "string" ? record.thinking : undefined;
  const filePath = typeof record.filePath === "string" ? record.filePath : undefined;
  const systemPrompt = typeof record.systemPrompt === "string" ? record.systemPrompt : undefined;
  return {
    name,
    ...(description ? { description } : {}),
    ...(model ? { model } : {}),
    ...(thinking ? { thinking } : {}),
    source,
    distribution: subagentDistribution(source),
    ...(filePath ? { filePath } : {}),
    ...(systemPrompt !== undefined ? { systemPrompt } : {}),
  };
}

export function availableSubagentRow(subagent: AvailableSubagent): AvailableSubagent {
  return {
    name: subagent.name,
    ...(subagent.description ? { description: subagent.description } : {}),
    ...(subagent.model ? { model: subagent.model } : {}),
    ...(subagent.thinking ? { thinking: subagent.thinking } : {}),
    source: subagent.source,
    distribution: subagent.distribution,
  };
}

async function discoverAgents(discovery: unknown, cwd: string): Promise<unknown> {
  const exports = discovery as {
    discoverAgentsAll?: (cwd: string) => unknown;
    discoverAgents?: (cwd: string, scope: string) => unknown;
  };
  if (typeof exports.discoverAgentsAll === "function") return await exports.discoverAgentsAll(cwd);
  if (typeof exports.discoverAgents === "function") return await exports.discoverAgents(cwd, "both");
  throw new Error(`${SUBAGENT_PACKAGE} exposes no agent discovery`);
}

export async function loadSubagentCatalog(request: SubagentCatalogRequest): Promise<SubagentCatalog> {
  try {
    const managed = request.managedSubagents;
    const packageRoot = managed?.verify();
    if (!managed || !packageRoot) return unavailable(`managed ${SUBAGENT_PACKAGE} is not installed`);
    const discovery = await (request.loadDiscovery ? request.loadDiscovery(packageRoot) : managed.loadDiscovery());
    const raw = await discoverAgents(discovery, request.cwd);
    const reports = raw !== null && typeof raw === "object" ? (raw as { agentDiagnostics?: unknown }).agentDiagnostics : undefined;
    const invalid = Array.isArray(reports) ? reports.filter((report): report is { error: string } =>
      report !== null && typeof report === "object" && typeof report.error === "string" && report.error.length > 0) : [];
    return { subagents: collectSubagents(raw), ...(invalid.length ? {
      invalidDefinitionCount: invalid.length,
      diagnostic: boundedDiagnostic(`${invalid.length} invalid subagent definition(s): ${invalid[0]!.error}`),
    } : {}) };
  } catch (error) {
    return unavailable(error instanceof Error ? error.message : String(error));
  }
}

function unavailable(reason: string): SubagentCatalog {
  return { subagents: [], diagnostic: boundedDiagnostic(`subagent catalog unavailable: ${reason}`) };
}

function boundedDiagnostic(text: string): string {
  return text.length <= MAX_DIAGNOSTIC_CHARACTERS ? text : `${text.slice(0, MAX_DIAGNOSTIC_CHARACTERS - 1)}…`;
}

export interface SubagentDetail extends AvailableSubagent {
  content?: string;
  contentBytes?: number;
  contentTruncated?: boolean;
}

export function subagentDetail(subagents: readonly AvailableSubagent[], name: string): SubagentDetail {
  const subagent = subagents.find((candidate) => candidate.name === name);
  if (!subagent) throw new GatewayError("not_found", "That subagent is no longer available");
  return {
    ...availableSubagentRow(subagent),
    ...(subagent.systemPrompt !== undefined ? boundCommandContent(redactCredentials(subagent.systemPrompt)) : {}),
  };
}
