import { GatewayError } from "../errors.js";
import type { JsonValue, TronModuleSummary } from "../protocol/types.js";
import { redactCredentials } from "../util/credential-redaction.js";
import type { HookResources } from "./hook-resources.js";
import type { McpAdminService } from "./mcp-admin-service.js";
import type { PackageService } from "./package-service.js";

function sanitize(value: JsonValue): JsonValue {
  if (typeof value === "string") return redactCredentials(value);
  if (Array.isArray(value)) return value.map(sanitize);
  if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, sanitize(item)]));
  return value;
}

function section(items: readonly JsonValue[], limit: number) {
  const retained: JsonValue[] = [];
  let bytes = 256;
  for (const item of items.slice(0, limit)) {
    const safe = sanitize(item);
    bytes += Buffer.byteLength(JSON.stringify(safe)) + 1;
    if (bytes > 12 * 1024) break;
    retained.push(safe);
  }
  return { items: retained, total: items.length, omitted: items.length - retained.length };
}

export class SettingsInventory {
  constructor(private readonly hooks: HookResources, private readonly packages: PackageService, private readonly mcp: McpAdminService) {}

  async read(cwd: string, modules: readonly TronModuleSummary[], limit = 50): Promise<JsonValue> {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 200) throw new GatewayError("invalid_request", "Inventory limit must be between 1 and 200");
    const [hooks, packages, mcp] = await Promise.all([this.hooks.list(cwd), this.packages.list(cwd), this.mcp.list({ scope: "global" })]);
    const events = new Map<string, Set<string>>();
    const extensions = hooks.extensions.map(row => {
      const handlers = row.handlers as Array<{ event: string; count: number }>;
      for (const handler of handlers) {
        const owners = events.get(handler.event) ?? new Set<string>();
        owners.add(row.name as string);
        events.set(handler.event, owners);
      }
      return { name: row.name, source: row.source, scope: row.scope, path: row.path, handlers } as JsonValue;
    });
    return {
      hooks: {
        byExtension: section(extensions, limit),
        byEvent: section([...events].sort(([a], [b]) => a.localeCompare(b)).map(([event, owners]) => ({ event, extensions: [...owners].sort() })), limit),
        diagnostics: hooks.hookInventory,
      },
      packages: section(packages.packages.map(row => ({ source: row.source, scope: row.scope, ...(row.installedPath ? { installedPath: row.installedPath } : {}), resourceCounts: Object.fromEntries(Object.entries(row.provides).map(([kind, names]) => [kind, names.length])) })), limit),
      modules: section(modules.map(row => ({ name: row.name, purpose: row.purpose, tools: row.tools, commands: row.commands })), limit),
      mcp: section(mcp.servers.map(row => ({ name: row.name, state: row.state, scope: row.scope, enabled: row.enabled, exposure: row.exposure, transport: row.transport })), limit),
    } as JsonValue;
  }
}
