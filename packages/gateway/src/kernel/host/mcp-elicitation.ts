import type { McpElicitation, McpElicitationRequest } from "../pi/coding-agent.js";
import type { ExtensionFormDescriptor } from "../../protocol/types.js";
import { TRON_FORM_CAPABILITY, type FormCapableUI } from "./extension-adapter-contract.js";

const ELICITATION_TIMEOUT_MS = 15 * 60_000;

interface Choice { key: string; question: string; values: string[]; labels: string[] }

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function strings(value: unknown): value is string[] {
  return Array.isArray(value) && value.every(item => typeof item === "string");
}

function choiceOf(request: McpElicitationRequest): Choice | undefined {
  const properties = isRecord(request.requestedSchema.properties) ? Object.entries(request.requestedSchema.properties) : [];
  const [key, property] = properties[0] ?? [];
  if (properties.length !== 1 || key === undefined || !isRecord(property)) return undefined;
  const oneOf = Array.isArray(property.oneOf) ? property.oneOf.filter(isRecord) : [];
  const values = strings(property.enum) ? property.enum : oneOf.map(option => option.const);
  const labels = strings(property.enum)
    ? strings(property.enumNames) && property.enumNames.length === property.enum.length ? property.enumNames : property.enum
    : oneOf.map(option => option.title ?? option.const);
  if (!strings(values) || !strings(labels) || values.length < 2 || values.length > 4 || values.length !== labels.length) return undefined;
  const question = typeof property.title === "string" ? property.title : typeof property.description === "string" ? property.description : "Choose a response";
  return { key, question, values, labels };
}

export function mcpElicitation(attended: () => boolean): McpElicitation {
  return {
    clientName: "Tron",
    async elicit(request, ctx, signal) {
      const requestForm = ctx?.hasUI && attended() ? (ctx.ui as typeof ctx.ui & FormCapableUI)[TRON_FORM_CAPABILITY] : undefined;
      const choice = choiceOf(request);
      if (!requestForm || !choice) return { action: "decline" };
      const form: ExtensionFormDescriptor = {
        version: 1,
        title: `${request.server}/${request.tool}`,
        allowCancel: true,
        questions: [{
          id: "choice",
          question: choice.question,
          context: request.message,
          options: choice.values.map((value, index) => ({ id: `choice-${index}`, label: choice.labels[index]!, description: value })),
          multiSelect: false,
          allowOther: false,
        }],
      };
      try {
        const answer = await requestForm({ form, timeout: ELICITATION_TIMEOUT_MS, ...(signal ? { signal } : {}) });
        const index = form.questions[0]!.options.findIndex(option => option.id === answer?.answers[0]?.optionIds[0]);
        return index < 0 ? { action: "cancel" } : { action: "accept", content: { [choice.key]: choice.values[index]! } };
      } catch {
        return { action: "cancel" };
      }
    },
  };
}
