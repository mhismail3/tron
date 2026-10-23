import type { ModelRuntime } from "../../kernel/pi/coding-agent.js";
import { clampThinkingLevel, getSupportedThinkingLevels, type Api, type Model, type ModelThinkingLevel } from "../../kernel/pi/ai.js";
import { GatewayError } from "../../errors.js";
import { isVirtualModel } from "../../providers/virtual-model.js";
import { ModelQueueExhausted, type ModelQueueOwner } from "../../providers/model-queue.js";
import { splitModelRef } from "../../kernel/settings/tool-contract.js";
import { SUBAGENT_QUEUE_MODEL, type QueueModelState } from "../../providers/model-queue-extension.js";
import type { SettingsModel } from "../../admin/settings-model.js";
import type { SessionSnapshot } from "../../protocol/types.js";
import type { HomeOwner } from "./home-owner.js";
import type { HomeTaskDispatchRequest } from "./home-task-dispatcher.js";

/** The thinking levels a delegation may name: the set the slot's `setThinking` accepts. */
export const HOME_TASK_THINKING_LEVELS: readonly ModelThinkingLevel[] = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];

/** A refusal lists at most this many valid models, so the Home tool error stays bounded. */
const VALID_MODEL_LIMIT = 20;

/** The model and thinking level a delegation chooses for its worker. Both are optional;
 * an omitted model keeps the worker session's default, and a thinking level needs a model. */
export interface HomeTaskWorkerChoice {
  model?: { provider: string; id: string };
  thinking?: ModelThinkingLevel;
}

/** Validates a delegation's choice against the Gateway's model runtime, before any task
 * record or worker session exists. A virtual model is refused by the same rule as Home's
 * designation: routing runs on the canonical transcript, which a worker does not own. A
 * registered model without credentials is refused too, since the worker's own model
 * change would be refused only after its session exists. */
export async function admitTaskWorkerChoice(runtime: ModelRuntime | undefined, choice: HomeTaskWorkerChoice): Promise<HomeTaskWorkerChoice> {
  if (choice.model === undefined) {
    if (choice.thinking !== undefined) {
      throw refusal("thinking-requires-model", "thinking needs a model: name the model the worker runs with, or omit thinking to keep the Gateway default");
    }
    // An omitted choice validates nothing, so it needs no model runtime.
    return {};
  }
  if (!runtime) throw new GatewayError("unsupported", "Task worker models need the Gateway model runtime");
  const { provider, id } = choice.model;
  if (typeof provider !== "string" || typeof id !== "string" || !provider || !id) {
    throw new GatewayError("invalid_request", "model needs a provider and an id", false, { reason: "invalid-model" });
  }
  const reference = `${provider}/${id}`;
  const model = runtime.getModel(provider, id);
  if (!model) {
    throw refusal("unregistered-model", `Model ${reference} is not registered. ${await validModelReferences(runtime)}`);
  }
  if (isVirtualModel(model)) {
    throw refusal("virtual-model", `Model ${reference} is virtual; a task worker needs a fixed physical model. ${await validModelReferences(runtime)}`);
  }
  if (!(await runtime.checkAuth(provider))) {
    throw refusal("unavailable-model", `Model ${reference} has no usable credentials. ${await validModelReferences(runtime)}`);
  }
  if (choice.thinking !== undefined) {
    const levels = getSupportedThinkingLevels(model);
    if (!levels.includes(choice.thinking)) {
      throw refusal("unsupported-thinking", `Model ${reference} does not support thinking level "${choice.thinking}". Supported levels: ${levels.join(", ")}.`, { thinkingLevels: levels });
    }
  }
  return { model: { provider, id }, ...(choice.thinking === undefined ? {} : { thinking: choice.thinking }) };
}

function refusal(reason: string, message: string, details: Record<string, unknown> = {}): GatewayError {
  return new GatewayError("invalid_request", message, false, { reason, ...details });
}

/** The models a choice would be accepted for: fixed and usable. The catalog holds
 * far more models than a refusal can name, so the list is a bounded sample. */
async function validModelReferences(runtime: ModelRuntime): Promise<string> {
  const references = (await runtime.getAllAvailable())
    .filter(model => !isVirtualModel(model))
    .slice(0, VALID_MODEL_LIMIT)
    .map(model => `${model.provider}/${model.id}`);
  return references.length ? `Valid models: ${references.join(", ")}.` : "No valid model is available.";
}

/** The generic reads Home's worker choice needs (the registry supplies them). */
export interface HomeWorkerChoicePort {
  settings(): Pick<SettingsModel, "resolve"> | undefined;
  homeRuntime(sessionId: string): Promise<Pick<SessionSnapshot, "model" | "thinkingLevel">>;
  modelQueues(): Promise<{ worker: string[]; subagent: string[] }>;
  availability(role: "worker" | "subagent", signal: AbortSignal | undefined, queue: string[]): ReturnType<ModelQueueOwner["availability"]> | undefined;
  model(provider: string, id: string): Model<Api> | undefined;
}

/** Home resolves its typed worker profile at the delegate boundary: the first
 * available model of the worker queue (settings-model.md 6.3), else Home's own
 * model when the queue is empty. The selected values are copied into this task
 * only; later Home/profile changes cannot retarget it. The worker queue's and
 * subagent queue's availability is returned to Home and written into the brief. */
export async function dispatchWithWorkerChoice(owner: Pick<HomeOwner, "dispatchTask">, ports: HomeWorkerChoicePort,
  sessionId: string, request: HomeTaskDispatchRequest, signal?: AbortSignal) {
  if ((request.model !== undefined || request.thinking !== undefined) && !request.reason?.trim()) {
    throw new GatewayError("invalid_request", "An explicit worker model or thinking choice needs a short reason");
  }
  const settings = ports.settings();
  const home = await ports.homeRuntime(sessionId);
  const resolution = settings ? await settings.resolve({ kind: "home" }, undefined, ["model.thinking[role=worker]"]) : undefined;
  const profileThinking = resolution?.keys.find(key => key.key === "model.thinking[role=worker]")?.value as
    string | { sameAs: "home" } | undefined;
  const modelQueues = await ports.modelQueues();
  const workerQueue = request.model === undefined ? await ports.availability("worker", signal, modelQueues.worker) : undefined;
  const subagentQueue = await ports.availability("subagent", signal, modelQueues.subagent);
  const queued = workerQueue && workerQueue.models.length > 0 ? workerQueue.models : undefined;
  const first = queued?.find(entry => entry.available);
  if (queued && !first) throw new ModelQueueExhausted("worker", queued);
  const candidateModel = request.model ?? (first ? splitModelRef(first.model) : home.model);
  const candidateThinking = request.thinking ?? (typeof profileThinking === "string" ? profileThinking : home.thinkingLevel);
  const choice: HomeTaskWorkerChoice = {
    ...(candidateModel ? { model: candidateModel } : {}),
    ...(candidateThinking && candidateModel ? { thinking: candidateThinking as NonNullable<HomeTaskWorkerChoice["thinking"]> } : {}),
  };
  let clampNote: string | undefined;
  if (choice.model) {
    const model = ports.model(choice.model.provider, choice.model.id);
    const supported = model ? getSupportedThinkingLevels(model) : [];
    if (choice.thinking && model && supported.length) {
      const requested = choice.thinking;
      choice.thinking = clampThinkingLevel(model, requested);
      if (choice.thinking !== requested) clampNote = `${requested} clamped to ${choice.thinking}`;
    }
  }
  const skipped = (models: readonly QueueModelState[]) => models.filter(entry => !entry.available)
    .map(entry => `${entry.model} skipped: ${entry.reason ?? "unavailable"}`);
  const modelText = choice.model ? `${choice.model.provider}/${choice.model.id}` : "Gateway default";
  const thinkingText = choice.thinking ?? "Gateway default";
  const explicitReason = request.model || request.thinking ? request.reason!.trim() : undefined;
  const modelSource = request.model ? `explicit: ${explicitReason}`
    : queued ? ["worker queue", ...skipped(queued.slice(0, queued.indexOf(first!)))].join("; ") : "same as Home";
  const thinkingSource = request.thinking ? `explicit: ${explicitReason}`
    : typeof profileThinking === "string" ? "Home profile" : "same as Home";
  const choiceNotes = [clampNote].filter(Boolean).join("; ");
  const subagentModels = subagentQueue?.models.length ? subagentQueue.models : undefined;
  const subagentLine = subagentModels
    ? `\n\nSubagent models, in fallback order: ${subagentModels.map(entry => entry.available ? `${entry.model} (available)` : `${entry.model} (skipped: ${entry.reason ?? "unavailable"})`).join(", ")}. Explicit eligible subagent model choices in this brief take precedence over the default queue: pass the chosen provider/model to the subagent launch. Otherwise, launch subagents with model ${SUBAGENT_QUEUE_MODEL.provider}/${SUBAGENT_QUEUE_MODEL.id}: it runs the first available one and moves along this queue on a usage-limit error. If an explicit choice is unavailable or hits a usage limit, disclose the reason and the chosen fallback; do not silently substitute the queue default.`
    : "";
  const brief = `${request.intent}\n\nWorker choice: model ${modelText} (${modelSource}); thinking ${thinkingText} (${thinkingSource})${choiceNotes ? `; ${choiceNotes}` : ""}.${subagentLine}`;
  const { model: _model, thinking: _thinking, ...input } = request;
  const worker = { model: modelText, thinking: thinkingText, modelSource, thinkingSource, ...(choiceNotes ? { note: choiceNotes } : {}),
    ...(queued ? { queue: queued } : {}) };
  const handle = await owner.dispatchTask(sessionId, { ...input, ...choice, modelQueues, intent: brief,
    provenance: {
      model: { via: request.model ? "home-explicit" : queued ? "home-profile" : "home-profile:sameAs:home", reason: modelSource },
      thinking: { via: request.thinking ? "home-explicit" : typeof profileThinking === "string" ? "home-profile" : "home-profile:sameAs:home", reason: [thinkingSource, clampNote].filter(Boolean).join("; ") },
    } }, signal);
  return { ...handle, worker, ...(subagentModels ? { subagentModels } : {}) };
}

/** Admits a delegation's model and thinking level against the Gateway's own model
 * runtime, the one designation validates against. Read-only. */
