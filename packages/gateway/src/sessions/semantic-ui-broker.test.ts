import { describe, expect, it } from "vitest";
import { SemanticUIBroker } from "./semantic-ui-broker.js";
import { ExtensionPresentationStore } from "../extensions/host/extension-presentation-store.js";
import type { JsonValue } from "../protocol/types.js";

function brokerWith(broadcast: (topic: string, payload: JsonValue) => void = () => {}): SemanticUIBroker {
  return new SemanticUIBroker(new ExtensionPresentationStore((topic, payload) => broadcast(topic, payload)));
}

describe("SemanticUIBroker", () => {
  it("admits structured questionnaire answers and keeps primitive fallback valid", async () => {
    const broker = brokerWith(() => {});
    const pending = broker.requestQuestionnaire({
      title: "Pick", question: "Pick one", options: [{ label: "One", preview: "**one**" }, { label: "Two" }],
      allowMultiple: false, allowFreeform: true,
    });
    const interaction = broker.interactions()[0]!;
    expect(interaction.questionnaire?.version).toBe(1);
    broker.respond(interaction.id, interaction.hostEpoch, interaction.presentationRevision,
      { selections: [{ option: 1, comment: "reason" }] }, false);
    await expect(pending).resolves.toEqual({ selections: [{ option: 1, comment: "reason" }] });

    const legacy = broker.requestQuestionnaire({
      title: "Pick", question: "Pick one", options: [{ label: "One" }], allowMultiple: false, allowFreeform: false,
    });
    const fallback = broker.interactions()[0]!;
    broker.respond(fallback.id, fallback.hostEpoch, fallback.presentationRevision, "1. One", false);
    await expect(legacy).resolves.toBe("1. One");
  });

  it("rejects invalid questionnaire answers without removing the pending request", async () => {
    const broker = brokerWith(() => {});
    const pending = broker.requestQuestionnaire({
      title: "Pick", question: "Pick", options: [{ label: "One" }], allowMultiple: false, allowFreeform: false,
    });
    const interaction = broker.interactions()[0]!;
    expect(() => broker.respond(interaction.id, interaction.hostEpoch, interaction.presentationRevision,
      { selections: [{ option: 4 }] }, false)).toThrow(expect.objectContaining({ code: "invalid_request" }));
    expect(() => broker.respond(interaction.id, interaction.hostEpoch, interaction.presentationRevision,
      { selections: [{ option: 0 }], freeform: "conflicting" }, false)).toThrow(expect.objectContaining({ code: "invalid_request" }));
    expect(broker.interactions()).toHaveLength(1);
    broker.cancelAll();
    await expect(pending).rejects.toMatchObject({ code: "cancelled" });
  });

  it("preserves the first primitive input shape for multi-select fallback", async () => {
    const broker = brokerWith(() => {});
    const pending = broker.requestQuestionnaire({ method: "input", title: "Choose", primitiveOptions: undefined, placeholder: "placeholder", question: "Choose", options: [{ label: "One" }], allowMultiple: true, allowFreeform: false });
    const interaction = broker.interactions()[0]!;
    expect(interaction.method).toBe("input");
    expect(interaction.options).toBeUndefined();
    broker.respond(interaction.id, interaction.hostEpoch, interaction.presentationRevision, "1", false);
    await expect(pending).resolves.toBe("1");
  });

  it("enforces the conditional 63/64 structured option boundary", async () => {
    const broker = brokerWith(() => {});
    const options = (count: number) => Array.from({ length: count }, (_, index) => ({ label: `Option ${index}` }));
    const sixtyThree = broker.requestQuestionnaire({ title: "Pick", question: "Pick", options: options(63), allowMultiple: false, allowFreeform: true });
    expect(broker.interactions()[0]?.options).toHaveLength(64);
    broker.cancelAll();
    await expect(sixtyThree).rejects.toMatchObject({ code: "cancelled" });
    await expect(broker.requestQuestionnaire({ title: "Pick", question: "Pick", options: options(64), allowMultiple: false, allowFreeform: true }))
      .rejects.toMatchObject({ code: "conflict" });
    broker.cancelAll();
    const sixtyFour = broker.requestQuestionnaire({ title: "Pick", question: "Pick", options: options(64), allowMultiple: false, allowFreeform: false });
    expect(broker.interactions()[0]?.options).toHaveLength(64);
    broker.cancelAll();
    await expect(sixtyFour).rejects.toMatchObject({ code: "cancelled" });
  });

  it("survives client churn until a response arrives", async () => {
    const broker = brokerWith(() => {});
    const result = broker.context().select("Choose", ["one", "two"]);
    const interaction = broker.interactions()[0];
    expect(interaction?.method).toBe("select");
    broker.respond(interaction!.id, interaction!.hostEpoch, interaction!.presentationRevision, "two", false);
    await expect(result).resolves.toBe("two");
  });

  it("rejects stale interaction scopes and retired epoch callbacks", async () => {
    const broker = brokerWith(() => {});
    const context = broker.context();
    const result = context.confirm("Confirm", "Proceed?");
    const interaction = broker.interactions()[0]!;
    expect(() => broker.respond(interaction.id, "wrong-epoch", interaction.presentationRevision, true, false))
      .toThrow(expect.objectContaining({ code: "conflict", retryable: true }));
    expect(() => broker.respond(interaction.id, interaction.hostEpoch, interaction.presentationRevision, "yes", false))
      .toThrow(expect.objectContaining({ code: "invalid_request" }));
    expect(broker.interactions()).toHaveLength(1);
    broker.respond(interaction.id, interaction.hostEpoch, interaction.presentationRevision, true, false);
    await expect(result).resolves.toBe(true);
    broker.retire();
    expect(() => context.setStatus("late", "ignored")).not.toThrow();
    expect(broker.state().semanticState.statuses.late).toBeUndefined();
  });

  it("applies native editor updates only at the authoritative epoch and base revision", () => {
    const broker = brokerWith(() => {});
    const applied = broker.updateEditor(broker.hostEpoch, 0, "operation-1", "draft");
    expect(applied).toEqual({ revision: 1, text: "draft", applied: true });
    expect(broker.updateEditor(broker.hostEpoch, 0, "operation-2", "stale"))
      .toEqual({ revision: 1, text: "draft", applied: false });
    expect(broker.updateEditor("old-host", 1, "operation-3", "stale"))
      .toEqual({ revision: 1, text: "draft", applied: false });
  });

  it("retains working indicator and tool expansion semantics", () => {
    const broker = brokerWith(() => {});
    const context = broker.context();
    context.setWorkingIndicator({ frames: ["\u001b[32m.\u001b[0m", ".."], intervalMs: 120 });
    context.setToolsExpanded(true);
    expect(context.getToolsExpanded()).toBe(true);
    expect(broker.state()).toMatchObject({
      version: 2,
      hostEpoch: broker.hostEpoch,
      semanticState: { working: { indicator: { kind: "animated", frames: [".", ".."], intervalMs: 120 } },
      toolsExpanded: true },
    });
  });

  it("returns Pi cancellation values when dialog signals abort", async () => {
    const broker = brokerWith(() => {});
    const preAborted = new AbortController();
    preAborted.abort();
    await expect(broker.context().confirm("Confirm", "Proceed?", { signal: preAborted.signal })).resolves.toBe(false);

    const controller = new AbortController();
    const pending = broker.context().input("Input", undefined, { signal: controller.signal });
    expect(broker.interactions()).toHaveLength(1);
    controller.abort();
    await expect(pending).resolves.toBeUndefined();
    expect(broker.interactions()).toHaveLength(0);
  });

  it("returns a real baseline theme and sanitizes themed semantic text", () => {
    const broker = brokerWith(() => {});
    const context = broker.context();
    expect(context.theme).toBeDefined();
    context.setStatus("theme", context.theme.fg("dim", "Ready"));
    expect(broker.state().semanticState.statuses.theme).toBe("Ready");
  });

  it("returns undefined when a dialog times out", async () => {
    const broker = brokerWith(() => {});
    await expect(broker.context().input("Input", undefined, { timeout: 1 })).resolves.toBeUndefined();
    expect(broker.interactions()).toHaveLength(0);
  });

  it("keeps versioned semantic state reconnect-safe while RPC custom UI remains explicit fallback", async () => {
    const events: Array<{ topic: string; payload: unknown }> = [];
    const broker = brokerWith((topic, payload) => events.push({ topic, payload }));
    const context = broker.context();

    await expect(context.custom(() => ({}) as never)).resolves.toBeUndefined();
    context.setStatus("build", "Checking");
    context.setWorkingMessage("Working carefully");
    context.setWorkingVisible(false);
    context.setHiddenThinkingLabel("Private reasoning");
    context.setWidget("summary", ["one", "two"], { placement: "belowEditor" });
    context.setTitle("Extension title");
    context.setEditorText("replace\nsecond line");
    context.pasteToEditor(" + append\nthird line");

    expect(broker.state()).toMatchObject({ semanticState: {
      statuses: { build: "Checking" },
      working: { message: "Working carefully", visible: false },
      hiddenThinkingLabel: "Private reasoning",
      widgets: [{ key: "summary", lines: ["one", "two"], placement: "belowEditor" }],
      title: "Extension title",
      editorRevision: 2,
      editorText: "replace\nsecond line + append\nthird line",
    }});

    context.setStatus("build", undefined);
    context.setWidget("summary", undefined);
    expect(broker.state().semanticState.statuses).toEqual({});
    expect(broker.state().semanticState.widgets).toEqual([]);
    expect(events.some((event) => event.topic === "session.extensionPresentation")).toBe(true);
    const interaction = context.confirm("Envelope", "Check");
    const interactionEvent = events.findLast((event) => event.topic === "session.extensionPresentation" && (event.payload as { interactionList?: unknown }).interactionList !== undefined);
    expect(interactionEvent?.payload).toMatchObject({
      hostEpoch: broker.hostEpoch,
      revision: expect.any(Number),
      interactionList: [expect.objectContaining({ method: "confirm" })],
    });
    broker.cancelAll();
    await expect(interaction).rejects.toMatchObject({ code: "cancelled" });
  });

  it("bounds retained statuses atomically while allowing updates and removals", () => {
    const broker = brokerWith(() => {});
    const context = broker.context();
    for (let index = 0; index < 32; index += 1) context.setStatus(`status-${index}`, `value-${index}`);

    expect(Object.keys(broker.state().semanticState.statuses)).toHaveLength(32);
    expect(() => context.setStatus("overflow", "value")).not.toThrow();
    expect(() => context.setStatus("status-0", "x".repeat(4 * 1_024))).not.toThrow();
    expect(broker.state().semanticState.statuses["status-0"]).toBe("value-0");

    context.setStatus("status-0", "updated");
    context.setStatus("status-1", undefined);
    context.setStatus("replacement", "admitted");
    expect(broker.state().semanticState.statuses["status-0"]).toBe("updated");
    expect(broker.state().semanticState.statuses.replacement).toBe("admitted");
  });

  it("bounds retained interactions, options, timeouts, and aggregate bytes", async () => {
    const broker = brokerWith(() => {});
    const context = broker.context();
    await expect(context.select("Choose", Array.from({ length: 65 }, (_, index) => `${index}`))).rejects.toMatchObject({
      code: "conflict",
    });
    await expect(context.input("Input", undefined, { timeout: 0 })).rejects.toMatchObject({ code: "conflict" });
    await expect(context.editor("Editor", "x".repeat(192 * 1_024 - 2))).rejects.toMatchObject({ code: "busy" });

    const pending = Array.from({ length: 8 }, (_, index) => context.confirm(`Confirm ${index}`, "message"));
    await expect(context.confirm("Overflow", "message")).rejects.toMatchObject({
      code: "busy",
      retryable: true,
    });
    expect(broker.interactions()).toHaveLength(8);
    broker.cancelAll();
    await Promise.allSettled(pending);
    expect(broker.interactions()).toEqual([]);
  });

  it("rejects malformed runtime values without poisoning retained state", async () => {
    const broker = brokerWith(() => {});
    const context = broker.context();

    await expect((context.select as unknown as (title: string, options: unknown) => Promise<unknown>)("Choose", null))
      .rejects.toMatchObject({ code: "conflict" });
    expect(() => (context.setWorkingVisible as unknown as (visible: unknown) => void)("yes")).not.toThrow();
    expect(() => (context.pasteToEditor as unknown as (text: unknown) => void)(42)).not.toThrow();
    expect(() => context.setWidget("bad-placement", ["line"], { placement: "sideways" as "aboveEditor" })).not.toThrow();
    expect(broker.state().semanticState.working.visible).toBe(true);
    expect(broker.state().semanticState.editorText).toBe("");
    expect(broker.interactions()).toEqual([]);
  });

  it("preserves multiline editor, paste, and interaction values", async () => {
    const broker = brokerWith(() => {});
    const context = broker.context();
    context.setEditorText("first line\nsecond line");
    context.pasteToEditor("\nthird line");
    expect(broker.state().semanticState.editorText).toBe("first line\nsecond line\nthird line");

    const pending = context.editor("Edit lines", "prefill one\nprefill two");
    await new Promise((resolve) => setTimeout(resolve, 0));
    const interaction = broker.interactions()[0];
    expect(interaction).toMatchObject({ method: "editor", prefill: "prefill one\nprefill two" });
    broker.respond(interaction.id, interaction.hostEpoch, interaction.presentationRevision, "result one\nresult two", false);
    await expect(pending).resolves.toBe("result one\nresult two");
  });

  it("bounds editor mutations before state or event publication", () => {
    const events: Array<{ topic: string; payload: unknown }> = [];
    const broker = brokerWith((topic, payload) => events.push({ topic, payload }));
    const context = broker.context();
    const initial = "a".repeat(128 * 1_024);
    const suffix = "b".repeat(32 * 1_024);
    context.setEditorText(initial);
    context.pasteToEditor(suffix);
    const admitted = broker.state();

    expect(admitted.semanticState.editorText).toBe(initial + suffix);
    expect(admitted.semanticState.editorRevision).toBe(2);
    expect(() => context.pasteToEditor("c".repeat(40 * 1_024))).not.toThrow();
    expect(broker.state().semanticState.editorText).toBe(admitted.semanticState.editorText);
    expect(broker.state().semanticState.editorRevision).toBe(admitted.semanticState.editorRevision);
    expect(Math.max(...events.map((event) => Buffer.byteLength(JSON.stringify(event.payload))))).toBeLessThan(768 * 1_024);
  });

  it("admits bounded string widgets and does not execute component factories in RPC mode", () => {
    const broker = brokerWith(() => {});
    const context = broker.context();
    let invoked = false;
    context.setWidget("component", (() => { invoked = true; return {} as never; }) as never);
    expect(invoked).toBe(false);
    expect(broker.state().semanticState.widgets).toEqual([]);

    context.setWidget("plain", Array.from({ length: 12 }, (_, index) => `line ${index}`));
    expect(broker.state().semanticState.widgets[0]).toMatchObject({ key: "plain", revision: 1, placement: "aboveEditor" });

    const beforeOversizedUpdate = broker.state();
    expect(() => context.setWidget("oversized", ["x".repeat(513)])).not.toThrow();
    expect(broker.state()).toEqual(beforeOversizedUpdate);

    expect(() => context.setWidget("plain", ["x".repeat(513)])).not.toThrow();
    expect(broker.state().semanticState.widgets[0]).toMatchObject({
      key: "plain",
      revision: 1,
      lines: Array.from({ length: 12 }, (_, index) => `line ${index}`),
    });
  });

  it("drops oversized RPC widget snapshots without escaping an extension callback", async () => {
    const broker = brokerWith(() => {});
    const context = broker.context();
    const snapshot = `PI_SUBAGENT_ASYNC_JSON:${JSON.stringify({
      kind: "pi-subagents.async-status-snapshot",
      version: 1,
      runs: [{ id: "run", label: "x".repeat(1_024), state: "running" }],
    })}`;

    await expect(new Promise<void>((resolve, reject) => {
      setImmediate(() => {
        try {
          context.setWidget("pi-subagents-async", [snapshot]);
          resolve();
        } catch (error) {
          reject(error);
        }
      });
    })).resolves.toBeUndefined();
    expect(broker.state().semanticState.widgets).toEqual([]);
  });

  it("contains a quote-dense async widget at the broker/store byte-boundary", async () => {
    const broker = brokerWith(() => {});
    const context = broker.context();
    const snapshot = `PI_SUBAGENT_ASYNC_JSON:${'"x",'.repeat(115)}`;
    expect(Buffer.byteLength(snapshot)).toBeLessThanOrEqual(512);
    expect(Buffer.byteLength(JSON.stringify(snapshot))).toBeGreaterThan(512);

    await expect(new Promise<void>((resolve) => {
      setImmediate(() => { context.setWidget("subagent-async", [snapshot]); resolve(); });
    })).resolves.toBeUndefined();
    expect(broker.state().semanticState.widgets).toEqual([]);
  });

  it("strips complete C0/C1 terminal protocol families from semantic projections", async () => {
    const events: unknown[] = [];
    const broker = brokerWith((_topic, payload) => events.push(payload));
    const context = broker.context();
    const hostile = "safe\u009b31m\u001b]52;c;clip\u0007\u001bPimage\u001b\\\u009dtitle\u009cmore";
    context.setStatus("key", hostile);
    context.setWorkingMessage(hostile);
    context.setWidget("widget", [hostile]);
    context.setTitle(hostile);
    context.notify(hostile, "warning");
    const pending = context.input(hostile, hostile);
    expect(JSON.stringify(broker.state())).not.toMatch(/[\u0000-\u0009\u000b-\u001f\u007f-\u009f]/u);
    expect(JSON.stringify(events)).not.toMatch(/[\u0000-\u0009\u000b-\u001f\u007f-\u009f]/u);
    broker.cancelAll();
    await expect(pending).rejects.toMatchObject({ code: "cancelled" });
  });

  it("bounds widget identities and scalar event fields", () => {
    const events: Array<{ topic: string; payload: unknown }> = [];
    const broker = brokerWith((topic, payload) => events.push({ topic, payload }));
    const context = broker.context();
    for (let index = 0; index < 24; index += 1) context.setWidget(`widget-${index}`, ["line"]);

    expect(() => context.setWidget("overflow", ["line"])).not.toThrow();
    expect(() => context.setWidget("unsupported", {})).not.toThrow();
    expect(() => context.setWidget("widget-0", {})).not.toThrow();
    expect(broker.state().semanticState.widgets.find((widget) => widget.key === "widget-0")?.lines).toEqual(["line"]);
    expect(() => context.setTitle("x".repeat(4 * 1_024))).not.toThrow();
    expect(() => context.notify("x".repeat(32 * 1_024), "info")).not.toThrow();
    expect(broker.state().semanticState.widgets).toHaveLength(24);
    expect(broker.state().semanticState.title).toBeUndefined();
    expect(events.every((event) => Buffer.byteLength(JSON.stringify(event.payload)) < 768 * 1_024)).toBe(true);
  });
});
