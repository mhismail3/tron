import type { ResourceDistribution } from "../protocol/types.js";

export function resourceDistribution(sourceInfo: { source: string; origin?: "package" | "top-level" }): ResourceDistribution | undefined {
  if (sourceInfo.origin === "package") return "external";
  if (sourceInfo.source === "inline") return "module";
  if (sourceInfo.origin === "top-level"
    && (sourceInfo.source === "local" || sourceInfo.source === "auto" || sourceInfo.source === "cli")) return "local";
  return undefined;
}
