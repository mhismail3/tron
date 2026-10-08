import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { Type } from "@earendil-works/pi-ai";
import type { HomeTaskDispatchRequest, HomeTaskHandle } from "./home-task-dispatcher.js";
import type { HomeMemoryToolAccess } from "./home-memory.js";
import { homeMemoryTools } from "./home-memory-tools.js";
import { markHomeMemoryCache } from "./home-request-policy.js";

/**
 * Tron Home's operating context. Home is designated, and every activation runs on
 * the memory view of the conversation before it, so the text states what the
 * runtime actually does: the history it can see, the view it reads, and the tool
 * ceiling. It never claims a capability Home does not have.
 *
 * The text is constant: it is the head of every cached prefix, so two activations
 * must send it byte-identically (gist §7.2). The view's own preamble
 * (`home-memory.ts`) owns how to navigate a line.
 */
export const HOME_OPERATING_CONTEXT = [
  "## Tron Home",
  "This conversation is Tron Home: one persistent conversation for this Gateway installation. The user reaches it deliberately; nothing else wakes it, and no scheduled or background work runs here.",
  "Each turn starts from the memory view that opens this request: one-line summaries of this conversation from its start up to the user's current message, and then the messages since. Nothing before this turn is replayed in full, so read the view before you act, guess or ask, zoom the lines you need, and say in your reply whatever you learned that will matter later: summaries keep little of tool output.",
  "Home is delegate-only for project work. It runs in its own empty working directory with no project resources, skills, prompt templates or context files. Use delegate to assign finite work in a trusted project to an ordinary worker session with project tools and an explicit report tool. In v1, task workers cannot launch subagents or scheduled work, because those can outlive their task. Only ask_user, display, notify, zoom, date, memory_search, delegate and task are available here.",
  "Give each delegation a stable unique taskId, explicit intent and target directory. Accepted task IDs cannot replay work. The worker must call report with exact acceptance evidence; an ordinary reply is not success. Each task has an internal fixed 24-hour ceiling and records actual token usage. Use task status to read durable spend/results and task steer/stop with its exact operation and controller generation. You and the maintainer share steering in accepted session-lane order; viewing never takes control. Results are stored but are not yet delivered into Home; do not assume task success from admission.",
  "Do not assume shell, file, browser or project tools exist in Home, and do not ask to change this directory. Delegate authorized project work rather than performing it here.",
  "Compaction is disabled for Home, so this conversation's history stays canonical and grows as it is used.",
].join("\n");

/**
 * The one first-party module only a Home runtime loads. It contributes Home's
 * operating context, registers the memory tools, places the view's cache
 * breakpoints, and is the single answer to the SDK's per-session cache warming
 * decision.
 *
 * `memoryTools` resolves the memory for the session the tools run in, at every
 * tool call: it answers `undefined` for a session that is not the enabled Home,
 * and the tools then return a typed unavailable result rather than reaching a
 * memory that is not theirs.
 *
 * The cache-warming handler is deliberately unconditional and cannot throw: the
 * SDK's decision listener fails open (a throwing handler keeps warming, and a
 * later `warm` answer overrides an earlier `stop`), so Home must be the last and
 * only answer, and it must never be absent. `cache-warmer.js` calls the model
 * runtime directly, outside every request wrapper, so this handler is the only
 * mechanism that keeps Home's prompt-cache refreshes at zero.
 */
export type HomeTaskToolRequest = { action: "status"; taskId: string }
  | ({ action: "steer"; text: string } & import("./home-task-dispatcher.js").HomeTaskControlRequest)
  | ({ action: "stop" } & import("./home-task-dispatcher.js").HomeTaskControlRequest);

export function createTronHomeExtension(memoryTools: () => HomeMemoryToolAccess | undefined,
  delegate?: (request: HomeTaskDispatchRequest) => Promise<HomeTaskHandle>,
  task?: (request: HomeTaskToolRequest) => Promise<unknown>): ExtensionFactory {
  return (pi) => {
    for (const tool of homeMemoryTools(memoryTools)) pi.registerTool(tool);
    pi.registerTool({ name: "delegate", label: "Delegate", description: "Dispatch finite work once in a trusted project. Returns admission identity, not success; results are stored separately.",
      parameters: Type.Object({ taskId: Type.String({ minLength: 1, maxLength: 160 }), intent: Type.String({ minLength: 1, maxLength: 65536 }), target: Type.String({ minLength: 1, maxLength: 4096 }) }, { additionalProperties: false }),
      executionMode: "sequential", execute: async (_id, request) => {
        if (!delegate) throw new Error("Home dispatch is unavailable");
        const { taskId, sessionId, operationId } = await delegate(request);
        return { content: [{ type: "text", text: "Task admitted; a report is required for its result." }], details: { taskId, sessionId, operationId } };
      },
    });
    pi.registerTool({ name: "task", label: "Task", description: "Read durable task status/spend, steer a shared active task, or Stop its exact operation. Status has no control effect. Mutations require the operation and controller generation from status.",
      parameters: Type.Union([
        Type.Object({ action: Type.Literal("status"), taskId: Type.String({ minLength: 1, maxLength: 160 }) }, { additionalProperties: false }),
        Type.Object({ action: Type.Literal("steer"), taskId: Type.String({ minLength: 1, maxLength: 160 }), operationId: Type.String({ minLength: 1, maxLength: 160 }), controllerGeneration: Type.Integer({ minimum: 1 }), text: Type.String({ minLength: 1, maxLength: 65536 }) }, { additionalProperties: false }),
        Type.Object({ action: Type.Literal("stop"), taskId: Type.String({ minLength: 1, maxLength: 160 }), operationId: Type.String({ minLength: 1, maxLength: 160 }), controllerGeneration: Type.Integer({ minimum: 1 }) }, { additionalProperties: false }),
      ]), executionMode: "sequential", execute: async (_id, request) => {
        if (!task) throw new Error("Home task control is unavailable");
        const result = await task(request);
        return { content: [{ type: "text", text: JSON.stringify(result) }], details: result };
      },
    });
    pi.on("before_agent_start", async (event) => ({
      systemPrompt: `${event.systemPrompt}\n\n${HOME_OPERATING_CONTEXT}`,
    }));
    pi.on("cache_warming_decision", () => ({ action: "stop" }));
    // The recipe's view breakpoints (gist §8). Anthropic caches only where a
    // request marks it; OpenAI and DeepSeek reuse the view's shared prefix on
    // their own. A failure here leaves pi-ai's own payload, which is still a
    // valid request, only without the view marks.
    pi.on("before_provider_request", (event, ctx) =>
      ctx.model?.api === "anthropic-messages" ? markHomeMemoryCache(event.payload) : undefined);
  };
}
