import { readFileSync } from "node:fs";
import type { ExtensionFactory, SessionEntry } from "../kernel/pi/coding-agent.js";

export const MODEL_QUEUE_PROJECTION_ENV = "TRON_MODEL_QUEUE_PROJECTION";
const MODEL_QUEUE_ENTRY = "tron.model-queue";

export function readWorkerQueueSelection(entries: readonly SessionEntry[], afterIndex: number): { provider: string; id: string } | undefined {
  for (let index = entries.length - 1; index > afterIndex; index -= 1) {
    const entry = entries[index];
    if (entry?.type !== "custom" || entry.customType !== MODEL_QUEUE_ENTRY) continue;
    const data = entry.data as { role?: unknown; next?: unknown } | null;
    if (data?.role !== "worker") continue;
    const ref = data.next;
    const slash = typeof ref === "string" ? ref.indexOf("/") : -1;
    if (typeof ref !== "string" || ref.length > 421 || slash <= 0 || slash === ref.length - 1) throw new Error("Canonical worker queue selection is invalid");
    return { provider: ref.slice(0, slash), id: ref.slice(slash + 1) };
  }
  return undefined;
}
export type ModelQueueRole = "worker" | "subagent" | "background";

import { UPSTREAM_USAGE_LIMIT } from "../util/upstream-error.js";

export function isUsageLimitError(text: string | undefined): boolean {
  return typeof text === "string" && UPSTREAM_USAGE_LIMIT.test(text);
}

export interface QueueModelState { model: string; available: boolean; reason?: string }

export interface ModelQueueSource {
  availability(role: ModelQueueRole): Promise<QueueModelState[]>;
  record(role: ModelQueueRole, model: string, reason: string): void;
}

export function exhaustedText(role: ModelQueueRole, models: readonly QueueModelState[]): string {
  if (models.length === 0) return `No ${role} models are configured (model.queue[role=${role}]).`;
  return `All ${role} models are unavailable: ${models.map(entry => `${entry.model} — ${entry.reason ?? "unavailable"}`).join("; ")}.`;
}

export function usageLimitReason(message: string): string {
  const text = message.replace(/\s+/gu, " ").trim();
  return `usage-limit error: ${text.length > 200 ? `${text.slice(0, 199)}…` : text}`;
}

export function isUsageLimitReason(reason: string | undefined): boolean {
  return reason !== undefined && (reason.startsWith("usage-limit error: ") || / usage \d+%$/u.test(reason));
}

interface Projection {
  version: 1;
  queues: Partial<Record<ModelQueueRole, string[]>>;
  unavailable: Record<string, { reason: string; until: number }>;
}

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

export const SUBAGENT_QUEUE_MODEL = { provider: "tron", id: "subagent" } as const;
const THINKING_LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh"] as const;

interface QueueOptions {
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
          if (request.failed && isUsageLimitError(request.failed.message.errorMessage)) {
            source.record(role, `${request.failed.model.provider}/${request.failed.model.id}`, usageLimitReason(request.failed.message.errorMessage!));
          }
          const models = await source.availability(role);
          const usable = models.filter(entry => entry.available);
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
      const virtual = isQueueModel(ctx.model);
      if (role === "subagent" && !virtual) return undefined;
      const failedModel = `${failed.message.provider}/${failed.message.model}`;
      const reason = usageLimitReason(failed.message.errorMessage!);
      source.record(role, failedModel, reason);
      const models = await source.availability(role);
      const states = models.map(entry => entry.model === failedModel ? { model: entry.model, available: false, reason } : entry);
      const start = states.findIndex(entry => entry.model === failedModel) + 1;
      const next = (virtual ? states : states.slice(start)).find(entry => entry.available);
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

const childQueue: ExtensionFactory = pi => createModelQueueExtension("subagent",
  projectionSource(process.env[MODEL_QUEUE_PROJECTION_ENV]), { virtualModel: true })(pi);
export default childQueue;
