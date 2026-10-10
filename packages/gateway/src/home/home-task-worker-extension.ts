import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";

/** Reviewed provider contract at fork commit 466f25763e9f55a3a42348e5bb395bd480b7c765
 * (tron.6: tool and skill text, and per-child settlement as context only; the
 * read-only actions, supervisor reads and blocking `bg_wait` are unchanged from
 * tron.5). A pin bump must re-review this gate: until then every action of the new
 * version is refused as unverified. async:false is NOT a foreground guarantee:
 * forceTopLevelAsync overrides it, so the task settles any async run it started
 * (HomeTaskDispatcher). */
export const HOME_TASK_SUBAGENT_VERSION = "0.76.1-tron.6";
/** The gate's two block reasons. A call it blocks never reaches the provider. */
export const HOME_TASK_PRODUCER_REFUSAL_REASON = "Home tasks can't start background, scheduled, mission or unverified producer work, or control runs the task did not start; do the work directly or report back.";
export const HOME_TASK_SEALED_REASON = "The task report is sealed, so this task has ended; no further work runs.";
export type HomeTaskProducerRefusal = "subagent-mutation" | "unverified-provider" | "schedule" | "wake-subscription";
const READ_ONLY_ACTIONS = new Set(["guide", "children.list", "status", "list", "get", "models"]);
/** Controls a task may use only on a run its own session launched. */
const OWN_RUN_ACTIONS = new Set(["stop", "interrupt"]);

/** A launch is allowed unless it attaches or starts a mission: a mission outlives its
 * run and would keep working after the task's join. Any other action is a control or
 * a read; a control needs a run this session launched, addressed by id (never by dir). */
function subagentRefusal(input: Record<string, unknown>, ownsRun: (runId: string) => boolean): HomeTaskProducerRefusal | undefined {
  if (input.action === undefined) {
    const mission = (input.mission !== undefined && input.mission !== false) || input.missionId !== undefined;
    return mission ? "subagent-mutation" : undefined;
  }
  const action = String(input.action);
  if (READ_ONLY_ACTIONS.has(action)) return undefined;
  const runId = input.id ?? input.runId;
  if (OWN_RUN_ACTIONS.has(action) && typeof runId === "string" && input.dir === undefined && ownsRun(runId)) return undefined;
  return "subagent-mutation";
}

export function createHomeTaskWorkerExtension(input: {
  providerVersion: (toolName: string) => string | undefined;
  refused: (reason: HomeTaskProducerRefusal) => void;
  /** True once the task's report is sealed: a later call in the same batch is refused. */
  reportSealed: () => boolean;
  /** True only for a run this session's canonical history launched. */
  ownsSubagentRun: (runId: string) => boolean;
}): ExtensionFactory {
  return pi => {
    pi.on("before_agent_start", event => ({ systemPrompt: `${event.systemPrompt}\n\nThis is a finite Home task. Work directly with project tools and finish with an explicit report and acceptance evidence. You may launch subagents; the task stops and joins every async run it started before it settles. Do not start scheduled or mission work, which outlives the task. The fixed internal deadline stops this operation; an ordinary final reply is not task success.` }));
    pi.on("tool_call", event => {
      if (input.reportSealed()) return { block: true, reason: HOME_TASK_SEALED_REASON };
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
        } else reason = subagentRefusal(event.input, input.ownsSubagentRun);
      }
      if (!reason) return;
      input.refused(reason);
      return { block: true, reason: HOME_TASK_PRODUCER_REFUSAL_REASON };
    });
  };
}
