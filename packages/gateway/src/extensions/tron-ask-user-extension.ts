import { Box, Text, TruncatedText, truncateToWidth } from "@earendil-works/pi-tui";
import { Type } from "typebox";
import type { ExtensionFactory, ToolDefinition } from "@earendil-works/pi-coding-agent";
import type {
  ExtensionFormAnswer,
  ExtensionFormDescriptor,
  JsonValue,
} from "../protocol/types.js";
import { TRON_FORM_REQUEST } from "../sessions/extension-adapter-contract.js";

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
        const requestForm = (context.ui as typeof context.ui & {
          [TRON_FORM_REQUEST]?: (input: { form: ExtensionFormDescriptor; signal?: AbortSignal }) => Promise<ExtensionFormAnswer | undefined>;
        })[TRON_FORM_REQUEST];
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
        const topics = args.questions.map((question) => question.header ?? truncateToWidth(question.question, 12)).join(", ");
        return new TruncatedText(theme.fg("toolTitle", theme.bold("ask_user ")) + theme.fg("muted", topics), 0, 0);
      },
      renderResult(result: ToolRenderResult, options: ToolRenderOptions, theme: ToolRenderTheme) {
        const details = result.details as AskUserResultDetails | undefined;
        if (!details || details.cancelled) return new Text(theme.fg("warning", "Cancelled"), 0, 0);
        const box = new Box(0, 0);
        for (const question of details.questions) {
          const value = details.answers[question.question];
          const answer = value ? answerValueText(value) : "(no answer)";
          box.addChild(new TruncatedText(theme.fg("success", "✓ ") + theme.fg("accent", `${question.header ?? truncateToWidth(question.question, 12)}: `) + theme.fg("text", answer), 0, 0));
          if (options?.expanded) {
            const selected = new Set(value?.selected ?? []);
            for (const option of question.options) {
              box.addChild(new TruncatedText(theme.fg("dim", `   ${selected.has(option.label) ? "●" : "○"} ${option.label}`), 0, 0));
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
interface AskUserResultDetails {
  questions: AskUserQuestion[];
  answers: Record<string, AskUserAnswerValue>;
  cancelled: boolean;
}

function cancelledResult(form: ExtensionFormDescriptor, text: string) {
  return {
    content: [{ type: "text" as const, text }],
    details: { questions: form.questions, answers: {}, cancelled: true } satisfies AskUserResultDetails,
  };
}

function answerValueText(value: AskUserAnswerValue): string {
  const values = [...value.selected];
  if (value.other !== null) values.push(value.other);
  return values.length > 0 ? values.join(", ") : "(no answer)";
}

function formResult(form: ExtensionFormDescriptor, answer: ExtensionFormAnswer): JsonValue {
  const questions = form.questions.map((question) => ({
    ...(question.header === undefined ? {} : { header: question.header }),
    question: question.question,
    ...(question.context === undefined ? {} : { context: question.context }),
    options: question.options.map((option) => ({
      label: option.label,
      ...(option.description === undefined ? {} : { description: option.description }),
    })),
    multiSelect: question.multiSelect,
  }));
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
  return { questions, answers, cancelled: false };
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