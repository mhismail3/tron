import { execFile } from "node:child_process";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { TerminalService } from "./terminal-service.js";
import { waitFor } from "../../test-support/wait-for.js";

/** Whether a program whose command line is exactly `command` is running. */
async function running(command: string): Promise<boolean> {
  return await new Promise(resolve => execFile("/usr/bin/pgrep", ["-fx", command], (_error, stdout) => resolve(stdout.trim().length > 0)));
}

describe("TerminalService", () => {
  it("opens a PTY and retains bounded replay", async () => {
    const cwd = await mkdtemp(join(tmpdir(), "tron-terminal-"));
    const events: Array<{ topic: string; payload: unknown }> = [];
    const service = new TerminalService(64_000, (_id, topic, payload) => events.push({ topic, payload }));
    const terminal = service.open("session", cwd, 80, 24);
    expect(service.belongsToSession(terminal.id, "session")).toBe(true);
    expect(service.belongsToSession(terminal.id, "other-session")).toBe(false);
    service.write(terminal.id, "write", "printf TRON_TERMINAL_OK\\n");

    await waitFor(() => JSON.stringify(events).includes("TRON_TERMINAL_OK"), "the terminal output");
    const replay = service.attach(terminal.id, 0);
    expect(replay.chunks.map((chunk) => chunk.data).join("")).toContain("TRON_TERMINAL_OK");
    await service.terminate(terminal.id);
    expect(service.activeTerminalIds()).not.toContain(terminal.id);
    expect(events.some(({ topic }) => topic === "terminal.exit")).toBe(true);
    service.dispose();
  });

  it("closes terminal admission atomically, refusing only for a busy PTY", async () => {
    const cwd = await mkdtemp(join(tmpdir(), "tron-terminal-drain-"));
    const active = new TerminalService(64_000, () => {});
    const first = active.open("session", cwd);
    active.write(first.id, "busy", "sleep 6479\r");
    await waitFor(async () => await running("sleep 6479") || undefined, "the foreground program");
    expect(await active.beginRestartDrain()).toEqual({ admitted: false, busy: { attached: 0, running: 1, input: 0 } });
    // A rejected restart did not leave the admission gate closed.
    const second = active.open("session", cwd);
    await active.terminate(first.id);
    await active.terminate(second.id);
    active.dispose();

    const draining = new TerminalService(64_000, () => {});
    expect(await draining.beginRestartDrain()).toEqual({ admitted: true, closed: 0 });
    expect(() => draining.open("session", cwd)).toThrow(/not accepting terminal/u);
    draining.dispose();
  });

  it("closes only a detached terminal idle at an empty prompt past the live idle period (#479)", async () => {
    const cwd = await mkdtemp(join(tmpdir(), "tron-terminal-idle-"));
    let now = 1_000_000;
    let limit: number | null = 60 * 60_000;
    const attached = new Set<string>();
    const events: Array<{ topic: string; payload: Record<string, unknown> }> = [];
    const logs: Array<{ message: string; metadata: Record<string, unknown> }> = [];
    const service = new TerminalService(64_000, (_id, topic, payload) => events.push({ topic, payload: payload as Record<string, unknown> }), {
      now: () => now,
      idle: { idleLimitMs: async () => limit, isAttached: id => attached.has(id) },
      log: (_level, message, metadata) => logs.push({ message, metadata }),
    });
    // A login shell runs children (path_helper) while it starts; each terminal
    // first finishes a command, so it is known to sit at its prompt.
    const ready = async (terminal: { id: string }, marker: string) => {
      service.write(terminal.id, `ready-${marker}`, `printf '${marker}_%s' READY\r`);
      await waitFor(() => service.attach(terminal.id, 0).chunks.map(chunk => chunk.data).join("").includes(`${marker}_READY`) || undefined, `${marker} at its prompt`);
    };
    const abandoned = service.open("session", cwd);
    const open = service.open("session", cwd);
    attached.add(open.id);
    const busy = service.open("session", cwd);
    const typed = service.open("session", cwd);
    const settled = service.open("session", cwd);
    await Promise.all([ready(abandoned, "ABANDONED"), ready(open, "OPEN"), ready(busy, "BUSY"), ready(typed, "TYPED")]);
    service.write(busy.id, "run", "sleep 6480\r");
    service.write(typed.id, "type", "echo unsaved");
    service.write(settled.id, "settled", "printf 'SETTLED_%s' OK\r");
    await waitFor(async () => await running("sleep 6480") || undefined, "the foreground program");
    await waitFor(() => service.attach(settled.id, 0).chunks.map(chunk => chunk.data).join("").includes("SETTLED_OK") || undefined, "the finished command");

    // Inside the period nothing closes.
    now += 59 * 60_000;
    await service.sweepIdle();
    expect(service.activeTerminalIds()).toHaveLength(5);
    // Off: past the period, still nothing closes.
    now += 2 * 60_000;
    limit = null;
    await service.sweepIdle();
    expect(service.activeTerminalIds()).toHaveLength(5);
    // The period applies at the next pass without a restart.
    limit = 60 * 60_000;
    // A prompt hook may run a short child right after a command; that pass
    // keeps the terminal and the next one (the interval's) closes it.
    await waitFor(async () => { await service.sweepIdle(); return service.activeTerminalIds().length <= 3 || undefined; }, "the idle pass");
    expect(service.activeTerminalIds().sort()).toEqual([open.id, busy.id, typed.id].sort());
    const closed = service.list("session").filter(terminal => terminal.exitedAt !== undefined);
    expect(closed.map(terminal => [terminal.id, terminal.closedReason]).sort())
      .toEqual([[abandoned.id, "Closed after 60 minutes idle"], [settled.id, "Closed after 60 minutes idle"]].sort());
    // A client that later shows it reads why it ended as its last line.
    expect(service.attach(abandoned.id, 0).chunks.at(-1)?.data).toBe("\r\n[Closed after 60 minutes idle]\r\n");
    expect(events.find(event => event.topic === "terminal.exit" && event.payload.terminalId === abandoned.id)?.payload)
      .toMatchObject({ closedReason: "Closed after 60 minutes idle" });
    expect(logs.find(log => log.message.includes(abandoned.id))?.metadata).toEqual({ event: "terminal.auto-closed", reason: "idle", elapsedMs: 61 * 60_000 });
    // No terminal content reaches the log.
    expect(JSON.stringify(logs)).not.toMatch(/sleep|unsaved|SETTLED|READY/u);

    // Input resets the period; a detached terminal counts from the last pass
    // that saw a device holding it open.
    now += 30 * 60_000;
    service.write(typed.id, "finish", "\x03");
    await service.sweepIdle();
    attached.delete(open.id);
    now += 59 * 60_000;
    await service.sweepIdle();
    expect(service.activeTerminalIds()).toHaveLength(3);
    now += 2 * 60_000;
    await waitFor(async () => { await service.sweepIdle(); return service.activeTerminalIds().length <= 1 || undefined; }, "the second idle pass");
    expect(service.activeTerminalIds()).toEqual([busy.id]);
    await service.terminate(busy.id);
    service.dispose();
  });
});
