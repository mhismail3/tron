import { getCapabilities, type Terminal } from "@earendil-works/pi-tui";
import { describe, expect, it, vi } from "vitest";
import {
  InMemoryTerminal,
  REMOTE_TUI_MAX_COLUMNS,
  REMOTE_TUI_MAX_INPUT_BYTES,
  REMOTE_TUI_MAX_ROWS,
} from "./in-memory-terminal.js";

describe("InMemoryTerminal", () => {
  it("implements the public Terminal contract without stdio", async () => {
    const stdout = vi.spyOn(process.stdout, "write");
    const terminal: Terminal = new InMemoryTerminal(80, 24);
    let input = "";
    let resizes = 0;
    terminal.start((data) => { input += data; }, () => { resizes += 1; });

    expect((terminal as InMemoryTerminal).injectInput("hello")).toBe(true);
    expect((terminal as InMemoryTerminal).resize(90, 30)).toBe(true);
    terminal.write("\u001b[2Jsecret");
    terminal.setTitle("safe\u0000 title");
    terminal.setProgress(true);
    terminal.moveBy(500);
    await terminal.drainInput();

    expect(input).toBe("hello");
    expect(resizes).toBe(1);
    expect(stdout).not.toHaveBeenCalled();
    expect((terminal as InMemoryTerminal).snapshot()).toMatchObject({
      started: true,
      title: "safe title",
      progressActive: true,
      verticalOffset: REMOTE_TUI_MAX_ROWS,
    });
    expect(getCapabilities()).toEqual({ images: null, trueColor: true, hyperlinks: true });
    expect(terminal.kittyProtocolActive).toBe(false);
    stdout.mockRestore();
  });

  it("clamps dimensions and retains only a tiny bounded write ring", () => {
    const terminal = new InMemoryTerminal(Number.POSITIVE_INFINITY, -20);
    expect(terminal.columns).toBe(1);
    expect(terminal.rows).toBe(1);
    terminal.resize(999, 999);
    expect(terminal.columns).toBe(REMOTE_TUI_MAX_COLUMNS);
    expect(terminal.rows).toBe(REMOTE_TUI_MAX_ROWS);

    for (let index = 0; index < 30; index += 1) terminal.write(`${index}:${"x".repeat(1_000)}`);
    const writes = terminal.snapshot().writeEvents;
    expect(writes).toHaveLength(16);
    expect(writes[0]?.sample.startsWith("14:")).toBe(true);
    expect(writes.every((event) => event.sample.length <= 256)).toBe(true);
  });

  it("has idempotent lifecycle and fails closed on oversized injected input", () => {
    const terminal = new InMemoryTerminal();
    const first = vi.fn();
    const replacement = vi.fn();
    terminal.start(first, vi.fn());
    terminal.start(replacement, vi.fn());
    expect(terminal.injectInput("x")).toBe(true);
    expect(first).not.toHaveBeenCalled();
    expect(replacement).toHaveBeenCalledWith("x");
    expect(() => terminal.injectInput("x".repeat(REMOTE_TUI_MAX_INPUT_BYTES + 1))).toThrow(/exceeds/);

    terminal.stop();
    terminal.stop();
    expect(terminal.injectInput("ignored")).toBe(false);
    expect(terminal.snapshot().started).toBe(false);
  });
});
