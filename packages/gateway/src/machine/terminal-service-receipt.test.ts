import { beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { CommandReceiptStore } from "../transport/command-receipts.js";
import { isUncertainOutcome } from "../errors.js";

const fixture = vi.hoisted(() => ({
  exit: undefined as undefined | ((event: { exitCode: number }) => void),
  terminate: () => {},
  cleanup: "exited" as "exited" | "unknown" | undefined,
}));
vi.mock("./terminal-owner.js", () => ({
  spawnTerminalOwner: () => ({
    pty: {
      pid: 42001,
      onData: () => {},
      onExit: (callback: (event: { exitCode: number }) => void) => { fixture.exit = callback; },
    },
    cleanup: fixture.cleanup === undefined ? new Promise(() => {}) : Promise.resolve(fixture.cleanup),
    terminate: () => fixture.terminate(),
  }),
}));
import { TerminalService } from "./terminal-service.js";

describe("TerminalService Quit receipt during restart", () => {
  beforeEach(() => { fixture.cleanup = "exited"; fixture.terminate = () => {}; });

  it.each(["unknown", undefined] as const)("does not promote a PTY callback without verified native cleanup (%s)", async (outcome) => {
    fixture.cleanup = outcome;
    const broadcast = vi.fn();
    const service = new TerminalService(64_000, broadcast);
    const terminal = service.open("session", process.cwd());
    const quit = service.terminate(terminal.id).then(() => "terminated", (error: unknown) => error);
    fixture.exit!({ exitCode: 0 });
    await Promise.resolve();
    expect(broadcast).not.toHaveBeenCalled();
    if (outcome === "unknown") {
      await expect(service.terminate(terminal.id)).rejects.toMatchObject({ details: { outcomeUnknown: true } });
    }
    service.dispose();
    expect(isUncertainOutcome(await quit)).toBe(true);
  });

  it.each([false, true])("keeps a missing exit unknown on disposal (later signal failure: %s)", async (failLaterSignal) => {
    const broadcast = vi.fn();
    let signals = 0;
    fixture.terminate = () => {
      signals++;
      if (failLaterSignal && signals > 1) throw Object.assign(new Error("signal failed"), { code: "EPERM" });
    };
    const service = new TerminalService(64_000, broadcast);
    const terminal = service.open("session", process.cwd());
    const quit = service.terminate(terminal.id);
    const receipt = quit.then(() => "terminated" as const, (error: unknown) => error);
    let settled = false;
    void receipt.then(() => { settled = true; });
    await Promise.resolve();
    expect(settled).toBe(false);

    service.beginRestartDrain();
    service.dispose();
    service.dispose();
    const result = await receipt;
    expect(result).not.toBe("terminated");
    expect(isUncertainOutcome(result)).toBe(true);
    expect(broadcast.mock.calls.some((call) => call[1] === "terminal.exit")).toBe(false);
    // A later callback cannot retroactively manufacture a successful receipt.
    fixture.exit!({ exitCode: 0 });
    expect(await receipt).toBe(result);
  });

  it("persists the admitted Quit as uncertain and refuses replay after restart disposal", async () => {
    fixture.terminate = () => {};
    const root = await mkdtemp(join(tmpdir(), "tron-quit-receipt-"));
    const service = new TerminalService(64_000, () => {});
    try {
      const terminal = service.open("session", process.cwd());
      const store = new CommandReceiptStore(root);
      let admitted!: () => void;
      const started = new Promise<void>((resolve) => { admitted = resolve; });
      const operation = vi.fn(async () => {
        admitted();
        await service.terminate(terminal.id);
        return { terminated: true };
      });
      const quit = store.execute("device", "terminal.terminate", "terminal-quit", operation).then((value) => value, (error: unknown) => error);
      await Promise.race([started, quit.then((unexpected) => { throw unexpected; })]);
      service.beginRestartDrain();
      service.dispose();
      expect(isUncertainOutcome(await quit)).toBe(true);
      expect(await store.status("device", "terminal.terminate", "terminal-quit")).toEqual({ status: "pending" });
      await expect(store.execute("device", "terminal.terminate", "terminal-quit", operation)).rejects.toMatchObject({ details: { outcomeUnknown: true } });
      expect(operation).toHaveBeenCalledTimes(1);
    } finally {
      service.dispose();
      await rm(root, { recursive: true, force: true });
    }
  });

  it("only a native cleanup plus canonical exit callback settles Quit successfully", async () => {
    fixture.terminate = () => {};
    const service = new TerminalService(64_000, () => {});
    const terminal = service.open("session", process.cwd());
    const quit = service.terminate(terminal.id);
    service.beginRestartDrain();
    fixture.exit!({ exitCode: 0 });
    await expect(quit).resolves.toBeUndefined();
    service.dispose();
  });
});
