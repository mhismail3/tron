/**
 * API id of Pi's virtual (routed) catalog entries. Requests for it fail unless
 * a router resolved them to a physical model first, and the SDK's own
 * `isVirtualModel` helper is not re-exported from the pinned package root, so
 * the one check Tron needs is defined here against the same value.
 */
export const VIRTUAL_MODEL_API = "pi-virtual";

/** Whether a selected model is virtual rather than a fixed physical model. */
export function isVirtualModel(model: { api: string }): boolean {
  return model.api === VIRTUAL_MODEL_API;
}
