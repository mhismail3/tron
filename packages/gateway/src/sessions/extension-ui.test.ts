import { describe, expect, it } from "vitest";
import { ExtensionUIBroker } from "./extension-ui.js";

describe("ExtensionUIBroker", () => {
  it("survives client churn until a response arrives", async () => {
    const broker = new ExtensionUIBroker(() => {});
    const result = broker.context().select("Choose", ["one", "two"]);
    const interaction = broker.interactions()[0];
    expect(interaction?.method).toBe("select");
    broker.respond(interaction!.id, "two", false);
    await expect(result).resolves.toBe("two");
  });

  it("returns undefined when a dialog times out", async () => {
    const broker = new ExtensionUIBroker(() => {});
    await expect(broker.context().input("Input", undefined, { timeout: 1 })).resolves.toBeUndefined();
    expect(broker.interactions()).toHaveLength(0);
  });

  it("degrades custom TUI and keeps portable state reconnect-safe", async () => {
    const events: Array<{ topic: string; payload: unknown }> = [];
    const broker = new ExtensionUIBroker((topic, payload) => events.push({ topic, payload }));
    const context = broker.context();

    await expect(context.custom(() => ({}) as never)).resolves.toBeUndefined();
    context.setStatus("build", "Checking");
    context.setWorkingMessage("Working carefully");
    context.setWorkingVisible(false);
    context.setHiddenThinkingLabel("Private reasoning");
    context.setWidget("summary", ["one", "two"], { placement: "belowEditor" });
    context.setTitle("Extension title");
    context.setEditorText("replace");
    context.pasteToEditor(" + append");

    expect(broker.state()).toMatchObject({
      statuses: { build: "Checking" },
      working: { message: "Working carefully", visible: false },
      hiddenThinkingLabel: "Private reasoning",
      widgets: [{ key: "summary", lines: ["one", "two"], placement: "belowEditor" }],
      title: "Extension title",
      editorRevision: 2,
      editorText: "replace + append",
    });

    context.setStatus("build", undefined);
    context.setWidget("summary", undefined);
    expect(broker.state().statuses).toEqual({});
    expect(broker.state().widgets).toEqual([]);
    expect(events.some((event) => event.topic === "session.editorText")).toBe(true);
  });

  it("bounds retained statuses atomically while allowing updates and removals", () => {
    const broker = new ExtensionUIBroker(() => {});
    const context = broker.context();
    for (let index = 0; index < 32; index += 1) context.setStatus(`status-${index}`, `value-${index}`);

    expect(Object.keys(broker.state().statuses)).toHaveLength(32);
    expect(() => context.setStatus("overflow", "value")).toThrow(expect.objectContaining({
      code: "busy",
      retryable: true,
    }));
    expect(() => context.setStatus("status-0", "x".repeat(4 * 1_024))).toThrow(expect.objectContaining({
      code: "conflict",
    }));
    expect(broker.state().statuses["status-0"]).toBe("value-0");

    context.setStatus("status-0", "updated");
    context.setStatus("status-1", undefined);
    context.setStatus("replacement", "admitted");
    expect(broker.state().statuses["status-0"]).toBe("updated");
    expect(broker.state().statuses.replacement).toBe("admitted");
  });

  it("bounds retained interactions, options, timeouts, and aggregate bytes", async () => {
    const broker = new ExtensionUIBroker(() => {});
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
    const broker = new ExtensionUIBroker(() => {});
    const context = broker.context();

    await expect((context.select as unknown as (title: string, options: unknown) => Promise<unknown>)("Choose", null))
      .rejects.toMatchObject({ code: "conflict" });
    expect(() => (context.setWorkingVisible as unknown as (visible: unknown) => void)("yes"))
      .toThrow(expect.objectContaining({ code: "conflict" }));
    expect(() => (context.pasteToEditor as unknown as (text: unknown) => void)(42))
      .toThrow(expect.objectContaining({ code: "conflict" }));
    expect(broker.state().working.visible).toBe(true);
    expect(broker.state().editorText).toBe("");
    expect(broker.interactions()).toEqual([]);
  });

  it("enforces one aggregate retained-state budget transactionally", async () => {
    const broker = new ExtensionUIBroker(() => {});
    const context = broker.context();
    for (let index = 0; index < 32; index += 1) {
      context.setStatus(`status-${index}`, "\\".repeat(2_047));
    }
    const lines = Array.from({ length: 12 }, () => "\\".repeat(512));
    for (let index = 0; index < 24; index += 1) context.setWidget(`widget-${index}`, lines);
    context.setEditorText("x".repeat(192 * 1_024 - 2));
    const admitted = broker.state();

    expect(Buffer.byteLength(JSON.stringify(admitted))).toBeLessThanOrEqual(640 * 1_024);
    const overflow = context.confirm("Aggregate overflow", "\\".repeat(16_383));
    if (broker.interactions().length > 0) broker.cancelAll();
    await expect(overflow).rejects.toMatchObject({
      code: "busy",
      retryable: true,
    });
    expect(broker.interactions()).toEqual([]);
    expect(broker.state()).toEqual(admitted);
  });

  it("bounds editor mutations before state or event publication", () => {
    const events: Array<{ topic: string; payload: unknown }> = [];
    const broker = new ExtensionUIBroker((topic, payload) => events.push({ topic, payload }));
    const context = broker.context();
    const initial = "a".repeat(128 * 1_024);
    const suffix = "b".repeat(32 * 1_024);
    context.setEditorText(initial);
    context.pasteToEditor(suffix);
    const admitted = broker.state();

    expect(admitted.editorText).toBe(initial + suffix);
    expect(admitted.editorRevision).toBe(2);
    expect(() => context.pasteToEditor("c".repeat(40 * 1_024))).toThrow(expect.objectContaining({
      code: "conflict",
    }));
    expect(broker.state().editorText).toBe(admitted.editorText);
    expect(broker.state().editorRevision).toBe(admitted.editorRevision);
    expect(Math.max(...events.map((event) => Buffer.byteLength(JSON.stringify(event.payload))))).toBeLessThan(768 * 1_024);
  });

  it("projects bounded plain text from extension-owned TUI widgets", () => {
    const broker = new ExtensionUIBroker(() => {});
    const context = broker.context();
    const component = {
      render: () => [
        "\u001b[32mAsync agents · background\u001b[0m",
        ...Array.from({ length: 20 }, (_, index) => `worker ${index}`),
      ],
    };

    context.setWidget("subagent-async", (() => component) as never);

    expect(broker.state().widgets).toEqual([{
      key: "subagent-async",
      placement: "aboveEditor",
      lines: [
        "Async agents · background",
        ...Array.from({ length: 11 }, (_, index) => `worker ${index}`),
      ],
    }]);

    context.setWidget("plain", ["x".repeat(600), ...Array.from({ length: 20 }, (_, index) => `line ${index}`)]);
    const plain = broker.state().widgets.find((widget) => widget.key === "plain")!;
    expect(plain.lines).toHaveLength(12);
    expect(plain.lines[0]).toHaveLength(512);

    context.setWidget("unicode", ["😀".repeat(300)]);
    const unicode = broker.state().widgets.find((widget) => widget.key === "unicode")!;
    expect(Buffer.byteLength(unicode.lines[0]!)).toBeLessThanOrEqual(512);
    expect(unicode.lines[0]).not.toContain("�");
    context.setWidget("replacement", [`${"x".repeat(509)}�overflow`]);
    expect(broker.state().widgets.find((widget) => widget.key === "replacement")?.lines[0]).toBe(
      `${"x".repeat(509)}�`,
    );
    context.setWidget("ignored", Array.from({ length: 257 }, () => "line"));
    expect(broker.state().widgets.some((widget) => widget.key === "ignored")).toBe(false);
  });

  it("bounds widget identities and scalar event fields", () => {
    const events: Array<{ topic: string; payload: unknown }> = [];
    const broker = new ExtensionUIBroker((topic, payload) => events.push({ topic, payload }));
    const context = broker.context();
    for (let index = 0; index < 24; index += 1) context.setWidget(`widget-${index}`, ["line"]);

    expect(() => context.setWidget("overflow", ["line"])).toThrow(expect.objectContaining({ code: "busy" }));
    expect(() => context.setWidget("unsupported", {})).not.toThrow();
    expect(() => context.setWidget("widget-0", {})).not.toThrow();
    expect(broker.state().widgets.find((widget) => widget.key === "widget-0")?.lines).toEqual(["line"]);
    expect(() => context.setTitle("x".repeat(4 * 1_024))).toThrow(expect.objectContaining({ code: "conflict" }));
    expect(() => context.notify("x".repeat(32 * 1_024), "info")).toThrow(expect.objectContaining({ code: "conflict" }));
    expect(broker.state().widgets).toHaveLength(24);
    expect(broker.state().title).toBeUndefined();
    expect(events.every((event) => Buffer.byteLength(JSON.stringify(event.payload)) < 768 * 1_024)).toBe(true);
  });
});
