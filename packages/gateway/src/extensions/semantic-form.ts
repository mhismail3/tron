import { GatewayError } from "../errors.js";
import type {
  ExtensionFormAnswer,
  ExtensionFormDescriptor,
  ExtensionFormOption,
  ExtensionFormQuestion,
} from "../protocol/types.js";
import { stripTerminalControls } from "./host/terminal-sanitizer.js";

export const EXTENSION_FORM_VERSION = 1 as const;
export const EXTENSION_FORM_MAX_QUESTIONS = 4;
export const EXTENSION_FORM_MAX_OPTIONS = 4;
export const EXTENSION_FORM_MAX_HEADER_CHARS = 12;
export const EXTENSION_FORM_MAX_QUESTION_CHARS = 1_000;
export const EXTENSION_FORM_MAX_ID_BYTES = 256;
export const EXTENSION_FORM_MAX_TITLE_BYTES = 4 * 1_024;
export const EXTENSION_FORM_MAX_HEADER_BYTES = 256;
export const EXTENSION_FORM_MAX_QUESTION_BYTES = 4 * 1_024;
export const EXTENSION_FORM_MAX_CONTEXT_BYTES = 32 * 1_024;
export const EXTENSION_FORM_MAX_OPTION_BYTES = 2 * 1_024;
export const EXTENSION_FORM_MAX_OTHER_BYTES = 32 * 1_024;
export const EXTENSION_FORM_MAX_ANSWER_BYTES = 192 * 1_024;
export const EXTENSION_FORM_MAX_INTERACTION_BYTES = 192 * 1_024;

function bytes(value: unknown): number { return Buffer.byteLength(JSON.stringify(value), "utf8"); }
function unsafeControl(value: string, preserveNewlines = false): boolean {
  return stripTerminalControls(value, preserveNewlines) !== value;
}
function bounded(value: unknown, maximumBytes: number, preserveNewlines = false): value is string {
  return typeof value === "string"
    && wellFormedUTF16(value)
    && Buffer.byteLength(value, "utf8") <= maximumBytes
    && !unsafeControl(value, preserveNewlines);
}
function wellFormedUTF16(value: string): boolean {
  for (let index = 0; index < value.length; index += 1) {
    const unit = value.charCodeAt(index);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (index + 1 >= value.length) return false;
      const next = value.charCodeAt(index + 1);
      if (next < 0xdc00 || next > 0xdfff) return false;
      index += 1;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) return false;
  }
  return true;
}
function plain(value: string, preserveNewlines = false): string {
  return stripTerminalControls(value, preserveNewlines);
}

export function normalizeExtensionForm(input: ExtensionFormDescriptor): ExtensionFormDescriptor {
  const form: ExtensionFormDescriptor = {
    version: EXTENSION_FORM_VERSION,
    title: plain(input.title, true),
    allowCancel: input.allowCancel,
    questions: input.questions.map((question) => ({
      id: plain(question.id),
      ...(question.header === undefined ? {} : { header: plain(question.header) }),
      question: plain(question.question),
      ...(question.context === undefined ? {} : { context: plain(question.context, true) }),
      options: question.options.map((option) => ({
        id: plain(option.id),
        label: plain(option.label),
        ...(option.description === undefined ? {} : { description: plain(option.description, true) }),
      })),
      multiSelect: question.multiSelect,
      allowOther: question.allowOther,
    })),
  };
  assertExtensionForm(form);
  return form;
}

export function assertExtensionForm(value: unknown): asserts value is ExtensionFormDescriptor {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new GatewayError("conflict", "Extension form is malformed");
  }
  const form = value as ExtensionFormDescriptor;
  if (Object.keys(form).some((key) => key !== "version" && key !== "title" && key !== "questions" && key !== "allowCancel")
    || form.version !== EXTENSION_FORM_VERSION
    || typeof form.allowCancel !== "boolean"
    || !bounded(form.title, EXTENSION_FORM_MAX_TITLE_BYTES, true)
    || form.title.trim().length === 0
    || !Array.isArray(form.questions)
    || form.questions.length < 1
    || form.questions.length > EXTENSION_FORM_MAX_QUESTIONS) {
    throw new GatewayError("conflict", "Extension form is invalid");
  }
  const questionIDs = new Set<string>();
  const questionTexts = new Set<string>();
  const headers = new Set<string>();
  for (const question of form.questions) assertQuestion(question, form.questions.length, questionIDs, questionTexts, headers);
  if (bytes(form) > EXTENSION_FORM_MAX_INTERACTION_BYTES) {
    throw new GatewayError("busy", "Extension form reached its bounded capacity", true);
  }
}

function assertQuestion(
  value: unknown,
  questionCount: number,
  questionIDs: Set<string>,
  questionTexts: Set<string>,
  headers: Set<string>,
): asserts value is ExtensionFormQuestion {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new GatewayError("conflict", "Extension form question is malformed");
  const question = value as ExtensionFormQuestion;
  if (Object.keys(question).some((key) => !["id", "header", "question", "context", "options", "multiSelect", "allowOther"].includes(key))
    || !bounded(question.id, EXTENSION_FORM_MAX_ID_BYTES)
    || question.id.length === 0
    || questionIDs.has(question.id)
    || !bounded(question.question, EXTENSION_FORM_MAX_QUESTION_BYTES)
    || question.question.length === 0
    || question.question.length > EXTENSION_FORM_MAX_QUESTION_CHARS
    || questionTexts.has(question.question)
    || (question.context !== undefined && !bounded(question.context, EXTENSION_FORM_MAX_CONTEXT_BYTES, true))
    || typeof question.multiSelect !== "boolean"
    || typeof question.allowOther !== "boolean"
    || !Array.isArray(question.options)
    || question.options.length < 2
    || question.options.length > EXTENSION_FORM_MAX_OPTIONS) {
    throw new GatewayError("conflict", "Extension form question is invalid");
  }
  if (questionCount > 1) {
    if (!bounded(question.header, EXTENSION_FORM_MAX_HEADER_BYTES)
      || question.header.trim().length === 0
      || question.header.length > EXTENSION_FORM_MAX_HEADER_CHARS
      || headers.has(question.header.trim())) {
      throw new GatewayError("conflict", "Extension form question header is invalid");
    }
  } else if (question.header !== undefined && (!bounded(question.header, EXTENSION_FORM_MAX_HEADER_BYTES)
    || question.header.trim().length === 0 || question.header.length > EXTENSION_FORM_MAX_HEADER_CHARS)) {
    throw new GatewayError("conflict", "Extension form question header is invalid");
  }
  questionIDs.add(question.id);
  questionTexts.add(question.question);
  if (question.header !== undefined) headers.add(question.header.trim());
  const optionIDs = new Set<string>();
  const labels = new Set<string>();
  for (const option of question.options) assertOption(option, optionIDs, labels);
}

function assertOption(value: unknown, ids: Set<string>, labels: Set<string>): asserts value is ExtensionFormOption {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new GatewayError("conflict", "Extension form option is malformed");
  const option = value as ExtensionFormOption;
  if (Object.keys(option).some((key) => key !== "id" && key !== "label" && key !== "description")
    || !bounded(option.id, EXTENSION_FORM_MAX_ID_BYTES)
    || option.id.length === 0
    || ids.has(option.id)
    || !bounded(option.label, EXTENSION_FORM_MAX_OPTION_BYTES)
    || option.label.trim().length === 0
    || labels.has(option.label)
    || (option.description !== undefined && !bounded(option.description, EXTENSION_FORM_MAX_OPTION_BYTES, true))) {
    throw new GatewayError("conflict", "Extension form option is invalid");
  }
  ids.add(option.id);
  labels.add(option.label);
}

export function isExtensionForm(value: unknown): value is ExtensionFormDescriptor {
  try { assertExtensionForm(value); return true; } catch { return false; }
}

export function canonicalExtensionFormAnswer(value: unknown, form: ExtensionFormDescriptor): ExtensionFormAnswer {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw invalidAnswer();
  const answer = value as ExtensionFormAnswer;
  if (Object.keys(answer).some((key) => key !== "version" && key !== "answers")
    || answer.version !== EXTENSION_FORM_VERSION
    || !Array.isArray(answer.answers)
    || answer.answers.length !== form.questions.length
    || bytes(answer) > EXTENSION_FORM_MAX_ANSWER_BYTES) throw invalidAnswer();

  const byQuestion = new Map<string, { questionId: string; optionIds: string[]; other?: string }>();
  for (const item of answer.answers) {
    if (!item || typeof item !== "object" || Array.isArray(item)
      || Object.keys(item).some((key) => key !== "questionId" && key !== "optionIds" && key !== "other")
      || !bounded(item.questionId, EXTENSION_FORM_MAX_ID_BYTES)
      || !Array.isArray(item.optionIds)
      || !item.optionIds.every((id) => bounded(id, EXTENSION_FORM_MAX_ID_BYTES))
      || new Set(item.optionIds).size !== item.optionIds.length
      || (item.other !== undefined && (!bounded(item.other, EXTENSION_FORM_MAX_OTHER_BYTES, true) || item.other.trim().length === 0))
      || byQuestion.has(item.questionId)) throw invalidAnswer();
    byQuestion.set(item.questionId, item);
  }

  const canonical = form.questions.map((question) => {
    const item = byQuestion.get(question.id);
    if (!item) throw invalidAnswer();
    const optionOrder = new Map(question.options.map((option, index) => [option.id, index]));
    if (item.optionIds.some((id) => !optionOrder.has(id))
      || (!question.multiSelect && item.optionIds.length > 1)
      || (!question.multiSelect && item.optionIds.length > 0 && item.other !== undefined)
      || (item.other !== undefined && !question.allowOther)
      || (item.optionIds.length === 0 && item.other === undefined)) throw invalidAnswer();
    const optionIds = [...item.optionIds].sort((left, right) => optionOrder.get(left)! - optionOrder.get(right)!);
    return { questionId: question.id, optionIds, ...(item.other === undefined ? {} : { other: item.other }) };
  });
  const result: ExtensionFormAnswer = { version: EXTENSION_FORM_VERSION, answers: canonical };
  if (bytes(result) > EXTENSION_FORM_MAX_ANSWER_BYTES) throw invalidAnswer();
  return result;
}

function invalidAnswer(): GatewayError {
  return new GatewayError("invalid_request", "Extension form response is invalid");
}
