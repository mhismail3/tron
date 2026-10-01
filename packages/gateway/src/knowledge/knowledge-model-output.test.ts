import { describe, expect, it, vi } from "vitest";
import { fauxAssistantMessage, fauxProvider, type AssistantMessage, type Context } from "@earendil-works/pi-ai";
import type { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { ModelRuntimeKnowledgeModel } from "./knowledge-service.js";

const input = {
  sessionId: "test-session",
  sourceText: "bounded fixture evidence",
  sourceRevisionIds: ["a".repeat(32)],
  signal: new AbortController().signal,
  maxOutputChars: 1_000,
};

function adapter(message: AssistantMessage) {
  const model = fauxProvider({ provider: "model-output-test" }).getModel();
  const completeSimple = vi.fn(async (_model: unknown, _context: Context, _options: unknown) => message);
  return { model: new ModelRuntimeKnowledgeModel({ completeSimple } as unknown as ModelRuntime, model, { maxInputChars: 2_000, maxOutputChars: 1_000 }), completeSimple };
}

describe("Knowledge model completion errors", () => {
  it("preserves an error stop reason and provider message instead of reporting invalid JSON", async () => {
    const message = { ...fauxAssistantMessage(""), stopReason: "error", errorMessage: "Provider is not configured: openai", content: [] } as AssistantMessage;
    const { model } = adapter(message);
    await expect(model.summarizeSource(input)).rejects.toMatchObject({
      code: "model-error",
      message: "Provider is not configured: openai",
      diagnostics: { modelId: expect.stringContaining("model-output-test/"), stopReason: "error", contentPartTypes: [], textLength: 0 },
    });
  });

  it("reports bounded reply-shape diagnostics without retaining malformed text", async () => {
    const raw = "```json\nnot JSON\n```";
    const { model } = adapter(fauxAssistantMessage(raw));
    await expect(model.summarizeSource(input)).rejects.toMatchObject({
      code: "model-output-invalid",
      diagnostics: {
        stopReason: "stop",
        contentPartTypes: ["text"],
        textLength: raw.length,
        codeFence: true,
        leadingProse: false,
      },
    });
  });

  it("uses the same provider-error contract for assessor, reflector, and synthesis paths", async () => {
    const message = { ...fauxAssistantMessage(""), stopReason: "aborted", errorMessage: "request cancelled", content: [] } as AssistantMessage;
    const { model } = adapter(message);
    const expected = { code: "model-error", message: "request cancelled" };
    await expect(model.reflect(input)).rejects.toMatchObject(expected);
    await expect(model.synthesize(input)).rejects.toMatchObject(expected);
    await expect(model.assess({ title: "fixture", text: "fixture", interests: [] }, input.signal)).rejects.toMatchObject(expected);
  });
});
