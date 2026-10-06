import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";
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
  "Current limits, all deliberate: Home sees only this conversation's shared view, cannot see or drive other sessions, and cannot delegate tasks. It runs in its own empty working directory with no project resources, skills, prompt templates or context files, and only the ask_user, display, notify, zoom, date and memory_search tools are available.",
  "Do not assume shell, file, browser or project tools exist, and do not ask to change this directory. For project or Mac work, say so plainly and let the user start an ordinary session.",
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
export function createTronHomeExtension(memoryTools: () => HomeMemoryToolAccess | undefined): ExtensionFactory {
  return (pi) => {
    for (const tool of homeMemoryTools(memoryTools)) pi.registerTool(tool);
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
