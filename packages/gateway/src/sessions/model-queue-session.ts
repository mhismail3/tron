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
 * - every managed subagent child of the session loads the child queue extension,
 *   and the projection it reads is refreshed before each top-level launch.
 */
export function modelQueueSessionExtension(input: {
  worker?: ModelQueueSource;
  publishProjection: () => Promise<void>;
  requireChildExtensions?: (sessionId: string, extensions: readonly { id: string; path: string }[]) => Promise<{ dispose(): void }>;
}): ExtensionFactory {
  return (pi) => {
    if (input.worker) createModelQueueExtension("worker", input.worker)(pi);
    let registration: { dispose(): void } | undefined;
    pi.on("session_start", async (_event, ctx) => {
      registration?.dispose();
      registration = await input.requireChildExtensions?.(ctx.sessionManager.getSessionId(),
        [{ id: "tron-model-queue", path: MODEL_QUEUE_CHILD_EXTENSION }]);
    });
    pi.on("session_shutdown", () => { registration?.dispose(); registration = undefined; });
    pi.on("tool_call", async (event) => {
      // A failed refresh leaves the previous projection; the child's own error
      // path still moves along the queue.
      if (event.toolName === "subagent") await input.publishProjection().catch(() => {});
    });
  };
}
