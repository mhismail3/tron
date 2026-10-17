import { readFileSync } from "node:fs";
import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";

/**
 * The in-session half of the model fallback queues (settings-model.md 6.3,
 * `model.queue[role=…]`). It runs in two places with one contract:
 *
 * - a Home task worker, in the Gateway process, reading availability from the
 *   Gateway's `ModelQueueOwner` (model-queue.ts);
 * - every managed subagent child, foreground or detached, as a host-required child
 *   extension (`default` below), reading the bounded projection that owner publishes
 *   at the path in `TRON_MODEL_QUEUE_PROJECTION`.
 *
 * Subagents run on the queue's virtual model `tron/subagent`, which routes each
 * request to the first available subagent queue model. When a run settles on a
 * usage-limit error, the failed request is omitted from context exactly as Pi
 * omits a retried attempt, the session moves to the next available queue model
 * (a worker by switching its model, a subagent through the route), and the same
 * request runs again. Each skip is recorded as
 * a `tron.model-queue` entry. With no model left the run ends on its error, with a
 * visible message naming every queue model and why it was skipped.
 *
 * This file is loaded on its own by child processes: it imports nothing from the
 * Gateway.
 */

export const MODEL_QUEUE_PROJECTION_ENV = "TRON_MODEL_QUEUE_PROJECTION";
export const MODEL_QUEUE_ENTRY = "tron.model-queue";
export type ModelQueueRole = "worker" | "subagent" | "background";

/** Plan and subscription limits, and throttles: the request may succeed on another
 * provider. Pi's own non-retryable limit patterns (pi-ai utils/retry) plus 429. */
const USAGE_LIMIT = /GoUsageLimitError|FreeUsageLimitError|usage.?limit|insufficient_quota|quota exceeded|out of budget|subscription_sharing_usage_limit_exceeded|available balance|\b429\b|rate.?limit|too many requests/iu;

export function isUsageLimitError(text: string | undefined): boolean {
  return typeof text === "string" && USAGE_LIMIT.test(text);
}

export interface QueueModelState { model: string; available: boolean; reason?: string }

/** Where a session reads its queue and reports a usage-limit failure. */
export interface ModelQueueSource {
  availability(role: ModelQueueRole): Promise<QueueModelState[]>;
  record(role: ModelQueueRole, model: string, reason: string): void;
}

/** "All subagent models are unavailable: a/b — weekly usage 100%; c/d — usage-limit error: …" */
export function exhaustedText(role: ModelQueueRole, models: readonly QueueModelState[]): string {
  if (models.length === 0) return `No ${role} models are configured (model.queue[role=${role}]).`;
  return `All ${role} models are unavailable: ${models.map(entry => `${entry.model} — ${entry.reason ?? "unavailable"}`).join("; ")}.`;
}

export function usageLimitReason(message: string): string {
  const text = message.replace(/\s+/gu, " ").trim();
  return `usage-limit error: ${text.length > 200 ? `${text.slice(0, 199)}…` : text}`;
}

/** A skip reason that a plan limit causes and time clears: a usage-limit error
 * (`usageLimitReason`) or a usage window at the queue's threshold (`usageSkip`).
 * Registration, credential and configuration skips are not time-bound. */
export function isUsageLimitReason(reason: string | undefined): boolean {
  return reason !== undefined && (reason.startsWith("usage-limit error: ") || / usage \d+%$/u.test(reason));
}

/** The projection's shape (written by ModelQueueOwner.publishProjection). */
interface Projection {
  version: 1;
  queues: Partial<Record<ModelQueueRole, string[]>>;
  unavailable: Record<string, { reason: string; until: number }>;
}

/** A child's source: the Gateway's projection, plus what this process saw itself.
 * A missing, unreadable or expired entry never blocks a model. */
export function projectionSource(path: string | undefined, now: () => number = Date.now): ModelQueueSource {
  const local = new Map<string, { reason: string; until: number }>();
  const read = (): Projection | undefined => {
    if (!path) return undefined;
    try {
      const value = JSON.parse(readFileSync(path, "utf8")) as Projection;
      return value?.version === 1 && value.queues && value.unavailable ? value : undefined;
    } catch { return undefined; }
  };
  return {
    async availability(role) {
      const projection = read();
      const at = now();
      return (projection?.queues[role] ?? []).map(model => {
        const skip = [local.get(model), projection?.unavailable[model]].find(entry => entry && entry.until > at);
        return skip ? { model, available: false, reason: skip.reason } : { model, available: true };
      });
    },
    record(_role, model, reason) { local.set(model, { reason, until: now() + 15 * 60_000 }); },
  };
}

/** The subagent queue as one selectable model. A subagent launched on it runs the
 * first available subagent queue model and moves along the queue on a usage-limit
 * error. Its virtual selection is what pi-subagents verifies, so the physical
 * model may change under it. */
export const SUBAGENT_QUEUE_MODEL = { provider: "tron", id: "subagent" } as const;
const THINKING_LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh"] as const;

interface QueueOptions {
  /** Register the subagent queue's virtual model (subagent role). */
  virtualModel?: boolean;
}

type Registry = { find(provider: string, id: string): unknown };

export function createModelQueueExtension(role: ModelQueueRole, source: ModelQueueSource, options: QueueOptions = {}): ExtensionFactory {
  return (pi) => {
    let registry: Registry | undefined;
    const find = (ref: string) => {
      const separator = ref.indexOf("/");
      return separator > 0 ? registry?.find(ref.slice(0, separator), ref.slice(separator + 1)) : undefined;
    };
    const isQueueModel = (model: { provider: string; id: string } | undefined) =>
      model?.provider === SUBAGENT_QUEUE_MODEL.provider && model.id === SUBAGENT_QUEUE_MODEL.id;
    pi.on("session_start", (_event, ctx) => { registry = ctx.modelRegistry; });

    if (options.virtualModel) {
      pi.registerVirtualModel({
        ...SUBAGENT_QUEUE_MODEL, name: "Subagent models", thinkingLevels: THINKING_LEVELS,
        route: async (request) => {
          // A retry after a plan limit (Pi retries a 429) moves on instead of waiting.
          if (request.failed && isUsageLimitError(request.failed.message.errorMessage)) {
            source.record(role, `${request.failed.model.provider}/${request.failed.model.id}`, usageLimitReason(request.failed.message.errorMessage!));
          }
          const models = await source.availability(role);
          const usable = models.filter(entry => entry.available);
          // Tool follow-ups stay on the model that answered, while it is still usable.
          const previous = request.reason === "continuation" && request.previous ? `${request.previous.model.provider}/${request.previous.model.id}` : undefined;
          const chosen = usable.find(entry => entry.model === previous) ?? usable[0];
          const model = chosen ? find(chosen.model) : undefined;
          if (!model) throw new Error(exhaustedText(role, models));
          return { model: model as never, thinkingLevel: request.thinkingLevel };
        },
      });
    }

    pi.on("agent_before_settle", async (event, ctx) => {
      if (event.outcome !== "error") return undefined;
      const branch = ctx.sessionManager.getBranch();
      const failed = branch.findLast(entry => entry.type === "message" && entry.message.role === "assistant");
      if (failed?.type !== "message" || failed.message.role !== "assistant" || failed.message.stopReason !== "error"
        || !isUsageLimitError(failed.message.errorMessage)) return undefined;
      // A subagent on an explicit physical model keeps it: only the queue model moves.
      const virtual = isQueueModel(ctx.model);
      if (role === "subagent" && !virtual) return undefined;
      const failedModel = `${failed.message.provider}/${failed.message.model}`;
      const reason = usageLimitReason(failed.message.errorMessage!);
      source.record(role, failedModel, reason);
      const models = await source.availability(role);
      const states = models.map(entry => entry.model === failedModel ? { model: entry.model, available: false, reason } : entry);
      // After the failed model's place; from the front when it is not a queue model.
      const start = states.findIndex(entry => entry.model === failedModel) + 1;
      const next = (virtual ? states : states.slice(start)).find(entry => entry.available);
      // The queue model routes the retried request itself; a worker switches its model.
      if (next && (virtual || await pi.setModel(find(next.model) as Parameters<typeof pi.setModel>[0]).catch(() => false))) {
        return {
          entries: [
            { type: "custom" as const, customType: MODEL_QUEUE_ENTRY, data: { role, skipped: failedModel, reason, next: next.model } },
            { type: "context_edit" as const, targetId: failed.id, replacement: null },
          ],
          continue: true,
        };
      }
      return { entries: [{ type: "custom_message" as const, customType: MODEL_QUEUE_ENTRY, display: true,
        content: exhaustedText(role, states.some(entry => entry.model === failedModel) ? states : [...states, { model: failedModel, available: false, reason }]),
        details: { role, skipped: failedModel, reason } }] };
    });
  };
}

/** A managed subagent child: the subagent queue, from the Gateway's projection. */
export default createModelQueueExtension("subagent", projectionSource(process.env[MODEL_QUEUE_PROJECTION_ENV]), { virtualModel: true });
