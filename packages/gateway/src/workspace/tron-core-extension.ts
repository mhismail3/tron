import { Type } from "../kernel/pi/ai.js";
import type { ExtensionFactory } from "../kernel/pi/coding-agent.js";
import type { ResourceRoot, TronWorkspaceDescriptor } from "../kernel/resources/resource-root.js";
import { tronCore, tronHandoff } from "../kernel/host/tron-context.js";
import type { JevDecisionClient } from "../providers/jev-client.js";
import { createJevExtension } from "../providers/jev-extension.js";
import type { ConnectionAccess } from "../modules/integrations/contract.js";

const CONNECTIONS_TOOL_PARAMETERS = Type.Object({ action: Type.Literal("list") }, { additionalProperties: false });

export function tronContext(workspace: TronWorkspaceDescriptor, cwd: string, tools: readonly string[]): string {
  const lines = [
    `Current execution working directory: ${JSON.stringify(cwd)}. Relative task paths and project instructions belong to this directory; do not change it to use the internal workspace.`,
    `Tron internal workspace: ${JSON.stringify(workspace.root)} (${workspace.available ? "available" : "unavailable"}). This separate, per-installation root is for deliberately retained cross-session information, not a copy of projects or sessions.`,
  ];
  if (tools.includes("display")) lines.push("Use display for useful visual/document results. source.kind=internal_file resolves relative to the internal workspace's files/ directory; source.kind=path remains relative to this session directory.");
  if (tools.includes("computer") || tools.includes("agent_browser")) lines.push(`Do on-screen work yourself, by default and liberally: web flows (consoles, dashboards, OAuth consent, forms)${tools.includes("computer") ? ", macOS permission prompts and dialogs, app windows, and storing secrets in Keychain without echoing them to chat, logs or files" : ""}. Use whichever available computer or browser tool does each step fastest and most accurately, and verify each effect by re-observing. Unblock yourself this way before asking; never hand the user on-screen steps. Before consenting or approving, confirm the signed-in account, app and requested scopes or permission match the authorized task. When no tool can do a step, say exactly what failed, file the gap on Tron issue #2476 and fix it robustly, not with a one-off workaround.`);
  if (tools.includes("agent_browser")) lines.push("Use agent_browser for browser work; prefer it to browser shell commands or one-off workarounds.");
  if (tools.includes("ask_user")) lines.push("Use ask_user for a necessary bounded decision after gathering context, not for questions you can resolve yourself.");
  if (tools.includes("notify")) lines.push("Use notify for useful attention requests; queued delivery is not proof the user received it.");
  return lines.join("\n");
}

export function createTronCoreExtension(workspace: Pick<ResourceRoot, "describe">, jev?: { client: JevDecisionClient; deferred: boolean }, connections?: Pick<ConnectionAccess, "snapshot">,
  registerChildContext?: (taskPrefix: string) => Promise<{ dispose(): void }>): ExtensionFactory {
  return async (pi) => {
    let childContext: { dispose(): void } | undefined;
    const publishChildContext = async () => {
      const descriptor = await workspace.describe();
      if (registerChildContext) {
        childContext?.dispose();
        childContext = undefined;
        childContext = await registerChildContext(tronHandoff(descriptor));
      }
      return descriptor;
    };
    await publishChildContext();
    pi.on("session_start", async () => { await publishChildContext(); });
    pi.on("session_shutdown", () => { childContext?.dispose(); });
    if (jev) createJevExtension(jev.client, jev.deferred)(pi);
    if (connections) {
      pi.registerTool({
        name: "connections",
        annotations: { openWorldHint: false },
        label: "Connections",
        description: "Inspect Tron-managed provider connection definitions, account instances, capability availability, and setup status. MCP servers are configured separately through Pi's agent-directory mcp.json. This read-only projection contains no credential values or references; setup and policy changes remain exact owner-typed Gateway commands.",
        promptSnippet: "Inspect connection status before using a provider capability. A configured account is not automatically admitted into this session.",
        parameters: CONNECTIONS_TOOL_PARAMETERS,
        executionMode: "sequential",
        execute: async () => {
          const snapshot = await connections.snapshot();
          return { content: [{ type: "text", text: JSON.stringify(snapshot) }], details: snapshot };
        },
      });
    }
    pi.on("before_agent_start", async (event, ctx) => {
      const descriptor = await publishChildContext();
      event.systemPromptOptions.preamble = tronCore(descriptor);
      event.systemPromptOptions.sections.tron = tronContext(descriptor, ctx.cwd, pi.getActiveTools());
    });
  };
}
