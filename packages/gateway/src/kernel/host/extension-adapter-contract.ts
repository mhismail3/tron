import type { ExtensionFormAnswer, ExtensionFormDescriptor } from "../../protocol/types.js";

export const TRON_FORM_CAPABILITY = "tron.form.v1";

interface FormRequestInput {
  form: ExtensionFormDescriptor;
  signal?: AbortSignal;
}

export type FormRequest = (input: FormRequestInput) => Promise<ExtensionFormAnswer | undefined>;

export type FormCapableUI = { [TRON_FORM_CAPABILITY]?: FormRequest };
