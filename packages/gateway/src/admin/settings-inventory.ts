import type { SettingsInventory, SettingsInventorySource } from "../kernel/settings/tool-contract.js";
import type { TrustService } from "../kernel/resources/trust-service.js";
import type { ModuleHost } from "../kernel/host/module-host.js";
import { tronModuleSummaries } from "../extensions/tron-modules.js";
import { decodePackageInventory } from "../protocol/types.js";
import { redactCredentials, redactCredentialUrls } from "../util/credential-redaction.js";
import type { HookResources } from "./hook-resources.js";
import type { PackageService } from "./package-service.js";
import type { McpAdminService, McpListing } from "./mcp-admin-service.js";

const LIMIT = 64;

const text = (value: string): string => redactCredentials(redactCredentialUrls(value));
const bounded = <T>(items: readonly T[]): T[] => items.slice(0, LIMIT);

export class SettingsInventoryReader implements SettingsInventorySource {
  constructor(
    private readonly hooks: HookResources,
    private readonly packages: PackageService,
    private readonly mcp: McpAdminService,
    private readonly trust: TrustService,
    private readonly modules: ModuleHost,
  ) {}

  async read(cwd: string): Promise<SettingsInventory> {
    const resolved = await this.trust.requireResolved(cwd);
    const [hookList, packageList, globalMcp, projectMcp] = await Promise.all([
      this.hooks.list(cwd),
      this.packages.list(cwd),
      this.mcp.list({ scope: "global" }),
      resolved.trusted ? this.mcp.list({ scope: "project", cwd: resolved.projectDir, trusted: true }) : undefined,
    ]);
    return {
      hooks: this.hookInventory(hookList),
      packages: bounded(decodePackageInventory(packageList).packages).map(pkg => ({
        source: text(pkg.source), scope: pkg.scope, filtered: pkg.filtered,
        ...(pkg.provides ? { provides: {
          skills: bounded(pkg.provides.skills), prompts: bounded(pkg.provides.prompts), themes: bounded(pkg.provides.themes),
          subagents: bounded(pkg.provides.subagents), tools: bounded(pkg.provides.tools), commands: bounded(pkg.provides.commands),
        } } : {}),
        ...(pkg.conflict ? { conflict: text(`${pkg.conflict.code}: ${pkg.conflict.message}`) } : {}),
        ...(pkg.nodeRequirement ? { nodeRequirement: pkg.nodeRequirement.status } : {}),
      })),
      modules: bounded(tronModuleSummaries(this.modules)).map(module => ({ name: module.name, purpose: module.purpose, tools: module.tools, commands: module.commands })),
      mcp: this.mcpStatus(projectMcp ? [globalMcp, projectMcp] : [globalMcp]),
    };
  }

  private hookInventory(list: Awaited<ReturnType<HookResources["list"]>>): SettingsInventory["hooks"] {
    const events = new Map<string, { count: number; extensions: string[] }>();
    for (const row of list.extensions) {
      for (const handler of row.handlers) {
        const entry = events.get(handler.event) ?? { count: 0, extensions: [] };
        entry.count += handler.count;
        entry.extensions.push(row.name);
        events.set(handler.event, entry);
      }
    }
    return {
      extensions: bounded(list.extensions).map(row => ({
        name: text(row.name), scope: row.scope, source: text(row.source), handlers: bounded(row.handlers),
      })),
      events: bounded([...events]).map(([event, entry]) => ({ event: text(event), count: entry.count, extensions: bounded(entry.extensions).map(text) })),
      loadErrors: list.extensionLoadErrors.length,
    };
  }

  private mcpStatus(listings: McpListing[]): SettingsInventory["mcp"] {
    const servers = listings.flatMap(listing => listing.servers);
    return {
      servers: bounded(servers).map(server => ({
        name: server.name, scope: server.scope, state: server.state, enabled: server.enabled, exposure: server.exposure,
        transport: text(server.transport), tools: bounded(server.tools).map(text),
        ...(server.error ? { error: text(server.error) } : {}),
      })),
      errors: listings.reduce((sum, listing) => sum + listing.errors, 0),
    };
  }
}
