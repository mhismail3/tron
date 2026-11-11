import { createHash } from "node:crypto";
import { pathToFileURL } from "node:url";
import { mkdir, rename, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import type { ModelRuntime } from "../kernel/pi/coding-agent.js";
import type { Api, AssistantMessage, Context, Model, SimpleStreamOptions } from "../kernel/pi/ai.js";
import { GatewayError } from "../errors.js";
import { splitModelRef } from "../kernel/settings/tool-contract.js";
import type { ProviderUsageOwner } from "./provider-usage.js";
import { isVirtualModel } from "./virtual-model.js";
import {
  exhaustedText, isUsageLimitError, isUsageLimitReason, usageLimitReason,
  type ModelQueueRole, type ModelQueueSource, type QueueModelState,
} from "./model-queue-extension.js";
import { tronHomePath } from "../foundation/tron-home-layout.js";
import { ModelUsageLedger, ModelUsageLedgerError, type ModelUsageCaller, type ModelUsageIdentity } from "./model-usage-ledger.js";

const MODEL_QUEUE_SKIP_PERCENT = 95;
const RECORD_MS = 15 * 60_000;
const PROJECTED_USAGE_MS = 10 * 60_000;
const PROJECTION_BYTES = 64 * 1024;

export function modelQueueProjectionPath(tronHome: string): string { return tronHomePath(tronHome, "gateway/model-queue.json"); }

function modelQueueSessionProjectionPath(base: string, sessionId: string): string {
  return join(dirname(base), "model-queue-sessions", `${createHash("sha256").update(sessionId).digest("hex")}.json`);
}

async function writeProjectionFile(path: string, contents: string): Promise<void> {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = `${path}.${process.pid}.tmp`;
  try {
    await writeFile(temporary, contents, { mode: 0o600 });
    await rename(temporary, path);
  } finally { await rm(temporary, { force: true }); }
}


interface QueueAvailability { role: ModelQueueRole; models: QueueModelState[] }

export type ModelQueueRecord =
  | { event: "model-queue.usage-failed"; code: ModelUsageLedgerError["code"] }
  | { event: "model-queue.skip"; role: ModelQueueRole; model: string; reason: string }
  | { event: "model-queue.projection"; role: "subagent"; scope: "global" | "task-launch"; sessionId?: string;
      status: "published"; models: readonly string[] }
  | { event: "model-queue.projection"; role: "subagent"; scope: "global" | "task-launch"; sessionId?: string;
      status: "failed"; reason: string };

export interface ModelQueueOptions {
  tronHome: string;
  runtime: ModelRuntime;
  usage: Pick<ProviderUsageOwner, "read">;
  queue(role: ModelQueueRole): Promise<readonly string[]>;
  projectionPath?: string;
  log?: (record: ModelQueueRecord) => void;
  now?: () => number;
}

export class ModelQueueExhausted extends GatewayError {
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
  private readonly usageLedger: ModelUsageLedger;

  constructor(private readonly options: ModelQueueOptions) {
    this.now = options.now ?? Date.now;
    this.usageLedger = new ModelUsageLedger(options.tronHome, this.now);
  }

  async initialize(): Promise<void> {
    await this.withUsageLedger(() => this.usageLedger.initialize());
  }

  queue(role: ModelQueueRole): Promise<readonly string[]> { return this.options.queue(role); }

  async availability(role: ModelQueueRole, signal?: AbortSignal, selected?: readonly string[]): Promise<QueueAvailability> {
    const queue = selected ?? await this.options.queue(role);
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

  async complete(role: ModelQueueRole, request: (model: Model<Api>) => { context: Context; options?: SimpleStreamOptions },
    attribution: { caller: ModelUsageCaller; kind: ModelUsageIdentity["kind"] },
    signal?: AbortSignal, selected?: readonly string[]): Promise<{ message: AssistantMessage; model: Model<Api> }> {
    const availability = await this.availability(role, signal, selected);
    const states = availability.models.map(entry => ({ ...entry }));
    for (const entry of states) {
      if (!entry.available) {
        this.options.log?.({ event: "model-queue.skip", role, model: entry.model, reason: entry.reason ?? "unavailable" });
        continue;
      }
      const ref = splitModelRef(entry.model)!;
      const model = this.options.runtime.getModel(ref.provider, ref.id)!;
      const identity: ModelUsageIdentity = { provider: model.provider, model: model.id, role, kind: attribution.kind,
        caller: "sessionId" in attribution.caller ? { sessionId: attribution.caller.sessionId } : { taskId: attribution.caller.taskId } };
      const { context, options } = request(model);
      await this.withUsageLedger(() => this.usageLedger.check(identity));
      let message: AssistantMessage;
      try {
        message = await this.options.runtime.completeSimple(model, context, { ...options, ...(signal ? { signal } : {}) });
      } catch (error) {
        await this.withUsageLedger(() => this.usageLedger.record(identity, "threw"), true);
        throw error;
      }
      await this.withUsageLedger(() => this.usageLedger.record(identity, message.stopReason, message.usage), true);
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

  source(selection?: (role: ModelQueueRole) => readonly string[] | undefined): ModelQueueSource {
    return {
      availability: async role => (await this.availability(role, undefined, selection?.(role))).models,
      record: (role, model, reason) => this.recordUsageLimit(role, model, reason),
    };
  }

  async publishProjection(task?: { sessionId: string; queue: readonly string[] }): Promise<void> {
    const base = this.options.projectionPath;
    if (!base) return;
    const path = task ? modelQueueSessionProjectionPath(base, task.sessionId) : base;
    const run = this.publishing.then(async () => {
      const availability = await this.availability("subagent", undefined, task?.queue);
      const at = this.now();
      const unavailable: Record<string, { reason: string; until: number }> = {};
      for (const entry of availability.models) if (!entry.available) {
        const record = this.records.get(entry.model);
        unavailable[entry.model] = record && record.until > at ? record
          : { reason: entry.reason ?? "unavailable", until: at + PROJECTED_USAGE_MS };
      }
      const document = JSON.stringify({ version: 1, queues: { subagent: availability.models.map(entry => entry.model) }, unavailable });
      if (Buffer.byteLength(document) > PROJECTION_BYTES) throw new GatewayError("conflict", "Model queue projection exceeds its byte limit");
      await writeProjectionFile(path, document);
      this.options.log?.({ event: "model-queue.projection", role: "subagent", scope: task ? "task-launch" : "global",
        ...(task ? { sessionId: task.sessionId } : {}), status: "published", models: availability.models.map(entry => entry.model) });
    });
    this.publishing = run.catch(() => {});
    try { await run; }
    catch (error) {
      const code = error && typeof error === "object" && "code" in error ? String(error.code) : "unknown";
      this.options.log?.({ event: "model-queue.projection", role: "subagent", scope: task ? "task-launch" : "global",
        ...(task ? { sessionId: task.sessionId } : {}), status: "failed", reason: code });
      throw error;
    }
  }

  async taskChildExtension(sessionId: string, implementation: string): Promise<string> {
    const base = this.options.projectionPath;
    if (!base) throw new GatewayError("unsupported", "Task child queues require a projection directory");
    const projection = modelQueueSessionProjectionPath(base, sessionId);
    const module = `${projection}.ts`;
    const contents = `import { createModelQueueExtension, projectionSource } from ${JSON.stringify(pathToFileURL(implementation).href)};\nexport default createModelQueueExtension("subagent", projectionSource(${JSON.stringify(projection)}), { virtualModel: true });\n`;
    const publishing = this.publishing.then(() => writeProjectionFile(module, contents));
    this.publishing = publishing.catch(() => {});
    await publishing;
    return module;
  }

  async releaseTaskProjection(sessionId: string): Promise<void> {
    const base = this.options.projectionPath;
    if (!base) return;
    const path = modelQueueSessionProjectionPath(base, sessionId);
    const release = this.publishing.then(async () => {
      await Promise.all([rm(path, { force: true }), rm(`${path}.ts`, { force: true })]);
    });
    this.publishing = release.catch(() => {});
    await release;
  }

  private async withUsageLedger(action: () => Promise<void>, completed = false): Promise<void> {
    try { await action(); }
    catch (error) {
      if (error instanceof ModelUsageLedgerError) {
        this.options.log?.({ event: "model-queue.usage-failed", code: error.code });
        if (completed) return;
      }
      throw error;
    }
  }

  private async hasAuth(provider: string): Promise<boolean> {
    if (this.options.runtime.hasConfiguredAuth(provider)) return true;
    try { return await this.options.runtime.checkAuth(provider) !== undefined; } catch { return false; }
  }

  private recordFor(model: string, at: number): string | undefined {
    const record = this.records.get(model);
    if (record && record.until <= at) this.records.delete(model);
    return record && record.until > at ? record.reason : undefined;
  }

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
