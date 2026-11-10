import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { join } from "node:path";
import {
  createBashToolDefinition,
  getShellConfig,
  type BashOperations,
  type SettingsManager,
} from "../pi/coding-agent.js";
import { TOOL_INTERRUPT_SIGNAL_GRACE_MS, ToolCallInterrupt } from "./bounded-tool-cancellation.js";
import { boundTaskCommandScope, closeTaskScopeAnchor, openTaskScopeAnchor, recordTaskCommandGroup, TASK_SCOPE_ANCHOR_FD } from "./task-command-scope.js";

export const AGENT_COMMAND_NICENESS = 10;
const NICE = "/usr/bin/nice";
const POST_EXIT_OUTPUT_GRACE_MS = 100;
const TERMINATED_OUTPUT_MAX_MS = 2_000;
const ABORT_SETTLEMENT_TIMEOUT_MS = 5_000;
const MAX_TIMEOUT_MS = 2_147_483_647;
function resolveTimeoutMs(timeout: number | undefined): number | undefined {
  if (timeout === undefined) return undefined;
  if (!Number.isFinite(timeout) || timeout <= 0) throw new Error("Invalid timeout: must be a finite number of seconds");
  const timeoutMs = timeout * 1_000;
  if (timeoutMs > MAX_TIMEOUT_MS) throw new Error(`Invalid timeout: maximum is ${MAX_TIMEOUT_MS / 1_000} seconds`);
  return timeoutMs;
}

interface ActiveProcess {
  readonly child: ChildProcess;
  readonly settled: Promise<void>;
  readonly terminate: () => void;
  aborted: boolean;
}

export class DirectBashProcessOwner {
  private readonly active = new Map<number, ActiveProcess>();

  constructor(private readonly settings: SettingsManager, private readonly sessionId: string) {}

  toolDefinition(cwd: string): ReturnType<typeof createBashToolDefinition> {
    const presentation = createBashToolDefinition(cwd);
    return {
      ...presentation,
      execute: (toolCallId, params, signal, onUpdate, context) => {
        const commandPrefix = this.settings.getShellCommandPrefix();
        const current = createBashToolDefinition(cwd, {
          operations: this.shellOperations("agent"),
          ...(commandPrefix === undefined ? {} : { commandPrefix }),
        });
        return current.execute(toolCallId, params, signal, onUpdate, context);
      },
    };
  }

  get hasActiveProcesses(): boolean { return this.active.size > 0; }

  async abortAll(): Promise<void> {
    const owned = [...this.active.values()];
    for (const process of owned) {
      process.aborted = true;
      process.terminate();
    }
    if (owned.length === 0) return;

    const settlement = Promise.allSettled(owned.map(process => process.settled));
    let timer: NodeJS.Timeout | undefined;
    const outcome = await Promise.race([
      settlement.then(() => "settled" as const),
      new Promise<"timeout">((resolve) => {
        timer = setTimeout(() => resolve("timeout"), ABORT_SETTLEMENT_TIMEOUT_MS);
      }),
    ]);
    if (timer) clearTimeout(timer);
    if (outcome === "timeout" || this.active.size > 0) {
      throw new Error("Direct bash process tree did not terminate after abort");
    }
  }

  private commandEnvironment(environment?: NodeJS.ProcessEnv): NodeJS.ProcessEnv {
    const commandEnvironment = Object.fromEntries(
      Object.entries(environment ?? process.env).filter(([name]) =>
        !name.startsWith("PI_") && !name.startsWith("TRON_GATEWAY_") && name !== "TRON_DATA_DIR" && name !== "TRON_HOME_NAME"),
    );
    commandEnvironment.PI_SESSION_ID = this.sessionId;
    return commandEnvironment;
  }

  shellOperations(origin: "agent" | "user"): BashOperations {
    return {
      exec: async (command, cwd, options) => {
        const timeoutMs = resolveTimeoutMs(options.timeout);
        if (options.signal?.aborted) throw new Error("aborted");
        const shell = getShellConfig(this.settings.getShellPath());
        const fromStdin = shell.commandTransport === "stdin";
        const scope = process.platform === "win32" ? undefined : boundTaskCommandScope(this.sessionId);
        const environment = this.commandEnvironment(options.env);
        if (scope) environment.TMPDIR = scope.tmp;
        const anchor = scope ? openTaskScopeAnchor(scope) : undefined;
        let child: ChildProcess;
        try {
          const shellArgs = fromStdin ? shell.args : [...shell.args, command];
          const lowered = origin === "agent" && process.platform !== "win32";
          child = spawn(
            lowered ? NICE : shell.shell,
            lowered ? ["-n", String(AGENT_COMMAND_NICENESS), shell.shell, ...shellArgs] : shellArgs,
            {
              cwd,
              detached: process.platform !== "win32",
              env: environment,
              stdio: [fromStdin ? "pipe" : "ignore", "pipe", "pipe",
                ...(anchor === undefined ? [] : [...Array<"ignore">(TASK_SCOPE_ANCHOR_FD - 3).fill("ignore"), anchor])],
              windowsHide: true,
            },
          );
        } finally {
          if (anchor !== undefined) closeTaskScopeAnchor(anchor);
        }
        if (scope && child.pid !== undefined) {
          try { recordTaskCommandGroup(scope, child.pid); }
          catch (error) { this.terminateOwnedTree(child); throw error; }
        }
        if (fromStdin) {
          child.stdin?.on("error", () => {});
          child.stdin?.end(command);
        }

        const pid = child.pid;
        if (pid === undefined) {
          this.terminateOwnedTree(child);
          throw new Error("Direct bash process did not receive a process identity");
        }

        child.stdout?.on("data", options.onData);
        child.stderr?.on("data", options.onData);

        const { completion, terminating } = this.waitForChild(child);
        const settled = completion.then(() => undefined, () => undefined);
        const terminate = () => {
          terminating();
          this.terminateOwnedTree(child);
        };
        const active: ActiveProcess = { child, settled, terminate, aborted: false };
        this.active.set(pid, active);
        const onAbort = () => {
          active.aborted = true;
          if (options.signal?.reason instanceof ToolCallInterrupt) void this.interruptOwnedTree(child, terminating, terminate);
          else terminate();
        };
        if (options.signal) {
          if (options.signal.aborted) onAbort();
          else options.signal.addEventListener("abort", onAbort, { once: true });
        }
        let timedOut = false;
        const timer = timeoutMs === undefined ? undefined : setTimeout(() => {
          timedOut = true;
          terminate();
        }, timeoutMs);

        try {
          const exitCode = await completion;
          if (active.aborted || options.signal?.aborted) throw new Error("aborted");
          if (timedOut) throw new Error(`timeout:${options.timeout}`);
          return { exitCode };
        } finally {
          if (timer) clearTimeout(timer);
          options.signal?.removeEventListener("abort", onAbort);
          if (this.active.get(pid)?.child === child) this.active.delete(pid);
        }
      },
    };
  }

  private async interruptOwnedTree(child: ChildProcess, terminating: () => void, terminate: () => void): Promise<void> {
    const pid = child.pid;
    if (pid === undefined || process.platform === "win32") { terminate(); return; }
    terminating();
    let exited = child.exitCode !== null || child.signalCode !== null;
    if (!exited) child.once("exit", () => { exited = true; });
    const seen = new Map<number, number>();
    const observe = () => {
      const parents = this.parentPids();
      for (const descendant of this.descendantPids(pid, parents)) if (!seen.has(descendant)) seen.set(descendant, parents.get(descendant)!);
      return [...seen].filter(([descendant, first]) => {
        const parent = parents.get(descendant);
        return parent !== undefined && (parent === first || parent === 1 || seen.has(parent));
      }).map(([descendant]) => descendant);
    };
    const groupAlive = () => { try { process.kill(-pid, 0); return true; } catch { return false; } };
    const signal = (name: NodeJS.Signals, descendants: number[]) => {
      try { process.kill(-pid, name); } catch { }
      for (const descendant of descendants) { try { process.kill(descendant, name); } catch { } }
    };
    const wait = async (done: () => boolean) => {
      for (const deadline = Date.now() + TOOL_INTERRUPT_SIGNAL_GRACE_MS; Date.now() < deadline && !done();) {
        await new Promise(resolve => setTimeout(resolve, 100));
      }
    };
    observe();
    signal("SIGINT", []);
    await wait(() => exited);
    const terminated = observe();
    signal("SIGTERM", terminated);
    const alive = (descendant: number) => { try { process.kill(descendant, 0); return true; } catch { return false; } };
    await wait(() => exited && !groupAlive() && !terminated.some(alive));
    const survivors = observe();
    terminate();
    for (const descendant of survivors) { try { process.kill(descendant, "SIGKILL"); } catch { } }
  }

  private terminateOwnedTree(child: ChildProcess): void {
    const pid = child.pid;
    if (pid === undefined) return;
    if (process.platform === "win32") {
      if (child.exitCode !== null || child.signalCode !== null) return;
      try {
        const killer = spawn(join(process.env.SystemRoot ?? "C:\\Windows", "System32", "taskkill.exe"), ["/F", "/T", "/PID", String(pid)], {
          detached: true,
          stdio: "ignore",
          windowsHide: true,
        });
        killer.once("error", () => {});
      } catch { }
      return;
    }
    if (child.exitCode !== null || child.signalCode !== null) {
      try { process.kill(-pid, "SIGKILL"); } catch { }
      return;
    }

    try { process.kill(-pid, "SIGSTOP"); }
    catch {
      try { process.kill(pid, "SIGSTOP"); } catch { }
    }
    const firstCut = this.descendantPids(pid);
    for (const descendant of firstCut) {
      try { process.kill(descendant, "SIGSTOP"); } catch { }
    }
    const descendants = [...new Set([...firstCut, ...this.descendantPids(pid)])];
    for (const descendant of descendants) {
      try { process.kill(descendant, "SIGSTOP"); } catch { }
    }
    try { process.kill(-pid, "SIGKILL"); }
    catch {
      try { process.kill(pid, "SIGKILL"); } catch { }
    }
    for (const descendant of descendants.reverse()) {
      try { process.kill(descendant, "SIGKILL"); } catch { }
    }
  }

  private parentPids(): Map<number, number> {
    const parents = new Map<number, number>();
    const result = spawnSync("ps", ["-axo", "pid=,ppid="], {
      encoding: "utf8",
      timeout: 2_000,
      windowsHide: true,
    });
    if (result.status !== 0 || typeof result.stdout !== "string") return parents;
    for (const line of result.stdout.split("\n")) {
      const match = line.trim().match(/^(\d+)\s+(\d+)$/);
      if (!match) continue;
      const pid = Number(match[1]);
      const parent = Number(match[2]);
      if (Number.isSafeInteger(pid) && Number.isSafeInteger(parent)) parents.set(pid, parent);
    }
    return parents;
  }

  private descendantPids(root: number, parents = this.parentPids()): number[] {
    const children = new Map<number, number[]>();
    for (const [pid, parent] of parents) {
      const siblings = children.get(parent) ?? [];
      siblings.push(pid);
      children.set(parent, siblings);
    }
    const descendants: number[] = [];
    const pending = [...(children.get(root) ?? [])];
    while (pending.length > 0) {
      const pid = pending.pop()!;
      descendants.push(pid);
      pending.push(...(children.get(pid) ?? []));
    }
    return descendants;
  }

  private waitForChild(child: ChildProcess): { completion: Promise<number | null>; terminating: () => void } {
    let terminating = () => {};
    const completion = new Promise<number | null>((resolve, reject) => {
      let settled = false;
      let exited = false;
      let terminationRequested = false;
      let exitCode: number | null = null;
      let grace: NodeJS.Timeout | undefined;
      let postExitLimit: NodeJS.Timeout | undefined;
      let stdoutEnded = child.stdout === null;
      let stderrEnded = child.stderr === null;

      const cleanup = () => {
        if (grace) clearTimeout(grace);
        if (postExitLimit) clearTimeout(postExitLimit);
        child.removeListener("error", onError);
        child.removeListener("exit", onExit);
        child.removeListener("close", onClose);
        child.stdout?.removeListener("end", onStdoutEnd);
        child.stderr?.removeListener("end", onStderrEnd);
        child.stdout?.removeListener("data", onData);
        child.stderr?.removeListener("data", onData);
      };
      const finish = (code: number | null) => {
        if (settled) return;
        settled = true;
        cleanup();
        child.stdout?.destroy();
        child.stderr?.destroy();
        resolve(code);
      };
      const maybeFinish = () => {
        if (exited && stdoutEnded && stderrEnded) finish(exitCode);
      };
      const armGrace = () => {
        if (grace) clearTimeout(grace);
        grace = setTimeout(() => finish(exitCode), POST_EXIT_OUTPUT_GRACE_MS);
      };
      const armPostExitLimit = () => {
        postExitLimit ??= setTimeout(() => finish(exitCode), TERMINATED_OUTPUT_MAX_MS);
      };
      terminating = () => {
        terminationRequested = true;
        if (exited && !settled) armPostExitLimit();
      };
      const onData = () => { if (exited && !settled) armGrace(); };
      const onStdoutEnd = () => { stdoutEnded = true; maybeFinish(); };
      const onStderrEnd = () => { stderrEnded = true; maybeFinish(); };
      const onError = (error: Error) => {
        if (settled) return;
        settled = true;
        cleanup();
        reject(error);
      };
      const onExit = (code: number | null) => {
        exited = true;
        exitCode = code;
        maybeFinish();
        if (!settled) {
          armGrace();
          if (terminationRequested) armPostExitLimit();
        }
      };
      const onClose = (code: number | null) => finish(code);

      child.stdout?.once("end", onStdoutEnd);
      child.stderr?.once("end", onStderrEnd);
      child.stdout?.on("data", onData);
      child.stderr?.on("data", onData);
      child.once("error", onError);
      child.once("exit", onExit);
      child.once("close", onClose);
    });
    return { completion, terminating: () => terminating() };
  }
}
