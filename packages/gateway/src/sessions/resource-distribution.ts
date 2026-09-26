import type { ResourceDistribution } from "../protocol/types.js";

/**
 * Derives the wire `distribution` tag for one available resource from Pi's
 * `sourceInfo`. This is the single classification rule for every tool, skill,
 * prompt and command row:
 * - `origin === "package"` is `external` (an installed package's resource);
 * - `source === "inline"` is `module` (a Tron extension factory);
 * - `origin === "top-level"` with a `local`, `auto` or `cli` source is `local`
 *   (a user- or project-authored file);
 * - Pi built-ins (`builtin`) and SDK tools (`sdk`) carry no tag.
 * Pi's own `origin` keeps its `package`/`top-level` meaning and is projected
 * unchanged beside this tag.
 */
export function resourceDistribution(sourceInfo: { source: string; origin?: "package" | "top-level" }): ResourceDistribution | undefined {
  if (sourceInfo.origin === "package") return "external";
  if (sourceInfo.source === "inline") return "module";
  if (sourceInfo.origin === "top-level"
    && (sourceInfo.source === "local" || sourceInfo.source === "auto" || sourceInfo.source === "cli")) return "local";
  return undefined;
}
