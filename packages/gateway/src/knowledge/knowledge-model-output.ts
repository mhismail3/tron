import type { AssistantMessage } from "@earendil-works/pi-ai";

export interface KnowledgeModelOutputDiagnostics {
  modelId: string;
  stopReason: string;
  contentPartTypes: string[];
  textLength: number;
  codeFence: boolean;
  leadingProse: boolean;
}

export class KnowledgeModelOutputError extends Error {
  constructor(readonly code: "model-error" | "model-output-invalid", message: string, readonly diagnostics: KnowledgeModelOutputDiagnostics) {
    super(message);
    this.name = "KnowledgeModelOutputError";
  }
}

function boundedMessage(value: string): string {
  return value.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 500);
}

/** Reply diagnostics contain shape only; they never retain model text. */
export function knowledgeModelDiagnostics(message: AssistantMessage, modelId: string): KnowledgeModelOutputDiagnostics {
  const parts = Array.isArray(message.content) ? message.content : [];
  const text = parts.filter((part): part is Extract<AssistantMessage["content"][number], { type: "text" }> => part.type === "text")
    .map(part => typeof part.text === "string" ? part.text : "").join("");
  const trimmed = text.trimStart();
  return {
    modelId: boundedMessage(modelId),
    stopReason: boundedMessage(String(message.stopReason ?? "unknown")),
    contentPartTypes: parts.slice(0, 16).map(part => boundedMessage(String(part.type))),
    textLength: text.length,
    codeFence: /^```/.test(trimmed),
    leadingProse: trimmed.length > 0 && !trimmed.startsWith("```") && !trimmed.startsWith("{") && !trimmed.startsWith("["),
  };
}

/** Extract only the text parts a Knowledge consumer may interpret. Error state
 * is diagnosed before a parser can turn provider failures into misleading JSON
 * errors. */
export function knowledgeModelText(message: AssistantMessage, modelId: string): string {
  const parts = Array.isArray(message.content) ? message.content : [];
  const text = parts.filter((part): part is Extract<AssistantMessage["content"][number], { type: "text" }> => part.type === "text")
    .map(part => typeof part.text === "string" ? part.text : "").join("");
  const diagnostics = knowledgeModelDiagnostics(message, modelId);
  if (message.stopReason === "error" || message.stopReason === "aborted" || text.trim().length === 0) {
    const reason = typeof message.errorMessage === "string" && message.errorMessage.trim()
      ? boundedMessage(message.errorMessage.trim())
      : `Model ${diagnostics.modelId} returned no text (stopReason=${diagnostics.stopReason}; parts=${diagnostics.contentPartTypes.join(",") || "none"})`;
    throw new KnowledgeModelOutputError("model-error", reason, diagnostics);
  }
  return text;
}

export function invalidKnowledgeModelText(text: string, modelId: string): KnowledgeModelOutputError {
  const trimmed = text.trimStart();
  return invalidKnowledgeModelOutput(modelId, {
    modelId: boundedMessage(modelId), stopReason: "stop", contentPartTypes: ["text"], textLength: text.length,
    codeFence: /^```/.test(trimmed),
    leadingProse: trimmed.length > 0 && !trimmed.startsWith("```") && !trimmed.startsWith("{") && !trimmed.startsWith("["),
  });
}

export function invalidKnowledgeModelOutput(modelId: string, diagnostics: KnowledgeModelOutputDiagnostics): KnowledgeModelOutputError {
  const shape = `stopReason=${diagnostics.stopReason}; parts=${diagnostics.contentPartTypes.join(",") || "none"}; textLength=${diagnostics.textLength}; codeFence=${diagnostics.codeFence}; leadingProse=${diagnostics.leadingProse}`;
  return new KnowledgeModelOutputError("model-output-invalid", `Model ${boundedMessage(modelId)} returned invalid output (${shape})`, diagnostics);
}

export function knowledgeModelFailureSummary(error: KnowledgeModelOutputError): { code: KnowledgeModelOutputError["code"]; reason: string } {
  const { diagnostics } = error;
  const shape = `stopReason=${diagnostics.stopReason}; parts=${diagnostics.contentPartTypes.join(",") || "none"}; textLength=${diagnostics.textLength}; codeFence=${diagnostics.codeFence}; leadingProse=${diagnostics.leadingProse}`;
  return { code: error.code, reason: `${diagnostics.modelId}: ${error.message} (${shape})`.slice(0, 800) };
}
