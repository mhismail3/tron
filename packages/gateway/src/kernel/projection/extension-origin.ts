import type { ExtensionOwner } from "../../protocol/types.js";

export function trustedExtensionOriginKind(owner: ExtensionOwner): "subagent" | "extension" {
  return owner.kind ?? "extension";
}
