import type { ExtensionFormAnswer, ExtensionFormDescriptor } from "../protocol/types.js";

/**
 * Public Tron extension-host capability: one atomic multi-question form.
 *
 * Tron's host UI object (Pi's `ExtensionUIContext`) exposes this capability
 * under one exact versioned property key, so any installed extension can
 * feature-detect it without importing Tron internals. Presence of the property
 * *is* the capability signal; the request and answer shapes are the versioned
 * contract below. An extension that does not find it must fall back to Pi's
 * standard primitive dialogs rather than assuming the capability exists.
 *
 * The capability is presentation-only. The Gateway still owns the single
 * pending continuation, exact settlement, and retirement; a returned
 * `undefined` means no answer was admitted (explicit user cancellation, host
 * retirement, or abort), and the caller must never treat it as a decision.
 */
export const TRON_FORM_CAPABILITY = "tron.form.v1";

interface FormRequestInput {
  form: ExtensionFormDescriptor;
  signal?: AbortSignal;
}

export type FormRequest = (input: FormRequestInput) => Promise<ExtensionFormAnswer | undefined>;

/** A Pi UI context that advertises the Tron form capability. */
export type FormCapableUI = { [TRON_FORM_CAPABILITY]?: FormRequest };
