import type { ManagedSubagents } from "../sessions/managed-subagents.js";
import type { GatewayWorkRegistry } from "../sessions/gateway-work-registry.js";
import {
  createBashToolDefinition, createEditToolDefinition, createFindToolDefinition, createGrepToolDefinition,
  createLsToolDefinition, createPowerShellToolDefinition, createReadToolDefinition, createWriteToolDefinition,
} from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { loadSessionFreeExtensions } from "./session-free-extensions.js";
import { resourceDistribution } from "../sessions/resource-distribution.js";
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
        const workingDirectory = cwd ?? process.cwd();
        const builtIns = [
          createReadToolDefinition(workingDirectory), createBashToolDefinition(workingDirectory),
          createPowerShellToolDefinition(workingDirectory), createEditToolDefinition(workingDirectory),
          createWriteToolDefinition(workingDirectory), createGrepToolDefinition(workingDirectory),
          createFindToolDefinition(workingDirectory), createLsToolDefinition(workingDirectory),
        ];
        const builtInByName = new Map(builtIns.map(definition => [definition.name, definition]));
        const builtInEntries = PI_BUILTIN_TOOL_NAMES.map(name => {
          const definition = builtInByName.get(name);
          if (!definition) throw new GatewayError("internal", `Pi built-in tool ${name} has no definition`);
          return { name, description: definition.description, resource: {
            name, label: definition.label, description: definition.description, parameters: definition.parameters,
          } };
        });
        const optIn = loaded.extensions.flatMap(extension => [...extension.tools.values()])
          .filter(tool => tool.definition.defaultActive === false && tool.definition.exposure !== "hidden")
          .map(tool => ({
            name: tool.definition.name,
            description: tool.definition.description,
            resource: {
              name: tool.definition.name, label: tool.definition.label, description: tool.definition.description,
              parameters: tool.definition.parameters,
              ...(resourceDistribution(tool.sourceInfo) ? { distribution: resourceDistribution(tool.sourceInfo) } : {}),
              source: tool.sourceInfo.source, ...(tool.definition.namespace ? { namespace: tool.definition.namespace } : {}),
            },
          }))
          .filter(tool => !PI_BUILTIN_TOOL_NAMES.includes(tool.name))
          .sort((a, b) => a.name.localeCompare(b.name));
        return [...builtInEntries, ...optIn];
      });
    } finally {
      work?.settle();
    }
  }
}
