import type { ExtensionFormAnswer, ExtensionFormDescriptor } from "../protocol/types.js";

/** Non-public host seam used only by exact, provenance-checked extension adapters. */
export const TRON_FORM_REQUEST = Symbol("tron.extension.form.request");

export type FormRequest = (input: {
  form: ExtensionFormDescriptor;
  signal?: AbortSignal;
  timeout?: number;
  presented?: () => void | Promise<void>;
}) => Promise<ExtensionFormAnswer | undefined>;
