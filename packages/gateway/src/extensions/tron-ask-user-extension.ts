import { Box, Text, TruncatedText, truncateToWidth } from "@earendil-works/pi-tui";
import { Type } from "@earendil-works/pi-ai";
import type { ExtensionFactory, ToolDefinition } from "@earendil-works/pi-coding-agent";
import type {
  ExtensionFormAnswer,
  ExtensionFormDescriptor,
  JsonValue,
} from "../protocol/types.js";
import { TRON_FORM_CAPABILITY } from "../sessions/extension-adapter-contract.js";
import type { FormCapableUI } from "../sessions/extension-adapter-contract.js";

export { TRON_ASK_USER_INLINE_PATH, TRON_ASK_USER_SOURCE } from "./tron-ask-user-contract.js";
import { TRON_ASK_USER_INLINE_PATH, TRON_ASK_USER_SOURCE } from "./tron-ask-user-contract.js";

interface AskUserOption {
  label: string;
  description?: string;
}
interface AskUserQuestion {
  header?: string;
  question: string;
  context?: string;
  options: AskUserOption[];
  multiSelect?: boolean;
  allowOther?: boolean;
}
interface AskUserParameters {
  title?: string;
  allowCancel?: boolean;
  questions: AskUserQuestion[];
}

type ToolRenderTheme = Parameters<NonNullable<ToolDefinition["renderCall"]>>[1];
type ToolRenderResult = Parameters<NonNullable<ToolDefinition["renderResult"]>>[0];
type ToolRenderOptions = Parameters<NonNullable<ToolDefinition["renderResult"]>>[1];
const AGENT_ABORTED_TEXT = "Agent aborted (goal cancelled, context compacted, or session switched). Do not assume an answer; do not retry ask_user — propagate the abort, or wait for new instructions if the decision is still required.";
const USER_CANCELLED_TEXT = "User cancelled. Do not assume an answer or continue the task — wait for new instructions or re-ask with refined options if the decision is still required.";

const parameters = Type.Object({
  title: Type.Optional(Type.String({ minLength: 1, maxLength: 256 })),
  allowCancel: Type.Optional(Type.Boolean()),
  questions: Type.Array(Type.Object({
    header: Type.Optional(Type.String({ minLength: 1, maxLength: 12 })),
    question: Type.String({ minLength: 1, maxLength: 1_000 }),
    context: Type.Optional(Type.String({ maxLength: 4 * 1_024 })),
    options: Type.Array(Type.Object({
      label: Type.String({ minLength: 1, maxLength: 2 * 1_024 }),
      description: Type.Optional(Type.String({ maxLength: 2 * 1_024 })),
    }, { additionalProperties: false }), { minItems: 2, maxItems: 4 }),
    multiSelect: Type.Optional(Type.Boolean()),
    allowOther: Type.Optional(Type.Boolean()),
  }, { additionalProperties: false }), { minItems: 1, maxItems: 4 }),
}, { additionalProperties: false });

/**
 * Tron owns the default form capability. It uses the same broker request seam
 * as the narrowly supported foreign adapter, but has no marker protocol or
 * package-provided event/context behavior.
 */
export function createTronAskUserExtension(): ExtensionFactory {
  return (pi) => {
    pi.registerTool({
      name: "ask_user",
      label: "Ask User",
      description: "Ask the user one bounded set of questions and wait for one atomic answer in Tron.",
      promptSnippet: "Ask the user for a bounded set of choices when a decision is required.",
      promptGuidelines: [
        "Use ask_user only when the user's answer is required to continue; do not use it for ordinary conversational questions.",
        "Provide two to four concrete options per question and keep the form to four questions or fewer.",
      ],
      parameters,
      executionMode: "sequential",
      execute: async (_toolCallId, request: AskUserParameters, signal, _onUpdate, context) => {
        if (!context?.ui || !context.hasUI) throw new Error("ask_user requires an interactive Tron form host");
        const form = toForm(request);
        if (signal?.aborted) return cancelledResult(form, AGENT_ABORTED_TEXT);
        const requestForm = (context.ui as typeof context.ui & FormCapableUI)[TRON_FORM_CAPABILITY];
        if (!requestForm) throw new Error("Tron semantic form host is unavailable");
        const answer = await requestForm({
          form,
          ...(signal === undefined ? {} : { signal }),
        });
        if (signal?.aborted) return cancelledResult(form, AGENT_ABORTED_TEXT);
        if (answer === undefined) return cancelledResult(form, USER_CANCELLED_TEXT);
        const details = formResult(form, answer);
        return {
          content: [{ type: "text" as const, text: resultText(form, answer) }],
          details,
        };
      },
      renderCall(args: AskUserParameters, theme: ToolRenderTheme) {
        const questions = isRecord(args) ? args.questions : undefined;
        if (!Array.isArray(questions) || questions.length === 0) {
          return new Text(theme.fg("warning", "ask_user"), 0, 0);
        }
        const topics = questions.map((rawQuestion) => {
          if (!isRecord(rawQuestion)) return "Question";
          if (typeof rawQuestion.header === "string" && rawQuestion.header.length > 0) return rawQuestion.header;
          return typeof rawQuestion.question === "string" ? truncateToWidth(rawQuestion.question, 12) : "Question";
        }).join(", ");
        return new TruncatedText(theme.fg("toolTitle", theme.bold("ask_user ")) + theme.fg("muted", topics), 0, 0);
      },
      renderResult(result: ToolRenderResult, options: ToolRenderOptions, theme: ToolRenderTheme) {
        const details = result?.details;
        if (!isRecord(details)) return new Text(theme.fg("warning", "No answer details"), 0, 0);
        if (details.cancelled === true) return new Text(theme.fg("warning", "Cancelled"), 0, 0);
        if (!Array.isArray(details.questions) || !isRecord(details.answers)) {
          return new Text(theme.fg("error", "Ask User result is unavailable"), 0, 0);
        }
        const box = new Box(0, 0);
        for (const rawQuestion of details.questions) {
          if (!isRecord(rawQuestion) || typeof rawQuestion.question !== "string" || !Array.isArray(rawQuestion.options)) continue;
          const rawValue: unknown = details.answers[rawQuestion.question];
          const value = isAnswerValue(rawValue) ? rawValue : undefined;
          const answer = value ? answerValueText(value) : "(no answer)";
          box.addChild(new TruncatedText(theme.fg("success", "✓ ") + theme.fg("accent", `${typeof rawQuestion.header === "string" ? rawQuestion.header : truncateToWidth(rawQuestion.question, 12)}: `) + theme.fg("text", answer), 0, 0));
          if (options?.expanded) {
            const selected = new Set(value && Array.isArray(value.selected) ? value.selected : []);
            for (const rawOption of rawQuestion.options) {
              if (!isRecord(rawOption) || typeof rawOption.label !== "string") continue;
              box.addChild(new TruncatedText(theme.fg("dim", `   ${selected.has(rawOption.label) ? "●" : "○"} ${rawOption.label}`), 0, 0));
            }
          }
        }
        return box;
      },
    });
  };
}

function toForm(request: AskUserParameters): ExtensionFormDescriptor {
  return {
    version: 1,
    title: request.title ?? (request.questions.length === 1 ? (request.questions[0]!.header ?? "Question") : "Questions"),
    allowCancel: request.allowCancel !== false,
    questions: request.questions.map((question, questionIndex) => ({
      id: `question-${questionIndex}`,
      ...(question.header === undefined ? {} : { header: question.header }),
      question: question.question,
      ...(question.context === undefined ? {} : { context: question.context }),
      options: question.options.map((option, optionIndex) => ({
        id: `question-${questionIndex}-option-${optionIndex}`,
        label: option.label,
        ...(option.description === undefined ? {} : { description: option.description }),
      })),
      multiSelect: question.multiSelect === true,
      allowOther: question.allowOther !== false,
    })),
  };
}

interface AskUserAnswerValue {
  selected: string[];
  other: string | null;
}
interface AskUserResultQuestion {
  header?: string;
  question: string;
  context?: string;
  options: AskUserOption[];
  multiSelect: boolean;
  allowOther: boolean;
}
interface AskUserResultDetails {
  title: string;
  questions: AskUserResultQuestion[];
  answers: Record<string, AskUserAnswerValue>;
  cancelled: boolean;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function isAnswerValue(value: unknown): value is AskUserAnswerValue {
  return isRecord(value)
    && Array.isArray(value.selected)
    && value.selected.every((item) => typeof item === "string")
    && (value.other === null || typeof value.other === "string");
}

function resultQuestions(form: ExtensionFormDescriptor): AskUserResultQuestion[] {
  // Result details are a public history shape, not the broker's ID-bearing
  // wire form. Keep IDs out so old native readers can decode the result while
  // preserving the descriptive fields needed to reconstruct the form.
  return form.questions.map((question) => ({
    ...(question.header === undefined ? {} : { header: question.header }),
    question: question.question,
    ...(question.context === undefined ? {} : { context: question.context }),
    options: question.options.map((option) => ({
      label: option.label,
      ...(option.description === undefined ? {} : { description: option.description }),
    })),
    multiSelect: question.multiSelect,
    allowOther: question.allowOther,
  }));
}

function cancelledResult(form: ExtensionFormDescriptor, text: string) {
  return {
    content: [{ type: "text" as const, text }],
    details: { title: form.title, questions: resultQuestions(form), answers: {}, cancelled: true } satisfies AskUserResultDetails,
  };
}

function answerValueText(value: AskUserAnswerValue): string {
  const values = [...value.selected];
  if (value.other !== null) values.push(value.other);
  return values.length > 0 ? values.join(", ") : "(no answer)";
}

function formResult(form: ExtensionFormDescriptor, answer: ExtensionFormAnswer): JsonValue {
  const questions = resultQuestions(form);
  const byQuestion = new Map(answer.answers.map((item) => [item.questionId, item]));
  const answers: Record<string, JsonValue> = Object.create(null) as Record<string, JsonValue>;
  for (const question of form.questions) {
    const item = byQuestion.get(question.id);
    if (!item) throw new Error("Tron semantic form answer is incomplete");
    const selected = item.optionIds.map((id) => question.options.find((option) => option.id === id)?.label)
      .filter((label): label is string => label !== undefined);
    answers[question.question] = {
      selected,
      other: item.other ?? null,
    };
  }
  return { title: form.title, questions: questions as unknown as JsonValue, answers, cancelled: false };
}

function resultText(form: ExtensionFormDescriptor, answer: ExtensionFormAnswer): string {
  const byQuestion = new Map(answer.answers.map((item) => [item.questionId, item]));
  return form.questions.map((question) => {
    const item = byQuestion.get(question.id);
    const labels = item?.optionIds.map((id) => question.options.find((option) => option.id === id)?.label)
      .filter((label): label is string => label !== undefined) ?? [];
    if (item?.other !== undefined) labels.push(item.other);
    return `"${question.question}" = "${labels.length > 0 ? labels.join(", ") : "(no answer)"}"`;
  }).join("\n");
}

export type { AskUserParameters, AskUserQuestion, AskUserOption };