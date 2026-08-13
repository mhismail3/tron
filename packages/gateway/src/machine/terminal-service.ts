import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { spawn, type IPty } from "node-pty";
import { GatewayError } from "../errors.js";
import type { JsonValue } from "../protocol/types.js";

interface OutputChunk {
  sequence: number;
  data: string;
  bytes: number;
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

  constructor(
    private readonly replayBytes: number,
    private readonly broadcast: (terminalId: string, topic: string, payload: JsonValue) => void,
  ) {}

  open(sessionId: string, cwd: string, columns = 100, rows = 30, sessionEnvironment: Record<string, string> = {}): TerminalSummary {
    const id = randomUUID();
    const shell = process.env.SHELL && existsSync(process.env.SHELL) ? process.env.SHELL : "/bin/zsh";
    const pty = spawn(shell, ["-l"], {
      name: "xterm-256color",
      cols: columns,
      rows,
      cwd,
      env: { ...process.env, ...sessionEnvironment, TERM: "xterm-256color", COLORTERM: "truecolor", HOME: homedir() } as Record<string, string>,
    });
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
    };
    this.terminals.set(id, record);
    pty.onData((data) => this.append(record, data));
    pty.onExit(({ exitCode }) => {
      record.pty = undefined;
      record.exitCode = exitCode;
      record.exitedAt = new Date().toISOString();
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

  terminate(id: string): void {
    const terminal = this.get(id);
    terminal.pty?.kill("SIGTERM");
  }

  dispose(): void {
    for (const terminal of this.terminals.values()) terminal.pty?.kill("SIGHUP");
    this.terminals.clear();
  }

  private append(terminal: TerminalRecord, data: string): void {
    const chunk: OutputChunk = { sequence: ++terminal.sequence, data, bytes: Buffer.byteLength(data) };
    terminal.output.push(chunk);
    terminal.outputBytes += chunk.bytes;
    while (terminal.outputBytes > this.replayBytes && terminal.output.length > 1) {
      terminal.outputBytes -= terminal.output.shift()!.bytes;
    }
    this.broadcast(terminal.id, "terminal.output", { terminalId: terminal.id, sequence: chunk.sequence, data });
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
