import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { spawn, type IPty } from "node-pty";
import { GatewayError } from "../errors.js";
import type { JsonValue } from "../protocol/types.js";

export const MAX_RETAINED_TERMINALS = 128;
export const MAX_ACTIVE_TERMINALS = 16;
export const MAX_TERMINAL_OUTPUT_CHUNK_BYTES = 64 * 1_024;
export const MAX_TERMINAL_REPLAY_ENCODED_BYTES = 768 * 1_024;

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
}

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

export interface TerminalSummary {
  id: string;
  sessionId: string;
  cwd: string;
  createdAt: string;
  exitedAt?: string;
  exitCode?: number;
  sequence: number;
}

export class TerminalService {
  private readonly terminals = new Map<string, TerminalRecord>();

  private readonly replayBytes: number;
  private disposed = false;

  constructor(
    replayBytes: number,
    private readonly broadcast: (terminalId: string, topic: string, payload: JsonValue) => void,
    private readonly terminateProcessGroup: (pty: IPty) => void = terminatePtyProcessGroup,
  ) {
    this.replayBytes = Math.max(0, Math.min(replayBytes, MAX_TERMINAL_REPLAY_ENCODED_BYTES));
  }

  open(sessionId: string, cwd: string, columns = 100, rows = 30, sessionEnvironment: Record<string, string> = {}): TerminalSummary {
    if (this.disposed) throw new GatewayError("conflict", "Terminal service is not available", true);
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
      this.broadcast(id, "terminal.exit", { terminalId: id, exitCode, sequence: record.sequence });
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
    return [...this.terminals.values()].filter((terminal) => terminal.pty !== undefined).map((terminal) => terminal.id);
  }

  attach(id: string, afterSequence: number): { terminal: TerminalSummary; chunks: Array<{ sequence: number; data: string }>; reset: boolean } {
    const terminal = this.get(id);
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
