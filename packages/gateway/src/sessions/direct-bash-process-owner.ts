import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { delimiter, join, resolve, sep } from "node:path";
import { homedir } from "node:os";
import {
  createBashToolDefinition,
  getShellConfig,
  type BashOperations,
  type SettingsManager,
} from "@earendil-works/pi-coding-agent";

const POST_EXIT_OUTPUT_GRACE_MS = 100;
/** How long output may still hold a call after a timeout or Stop has asked for
 * termination and the shell has exited. Only a descendant that escaped the
 * process group can still be writing then, and without this bound it would hold
 * the call open for as long as it writes (#499 review). Without termination the
 * call keeps reading, as Pi does (pi#5303), so legitimate output is never cut. */
const TERMINATED_OUTPUT_MAX_MS = 2_000;
const ABORT_SETTLEMENT_TIMEOUT_MS = 5_000;
/** Pi's own bound on a bash timeout (the largest `setTimeout` delay). */
const MAX_TIMEOUT_MS = 2_147_483_647;
const TRON_HOME_PATHS = [resolve(homedir(), ".tron"), resolve(homedir(), ".tron-dev")];

function isTronHomePath(value: string): boolean {
  return TRON_HOME_PATHS.some((home) => value === home || value.startsWith(`${home}${sep}`));
}

/**
 * The tool's `timeout` (seconds) as milliseconds, validated exactly as Pi's own
 * bash operations do. `BashOperations.exec` owns the timeout: Pi's tool only
 * passes it through, so operations that ignore it leave every command unbounded
 * (#499: a call with timeout 900 ran 57 minutes until it was aborted).
 */
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
  /** Terminates the owned tree and bounds how long output can still hold the call. */
  readonly terminate: () => void;
  aborted: boolean;
}

/**
 * Owns only the built-in foreground bash tool for one canonical session.
 * Detached/background extension-managed subagents never enter this owner.
 */
export class DirectBashProcessOwner {
  private readonly active = new Map<number, ActiveProcess>();

  constructor(private readonly settings: SettingsManager, private readonly sessionId: string) {}

  toolDefinition(cwd: string): ReturnType<typeof createBashToolDefinition> {
    const presentation = createBashToolDefinition(cwd);
    return {
      ...presentation,
      execute: (toolCallId, params, signal, onUpdate, context) => {
        // Shell settings are read at execution time so a resource reload keeps
        // the same behavior as Pi's built-in bash definition.
        const commandPrefix = this.settings.getShellCommandPrefix();
        const current = createBashToolDefinition(cwd, {
          operations: this.shellOperations(),
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

  /** Keep the work CLI's opaque session identity, but never expose Gateway-owned
   * paths or supervision controls to arbitrary shell commands. */
  private commandEnvironment(environment?: NodeJS.ProcessEnv): NodeJS.ProcessEnv {
    const commandEnvironment = Object.fromEntries(
      Object.entries(environment ?? process.env).filter(([name]) => !name.startsWith("PI_") && !name.startsWith("TRON_GATEWAY_")),
    );
    commandEnvironment.PI_SESSION_ID = this.sessionId;
    if (commandEnvironment.PATH) {
      commandEnvironment.PATH = commandEnvironment.PATH.split(delimiter).filter((entry) => !isTronHomePath(entry)).join(delimiter);
    }
    return commandEnvironment;
  }

  /** Shared by assistant bash tools and Pi's direct user `!` bash execution. */
  shellOperations(): BashOperations {
    return {
      exec: async (command, cwd, options) => {
        // Validated before the abort check, in Pi's order.
        const timeoutMs = resolveTimeoutMs(options.timeout);
        if (options.signal?.aborted) throw new Error("aborted");
        const shell = getShellConfig(this.settings.getShellPath());
        const fromStdin = shell.commandTransport === "stdin";
        const child = spawn(
          shell.shell,
          fromStdin ? shell.args : [...shell.args, command],
          {
            cwd,
            detached: process.platform !== "win32",
            env: this.commandEnvironment(options.env),
            stdio: [fromStdin ? "pipe" : "ignore", "pipe", "pipe"],
            windowsHide: true,
          },
        );
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
          terminate();
        };
        if (options.signal) {
          if (options.signal.aborted) onAbort();
          else options.signal.addEventListener("abort", onAbort, { once: true });
        }
        // The same termination as an abort: the freeze-then-kill of the owned tree,
        // and a bounded settlement even if an escaped descendant holds the output.
        let timedOut = false;
        const timer = timeoutMs === undefined ? undefined : setTimeout(() => {
          timedOut = true;
          terminate();
        }, timeoutMs);

        try {
          const exitCode = await completion;
          if (active.aborted || options.signal?.aborted) throw new Error("aborted");
          // Pi's tool reports this as "Command timed out after N seconds",
          // keeping the output the command wrote.
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

  /** Freeze the owned group before taking one exact descendant cut. This keeps
   * a child from escaping between discovery and termination. */
  private terminateOwnedTree(child: ChildProcess): void {
    const pid = child.pid;
    if (pid === undefined) return;
    if (process.platform === "win32") {
      if (child.exitCode !== null || child.signalCode !== null) return;
      try {
        // The trusted System32 executable, as Pi uses: cleanup must not depend on PATH.
        const killer = spawn(join(process.env.SystemRoot ?? "C:\\Windows", "System32", "taskkill.exe"), ["/F", "/T", "/PID", String(pid)], {
          detached: true,
          stdio: "ignore",
          windowsHide: true,
        });
        // A failed spawn emits "error" asynchronously; an unconsumed one would crash the Gateway.
        killer.once("error", () => {});
      } catch { /* process already exited */ }
      return;
    }
    if (child.exitCode !== null || child.signalCode !== null) {
      // The shell has exited, but descendants it left in its process group can
      // still run and hold its output: kill the group, as Pi does. Descendants
      // can no longer be found by ancestry once the root is gone.
      try { process.kill(-pid, "SIGKILL"); } catch { /* group already gone */ }
      return;
    }

    try { process.kill(-pid, "SIGSTOP"); }
    catch {
      try { process.kill(pid, "SIGSTOP"); } catch { /* process already exited */ }
    }
    const firstCut = this.descendantPids(pid);
    for (const descendant of firstCut) {
      try { process.kill(descendant, "SIGSTOP"); } catch { /* process already exited */ }
    }
    // A descendant in another process group could fork while the first cut was
    // being read. Once every observed owner is frozen, a second cut closes that
    // interval without widening ownership beyond this root tree.
    const descendants = [...new Set([...firstCut, ...this.descendantPids(pid)])];
    for (const descendant of descendants) {
      try { process.kill(descendant, "SIGSTOP"); } catch { /* process already exited */ }
    }
    try { process.kill(-pid, "SIGKILL"); }
    catch {
      try { process.kill(pid, "SIGKILL"); } catch { /* process already exited */ }
    }
    // Some programs (notably XCTest diagnostics) create their own process
    // groups. They remain exact descendants at the frozen ownership cut.
    for (const descendant of descendants.reverse()) {
      try { process.kill(descendant, "SIGKILL"); } catch { /* process already exited */ }
    }
  }

  private descendantPids(root: number): number[] {
    const result = spawnSync("ps", ["-axo", "pid=,ppid="], {
      encoding: "utf8",
      timeout: 2_000,
      windowsHide: true,
    });
    if (result.status !== 0 || typeof result.stdout !== "string") return [];
    const children = new Map<number, number[]>();
    for (const line of result.stdout.split("\n")) {
      const match = line.trim().match(/^(\d+)\s+(\d+)$/);
      if (!match) continue;
      const pid = Number(match[1]);
      const parent = Number(match[2]);
      if (!Number.isSafeInteger(pid) || !Number.isSafeInteger(parent)) continue;
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

  /** Settles once the shell has exited and its output is done: both pipes ended,
   * or no output for the grace period. `terminating` marks that termination was
   * requested; from then on output can extend the call by at most
   * TERMINATED_OUTPUT_MAX_MS after the shell exits. Settlement always follows the
   * shell's exit (or a spawn error), which `abortAll` relies on. */
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
