import { describe, expect, it, vi } from "vitest";
import { GatewayError } from "../errors.js";

const spawnState = vi.hoisted(() => ({ failNext: false, nextPid: 40_000 }));
const ptys = vi.hoisted(() => [] as Array<{
  emitData(data: string): void;
  emitExit(exitCode?: number): void;
}>);

vi.mock("node-pty", () => ({
  spawn: vi.fn(() => {
    if (spawnState.failNext) {
      spawnState.failNext = false;
      throw new Error("spawn failed");
    }
    let dataHandler: (data: string) => void = () => {};
    let exitHandler: (event: { exitCode: number; signal?: number }) => void = () => {};
    const pty = {
      pid: spawnState.nextPid++,
      onData(handler: (data: string) => void) { dataHandler = handler; return { dispose() {} }; },
      onExit(handler: (event: { exitCode: number; signal?: number }) => void) { exitHandler = handler; return { dispose() {} }; },
      write() {},
      resize() {},
      kill() {},
      emitData(data: string) { dataHandler(data); },
      emitExit(exitCode = 0) { exitHandler({ exitCode }); },
    };
    ptys.push(pty);
    return pty;
  }),
}));

import {
  MAX_ACTIVE_TERMINALS,
  MAX_RETAINED_TERMINALS,
  MAX_TERMINAL_OUTPUT_CHUNK_BYTES,
  TerminalService,
} from "./terminal-service.js";

describe("TerminalService hardening policy", () => {
  it("fails retryably at the global active PTY ceiling", () => {
    const service = new TerminalService(64_000, () => {});
    for (let index = 0; index < MAX_ACTIVE_TERMINALS; index += 1) {
      service.open(`session-${index}`, "/tmp");
    }

    try {
      service.open("overflow", "/tmp");
      throw new Error("expected active capacity rejection");
    } catch (error) {
      expect(error).toBeInstanceOf(GatewayError);
      expect(error).toMatchObject({ code: "busy", retryable: true });
    }
    expect(service.activeTerminalIds()).toHaveLength(MAX_ACTIVE_TERMINALS);
    service.dispose();
  });

  it("evicts only the oldest exited record and preserves retained insertion order", () => {
    const service = new TerminalService(64_000, () => {});
    const ids: string[] = [];
    ids.push(service.open("session", "/tmp").id);
    for (let index = 1; index < MAX_RETAINED_TERMINALS; index += 1) {
      ids.push(service.open("session", "/tmp").id);
      ptys.at(-1)!.emitExit();
    }

    const newest = service.open("session", "/tmp").id;
    expect(service.list("session").map(({ id }) => id)).toEqual([
      ids[0],
      ...ids.slice(2),
      newest,
    ]);
    expect(service.activeTerminalIds()).toEqual([ids[0], newest]);
    service.dispose();
  });

  it("preserves retained history when PTY spawn fails", () => {
    const service = new TerminalService(64_000, () => {});
    for (let index = 0; index < MAX_RETAINED_TERMINALS; index += 1) {
      service.open("session", "/tmp");
      if (index > 0) ptys.at(-1)!.emitExit();
    }
    const retained = service.list("session").map(({ id }) => id);
    spawnState.failNext = true;

    expect(() => service.open("session", "/tmp")).toThrow("spawn failed");
    expect(service.list("session").map(({ id }) => id)).toEqual(retained);
    service.dispose();
  });

  it("does not complete termination before the process group exits", async () => {
    const terminatedPids: number[] = [];
    const events: string[] = [];
    const service = new TerminalService(
      64_000,
      (_id, topic) => events.push(topic),
      (pty) => { terminatedPids.push(pty.pid); },
    );
    const terminal = service.open("session", "/tmp");
    const pty = ptys.at(-1)!;

    let settled = false;
    const terminating = service.terminate(terminal.id).then(() => { settled = true; });
    expect(terminatedPids).toEqual([expect.any(Number)]);
    expect(service.activeTerminalIds()).toContain(terminal.id);
    expect(events).not.toContain("terminal.exit");
    await Promise.resolve();
    expect(settled).toBe(false);

    pty.emitExit(137);
    await terminating;
    expect(settled).toBe(true);
    expect(service.activeTerminalIds()).not.toContain(terminal.id);
    expect(events).toContain("terminal.exit");
    service.dispose();
  });

  it("terminates active process groups and suppresses PTY callbacks after disposal", () => {
    const events: string[] = [];
    const terminatedPids: number[] = [];
    const service = new TerminalService(
      64_000,
      (_id, topic) => events.push(topic),
      (pty) => { terminatedPids.push(pty.pid); },
    );
    service.open("session", "/tmp");
    const pty = ptys.at(-1)!;
    service.dispose();

    expect(terminatedPids).toEqual([pty.pid]);
    expect(service.activeTerminalIds()).toEqual([]);
    pty.emitData("late");
    pty.emitExit();
    expect(events).toEqual([]);
  });

  it("splits arbitrary output on UTF-8 boundaries with contiguous sequences and exact replay", () => {
    const events: Array<{ sequence: number; data: string }> = [];
    const service = new TerminalService(768 * 1_024, (_id, topic, payload) => {
      if (topic === "terminal.output") events.push(payload as unknown as { sequence: number; data: string });
    });
    const terminal = service.open("session", "/tmp");
    const output = `${"a".repeat(MAX_TERMINAL_OUTPUT_CHUNK_BYTES - 1)}😀${"b".repeat(70_000)}`;
    ptys.at(-1)!.emitData(output);

    expect(events.length).toBeGreaterThan(1);
    expect(events.map(({ sequence }) => sequence)).toEqual(events.map((_, index) => index + 1));
    expect(events.every(({ data }) => Buffer.byteLength(data) <= MAX_TERMINAL_OUTPUT_CHUNK_BYTES)).toBe(true);
    expect(events.map(({ data }) => data).join("")).toBe(output);
    const replay = service.attach(terminal.id, 0);
    expect(replay.reset).toBe(false);
    expect(replay.chunks).toEqual(events.map(({ sequence, data }) => ({ sequence, data })));
    service.dispose();
  });

  it("accounts for JSON string escaping and never retains one chunk above the replay cap", () => {
    const service = new TerminalService(64, () => {});
    const terminal = service.open("session", "/tmp");
    ptys.at(-1)!.emitData("\n".repeat(64));

    const replay = service.attach(terminal.id, 0);
    expect(replay.terminal.sequence).toBe(1);
    expect(replay.chunks).toEqual([]);
    expect(replay.reset).toBe(true);
    service.dispose();
  });
});
