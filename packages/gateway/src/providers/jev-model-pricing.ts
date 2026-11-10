import type { AnyModel } from "../kernel/pi/ai.js";
import type { ModelRuntime } from "../kernel/pi/coding-agent.js";

export const JEV_CLASSIFIER = { provider: "typesafe", model: "jev-latest", inputUsdPerMillion: 0.042, outputUsdPerMillion: 0 } as const;

function withJevEstimate(model: AnyModel): AnyModel {
  if (model.type !== "classifier" || model.provider !== JEV_CLASSIFIER.provider || model.id !== JEV_CLASSIFIER.model) return model;
  return {
    ...model,
    cost: {
      input: JEV_CLASSIFIER.inputUsdPerMillion,
      output: JEV_CLASSIFIER.outputUsdPerMillion,
      cacheRead: 0,
      cacheWrite: 0,
    },
  } as AnyModel;
}

function withJevEstimateList<T extends AnyModel>(models: readonly T[]): readonly T[] {
  return models.map((model) => withJevEstimate(model) as T);
}

export function applyJevModelPricing(runtime: ModelRuntime): ModelRuntime {
  const wrapped = new Set(["getModelOfType", "getModelsOfType", "getAllModels", "getAllAvailable", "getAvailableOfType"]);
  return new Proxy(runtime, {
    get(target, property) {
      const value = Reflect.get(target, property, target) as unknown;
      if (typeof property !== "string" || !wrapped.has(property) || typeof value !== "function") return value;
      return (...args: unknown[]) => {
        const result = Reflect.apply(value, target, args) as unknown;
        const transform = (models: unknown): unknown => {
          if (Array.isArray(models)) return withJevEstimateList(models as AnyModel[]);
          if (models && typeof models === "object" && "provider" in models && "id" in models && "cost" in models) {
            return withJevEstimate(models as AnyModel);
          }
          return models;
        };
        return result instanceof Promise ? result.then(transform) : transform(result);
      };
    },
  });
}
