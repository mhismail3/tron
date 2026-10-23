import { extname } from "node:path";
import { fileURLToPath } from "node:url";
import type { ModelRuntimePolicy, SessionContext } from "../kernel/host/module-host.js";
import { GatewayError } from "../errors.js";
import type { ModelQueueOwner } from "./model-queue.js";
import { createModelQueueExtension } from "./model-queue-extension.js";

/** The child half, as its own module: every managed subagent child loads it. */
const MODEL_QUEUE_CHILD_EXTENSION = fileURLToPath(new URL(`./model-queue-extension${extname(fileURLToPath(import.meta.url))}`, import.meta.url));

/** Queue registration stays after ordinary modules and before worker controls.
 * Canonical launch inputs outlive the active task runtime: a cold-opened completed
 * worker still owns its recorded child policy, never the current Home profile. */
export function modelQueueSessionExtensions(queue: ModelQueueOwner | undefined, session: SessionContext,
  requireChildren: Parameters<ModelRuntimePolicy["extensions"]>[1],
): ReturnType<ModelRuntimePolicy["extensions"]> {
  if (!queue) return [];
  const selection = (role: string): readonly string[] | undefined => {
    const value = session.fixedSettings()[`model.queue[role=${role}]`]?.value;
    if (value === undefined) return undefined;
    if (!Array.isArray(value) || value.some(item => typeof item !== "string")) throw new GatewayError("conflict", "Invalid canonical task queue");
    return value;
  };
  const source = queue.source(selection);
  const worker = session.delegatedWorker();
  return [{ name: "tron-model-queue", factory: (pi) => {
    if (worker) createModelQueueExtension("worker", source)(pi);
    createModelQueueExtension("subagent", source, { virtualModel: true })(pi);
    let registration: { dispose(): void } | undefined;
    const registerChildPolicy = async (sessionId: string) => {
      registration?.dispose();
      registration = await requireChildren?.(sessionId,
        [{ id: "tron-model-queue", path: selection("subagent") === undefined ? MODEL_QUEUE_CHILD_EXTENSION
          : await queue.taskChildExtension(session.sessionId(), MODEL_QUEUE_CHILD_EXTENSION) }]);
    };
    pi.on("session_start", async (_event, ctx) => { await registerChildPolicy(ctx.sessionManager.getSessionId()); });
    pi.on("session_shutdown", async () => {
      registration?.dispose(); registration = undefined;
      await queue.releaseTaskProjection(session.sessionId());
    });
    pi.on("tool_call", async (event, ctx) => {
      if (event.toolName !== "subagent") return;
      // Admission may persist launch inputs after the initial session_start.
      // Bind from the same canonical choice immediately before actual launch.
      try {
        const selected = selection("subagent");
        await queue.publishProjection(selected === undefined ? undefined : { sessionId: session.sessionId(), queue: selected });
        await registerChildPolicy(ctx.sessionManager.getSessionId());
      }
      catch { return { block: true, reason: "Cannot publish this session’s model queue; no child was launched." }; }
    });
  } }];
}
