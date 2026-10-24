import type { Diagnostic } from "../kernel/settings/tool-contract.js";
import type { SettingsSchema } from "./settings-schema.js";

/** An exact JSON path for applied values; diagnostics bound untrusted key names. */
export function projectSettingPath(parts: readonly string[]): string {
  return parts.map((part, index) => /^[A-Za-z_]\w*$/.test(part)
    ? `${index ? "." : ""}${part}` : `[${JSON.stringify(part)}]`).join("");
}

/** Report ignored fields without copying their values or descending into unknown
 * objects. Both traversal and output are bounded independently of repo content. */
export function projectSettingsDiagnostics(schema: SettingsSchema, raw: Record<string, unknown>, file: string): {
  diagnostics: Diagnostic[]; diagnosticsTruncated?: true;
} {
  const rules = schema.KEYS.flatMap(key => {
    const binding = key.layers.project ?? key.layers.global;
    const paths = binding?.store === "pi-model-ref" ? [["defaultProvider"], ["defaultModel"]]
      : binding?.store === "pi" ? [binding.path, ...(binding.qualified ? [binding.qualified] : [])] : [];
    return paths.map(path => ({ path, key: key.id, allowed: key.projectSettable }));
  });
  const diagnostics: Diagnostic[] = [];
  let visited = 0;
  let truncated = false;
  const walk = (value: unknown, path: readonly string[]): void => {
    if (diagnostics.length >= 32 || ++visited > 1024) { truncated = true; return; }
    const matching = rules.filter(rule => path.length <= rule.path.length
      && path.every((part, index) => rule.path[index] === part || rule.path[index] === "{model}"));
    const exact = matching.find(rule => rule.path.length === path.length);
    if (exact?.allowed) return;
    if (!exact && matching.length && value && typeof value === "object" && !Array.isArray(value)) {
      for (const name in value) {
        if (truncated) break;
        if (Object.hasOwn(value, name)) walk((value as Record<string, unknown>)[name], [...path, name]);
      }
      return;
    }
    const fullPath = projectSettingPath(path);
    const boundedPath = fullPath.length > 256 ? `${fullPath.slice(0, 256)}…` : fullPath;
    diagnostics.push({ file, layer: "project", key: exact?.key ?? boundedPath, path: boundedPath,
      reason: exact ? "project-forbidden" : "unknown-key" });
  };
  for (const name in raw) {
    if (truncated) break;
    if (Object.hasOwn(raw, name)) walk(raw[name], [name]);
  }
  return { diagnostics, ...(truncated ? { diagnosticsTruncated: true } : {}) };
}
