import { mkdir, rename, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import type { ModelRuntime } from "@earendil-works/pi-coding-agent";
import type { Api, AssistantMessage, Context, Model, SimpleStreamOptions } from "@earendil-works/pi-ai";
import { GatewayError } from "../errors.js";
import type { ProviderUsageOwner } from "./provider-usage.js";
import { isVirtualModel } from "./virtual-model.js";
import {
  exhaustedText, isUsageLimitError, isUsageLimitReason, usageLimitReason,
  type ModelQueueRole, type ModelQueueSource, type QueueModelState,
} from "./model-queue-extension.js";

/**
 * The Gateway's model fallback queues (settings-model.md 6.3). One owner per
 * process answers which models of a role's queue are usable now and why each
 * other one is skipped, records usage-limit failures, runs the Gateway's own
 * background completions along the queue, and publishes the bounded projection
 * managed subagent children read (model-queue-extension.ts).
 *
 * A model is skipped when it is not registered, is virtual, has no credentials,
 * failed with a usage-limit error in the last 15 minutes, or when any usage window
 * of its provider is at least 95% in a fresh `ProviderUsageOwner` read (its own
 * 60-second cache). Stale or unknown usage never skips a model: the error path
 * catches a limit the usage read could not see.
 */

export const MODEL_QUEUE_ROLES = ["worker", "subagent", "background"] as const;
export const MODEL_QUEUE_SKIP_PERCENT = 95;
const RECORD_MS = 15 * 60_000;
/** A projected usage skip lasts this long, so a child never acts on an old read. */
const PROJECTED_USAGE_MS = 10 * 60_000;
const PROJECTION_BYTES = 64 * 1024;

export function modelQueueKey(role: ModelQueueRole): string { return `model.queue[role=${role}]`; }

/** The children's projection, in the Gateway's own state directory. */
export function modelQueueProjectionPath(tronHome: string): string { return join(tronHome, "gateway", "model-queue.json"); }

export function splitModelRef(value: string): { provider: string; id: string } | undefined {
  const separator = value.indexOf("/");
  return separator > 0 && separator < value.length - 1 ? { provider: value.slice(0, separator), id: value.slice(separator + 1) } : undefined;
}

export interface QueueAvailability { role: ModelQueueRole; models: QueueModelState[] }

export interface ModelQueueRecord { event: "model-queue.skip"; role: ModelQueueRole; model: string; reason: string }

export interface ModelQueueOptions {
  runtime: ModelRuntime;
  usage: Pick<ProviderUsageOwner, "read">;
  /** The role's configured queue, `provider/id` in order (background already
   * resolved to the subagent queue when it has no value of its own). */
  queue(role: ModelQueueRole): Promise<readonly string[]>;
  /** Where children read the projection (`TRON_MODEL_QUEUE_PROJECTION`). */
  projectionPath?: string;
  log?: (record: ModelQueueRecord) => void;
  now?: () => number;
}

export class ModelQueueExhausted extends GatewayError {
  /** At least one exhausted model can recover when its plan limit clears, even if
   * other queue members need configuration repair. The caller must not stay blocked. */
  readonly limited: boolean;

  constructor(readonly role: ModelQueueRole, readonly models: QueueModelState[]) {
    super("conflict", exhaustedText(role, models), false, { role, models });
    this.limited = models.some(entry => !entry.available && isUsageLimitReason(entry.reason));
  }
}

export class ModelQueueOwner {
  private readonly records = new Map<string, { reason: string; until: number }>();
  private readonly now: () => number;
  private publishing: Promise<void> = Promise.resolve();

  constructor(private readonly options: ModelQueueOptions) { this.now = options.now ?? Date.now; }

  queue(role: ModelQueueRole): Promise<readonly string[]> { return this.options.queue(role); }

  async availability(role: ModelQueueRole, signal?: AbortSignal): Promise<QueueAvailability> {
    const queue = await this.options.queue(role);
    const usage = new Map<string, Promise<string | undefined>>();
    const usageSkip = (provider: string) => {
      if (!usage.has(provider)) usage.set(provider, this.usageSkip(provider, signal));
      return usage.get(provider)!;
    };
    const at = this.now();
    const models = await Promise.all(queue.map(async (model): Promise<QueueModelState> => {
      const ref = splitModelRef(model);
      const registered = ref ? this.options.runtime.getModel(ref.provider, ref.id) : undefined;
      const reason = !ref || !registered ? "not registered"
        : isVirtualModel(registered) ? "virtual model"
          : !await this.hasAuth(ref.provider) ? "no credentials"
            : this.recordFor(model, at) ?? await usageSkip(ref.provider);
      return reason ? { model, available: false, reason } : { model, available: true };
    }));
    return { role, models };
  }

  /** The first usable model, or the loud refusal that names every model and why. */
  async select(role: ModelQueueRole, signal?: AbortSignal): Promise<{ model: Model<Api>; availability: QueueAvailability }> {
    const availability = await this.availability(role, signal);
    const first = availability.models.find(entry => entry.available);
    if (!first) throw new ModelQueueExhausted(role, availability.models);
    const ref = splitModelRef(first.model)!;
    return { model: this.options.runtime.getModel(ref.provider, ref.id)!, availability };
  }

  recordUsageLimit(role: ModelQueueRole, model: string, reason: string): void {
    this.records.set(model, { reason, until: this.now() + RECORD_MS });
    this.options.log?.({ event: "model-queue.skip", role, model, reason });
    void this.publishProjection().catch(() => {});
  }

  /** One Gateway background completion along the role's queue: a usage-limit
   * error retries the same request on the next model; any other result returns. */
  async complete(role: ModelQueueRole, request: (model: Model<Api>) => { context: Context; options?: SimpleStreamOptions },
    signal?: AbortSignal): Promise<{ message: AssistantMessage; model: Model<Api> }> {
    const availability = await this.availability(role, signal);
    const states = availability.models.map(entry => ({ ...entry }));
    for (const entry of states) {
      if (!entry.available) {
        this.options.log?.({ event: "model-queue.skip", role, model: entry.model, reason: entry.reason ?? "unavailable" });
        continue;
      }
      const ref = splitModelRef(entry.model)!;
      const model = this.options.runtime.getModel(ref.provider, ref.id)!;
      const { context, options } = request(model);
      const message = await this.options.runtime.completeSimple(model, context, { ...options, ...(signal ? { signal } : {}) });
      if (message.stopReason === "error" && isUsageLimitError(message.errorMessage)) {
        const reason = usageLimitReason(message.errorMessage!);
        this.recordUsageLimit(role, entry.model, reason);
        Object.assign(entry, { available: false, reason });
        continue;
      }
      return { message, model };
    }
    throw new ModelQueueExhausted(role, states);
  }

  /** The in-process source a Home task worker's queue extension reads. */
  source(): ModelQueueSource {
    return {
      availability: async role => (await this.availability(role)).models,
      record: (role, model, reason) => this.recordUsageLimit(role, model, reason),
    };
  }

  /**
   * Publish what a subagent child needs: the subagent queue and the models
   * skipped now, each with an expiry. Called before every top-level subagent
   * launch and after every recorded failure; the file is a disposable projection
   * of this owner, never read back by the Gateway.
   */
  async publishProjection(): Promise<void> {
    const path = this.options.projectionPath;
    if (!path) return;
    const run = this.publishing.then(async () => {
      const availability = await this.availability("subagent").catch(() => undefined);
      const at = this.now();
      const unavailable: Record<string, { reason: string; until: number }> = {};
      for (const [model, record] of this.records) if (record.until > at) unavailable[model] = record;
      for (const entry of availability?.models ?? []) {
        if (!entry.available && !unavailable[entry.model]) unavailable[entry.model] = { reason: entry.reason ?? "unavailable", until: at + PROJECTED_USAGE_MS };
      }
      const document = JSON.stringify({ version: 1, queues: { subagent: availability?.models.map(entry => entry.model) ?? [] }, unavailable });
      if (Buffer.byteLength(document) > PROJECTION_BYTES) return;
      await mkdir(dirname(path), { recursive: true, mode: 0o700 });
      const temporary = `${path}.${process.pid}.tmp`;
      await writeFile(temporary, document, { mode: 0o600 });
      await rename(temporary, path);
    });
    this.publishing = run.catch(() => {});
    await run;
  }

  /** Pi's own admission test for a prompt: configured, else resolvable now. */
  private async hasAuth(provider: string): Promise<boolean> {
    if (this.options.runtime.hasConfiguredAuth(provider)) return true;
    try { return await this.options.runtime.checkAuth(provider) !== undefined; } catch { return false; }
  }

  private recordFor(model: string, at: number): string | undefined {
    const record = this.records.get(model);
    if (record && record.until <= at) this.records.delete(model);
    return record && record.until > at ? record.reason : undefined;
  }

  /** "Weekly usage 97%" when a fresh read puts any window at the threshold. */
  private async usageSkip(provider: string, signal?: AbortSignal): Promise<string | undefined> {
    try {
      const snapshot = (await this.options.usage.read(this.options.runtime, provider, signal)).providers[0];
      if (!snapshot || snapshot.status !== "available" || snapshot.stale) return undefined;
      const full = snapshot.windows.find(window => window.usedPercent !== null && window.usedPercent >= MODEL_QUEUE_SKIP_PERCENT);
      return full ? `${full.label} usage ${Math.round(full.usedPercent!)}%` : undefined;
    } catch {
      return undefined;
    }
  }
}
