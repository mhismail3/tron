import type { LayerId, SettingsTarget, Qualifiers } from "./tool-contract.js";
import type { StoreLayer } from "./settings-types.js";

/** Storage paths remain available to the SDK and historical undo. Grants are
 * checked independently, before values enter resolution or a new mutation. */
export function scopeAdmitted(key: { projectSettable: boolean; sessionOverridable: boolean }, layer: StoreLayer): boolean {
  return layer === "project" ? key.projectSettable : layer === "session" || layer === "home" ? key.sessionOverridable : true;
}

export function scopeForStore(layer: StoreLayer): LayerId {
  return layer === "project" ? "project" : layer === "session" || layer === "home" ? "session" : "global";
}

export function storeForScope(scope: LayerId, layers: readonly StoreLayer[]): Exclude<StoreLayer, "default"> {
  return scope === "session" && layers.includes("home") ? "home" : scope;
}

export function canonicalSettingsTarget(target: SettingsTarget, home: boolean): SettingsTarget {
  return home && target.kind === "session" ? { kind: "home" } : target;
}

export function instanceId(key: string, qualifiers: Qualifiers | undefined): string {
  const sorted = Object.fromEntries(Object.entries(qualifiers ?? {}).sort(([left], [right]) => left.localeCompare(right)));
  return `${key}\u0000${JSON.stringify(sorted)}`;
}
