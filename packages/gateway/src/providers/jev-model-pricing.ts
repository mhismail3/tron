import type { AnyModel } from "@earendil-works/pi-ai";
import type { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { JEV_CLASSIFIER } from "../knowledge/jev-client.js";

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

/**
 * Tron-owned price metadata for TypeSafe's classifier, applied at the catalog
 * boundary before any consumer (including Pi extensions) resolves the model.
 * It changes only the returned catalog view, never Pi's persisted models.json.
 */
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
