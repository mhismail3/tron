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
});
