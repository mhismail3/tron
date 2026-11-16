import { extname } from "node:path";
import { fileURLToPath } from "node:url";
import type { ModelRuntimePolicy, SessionContext } from "../kernel/host/module-host.js";
import { GatewayError } from "../errors.js";
import type { ModelQueueOwner } from "./model-queue.js";
import { createModelQueueExtension, subagentModelsText } from "./model-queue-extension.js";

const MODEL_QUEUE_CHILD_EXTENSION = fileURLToPath(new URL(`./model-queue-extension${extname(fileURLToPath(import.meta.url))}`, import.meta.url));

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
  if (worker) session.turnFacts(async () => {
    const fixed = session.fixedSettings();
    const model = fixed["model.ref[role=chat]"], thinking = fixed["model.thinking[role=chat]"];
    const ref = model?.value as { provider?: string; id?: string } | undefined;
    const subagents = selection("subagent") === undefined ? [] : await source.availability("subagent");
    return [
      ...(ref?.provider && ref.id ? [`Worker choice: ${ref.provider}/${ref.id}. Thinking: ${String(thinking?.value ?? "default")}. Source: model ${model?.reason ?? "unrecorded"}; thinking ${thinking?.reason ?? "unrecorded"}.`] : []),
      ...(subagents.length ? [`Subagent models: ${subagentModelsText(subagents)}.`] : []),
    ].join("\n") || undefined;
  });
  return [{ name: "tron-model-queue", factory: (pi) => {
    if (worker) createModelQueueExtension("worker", source)(pi);
    createModelQueueExtension("subagent", source, { virtualModel: true, ...(worker ? { guidance: () => Boolean(selection("subagent")?.length) } : {}) })(pi);
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
      try {
        const selected = selection("subagent");
        await queue.publishProjection(selected === undefined ? undefined : { sessionId: session.sessionId(), queue: selected });
        await registerChildPolicy(ctx.sessionManager.getSessionId());
      }
      catch { return { block: true, reason: "Cannot publish this session’s model queue; no child was launched." }; }
    });
  } }];
}
