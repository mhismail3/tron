import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { closeSync, mkdirSync, openSync, realpathSync, statSync, truncateSync, unlinkSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { createConnection, createServer, type Server, type Socket } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { TERMINAL_IDLE_DEFAULT_MINUTES, schemaKey } from "../admin/settings-schema.js";
import { GatewayError } from "../errors.js";
import type { JsonValue } from "../protocol/types.js";
import { TerminalService } from "./terminal-service.js";

/**
 * Mac Terminal's shell host (README "Mac Terminal", #1075): the process on the
 * Mac that holds Mac Terminal's login shells, so a shell outlives the SSH
 * connection that opened it. iOS drops sockets in the background and a sheet
 * can be dismissed; the shell, its running programs and its replay stay here
 * until the user exits or quits it, or the #479 idle policy closes it.
 *
 * It is the Gateway's own `TerminalService` (PTYs, bounded replay with
 * sequences, idle and busy rules, closure reasons) in a separate process that
 * does not need the Gateway: the iPhone's SSH session runs
 * `node mac-terminal-host.js connect --home <tronHome>` (the argv
 * `macTerminal.status` reports as `hostCommand`). `connect` starts the host
 * detached when none answers on its socket, then relays the SSH channel's
 * stdin/stdout to it. A Gateway restart, quit or replacement leaves the host
 * and its shells alone.
 *
 * Protocol: one JSON object per line. The host greets with
 * `{"hello":{"protocol":1}}`; requests are `{"id","op",...}` answered by
 * `{"id","result"}` or `{"id","error":{"code","message"}}`; `output` and `exit`
 * events go to connections attached to that shell. The socket name carries the
 * protocol version, so a Tron update with a new protocol starts its own host
 * and never strands the shells an older one holds.
 */
export const MAC_TERMINAL_HOST_PROTOCOL = 1;
const SCOPE = "mac-terminal";
/** The replay each shell keeps, the same budget as app terminals (config.ts). */
const REPLAY_BYTES = 768 * 1_024;
const MAXIMUM_FRAME_BYTES = 256 * 1_024;
const MAXIMUM_WRITE_LENGTH = 65_536;
/** With no shell running and no device connected for this long, the host exits.
 * Until then it keeps exited shells, so their output and why they closed stay
 * readable under Recent shells. */
const HOST_IDLE_EXIT_MS = 24 * 60 * 60_000;
const HOST_EXIT_CHECK_MS = 60_000;
const MAXIMUM_LOG_BYTES = 1024 * 1024;
const SPAWN_WAIT_MS = 5_000;

export function macTerminalHostDirectory(tronHome: string): string {
  return join(tronHome, "gateway", "mac-terminal");
}

export function macTerminalHostSocket(tronHome: string): string {
  return join(macTerminalHostDirectory(tronHome), `host-${MAC_TERMINAL_HOST_PROTOCOL}.sock`);
}

/** The command an iPhone's SSH session runs to reach the host, or undefined
 * when this Gateway has no compiled host beside it (a source checkout run
 * from TypeScript). */
export function macTerminalHostCommand(tronHome: string, nodePath = process.execPath): string[] | undefined {
  const script = fileURLToPath(new URL("./mac-terminal-host.js", import.meta.url));
  try {
    if (!statSync(script).isFile()) return undefined;
  } catch {
    return undefined;
  }
  return [nodePath, script, "connect", "--home", tronHome];
}

/** The #479 idle period from the Gateway settings store, read without the
 * Gateway: the same key, store and validation the Gateway resolves. An
 * unreadable or invalid value keeps every shell (null is "off"). */
export async function macTerminalIdleLimitMs(tronHome: string): Promise<number | null> {
  const key = schemaKey("setup.terminalIdleMinutes");
  const binding = key.layers.mac;
  const path = binding && "path" in binding ? binding.path : [];
  let document: unknown;
  try {
    document = JSON.parse(await readFile(join(tronHome, "gateway", "settings", "gateway.json"), "utf8"));
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") document = {};
    else return null;
  }
  let value: unknown = document;
  for (const segment of path) {
    value = value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>)[segment] : undefined;
  }
  let minutes = TERMINAL_IDLE_DEFAULT_MINUTES;
  if (value !== undefined) {
    try {
      minutes = await key.type.validate(value, key.id) as number;
    } catch {
      return null;
    }
  }
  return minutes > 0 ? minutes * 60_000 : null;
}

interface Connection {
  socket: Socket;
  attached: Set<string>;
}

function send(socket: Socket, frame: Record<string, unknown>): void {
  if (!socket.destroyed) socket.write(`${JSON.stringify(frame)}\n`);
}

function shellSummary(summary: ReturnType<TerminalService["list"]>[number]) {
  return {
    id: summary.id,
    createdAt: summary.createdAt,
    sequence: summary.sequence,
    ...(summary.exitedAt ? { exitedAt: summary.exitedAt } : {}),
    ...(summary.exitCode === undefined ? {} : { exitCode: summary.exitCode }),
    ...(summary.closedReason ? { closedReason: summary.closedReason } : {}),
  };
}

function integerField(frame: Record<string, unknown>, name: string, minimum: number, maximum: number): number {
  const value = frame[name];
  if (typeof value !== "number" || !Number.isInteger(value) || value < minimum || value > maximum) {
    throw new GatewayError("invalid_request", `${name} must be an integer from ${minimum} to ${maximum}`);
  }
  return value;
}

function shellField(frame: Record<string, unknown>): string {
  const value = frame.shell;
  if (typeof value !== "string" || value.length === 0 || value.length > 100) throw new GatewayError("invalid_request", "shell must be a shell id");
  return value;
}

export class MacTerminalShellHost {
  private readonly connections = new Set<Connection>();
  private readonly terminals: TerminalService;
  private lastActivity: number;
  private readonly exitTimer: NodeJS.Timeout;
  private server: Server | undefined;

  constructor(
    private readonly tronHome: string,
    private readonly options: { log?: (event: string, detail?: Record<string, unknown>) => void; onIdleExit?: () => void } = {},
  ) {
    this.lastActivity = Date.now();
    this.terminals = new TerminalService(REPLAY_BYTES, (terminalId, topic, payload) => this.broadcast(terminalId, topic, payload), {
      idle: {
        idleLimitMs: () => macTerminalIdleLimitMs(this.tronHome),
        isAttached: (terminalId) => [...this.connections].some(connection => connection.attached.has(terminalId)),
      },
      // The message names the shell id and the reason; never shell content.
      log: (_level, message, metadata) => this.options.log?.(metadata.event, { message, reason: metadata.reason, elapsedMs: metadata.elapsedMs, error: metadata.error }),
    });
    this.exitTimer = setInterval(() => this.exitWhenIdle(), HOST_EXIT_CHECK_MS);
    this.exitTimer.unref();
  }

  listen(path: string): Promise<void> {
    const server = createServer(socket => this.accept(socket));
    this.server = server;
    return new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(path, () => {
        server.off("error", reject);
        resolve();
      });
    });
  }

  dispose(): void {
    clearInterval(this.exitTimer);
    this.server?.close();
    for (const connection of this.connections) connection.socket.destroy();
    this.terminals.dispose();
  }

  private exitWhenIdle(): void {
    if (this.connections.size > 0 || this.terminals.activeTerminalIds().length > 0) {
      this.lastActivity = Date.now();
      return;
    }
    if (Date.now() - this.lastActivity < HOST_IDLE_EXIT_MS) return;
    this.options.log?.("host.idle-exit");
    this.options.onIdleExit?.();
  }

  private accept(socket: Socket): void {
    const connection: Connection = { socket, attached: new Set() };
    this.connections.add(connection);
    this.lastActivity = Date.now();
    let buffered = "";
    socket.setEncoding("utf8");
    send(socket, { hello: { protocol: MAC_TERMINAL_HOST_PROTOCOL } });
    socket.on("data", (chunk: string) => {
      buffered += chunk;
      let newline = buffered.indexOf("\n");
      while (newline >= 0) {
        const line = buffered.slice(0, newline);
        buffered = buffered.slice(newline + 1);
        if (line.trim().length > 0) void this.handle(connection, line);
        newline = buffered.indexOf("\n");
      }
      if (buffered.length > MAXIMUM_FRAME_BYTES) {
        this.options.log?.("host.frame-too-large");
        socket.destroy();
      }
    });
    const release = () => {
      if (!this.connections.delete(connection)) return;
      this.lastActivity = Date.now();
    };
    socket.on("close", release);
    socket.on("error", release);
  }

  private async handle(connection: Connection, line: string): Promise<void> {
    let frame: Record<string, unknown>;
    try {
      const parsed = JSON.parse(line) as unknown;
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("not an object");
      frame = parsed as Record<string, unknown>;
    } catch {
      send(connection.socket, { error: { code: "invalid_request", message: "Each line must be one JSON object" } });
      return;
    }
    const id = frame.id;
    try {
      const result = await this.perform(connection, frame);
      send(connection.socket, { id, result });
    } catch (error) {
      const code = error instanceof GatewayError ? error.code : "internal";
      send(connection.socket, { id, error: { code, message: error instanceof Error ? error.message : String(error) } });
    }
  }

  private async perform(connection: Connection, frame: Record<string, unknown>): Promise<Record<string, unknown>> {
    switch (frame.op) {
      case "list":
        return { shells: this.terminals.list(SCOPE).map(shellSummary) };
      case "open": {
        const summary = this.terminals.open(SCOPE, homedir(),
          integerField(frame, "columns", 20, 500), integerField(frame, "rows", 5, 300),
          { LANG: process.env.LANG ?? "en_US.UTF-8" });
        this.options.log?.("shell.opened", { shell: summary.id });
        connection.attached.add(summary.id);
        const replay = this.terminals.attach(summary.id, 0);
        return { shell: shellSummary(replay.terminal), chunks: replay.chunks, reset: replay.reset };
      }
      case "attach": {
        const shell = shellField(frame);
        const replay = this.terminals.attach(shell, integerField(frame, "after", 0, Number.MAX_SAFE_INTEGER));
        connection.attached.add(shell);
        return { shell: shellSummary(replay.terminal), chunks: replay.chunks, reset: replay.reset };
      }
      case "detach":
        connection.attached.delete(shellField(frame));
        return {};
      case "write": {
        const shell = shellField(frame);
        const data = frame.data;
        if (typeof data !== "string" || data.length > MAXIMUM_WRITE_LENGTH) throw new GatewayError("invalid_request", "data must be text of at most 65536 characters");
        this.terminals.write(shell, randomUUID(), data);
        return {};
      }
      case "resize":
        this.terminals.resize(shellField(frame), integerField(frame, "columns", 20, 500), integerField(frame, "rows", 5, 300));
        return {};
      case "terminate": {
        const shell = shellField(frame);
        await this.terminals.terminate(shell);
        this.options.log?.("shell.quit", { shell });
        return {};
      }
      default:
        throw new GatewayError("not_found", "Unknown operation");
    }
  }

  private broadcast(terminalId: string, topic: string, payload: JsonValue): void {
    const event = topic === "terminal.output" ? "output" : topic === "terminal.exit" ? "exit" : undefined;
    if (!event || !payload || typeof payload !== "object" || Array.isArray(payload)) return;
    const { terminalId: _omit, ...rest } = payload as Record<string, JsonValue>;
    if (event === "exit") {
      this.lastActivity = Date.now();
      this.options.log?.("shell.exited", { shell: terminalId, exitCode: rest.exitCode, closed: rest.closedReason !== undefined });
    }
    for (const connection of this.connections) {
      if (connection.attached.has(terminalId)) send(connection.socket, { event, shell: terminalId, ...rest });
    }
  }
}

function connectSocket(path: string): Promise<Socket> {
  return new Promise((resolve, reject) => {
    const socket = createConnection(path);
    socket.once("connect", () => { socket.off("error", reject); resolve(socket); });
    socket.once("error", reject);
  });
}

/** Environment the host and its shells start from: the SSH session's, without
 * the variables that describe that one connection, which the shells outlive. */
function hostEnvironment(): NodeJS.ProcessEnv {
  const environment = { ...process.env };
  for (const name of ["SSH_CLIENT", "SSH_CONNECTION", "SSH_TTY", "SSH_AUTH_SOCK", "SSH_ORIGINAL_COMMAND"]) delete environment[name];
  return environment;
}

/** The host's diagnostics: stderr, which `connect` points at `host.log`.
 * Ids, reasons and timings only, never shell input or output. */
function log(event: string, detail: Record<string, unknown> = {}): void {
  process.stderr.write(`${JSON.stringify({ at: new Date().toISOString(), event, ...detail })}\n`);
}

async function serve(tronHome: string): Promise<void> {
  const path = macTerminalHostSocket(tronHome);
  const host = new MacTerminalShellHost(tronHome, { log, onIdleExit: () => { host.dispose(); process.exit(0); } });
  try {
    await host.listen(path);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "EADDRINUSE") throw error;
    // Another host answering owns the socket; a dead one left a stale file.
    try {
      (await connectSocket(path)).destroy();
      host.dispose();
      return;
    } catch {
      unlinkSync(path);
      await host.listen(path);
    }
  }
  log("host.started", { pid: process.pid, protocol: MAC_TERMINAL_HOST_PROTOCOL });
  const stop = () => { log("host.stopped"); host.dispose(); process.exit(0); };
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);
  process.on("SIGHUP", () => {});
}

async function connect(tronHome: string): Promise<void> {
  const directory = macTerminalHostDirectory(tronHome);
  const path = macTerminalHostSocket(tronHome);
  let socket: Socket;
  try {
    socket = await connectSocket(path);
  } catch {
    mkdirSync(directory, { recursive: true, mode: 0o700 });
    const logPath = join(directory, "host.log");
    try { if (statSync(logPath).size > MAXIMUM_LOG_BYTES) truncateSync(logPath, 0); } catch {}
    const log = openSync(logPath, "a", 0o600);
    // Detached in its own session: the SSH session's end (SIGHUP to its
    // process group) never reaches the host or its shells.
    const child = spawn(process.execPath, [fileURLToPath(import.meta.url), "serve", "--home", tronHome], {
      detached: true, stdio: ["ignore", log, log], env: hostEnvironment(), cwd: homedir(),
    });
    child.unref();
    closeSync(log);
    const deadline = Date.now() + SPAWN_WAIT_MS;
    for (;;) {
      try {
        socket = await connectSocket(path);
        break;
      } catch (error) {
        if (Date.now() > deadline) {
          process.stderr.write(`Mac Terminal's shell host did not start: ${(error as Error).message}\n`);
          process.exit(69);
        }
        await new Promise(resolve => setTimeout(resolve, 50));
      }
    }
  }
  process.stdin.pipe(socket);
  socket.pipe(process.stdout);
  process.stdin.on("end", () => socket.end());
  socket.on("close", () => process.exit(0));
  socket.on("error", () => process.exit(1));
}

async function main(argv: string[]): Promise<void> {
  const [mode, flag, tronHome] = argv;
  if ((mode !== "connect" && mode !== "serve") || flag !== "--home" || !tronHome) {
    process.stderr.write("usage: mac-terminal-host.js connect|serve --home <tronHome>\n");
    process.exit(64);
  }
  if (mode === "serve") await serve(tronHome);
  else await connect(tronHome);
}

/** Run as a program, not imported (the Gateway imports it for the command).
 * The module URL is the resolved path; argv may name it through a symlink. */
function isEntryPoint(): boolean {
  try {
    return process.argv[1] !== undefined && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
}

if (isEntryPoint()) {
  void main(process.argv.slice(2)).catch((error: unknown) => {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exit(1);
  });
}
