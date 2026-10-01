import { spawnOwnedProcess, type OwnedProcess } from "../lifecycle/owned-process.js";
import {
  createBashToolDefinition,
  getShellConfig,
  type BashOperations,
  type SettingsManager,
} from "@earendil-works/pi-coding-agent";

const ABORT_SETTLEMENT_TIMEOUT_MS = 5_000;

interface ActiveProcess {
  readonly owner: OwnedProcess;
  readonly settled: Promise<void>;
  aborted: boolean;
}

/**
 * Owns only the built-in foreground bash tool for one canonical session.
 * Detached/background extension-managed subagents never enter this owner.
 */
export class DirectBashProcessOwner {
  private readonly active = new Map<number, ActiveProcess>();

  constructor(private readonly settings: SettingsManager) {}

  toolDefinition(cwd: string): ReturnType<typeof createBashToolDefinition> {
    const presentation = createBashToolDefinition(cwd);
    return {
      ...presentation,
      execute: (toolCallId, params, signal, onUpdate, context) => {
        // Shell settings are read at execution time so a resource reload keeps
        // the same behavior as Pi's built-in bash definition.
        const commandPrefix = this.settings.getShellCommandPrefix();
        const current = createBashToolDefinition(cwd, {
          operations: this.operations(),
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
      process.owner.terminate();
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

  operations(): BashOperations {
    return {
      exec: async (command, cwd, options) => {
        if (options.signal?.aborted) throw new Error("aborted");
        if (options.timeout !== undefined && (!Number.isFinite(options.timeout) || options.timeout <= 0 || options.timeout * 1000 > 2_147_483_647)) {
          throw new Error("Invalid timeout: must be a finite positive number of seconds within the timer bound");
        }
        const shell = getShellConfig(this.settings.getShellPath());
        const fromStdin = shell.commandTransport === "stdin";
        const owner = spawnOwnedProcess(
          shell.shell,
          fromStdin ? shell.args : [...shell.args, command],
          {
            cwd,
            detached: process.platform !== "win32",
            env: options.env,
            stdio: [fromStdin ? "pipe" : "ignore", "pipe", "pipe"],
            windowsHide: true,
          },
        );
        const { child } = owner;
        if (fromStdin) {
          child.stdin?.on("error", () => {});
          child.stdin?.end(command);
        }

        const pid = child.pid;
        if (pid === undefined) {
          owner.terminate();
          throw new Error("Direct bash process did not receive a process identity");
        }

        child.stdout?.on("data", options.onData);
        child.stderr?.on("data", options.onData);

        const completion = (async () => {
          await owner.ready;
          if (await owner.cleanup !== "exited") throw new Error("Native bash process cleanup is unknown");
          return child.exitCode;
        })();
        const settled = completion.then(() => undefined, () => undefined);
        const active: ActiveProcess = { owner, settled, aborted: false };
        this.active.set(pid, active);
        const onAbort = () => {
          active.aborted = true;
          owner.terminate();
        };
        if (options.signal) {
          if (options.signal.aborted) onAbort();
          else options.signal.addEventListener("abort", onAbort, { once: true });
        }

        let timeout: NodeJS.Timeout | undefined;
        let timedOut = false;
        if (options.timeout !== undefined) timeout = setTimeout(() => { timedOut = true; owner.terminate(); }, options.timeout * 1000);
        try {
          const exitCode = await completion;
          if (active.aborted || options.signal?.aborted) throw new Error("aborted");
          if (timedOut) throw new Error(`timeout:${options.timeout}`);
          return { exitCode };
        } finally {
          if (timeout) clearTimeout(timeout);
          options.signal?.removeEventListener("abort", onAbort);
          if (this.active.get(pid)?.owner === owner) this.active.delete(pid);
        }
      },
    };
  }

}
