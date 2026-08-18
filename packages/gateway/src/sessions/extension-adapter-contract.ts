import type { ExtensionQuestionnaireDescriptor } from "../protocol/types.js";

/** Non-public host seam used only by explicit Gateway extension adapters. */
export const TRON_QUESTIONNAIRE_REQUEST = Symbol.for("tron.extension.questionnaire.request");

export type QuestionnaireRequest = (input: {
  title: string;
  method?: "select" | "input";
  primitiveOptions?: string[];
  placeholder?: string;
  question: string;
  context?: string;
  options: ExtensionQuestionnaireDescriptor["options"];
  allowMultiple: boolean;
  allowFreeform: boolean;
  signal?: AbortSignal;
  timeout?: number;
}) => Promise<unknown>;
