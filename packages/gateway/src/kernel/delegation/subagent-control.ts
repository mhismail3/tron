import { randomUUID } from "node:crypto";
import type { AgentSession, ToolDefinition } from "../pi/coding-agent.js";
import { GatewayError } from "../../errors.js";

/** The provider's own control for one run, through the exact installed controller.
 * A rejection is an error: the caller must not assume the run was stopped. */
export async function controlSubagentRun(session: AgentSession, tool: ToolDefinition, input: Record<string, unknown>): Promise<void> {
  const toolCallId = `tron-control-${randomUUID()}`;
  const signal = new AbortController().signal;
  const result = await tool.execute(toolCallId, input, signal, undefined,
    session.extensionRunner.createToolContext(toolCallId, signal));
  if ((result as typeof result & { isError?: boolean }).isError === true) {
    const message = result.content.find(content => content.type === "text")?.text;
    throw new GatewayError("conflict", message?.slice(0, 512) || "The subagent controller rejected the request", true);
  }
}
