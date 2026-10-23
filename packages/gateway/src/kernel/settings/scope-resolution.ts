import type { LayerId, SettingsTarget } from "./tool-contract.js";
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
