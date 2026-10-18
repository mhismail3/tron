import { extname } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { createModelQueueExtension, type ModelQueueSource } from "../providers/model-queue-extension.js";

/** The child half, as its own module: every managed subagent child loads it. */
export const MODEL_QUEUE_CHILD_EXTENSION = fileURLToPath(new URL(`../providers/model-queue-extension${extname(fileURLToPath(import.meta.url))}`, import.meta.url));

/**
 * A Gateway session's part of the model queues (settings-model.md 6.3):
 *
 * - a Home task worker falls over along the worker queue on a usage-limit error;
 * - the session lists the subagent queue's virtual model `tron/subagent`, so a
 *   subagent can be launched on it;
 * - every managed subagent child of the session loads the child queue extension,
 *   and the projection it reads is refreshed before each top-level launch.
 */
export function modelQueueSessionExtension(input: {
  source: ModelQueueSource;
  worker: boolean;
  publishProjection: () => Promise<void>;
  releaseProjection?: () => Promise<void>;
  taskChildExtension?: (implementation: string) => Promise<string>;
  requireChildExtensions?: (sessionId: string, extensions: readonly { id: string; path: string }[]) => Promise<{ dispose(): void }>;
}): ExtensionFactory {
  return (pi) => {
    if (input.worker) createModelQueueExtension("worker", input.source)(pi);
    createModelQueueExtension("subagent", input.source, { virtualModel: true })(pi);
    let registration: { dispose(): void } | undefined;
    const registerChildPolicy = async (sessionId: string) => {
      registration?.dispose();
      registration = await input.requireChildExtensions?.(sessionId,
        [{ id: "tron-model-queue", path: await input.taskChildExtension?.(MODEL_QUEUE_CHILD_EXTENSION) ?? MODEL_QUEUE_CHILD_EXTENSION }]);
    };
    pi.on("session_start", async (_event, ctx) => { await registerChildPolicy(ctx.sessionManager.getSessionId()); });
    pi.on("session_shutdown", async () => {
      registration?.dispose(); registration = undefined;
      await input.releaseProjection?.();
    });
    pi.on("tool_call", async (event, ctx) => {
      if (event.toolName !== "subagent") return;
      // Admission may persist launch inputs after the initial session_start.
      // Bind from the same canonical choice immediately before actual launch.
      try {
        await input.publishProjection();
        await registerChildPolicy(ctx.sessionManager.getSessionId());
      }
      catch { return { block: true, reason: "Cannot publish this session’s model queue; no child was launched." }; }
    });
  };
}
