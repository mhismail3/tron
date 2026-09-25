import { type Component, type Focusable } from "@earendil-works/pi-tui";
import { afterEach, describe, expect, it, vi } from "vitest";
import { CapturingTuiMainScreen } from "./capturing-tui-main-screen.js";
import { InMemoryTerminal } from "./in-memory-terminal.js";
import { RecordingComponent, type ComponentDiagnostic } from "./recording-component.js";

function component(lines: string[], input = vi.fn()): Component & Focusable {
  return {
    focused: false,
    render: vi.fn(() => lines),
    handleInput: input,
    invalidate: vi.fn(),
  };
}

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
});

describe("public TuiMainScreen feasibility harness", () => {

  it("bounds raw render output before compositor work and emits nothing after stop", () => {
    const terminal = new InMemoryTerminal(40, 12);
    const onRender = vi.fn();
    const diagnostics: ComponentDiagnostic[] = [];
    const tui = new CapturingTuiMainScreen(terminal, { onRender });
    const giantControl = new RecordingComponent(component(["\u001b[31m".repeat(100)]), {
      maximumSourceBytes: 256,
      onDiagnostic: (diagnostic) => diagnostics.push(diagnostic),
    });
    tui.addChild(giantControl);
    tui.renderNow();
    expect(giantControl.capture).toMatchObject({ failed: true, lines: ["[Extension component unavailable]"] });
    expect(diagnostics).toContainEqual(expect.objectContaining({ code: "render-invalid" }));

    const giantArray = new RecordingComponent(component(Array.from({ length: 121 }, () => "x")));
    expect(giantArray.render(40)).toEqual(["[Extension component unavailable]"]);
    expect(giantArray.capture?.failed).toBe(true);

    const cycles = tui.renderCycles;
    tui.stop({ preserveScreen: true });
    tui.renderNow();
    expect(tui.renderCycles).toBe(cycles);
    expect(onRender).toHaveBeenCalledTimes(1);
  });

  it("contains component and host callback failures and disposes once", () => {
    const terminal = new InMemoryTerminal(40, 12);
    const diagnostics: ComponentDiagnostic[] = [];
    const tui = new CapturingTuiMainScreen(terminal, {
      onRender: () => { throw new Error("callback\u001b]52;c;secret\u0007 safe"); },
      onDiagnostic: (diagnostic) => diagnostics.push(diagnostic),
    });
    const dispose = vi.fn(() => { throw new Error("dispose failed"); });
    const bad: Component & { dispose(): void } = {
      render: () => { throw new Error("render failed"); },
      handleInput: () => { throw new Error("input failed"); },
      invalidate: () => { throw new Error("invalidate failed"); },
      dispose,
    };
    const componentDiagnostics: ComponentDiagnostic[] = [];
    const recording = new RecordingComponent(bad, { onDiagnostic: (diagnostic) => componentDiagnostics.push(diagnostic) });
    tui.addChild(recording);
    tui.setFocus(recording);

    expect(() => tui.renderNow()).not.toThrow();
    expect(recording.capture).toMatchObject({ failed: true, lines: ["[Extension component unavailable]"] });
    expect(() => recording.handleInput("x")).not.toThrow();
    expect(() => recording.invalidate()).not.toThrow();
    recording.dispose();
    recording.dispose();
    expect(dispose).toHaveBeenCalledTimes(1);
    expect(componentDiagnostics.map(({ code }) => code)).toEqual(expect.arrayContaining([
      "render-failed", "input-failed", "invalidate-failed", "dispose-failed",
    ]));
    expect(diagnostics).toContainEqual(expect.objectContaining({ code: "render-failed", message: "callback safe" }));
  });
});
