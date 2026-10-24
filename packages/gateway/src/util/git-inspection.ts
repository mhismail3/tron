import { spawn } from "node:child_process";
import { GatewayError } from "../errors.js";
import { workspaceGitEnvironment } from "./workspace-git-environment.js";

const GIT = process.env.TRON_GIT_PATH ?? "/usr/bin/git";
const GIT_TIMEOUT_MS = 5_000;
const GIT_MAX_OUTPUT_BYTES = 768 * 1_024;

export interface GitResult {
  stdout: Buffer;
  stderr: Buffer;
  exitCode: number;
  truncated: boolean;
}

export async function runGit(
  cwd: string,
  arguments_: string[],
  options: {
    timeoutMs?: number;
    maximumBytes?: number;
    allowedExitCodes?: readonly number[];
    truncate?: boolean;
  } = {},
): Promise<GitResult> {
  const maximumBytes = options.maximumBytes ?? GIT_MAX_OUTPUT_BYTES;
  const allowedExitCodes = options.allowedExitCodes ?? [0];
  return await new Promise<GitResult>((resolvePromise, rejectPromise) => {
    const child = spawn(GIT, ["--no-pager", "-C", cwd, ...arguments_], {
      cwd,
      env: {
        ...workspaceGitEnvironment(),
        LC_ALL: "C",
        LANG: "C",
        GIT_OPTIONAL_LOCKS: "0",
        GIT_TERMINAL_PROMPT: "0",
        GIT_PAGER: "cat",
        PAGER: "cat",
      },
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
      detached: process.platform !== "win32",
    });
    const killProcessGroup = () => {
      if (process.platform !== "win32" && child.pid !== undefined) {
        try {
          process.kill(-child.pid, "SIGKILL");
          return;
        } catch {
          // Fall back to the direct child if the process group already retired.
        }
      }
      child.kill("SIGKILL");
    };
    const chunks: Buffer[] = [];
    const errors: Buffer[] = [];
    let bytes = 0;
    let errorBytes = 0;
    let truncated = false;
    let timedOut = false;
    let overflowed = false;
    const timer = setTimeout(() => {
      timedOut = true;
      killProcessGroup();
    }, options.timeoutMs ?? GIT_TIMEOUT_MS);
    timer.unref();

    child.stdout.on("data", (chunk: Buffer) => {
      if (truncated) return;
      if (chunk.length > maximumBytes - bytes) {
        if (options.truncate) {
          const remaining = Math.max(0, maximumBytes - bytes);
          if (remaining > 0) chunks.push(chunk.subarray(0, remaining));
          bytes = maximumBytes;
          truncated = true;
          killProcessGroup();
        } else {
          overflowed = true;
          killProcessGroup();
        }
        return;
      }
      chunks.push(chunk);
      bytes += chunk.length;
    });
    child.stderr.on("data", (chunk: Buffer) => {
      const remaining = Math.max(0, 16_384 - errorBytes);
      if (remaining > 0) errors.push(chunk.subarray(0, remaining));
      errorBytes += Math.min(chunk.length, remaining);
    });
    child.once("error", (error) => {
      clearTimeout(timer);
      rejectPromise(new GatewayError("internal", `Git could not be started: ${error.message}`, true));
    });
    child.once("close", (code) => {
      clearTimeout(timer);
      if (timedOut) return rejectPromise(new GatewayError("busy", "Git inspection timed out", true));
      if (overflowed) return rejectPromise(new GatewayError("conflict", "Git output exceeded the bounded inspection limit", true));
      if (truncated && options.truncate) return resolvePromise({
        stdout: Buffer.concat(chunks), stderr: Buffer.concat(errors), exitCode: code ?? -1, truncated: true,
      });
      if (code === null || !allowedExitCodes.includes(code)) {
        const detail = Buffer.concat(errors).toString("utf8").trim().slice(0, 1_000);
        return rejectPromise(new GatewayError("conflict", detail ? `Git inspection failed: ${detail}` : "Git inspection failed", true));
      }
      resolvePromise({ stdout: Buffer.concat(chunks), stderr: Buffer.concat(errors), exitCode: code, truncated: false });
    });
  });
}
