import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";

/**
 * Tron Home's operating context. Home is designated, and every activation runs on
 * the memory view of the conversation before it, so the text states what the
 * runtime actually does: the history it can see, the view it reads, and the tool
 * ceiling. It never claims a capability Home does not have.
 */
export const HOME_OPERATING_CONTEXT = [
  "## Tron Home",
  "This conversation is Tron Home: one persistent conversation for this Gateway installation. The user reaches it deliberately; nothing else wakes it, and no scheduled or background work runs here.",
  "Each turn starts from the memory view that opens this request: one-line summaries of this conversation from its start up to the user's current message, and then the messages since. Nothing before this turn is replayed in full, so read the view before you act, guess or ask, and say in your reply whatever you learned that will matter later: summaries keep little of tool output.",
  "Current limits, all deliberate: Home sees only this conversation's shared view, cannot see or drive other sessions, and cannot delegate tasks. It runs in its own empty working directory with no project resources, skills, prompt templates or context files, and only the ask_user, display and notify tools are available.",
  "Do not assume shell, file, browser or project tools exist, and do not ask to change this directory. For project or Mac work, say so plainly and let the user start an ordinary session.",
  "Compaction is disabled for Home, so this conversation's history stays canonical and grows as it is used.",
].join("\n");

/**
 * The one first-party module only a Home runtime loads. It contributes Home's
 * operating context and is the single answer to the SDK's per-session cache
 * warming decision.
 *
 * The cache-warming handler is deliberately unconditional and cannot throw: the
 * SDK's decision listener fails open (a throwing handler keeps warming, and a
 * later `warm` answer overrides an earlier `stop`), so Home must be the last and
 * only answer, and it must never be absent. `cache-warmer.js` calls the model
 * runtime directly, outside every request wrapper, so this handler is the only
 * mechanism that keeps Home's prompt-cache refreshes at zero.
 */
export function createTronHomeExtension(): ExtensionFactory {
  return (pi) => {
    pi.on("before_agent_start", async (event) => ({
      systemPrompt: `${event.systemPrompt}\n\n${HOME_OPERATING_CONTEXT}`,
    }));
    pi.on("cache_warming_decision", () => ({ action: "stop" }));
  };
}
