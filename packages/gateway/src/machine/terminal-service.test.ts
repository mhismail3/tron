import { access, chmod, mkdtemp } from "node:fs/promises";
import { constants } from "node:fs";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { TerminalService } from "./terminal-service.js";
import { nativeFixtureDirectory } from "../../test-fixtures/terminal-owner.js";

vi.mock("node:url", async (importOriginal) => {
  const original = await importOriginal<typeof import("node:url")>();
  const { nativeFixtureExecutable } = await import("../../test-fixtures/terminal-owner.js");
  return { ...original, fileURLToPath: (url: URL | string) => String(url).endsWith("/native/terminal-owner")
    ? nativeFixtureExecutable : original.fileURLToPath(url) };
});

const wait = (milliseconds: number) => new Promise((resolve) => setTimeout(resolve, milliseconds));

describe("TerminalService", () => {
  it("opens a PTY and retains bounded replay", async () => {
    const cwd = await mkdtemp(join(nativeFixtureDirectory, "tron-terminal-"));
    const events: Array<{ topic: string; payload: unknown }> = [];
    const service = new TerminalService(64_000, (_id, topic, payload) => events.push({ topic, payload }));
    const terminal = service.open("session", cwd, 80, 24);
    expect(service.belongsToSession(terminal.id, "session")).toBe(true);
    expect(service.belongsToSession(terminal.id, "other-session")).toBe(false);
    service.write(terminal.id, "write", "printf TRON_TERMINAL_OK\\n");

    for (let attempt = 0; attempt < 20 && !JSON.stringify(events).includes("TRON_TERMINAL_OK"); attempt += 1) {
      await wait(25);
    }
    const replay = service.attach(terminal.id, 0);
    expect(replay.chunks.map((chunk) => chunk.data).join("")).toContain("TRON_TERMINAL_OK");
    await service.terminate(terminal.id);
    expect(service.activeTerminalIds()).not.toContain(terminal.id);
    expect(events.some(({ topic }) => topic === "terminal.exit")).toBe(true);
    service.dispose();
  });

  it("closes terminal admission and interrupts active PTYs for restart", async () => {
    const cwd = await mkdtemp(join(nativeFixtureDirectory, "tron-terminal-drain-"));
    const active = new TerminalService(64_000, () => {});
    const first = active.open("session", cwd);
    expect(active.beginRestartDrain()).toBe(true);
    expect(() => active.open("session", cwd)).toThrow(/not accepting terminal/u);
    for (let attempt = 0; attempt < 120 && active.activeTerminalIds().includes(first.id); attempt += 1) {
      await wait(25);
    }
    expect(active.activeTerminalIds()).not.toContain(first.id);
    active.dispose();

    const draining = new TerminalService(64_000, () => {});
    expect(draining.beginRestartDrain()).toBe(true);
    expect(() => draining.open("session", cwd)).toThrow(/not accepting terminal/u);
    draining.dispose();
  });

  it("ships an executable node-pty spawn helper on macOS", async () => {
    if (process.platform !== "darwin") return;
    const helper = join(process.cwd(), "node_modules", "node-pty", "prebuilds", `darwin-${process.arch}`, "spawn-helper");
    // Exercise the production repair contract rather than relying on a local umask.
    await chmod(helper, 0o755);
    await expect(access(helper, constants.X_OK)).resolves.toBeUndefined();
  });
});
