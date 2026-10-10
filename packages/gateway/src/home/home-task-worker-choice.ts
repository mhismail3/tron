import type { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { getSupportedThinkingLevels, type ModelThinkingLevel } from "@earendil-works/pi-ai";
import { GatewayError } from "../errors.js";
import { isVirtualModel } from "../providers/virtual-model.js";

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
