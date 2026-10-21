import type { KeyDeclaration } from "./settings-schema.js";

/** Bindings describe storage, not permission. The two declaration booleans are
 * the grant; all consumers receive this derived, admitted binding projection. */
export function admitKey(key: KeyDeclaration): KeyDeclaration {
  const layers = { ...key.layers };
  if (!key.projectSettable) delete layers.project;
  if (!key.sessionOverridable) { delete layers.chat; delete layers.profile; }
  return { ...key, layers };
}
