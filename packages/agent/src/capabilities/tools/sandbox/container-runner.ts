/**
 * @fileoverview Container CLI wrapper
 *
 * Thin wrapper around Apple's `container` CLI binary.
 * Follows BashTool's runCommand pattern with timeout/abort support.
 */

import { spawn, execFile } from 'child_process';
import type { ContainerRunResult } from './types.js';

const DEFAULT_TIMEOUT = 120_000;
const MAX_OUTPUT_CHARS = 200_000;
const SIGKILL_GRACE_MS = 1_000;
const ABORT_GRACE_MS = 500;

export interface ContainerRunOptions {
  timeout?: number;
  signal?: AbortSignal;
}

export class ContainerRunner {
  run(args: string[], options: ContainerRunOptions = {}): Promise<ContainerRunResult> {
    const timeout = options.timeout ?? DEFAULT_TIMEOUT;

    return new Promise((resolve, reject) => {
      let stdout = '';
      let stderr = '';
      let timedOut = false;
      let interrupted = false;

      const proc = spawn('container', args, {
        env: { ...process.env },
      });

      const timeoutId = setTimeout(() => {
        timedOut = true;
        proc.kill('SIGTERM');
        setTimeout(() => {
          if (!proc.killed) {
            proc.kill('SIGKILL');
          }
        }, SIGKILL_GRACE_MS);
      }, timeout);

      const abortHandler = () => {
        interrupted = true;
        proc.kill('SIGTERM');
        setTimeout(() => {
          if (!proc.killed) {
            proc.kill('SIGKILL');
          }
        }, ABORT_GRACE_MS);
      };

      if (options.signal) {
        options.signal.addEventListener('abort', abortHandler, { once: true });
      }

      proc.stdout.on('data', (data: Buffer) => {
        stdout += data.toString();
      });

      proc.stderr.on('data', (data: Buffer) => {
        stderr += data.toString();
      });

      proc.on('close', (code: number | null) => {
        clearTimeout(timeoutId);
        if (options.signal) {
          options.signal.removeEventListener('abort', abortHandler);
        }

        // Truncate large outputs
        stdout = truncate(stdout);
        stderr = truncate(stderr);

        if (timedOut) {
          resolve({
            stdout,
            stderr,
            exitCode: code ?? 137,
          });
          return;
        }

        if (interrupted) {
          resolve({
            stdout,
            stderr,
            exitCode: code ?? 130,
            interrupted: true,
          });
          return;
        }

        resolve({
          stdout,
          stderr,
          exitCode: code ?? 1,
        });
      });

      proc.on('error', (err: Error) => {
        clearTimeout(timeoutId);
        if (options.signal) {
          options.signal.removeEventListener('abort', abortHandler);
        }
        reject(err);
      });
    });
  }

  checkInstalled(): Promise<boolean> {
    return new Promise((resolve) => {
      execFile('which', ['container'], (error) => {
        resolve(!error);
      });
    });
  }
}

function truncate(output: string): string {
  if (output.length <= MAX_OUTPUT_CHARS) return output;
  const kept = output.slice(0, MAX_OUTPUT_CHARS);
  const droppedChars = output.length - MAX_OUTPUT_CHARS;
  return `${kept}\n... [Output truncated: ${droppedChars} characters omitted]`;
}
