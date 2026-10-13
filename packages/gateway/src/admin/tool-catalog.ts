import type { ManagedSubagents } from "../sessions/managed-subagents.js";
import type { GatewayWorkRegistry } from "../sessions/gateway-work-registry.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { loadSessionFreeExtensions } from "./session-free-extensions.js";
import type { ToolCatalogEntry } from "./settings-model.js";
import { PI_BUILTIN_TOOL_NAMES } from "./settings-types.js";
import type { TrustService } from "./trust-service.js";

/** The tools a Mac or Project `defaultTools` selection can name, without a session.
 *
 * pi starts a chat with its selected built-in tools, and an extension's tool is
 * active once registered unless it declares `defaultActive: false` (codemode).
 * So a scope's selection means something only for pi's built-ins and those
 * opt-in tools (hidden tools cannot be selected). Reading registrations loads extension modules, so this read
 * takes the `hooks.list` treatment: serialized, drain-aware administrative work. */
export class ScopeToolCatalog {
  private readonly mutex = new AsyncMutex();

  constructor(
    private readonly agentDir: string,
    private readonly trust: TrustService,
    private readonly workRegistry?: GatewayWorkRegistry,
    private readonly managedSubagents?: ManagedSubagents,
  ) {}

  async list(cwd?: string): Promise<ToolCatalogEntry[]> {
    const work = this.workRegistry?.begin({
      kind: "administrative-provider-package-operation",
      hostEpoch: this.workRegistry.runtimeEpoch,
    });
    try {
      return await this.mutex.run(async () => {
        const loaded = await loadSessionFreeExtensions(this.agentDir, this.trust, cwd, this.managedSubagents);
        const optIn = loaded.extensions.flatMap(extension => [...extension.tools.values()])
          .filter(tool => tool.definition.defaultActive === false && tool.definition.exposure !== "hidden")
          .map(tool => ({ name: tool.definition.name, ...(tool.definition.description ? { description: tool.definition.description } : {}) }))
          .filter(tool => !PI_BUILTIN_TOOL_NAMES.includes(tool.name))
          .sort((a, b) => a.name.localeCompare(b.name));
        return [...PI_BUILTIN_TOOL_NAMES.map(name => ({ name })), ...optIn];
      });
    } finally {
      work?.settle();
    }
  }
}
