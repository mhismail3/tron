import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { spawn, type IPty } from "node-pty";
import { GatewayError } from "../errors.js";
import type { JsonValue } from "../protocol/types.js";

const MAX_RETAINED_TERMINALS = 128;
const MAX_ACTIVE_TERMINALS = 16;
const MAX_TERMINAL_OUTPUT_CHUNK_BYTES = 64 * 1_024;
/** How often the idle owner looks for abandoned terminals; an idle terminal is
 * closed at most this long after its period elapses. */
export const TERMINAL_IDLE_SWEEP_MS = 30_000;
/** Input ending in Enter, Ctrl-C or Ctrl-D leaves the shell with no half-typed
 * line; anything else (a partial command, an arrow key) may be unsaved input. */
const SETTLED_INPUT = /[\r\n\x03\x04]$/u;

interface OutputChunk {
  sequence: number;
  data: string;
  encodedBytes: number;
}

interface TerminalRecord {
  id: string;
  sessionId: string;
  cwd: string;
  createdAt: string;
  exitedAt?: string;
  exitCode?: number;
  sequence: number;
  output: OutputChunk[];
  outputBytes: number;
  writes: Set<string>;
  pty: IPty | undefined;
  exitPromise: Promise<void>;
  resolveExit: () => void;
  /** Last input, attachment or replay (ms). Output alone is not use (#479). */
  lastUsedAt: number;
  /** The last input may have left a half-typed line at the prompt. */
  pendingInput: boolean;
  /** Why the Gateway closed this terminal, in the words a client shows. */
  closedReason?: string;
}

/** Why a live terminal cannot be closed without the user (#479). */
export type TerminalBusyReason = "attached" | "running" | "input";

/** The Gateway-owned idle policy: the configured period and the transport's
 * view of which terminals a client has open. */
export interface TerminalIdlePolicy {
  /** The idle period in ms, or null when auto-close is off. */
  idleLimitMs(): Promise<number | null>;
  isAttached(terminalId: string): boolean;
}

export interface TerminalServiceOptions {
  idle?: TerminalIdlePolicy;
  now?: () => number;
  /** Diagnostics: the terminal id goes in the message; `elapsedMs` is the idle
   * duration and `reason` is `idle` or `restart`. Never terminal content. */
  log?: (level: "info" | "warning", message: string, metadata: { event: string; reason?: string; elapsedMs?: number; error?: string }) => void;
  terminateProcessGroup?: (pty: IPty) => void;
}

export type RestartDrainAdmission =
  | { admitted: true; closed: number }
  | { admitted: false; busy: Record<TerminalBusyReason, number> };

function terminatePtyProcessGroup(pty: IPty): void {
  if (process.platform === "win32") {
    pty.kill();
    return;
  }
  // node-pty creates the shell as the leader of its own process group. Quit is
  // destructive by contract, so retire the whole group rather than signalling
  // only the login shell and leaving foreground children behind.
  process.kill(-pty.pid, "SIGKILL");
}

interface TerminalSummary {
  id: string;
  sessionId: string;
  cwd: string;
  createdAt: string;
  exitedAt?: string;
  exitCode?: number;
  sequence: number;
  closedReason?: string;
}

/** Process ids that currently have at least one child. A shell with a child
 * runs a program (foreground or background job), so it is never idle. */
async function parentProcessIds(): Promise<Set<number>> {
  const output = await new Promise<string>((resolve, reject) => {
    execFile("/bin/ps", ["-A", "-o", "ppid="], { timeout: 10_000, maxBuffer: 4 * 1_024 * 1_024 }, (error, stdout) => {
      if (error) reject(error); else resolve(stdout);
    });
  });
  return new Set(output.split("\n").map(line => Number(line.trim())).filter(pid => Number.isInteger(pid) && pid > 0));
}

function minutes(ms: number): string {
  const value = Math.round(ms / 60_000);
  return value === 1 ? "1 minute" : `${value} minutes`;
}

export class TerminalService {
  private readonly terminals = new Map<string, TerminalRecord>();

  private readonly replayBytes: number;
  private disposed = false;
  private restartAdmissionClosed = false;
  private drainCheck: Promise<RestartDrainAdmission> | undefined;
  private sweeping = false;
  private readonly sweepTimer: NodeJS.Timeout | undefined;
  private readonly now: () => number;
  private readonly terminateProcessGroup: (pty: IPty) => void;

  constructor(
    replayBytes: number,
    private readonly broadcast: (terminalId: string, topic: string, payload: JsonValue) => void,
    private readonly options: TerminalServiceOptions = {},
  ) {
    // `config.terminalReplayBytes` owns the replay cap; this service enforces
    // exactly the admitted value instead of re-declaring a second ceiling.
    this.replayBytes = Math.max(0, replayBytes);
    this.now = options.now ?? Date.now;
    this.terminateProcessGroup = options.terminateProcessGroup ?? terminatePtyProcessGroup;
    if (options.idle) {
      this.sweepTimer = setInterval(() => { void this.sweepIdle(); }, TERMINAL_IDLE_SWEEP_MS);
      this.sweepTimer.unref();
    }
  }

  /** Restart and stop admission (#479). A detached terminal sitting at an empty
   * prompt is abandoned: it is closed so the drain can proceed. A terminal a
   * client has open, one running a program, or one holding typed input refuses
   * the drain and stays untouched. When admitted, future PTY admission closes
   * before any previously dispatched terminal.open can spawn. */
  beginRestartDrain(): Promise<RestartDrainAdmission> {
    // Concurrent restart and stop requests share one decision.
    this.drainCheck ??= this.admitRestartDrain().finally(() => { this.drainCheck = undefined; });
    return this.drainCheck;
  }

  private async admitRestartDrain(): Promise<RestartDrainAdmission> {
    if (this.restartAdmissionClosed) return { admitted: true, closed: 0 };
    // Close admission while the process table is read, so no terminal opens
    // between the decision and the drain; a refusal reopens it.
    this.restartAdmissionClosed = true;
    const busy: Record<TerminalBusyReason, number> = { attached: 0, running: 0, input: 0 };
    let idle: TerminalRecord[] = [];
    try {
      const active = this.activeRecords();
      const usedAt = new Map(active.map(record => [record, record.lastUsedAt]));
      const parents = active.length === 0 ? new Set<number>() : await parentProcessIds();
      for (const record of this.activeRecords()) {
        const reason = usedAt.get(record) === record.lastUsedAt ? this.busyReason(record, parents) : "input";
        if (reason) busy[reason] += 1; else idle.push(record);
      }
    } catch (error) {
      this.restartAdmissionClosed = false;
      throw error;
    }
    if (busy.attached + busy.running + busy.input > 0) {
      this.restartAdmissionClosed = false;
      return { admitted: false, busy };
    }
    idle = idle.filter(record => record.pty !== undefined);
    await Promise.all(idle.map(record => this.close(record, "Closed for a Gateway restart", "restart")));
    return { admitted: true, closed: idle.length };
  }

  /** One idle pass (#479): close each live terminal no client has had open and
   * nobody has typed into for the configured period, if it sits at an empty
   * prompt. The interval drives it; tests call it with an injected clock. */
  async sweepIdle(): Promise<void> {
    const policy = this.options.idle;
    if (!policy || this.sweeping || this.disposed) return;
    this.sweeping = true;
    try {
      const now = this.now();
      for (const record of this.activeRecords()) {
        if (policy.isAttached(record.id)) record.lastUsedAt = now;
      }
      const limit = await policy.idleLimitMs();
      if (limit === null) return;
      const expired = (record: TerminalRecord) => this.now() - record.lastUsedAt >= limit;
      if (!this.activeRecords().some(expired)) return;
      const parents = await parentProcessIds();
      // Re-check after the await: a write or attachment since then keeps it.
      const idle = this.activeRecords().filter(record => expired(record) && this.busyReason(record, parents) === undefined);
      await Promise.all(idle.map(record => this.close(record, `Closed after ${minutes(limit)} idle`, "idle")));
    } catch (error) {
      // An unreadable setting or process table keeps every terminal.
      this.options.log?.("warning", "Terminal idle check failed", {
        event: "terminal.idle-check-failed", error: error instanceof Error ? error.message : String(error),
      });
    } finally {
      this.sweeping = false;
    }
  }

  private busyReason(record: TerminalRecord, parents: Set<number>): TerminalBusyReason | undefined {
    if (this.options.idle?.isAttached(record.id)) return "attached";
    if (record.pty && parents.has(record.pty.pid)) return "running";
    if (record.pendingInput) return "input";
    return undefined;
  }

  private async close(record: TerminalRecord, reason: string, cause: "idle" | "restart"): Promise<void> {
    if (!record.pty) return;
    const idleMs = this.now() - record.lastUsedAt;
    record.closedReason = reason;
    // The reason is the terminal's last line, so every client that shows the
    // terminal (live or from replay) reads why it ended, never a silent stop.
    this.append(record, `\r\n[${reason}]\r\n`);
    await this.terminate(record.id);
    this.options.log?.("info", `Terminal ${record.id} closed: ${reason}`, { event: "terminal.auto-closed", reason: cause, elapsedMs: idleMs });
  }

  private activeRecords(): TerminalRecord[] {
    return [...this.terminals.values()].filter(record => record.pty !== undefined);
  }

  open(sessionId: string, cwd: string, columns = 100, rows = 30, sessionEnvironment: Record<string, string> = {}): TerminalSummary {
    if (this.disposed) throw new GatewayError("conflict", "Terminal service is not available", true);
    if (this.restartAdmissionClosed) throw new GatewayError("busy", "Gateway restart is not accepting terminal sessions", true);
    if (this.activeTerminalIds().length >= MAX_ACTIVE_TERMINALS) {
      throw new GatewayError("busy", "Active terminals reached their bounded capacity", true);
    }
    const id = randomUUID();
    const shell = process.env.SHELL && existsSync(process.env.SHELL) ? process.env.SHELL : "/bin/zsh";
    const pty = spawn(shell, ["-l"], {
      name: "xterm-256color",
      cols: columns,
      rows,
      cwd,
      env: { ...process.env, ...sessionEnvironment, TERM: "xterm-256color", COLORTERM: "truecolor", HOME: homedir() } as Record<string, string>,
    });
    this.evictExitedForOpen();
    let resolveExit = () => {};
    const exitPromise = new Promise<void>((resolve) => { resolveExit = resolve; });
    const record: TerminalRecord = {
      id,
      sessionId,
      cwd,
      createdAt: new Date().toISOString(),
      sequence: 0,
      output: [],
      outputBytes: 0,
      writes: new Set(),
      pty,
      exitPromise,
      resolveExit,
      lastUsedAt: this.now(),
      pendingInput: false,
    };
    this.terminals.set(id, record);
    pty.onData((data) => this.append(record, data));
    pty.onExit(({ exitCode }) => {
      if (this.disposed || this.terminals.get(record.id) !== record) {
        record.resolveExit();
        return;
      }
      record.pty = undefined;
      record.exitCode = exitCode;
      record.exitedAt = new Date().toISOString();
      record.resolveExit();
      this.broadcast(id, "terminal.exit", {
        terminalId: id, exitCode, sequence: record.sequence, ...(record.closedReason ? { closedReason: record.closedReason } : {}),
      });
    });
    return this.summary(record);
  }

  list(sessionId: string): TerminalSummary[] {
    return [...this.terminals.values()].filter((terminal) => terminal.sessionId === sessionId).map((terminal) => this.summary(terminal));
  }

  belongsToSession(id: string, sessionId: string): boolean {
    return this.get(id).sessionId === sessionId;
  }

  activeTerminalIds(): string[] {
    return this.activeRecords().map((terminal) => terminal.id);
  }

  attach(id: string, afterSequence: number): { terminal: TerminalSummary; chunks: Array<{ sequence: number; data: string }>; reset: boolean } {
    const terminal = this.get(id);
    terminal.lastUsedAt = this.now();
    const first = terminal.output[0]?.sequence ?? terminal.sequence + 1;
    const reset = afterSequence + 1 < first;
    return {
      terminal: this.summary(terminal),
      chunks: terminal.output.filter((chunk) => reset || chunk.sequence > afterSequence).map(({ sequence, data }) => ({ sequence, data })),
      reset,
    };
  }

  write(id: string, writeId: string, data: string): void {
    const terminal = this.get(id);
    if (terminal.writes.has(writeId)) return;
    if (!terminal.pty) throw new GatewayError("conflict", "Terminal has exited");
    terminal.writes.add(writeId);
    if (terminal.writes.size > 512) terminal.writes.delete(terminal.writes.values().next().value!);
    terminal.lastUsedAt = this.now();
    if (data.length > 0) terminal.pendingInput = !SETTLED_INPUT.test(data);
    terminal.pty.write(data);
  }

  resize(id: string, columns: number, rows: number): void {
    const terminal = this.get(id);
    terminal.pty?.resize(columns, rows);
  }

  async terminate(id: string): Promise<void> {
    const terminal = this.get(id);
    const pty = terminal.pty;
    if (!pty) return;
    try {
      this.terminateProcessGroup(pty);
    } catch (error) {
      // Process exit can win the race before node-pty delivers its callback.
      // ESRCH therefore still waits for the canonical callback; other failures
      // remain visible instead of reporting a false successful quit.
      if ((error as NodeJS.ErrnoException).code !== "ESRCH" && terminal.pty !== undefined) throw error;
    }
    await terminal.exitPromise;
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    if (this.sweepTimer) clearInterval(this.sweepTimer);
    for (const terminal of this.terminals.values()) {
      const pty = terminal.pty;
      if (pty) {
        try {
          this.terminateProcessGroup(pty);
        } catch (error) {
          if ((error as NodeJS.ErrnoException).code !== "ESRCH") {
            try { pty.kill("SIGKILL"); } catch {}
          }
        }
      }
      terminal.resolveExit();
    }
    this.terminals.clear();
  }

  private append(terminal: TerminalRecord, data: string): void {
    if (this.disposed || this.terminals.get(terminal.id) !== terminal) return;
    for (const piece of splitUtf8(data, MAX_TERMINAL_OUTPUT_CHUNK_BYTES)) {
      const sequence = ++terminal.sequence;
      const chunk: OutputChunk = {
        sequence,
        data: piece,
        encodedBytes: Buffer.byteLength(JSON.stringify({ sequence, data: piece })) + 1,
      };
      terminal.output.push(chunk);
      terminal.outputBytes += chunk.encodedBytes;
      while (terminal.outputBytes > this.replayBytes && terminal.output.length > 0) {
        terminal.outputBytes -= terminal.output.shift()!.encodedBytes;
      }
      this.broadcast(terminal.id, "terminal.output", { terminalId: terminal.id, sequence, data: piece });
    }
  }

  private evictExitedForOpen(): void {
    if (this.terminals.size < MAX_RETAINED_TERMINALS) return;
    for (const [id, terminal] of this.terminals) {
      if (terminal.pty !== undefined) continue;
      this.terminals.delete(id);
      if (this.terminals.size < MAX_RETAINED_TERMINALS) return;
    }
  }

  private get(id: string): TerminalRecord {
    const terminal = this.terminals.get(id);
    if (!terminal) throw new GatewayError("not_found", "Terminal was not found");
    return terminal;
  }

  private summary(terminal: TerminalRecord): TerminalSummary {
    return {
      id: terminal.id,
      sessionId: terminal.sessionId,
      cwd: terminal.cwd,
      createdAt: terminal.createdAt,
      ...(terminal.exitedAt ? { exitedAt: terminal.exitedAt } : {}),
      ...(terminal.exitCode === undefined ? {} : { exitCode: terminal.exitCode }),
      sequence: terminal.sequence,
      ...(terminal.closedReason ? { closedReason: terminal.closedReason } : {}),
    };
  }
}

function splitUtf8(data: string, maximumBytes: number): string[] {
  if (Buffer.byteLength(data) <= maximumBytes) return [data];
  const chunks: string[] = [];
  let start = 0;
  let bytes = 0;
  for (let index = 0; index < data.length;) {
    const codePoint = data.codePointAt(index)!;
    const width = codePoint > 0xffff ? 2 : 1;
    const next = index + width;
    const characterBytes = Buffer.byteLength(data.slice(index, next));
    if (bytes + characterBytes > maximumBytes) {
      chunks.push(data.slice(start, index));
      start = index;
      bytes = 0;
    }
    bytes += characterBytes;
    index = next;
  }
  chunks.push(data.slice(start));
  return chunks;
}
