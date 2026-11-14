import { GatewayError } from "../../errors.js";
import { boolean, integer, object, string } from "../../util/validation.js";
import { refuseSetting as refuse, secretFreeText, secretFreeUrl } from "./secret-free.js";
import type { Direction } from "./tool-contract.js";
import type { ValueType } from "./settings-types.js";

const HINT = "provider credentials and request options are set in models.json or the app, never through settings";
const FIELDS = ["baseUrl", "api", "name", "models"] as const;
const MODEL_FIELDS = ["id", "name", "reasoning", "input", "contextWindow", "maxTokens"] as const;
const MODALITIES = ["text", "image"] as const;
const MAX_MODELS = 500;

export type ModelProviderModality = typeof MODALITIES[number];

export interface ModelProviderModel {
  id: string;
  name?: string;
  reasoning?: boolean;
  input?: ModelProviderModality[];
  contextWindow?: number;
  maxTokens?: number;
}

export interface ModelProviderValue {
  baseUrl: string;
  api: string;
  name?: string;
  models?: ModelProviderModel[];
}

function validateModel(raw: unknown, label: string): ModelProviderModel {
  const model = object(raw, label);
  if (Object.keys(model).some(name => !(MODEL_FIELDS as readonly string[]).includes(name))) {
    refuse(label, `carries a field that is not a model setting here; ${HINT}`);
  }
  const result: ModelProviderModel = { id: secretFreeText(string(model.id, `${label}.id`, { max: 256 }), label, "model id", HINT) };
  if (model.name !== undefined) result.name = secretFreeText(string(model.name, `${label}.name`, { max: 120 }), label, "model name", HINT);
  if (model.reasoning !== undefined) result.reasoning = boolean(model.reasoning, `${label}.reasoning`);
  if (model.input !== undefined) {
    if (!Array.isArray(model.input) || model.input.length === 0 || model.input.length > MODALITIES.length) {
      refuse(label, "input must list text, image, or both");
    }
    const modalities = model.input.map(item => {
      if (!(MODALITIES as readonly unknown[]).includes(item)) refuse(label, "input must list text or image only");
      return item as ModelProviderModality;
    });
    if (new Set(modalities).size !== modalities.length) refuse(label, "input must not repeat a modality");
    result.input = modalities;
  }
  if (model.contextWindow !== undefined) result.contextWindow = integer(model.contextWindow, `${label}.contextWindow`, 1, 10_000_000);
  if (model.maxTokens !== undefined) result.maxTokens = integer(model.maxTokens, `${label}.maxTokens`, 1, 10_000_000);
  return result;
}

export function validateModelProviderValue(value: unknown, label: string): ModelProviderValue {
  const raw = object(value, label);
  if (Object.keys(raw).some(name => !(FIELDS as readonly string[]).includes(name))) {
    refuse(label, `carries a field that is not a provider setting here; ${HINT}`);
  }
  const baseUrl = secretFreeUrl(string(raw.baseUrl, `${label}.baseUrl`, { max: 4_096 }), `${label}.baseUrl`, HINT);
  const api = string(raw.api, `${label}.api`, { max: 64 });
  if (!/^[a-z][a-z0-9-]*$/u.test(api)) refuse(label, "api must be a provider API name such as openai-completions");
  const result: ModelProviderValue = { baseUrl, api };
  if (raw.name !== undefined) result.name = secretFreeText(string(raw.name, `${label}.name`, { max: 120 }), label, "name", HINT);
  if (raw.models !== undefined) {
    if (!Array.isArray(raw.models) || raw.models.length > MAX_MODELS) refuse(label, `models must be a list of at most ${MAX_MODELS} models`);
    const models = raw.models.map((model, index) => validateModel(model, `${label}.models[${index}]`));
    if (new Set(models.map(model => model.id)).size !== models.length) refuse(label, "models must have unique ids");
    result.models = models;
  }
  return result;
}

export function modelProviderOnDisk(id: string, raw: unknown): ModelProviderValue {
  try {
    return validateModelProviderValue(raw, `Custom model provider ${id}`);
  } catch (error) {
    const reason = error instanceof Error ? error.message.replace(/^Custom model provider \S+ /u, "") : "cannot be read";
    throw new GatewayError("conflict", `Custom model provider ${id} cannot be changed here: its configuration ${reason}; edit models.json or use the app`);
  }
}

export function modelProviderDirection(before: unknown, after: unknown): Direction {
  if (after === undefined) return "narrow";
  if (before === undefined) return "widen";
  const was = before as ModelProviderValue;
  const now = after as ModelProviderValue;
  return was.baseUrl === now.baseUrl && was.api === now.api ? "narrow" : "widen";
}

export const modelProviderType: ValueType = {
  kind: "modelProvider",
  validate: (value, label) => validateModelProviderValue(value, label),
  format: value => {
    const provider = value as ModelProviderValue;
    const models = provider.models ? `${provider.models.length} model${provider.models.length === 1 ? "" : "s"}` : undefined;
    return [provider.name, provider.baseUrl, provider.api, models].filter(Boolean).join(", ");
  },
};
