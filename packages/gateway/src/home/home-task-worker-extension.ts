import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";

/** Reviewed provider contract at a0ddb64531df574dedcda1686a7d8d2bb62bfbb2.
 * async:false is NOT a foreground guarantee: forceTopLevelAsync overrides it.
 * Do not enable execution until the provider has an operation-owned contract. */
export const HOME_TASK_SUBAGENT_VERSION = "0.76.1-tron.5";
export type HomeTaskProducerRefusal = "subagent-execution" | "subagent-mutation" | "unverified-provider" | "schedule" | "wake-subscription";
const READ_ONLY_ACTIONS = new Set(["guide", "children.list", "status", "list", "get", "models"]);

export function createHomeTaskWorkerExtension(input: {
  providerVersion: (toolName: string) => string | undefined;
  refused: (reason: HomeTaskProducerRefusal) => void;
}): ExtensionFactory {
  return pi => {
    pi.on("before_agent_start", event => ({ systemPrompt: `${event.systemPrompt}\n\nThis is a finite Home task. Work directly with project tools and finish with an explicit report and acceptance evidence. Do not start background, scheduled or subagent work: it can outlive the task. The fixed internal deadline stops this operation; an ordinary final reply is not task success.` }));
    pi.on("tool_call", event => {
      let reason: HomeTaskProducerRefusal | undefined;
      if (event.toolName === "schedule") reason = "schedule";
      else if (event.toolName === "subagent" || event.toolName === "subagent_supervisor" || event.toolName === "bg_wait") {
        if (input.providerVersion(event.toolName) !== HOME_TASK_SUBAGENT_VERSION) reason = "unverified-provider";
        else if (event.toolName === "bg_wait") {
          // Blocking waits use the operation signal; subscriptions can wake a
          // settled task session later and are not owned by that signal.
          if (event.input.nonBlocking === true) reason = "wake-subscription";
        } else if (event.toolName === "subagent_supervisor") {
          if (!["status", "pending", "list"].includes(String(event.input.action))) reason = "subagent-mutation";
        } else if (event.input.action === undefined) reason = "subagent-execution";
        else if (!READ_ONLY_ACTIONS.has(String(event.input.action).trim())) reason = "subagent-mutation";
      }
      if (!reason) return;
      input.refused(reason);
      return { block: true, reason: reason === "subagent-execution"
        ? "Home tasks can't launch subagents yet: subagent runs can outlive the task; do the work directly or report back."
        : "Home tasks can't start background, scheduled or unverified producer work; do the work directly or report back." };
    });
  };
}
