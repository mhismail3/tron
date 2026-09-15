import type { ExtensionFormAnswer, ExtensionFormDescriptor } from "../protocol/types.js";

/** Non-public host seam for Tron-owned semantic form producers and the exact,
 * provenance-checked foreign compatibility adapter. */
export const TRON_FORM_REQUEST = Symbol("tron.extension.form.request");

export type FormRequest = (input: {
  form: ExtensionFormDescriptor;
  signal?: AbortSignal;
  timeout?: number;
}) => Promise<ExtensionFormAnswer | undefined>;
