import { describe, expect, it } from "vitest";
import {
  assertExtensionForm,
  canonicalExtensionFormAnswer,
  EXTENSION_FORM_MAX_ANSWER_BYTES,
  EXTENSION_FORM_MAX_OTHER_BYTES,
  normalizeExtensionForm,
} from "./semantic-form.js";

const form = () => ({
  version: 1 as const,
  title: "Questions",
  allowCancel: true,
  questions: [
    {
      id: "one", header: "One", question: "First?", context: "Context",
      options: [{ id: "a", label: "A", description: "First" }, { id: "b", label: "B" }],
      multiSelect: false, allowOther: true,
    },
    {
      id: "two", header: "Two", question: "Second?",
      options: [{ id: "c", label: "C" }, { id: "d", label: "D" }],
      multiSelect: true, allowOther: false,
    },
  ],
});

describe("semantic extension form contract", () => {
  it("normalizes terminal controls before validating the retained descriptor", () => {
    const normalized = normalizeExtensionForm({
      ...form(), title: "\u001b[31mQuestions\u001b[0m",
      questions: [{ ...form().questions[0]!, context: "safe\u001b]52;c;bad\u0007\nnext" }],
    });
    expect(normalized.title).toBe("Questions");
    expect(normalized.questions[0]?.context).toBe("safe\nnext");
  });

  it("rejects question, header, option, identity, and cardinality violations", () => {
    const invalid = [
      { ...form(), questions: [] },
      { ...form(), questions: Array.from({ length: 5 }, (_, index) => ({ ...form().questions[0]!, id: `q${index}`, header: `${index}`, question: `${index}?` })) },
      { ...form(), questions: [{ ...form().questions[0]!, id: "duplicate" }, { ...form().questions[1]!, id: "duplicate" }] },
      { ...form(), questions: [{ ...form().questions[0]!, header: "Same" }, { ...form().questions[1]!, header: "Same" }] },
      { ...form(), questions: [{ ...form().questions[0]!, options: [{ id: "a", label: "A" }] }] },
      { ...form(), questions: [{ ...form().questions[0]!, options: [{ id: "a", label: "A" }, { id: "a", label: "B" }] }] },
      { ...form(), questions: [{ ...form().questions[0]!, options: [{ id: "a", label: "A" }, { id: "b", label: "A" }] }] },
      { ...form(), questions: [{ ...form().questions[0]!, question: "line\nbreak" }] },
      { ...form(), questions: [{ ...form().questions[0]!, question: "bad\ud800" }] },
    ];
    invalid.forEach((candidate, index) => expect(() => assertExtensionForm(candidate), `invalid case ${index}`).toThrow());
  });

  it("requires exact answer coverage and canonicalizes question and option order", () => {
    expect(canonicalExtensionFormAnswer({
      version: 1,
      answers: [
        { questionId: "two", optionIds: ["d", "c"] },
        { questionId: "one", optionIds: ["b"] },
      ],
    }, form())).toEqual({
      version: 1,
      answers: [
        { questionId: "one", optionIds: ["b"] },
        { questionId: "two", optionIds: ["c", "d"] },
      ],
    });
    const invalid = [
      { version: 1, answers: [] },
      { version: 1, answers: [{ questionId: "one", optionIds: ["a"] }, { questionId: "unknown", optionIds: ["c"] }] },
      { version: 1, answers: [{ questionId: "one", optionIds: ["a", "b"] }, { questionId: "two", optionIds: ["c"] }] },
      { version: 1, answers: [{ questionId: "one", optionIds: ["a"], other: "other" }, { questionId: "two", optionIds: ["c"] }] },
      { version: 1, answers: [{ questionId: "one", optionIds: [] }, { questionId: "two", optionIds: ["c"] }] },
      { version: 1, answers: [{ questionId: "one", optionIds: [], other: "ok" }, { questionId: "two", optionIds: [], other: "forbidden" }] },
      { version: 1, answers: [{ questionId: "one", optionIds: [], other: "bad\ud800" }, { questionId: "two", optionIds: ["c"] }] },
    ];
    for (const candidate of invalid) expect(() => canonicalExtensionFormAnswer(candidate, form())).toThrow(/response is invalid/);
  });

  it("enforces UTF-8 and aggregate answer byte bounds without truncation", () => {
    const exact = "é".repeat(EXTENSION_FORM_MAX_OTHER_BYTES / 2 - 1);
    expect(() => canonicalExtensionFormAnswer({
      version: 1,
      answers: [{ questionId: "one", optionIds: [], other: exact }, { questionId: "two", optionIds: ["c"] }],
    }, form())).not.toThrow();
    expect(() => canonicalExtensionFormAnswer({
      version: 1,
      answers: [{ questionId: "one", optionIds: [], other: "é".repeat(EXTENSION_FORM_MAX_OTHER_BYTES / 2 + 1) }, { questionId: "two", optionIds: ["c"] }],
    }, form())).toThrow();
    expect(EXTENSION_FORM_MAX_ANSWER_BYTES).toBe(192 * 1_024);
  });
});
