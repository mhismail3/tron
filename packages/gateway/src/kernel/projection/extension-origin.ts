import type { ExtensionOwner } from "../../protocol/types.js";

export function trustedExtensionOriginKind(owner: ExtensionOwner): "subagent" | "extension" {
  // Live admission and canonical receipt decoding supply the classification.
  // Build provenance is not a second consumer-side capability discriminator.
  return owner.kind ?? "extension";
}
