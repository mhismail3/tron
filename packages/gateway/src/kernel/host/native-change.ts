import type { ExtensionContext } from "../pi/coding-agent.js";
import type { ConfirmChange } from "../settings/tool-contract.js";
import { TRON_CHANGE_CAPABILITY, type ChangeCapableUI } from "./extension-adapter-contract.js";

/** Generic forms never grant authority. This server-installed port binds a typed effect to one exact native card. */
export function nativeChangeConfirmer(context: Pick<ExtensionContext, "hasUI" | "ui">, signal?: AbortSignal): ConfirmChange | undefined {
  const request = context.hasUI ? (context.ui as ChangeCapableUI)[TRON_CHANGE_CAPABILITY] : undefined;
  return request ? (review, apply) => request({ review, apply, ...(signal ? { signal } : {}) }) : undefined;
}
