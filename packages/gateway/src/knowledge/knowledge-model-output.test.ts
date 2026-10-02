import { describe, expect, it, vi } from "vitest";
import { fauxAssistantMessage, fauxProvider, type AssistantMessage, type Context } from "@earendil-works/pi-ai";
import type { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { knowledgeModelFailureSummary, KnowledgeModelOutputError } from "./knowledge-model-output.js";
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

// Synthetic reply shape from #292; no captured model/source text.
describe("Knowledge single-object JSON contract", () => {
  it("summarizes the Luna leading-prose reply shape without interpreting prose as evidence", async () => {
    const text = 'A quoted "claim", a backslash \\, braces {like this}, and [uncertainty].';
    const json = JSON.stringify({ text, extra: { nested: [1, { ok: true }] } });
    const raw = "Here is the saved-source summary.\n" + json + "\nEnd of summary.";
    const { model } = adapter(fauxAssistantMessage(raw));
    await expect(model.summarizeSource(input)).resolves.toEqual({ text });
  });

  it("assesses a prose-wrapped object while preserving assessment validation", async () => {
    const assessment = { summary: "Bounded summary", evidenceQuality: "low", freshness: "unknown", recommendation: "pending", confidence: 0.4, classification: "Research" };
    const { model } = adapter(fauxAssistantMessage("Assessment follows.\n" + JSON.stringify(assessment)));
    await expect(model.assess({ title: "fixture", text: "fixture", interests: [] }, input.signal)).resolves.toEqual(assessment);
  });

  it.each([
    '[{"text":"array"}]',
    'Here: {"text":"first"} then {"text":"second"}',
    'Here: {"text":"complete"} then {"text":',
    'Here: {"text":"unfinished"',
    'Here: {"text":"bad",}',
    'Here: {"text":"complete"} ]',
    'Here: [ {"text":"nested"} ]',
    'No JSON here.',
    'Here: {"text":"unterminated}',
  ])("rejects ambiguous or incomplete reply %s with shape-only diagnostics", async raw => {
    const { model } = adapter(fauxAssistantMessage(raw));
    await expect(model.summarizeSource(input)).rejects.toMatchObject({ code: "model-output-invalid" });
  });

  it("emits each invalid-output diagnostic field once in the failure reason", async () => {
    const { model } = adapter(fauxAssistantMessage("private malformed output"));
    const error = await model.summarizeSource(input).catch(error => error);
    expect(error).toBeInstanceOf(KnowledgeModelOutputError);
    const failure = knowledgeModelFailureSummary(error);
    for (const key of ["stopReason", "parts", "textLength", "codeFence", "leadingProse"]) {
      expect(failure.reason.split(`${key}=`)).toHaveLength(2);
    }
    expect(failure.reason).not.toContain("private malformed output");
  });
});
