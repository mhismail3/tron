import type { ExtensionFactory } from "../pi/coding-agent.js";

export const HOME_TASK_PRODUCER_REFUSAL_REASON = "Home tasks can't schedule work, launch or attach a mission, subscribe to a wake, control a run the task did not start, or use an unverified producer; do the work directly or report back.";
export const HOME_TASK_SEALED_REASON = "The task report is sealed, so this task has ended; no further work runs.";
export type HomeTaskProducerRefusal = "subagent-mutation" | "unverified-provider" | "schedule" | "wake-subscription";
const READ_ONLY_ACTIONS = new Set(["guide", "children.list", "status", "list", "get", "models"]);
const OWN_RUN_ACTIONS = new Set(["steer", "resume", "interrupt", "stop", "command.status", "command.yield", "command.cancel"]);

async function subagentRefusal(input: Record<string, unknown>, ownsRun: (runId: string) => Promise<boolean>): Promise<HomeTaskProducerRefusal | undefined> {
  const mission = (input.mission !== undefined && input.mission !== false) || input.missionId !== undefined;
  if (input.action === undefined) return mission ? "subagent-mutation" : undefined;
  const action = String(input.action);
  if (READ_ONLY_ACTIONS.has(action)) return undefined;
  const runId = input.id ?? input.runId;
  if (OWN_RUN_ACTIONS.has(action) && !mission && typeof runId === "string" && input.dir === undefined && await ownsRun(runId)) return undefined;
  return "subagent-mutation";
}

async function supervisorRefusal(input: Record<string, unknown>, ownsRequest: (requestId: string) => Promise<boolean>): Promise<HomeTaskProducerRefusal | undefined> {
  if (["status", "pending", "list"].includes(String(input.action))) return undefined;
  if (input.action === "reply" && typeof input.replyTo === "string" && await ownsRequest(input.replyTo)) return undefined;
  return "subagent-mutation";
}

export function createHomeTaskWorkerExtension(input: {
  isVerifiedProvider: (toolName: string) => boolean;
  refused: (reason: HomeTaskProducerRefusal) => void;
  reportSealed: () => boolean;
  ownsSubagentRun: (runId: string) => Promise<boolean>;
  ownsSupervisorRequest: (requestId: string) => Promise<boolean>;
}): ExtensionFactory {
  return pi => {
    pi.on("before_agent_start", event => ({ systemPrompt: `${event.systemPrompt}\n\nThis is a finite Home task. Work directly with project tools and finish with an explicit report and acceptance evidence. Send a lightweight checkin at milestones and about every 30 minutes: current step, done, next, and optional blocker/branch/commit/issue refs. Check-ins are durable progress, never a pause or final result. They are quiet by default; use needsAttention only for blockers needing Home (at most one wake request per 30 minutes across resumes). A brief's instruction to delegate is the operator's request to delegate: when it asks for subagents, launch them as it says. You may launch subagents (foreground, async or workflows), and the task owns every run it starts: you may steer, resume, interrupt or stop them, and reply to their supervisor requests. A turn that ends while they are live waits for them: their completion or supervisor request starts your next turn in this same task, so you may end a turn to wait like an ordinary session. report is refused while one of them is live: wait for it (subagent status, or a blocking bg_wait) or stop it, then report. Settlement stops and joins any async run still live. Do not start scheduled or mission work, which outlives the task. The fixed internal deadline stops this operation; an ordinary final reply is not task success.` }));
    pi.on("tool_call", async event => {
      if (input.reportSealed()) return { block: true, reason: HOME_TASK_SEALED_REASON };
      let reason: HomeTaskProducerRefusal | undefined;
      if (event.toolName === "schedule") reason = "schedule";
      else if (event.toolName === "subagent" || event.toolName === "subagent_supervisor" || event.toolName === "bg_wait") {
        if (!input.isVerifiedProvider(event.toolName)) reason = "unverified-provider";
        else if (event.toolName === "bg_wait") {
          if (event.input.nonBlocking === true) reason = "wake-subscription";
        } else if (event.toolName === "subagent_supervisor") reason = await supervisorRefusal(event.input, input.ownsSupervisorRequest);
        else reason = await subagentRefusal(event.input, input.ownsSubagentRun);
      }
      if (!reason) return;
      input.refused(reason);
      return { block: true, reason: HOME_TASK_PRODUCER_REFUSAL_REASON };
    });
  };
}
