import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import type { IPty } from "node-pty";
import { spawnTerminalOwner, type TerminalOwner } from "./terminal-owner.js";
import { GatewayError, uncertainOutcome } from "../errors.js";
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
  owner: TerminalOwner;
  exitPromise: Promise<"exited" | "unknown">;
  resolveExit: (outcome: "exited" | "unknown") => void;
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
  private restartAdmissionClosed = false;

  constructor(
    replayBytes: number,
    private readonly broadcast: (terminalId: string, topic: string, payload: JsonValue) => void,
  ) {
    this.replayBytes = Math.max(0, Math.min(replayBytes, MAX_TERMINAL_REPLAY_ENCODED_BYTES));
  }

  /** Close admission and request native session cleanup without waiting. */
  beginRestartDrain(): boolean {
    if (this.restartAdmissionClosed) return true;
    this.restartAdmissionClosed = true;
    for (const id of this.activeTerminalIds()) {
      void this.terminate(id).catch(() => {
        // A failed cleanup must not become a fabricated terminal-exit success.
      });
    }
    return true;
  }

  open(sessionId: string, cwd: string, columns = 100, rows = 30, sessionEnvironment: Record<string, string> = {}): TerminalSummary {
    if (this.disposed) throw new GatewayError("conflict", "Terminal service is not available", true);
    if (this.restartAdmissionClosed) throw new GatewayError("busy", "Gateway restart is not accepting terminal sessions", true);
    if (this.activeTerminalIds().length >= MAX_ACTIVE_TERMINALS) {
      throw new GatewayError("busy", "Active terminals reached their bounded capacity", true);
    }
    const id = randomUUID();
    const shell = process.env.SHELL && existsSync(process.env.SHELL) ? process.env.SHELL : "/bin/zsh";
    const owner = spawnTerminalOwner(shell, {
      name: "xterm-256color",
      cols: columns,
      rows,
      cwd,
      env: { ...process.env, ...sessionEnvironment, TERM: "xterm-256color", COLORTERM: "truecolor", HOME: homedir() } as Record<string, string>,
    });
    const { pty } = owner;
    this.evictExitedForOpen();
    let resolveExit: TerminalRecord["resolveExit"] = () => {};
    const exitPromise = new Promise<"exited" | "unknown">((resolve) => { resolveExit = resolve; });
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
      owner,
      exitPromise,
      resolveExit,
    };
    this.terminals.set(id, record);
    pty.onData((data) => this.append(record, data));
    void owner.cleanup.then((outcome) => {
      if (outcome === "unknown") record.resolveExit("unknown");
    });
    pty.onExit(async ({ exitCode }) => {
      // Retire the PTY handle even when cleanup proof is unavailable. The
      // separate receipt stays unknown; a later Quit must not turn it into success.
      record.pty = undefined;
      if (await owner.cleanup !== "exited") {
        record.resolveExit("unknown");
        return;
      }
      if (this.disposed || this.terminals.get(record.id) !== record) {
        record.resolveExit("exited");
        return;
      }
      record.exitCode = exitCode;
      record.exitedAt = new Date().toISOString();
      record.resolveExit("exited");
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
    if (terminal.pty) terminal.owner.terminate();
    if (await terminal.exitPromise !== "exited") {
      throw uncertainOutcome("Terminal session cleanup could not be verified; termination outcome is unknown.");
    }
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    for (const terminal of this.terminals.values()) {
      const pty = terminal.pty;
      if (pty) {
        try { terminal.owner.terminate(); } catch { /* Preserve unknown below; never kill the SID owner first. */ }
      }
      // Disposal is not an exit receipt. Preserve uncertainty for an already
      // admitted Quit even if signalling was attempted or the PTY record is lost.
      terminal.resolveExit("unknown");
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
