import type { ExtensionContext } from "../pi/coding-agent.js";
import type { ConfirmChange } from "../settings/tool-contract.js";

/** Internal host port, passed only to Tron module factories, never extension UI. */
export type NativeChangeRequest = <T>(input: {
  review: import("../../protocol/types.js").ChangeReview;
  apply: (acceptance: import("../../protocol/types.js").NativeChangeAcceptance) => Promise<T>;
  signal?: AbortSignal;
}) => Promise<T | undefined>;

/** Generic extension dialogs/forms never grant authority. */
export function nativeChangeConfirmer(context: Pick<ExtensionContext, "hasUI">, request: NativeChangeRequest, signal?: AbortSignal): ConfirmChange | undefined {
  return context.hasUI ? (review, apply) => request({ review, apply, ...(signal ? { signal } : {}) }) : undefined;
}
