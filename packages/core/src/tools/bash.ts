/**
 * @fileoverview Bash tool for shell command execution
 *
 * Executes shell commands with safety checks and timeout support.
 */

import { spawn } from 'child_process';
import type { TronTool, TronToolResult } from '../types/index.js';
import { createLogger } from '../logging/logger.js';
import { getSettings } from '../settings/index.js';

const logger = createLogger('tool:bash');

// Get settings (loaded lazily on first access)
function getBashSettings() {
  return getSettings().tools.bash;
}

// Compile dangerous patterns from settings (cached after first call)
let compiledPatterns: RegExp[] | null = null;
function getDangerousPatterns(): RegExp[] {
  if (!compiledPatterns) {
    const settings = getBashSettings();
    compiledPatterns = settings.dangerousPatterns.map(p => new RegExp(p, 'i'));
  }
  return compiledPatterns;
}

export interface BashToolConfig {
  workingDirectory: string;
  defaultTimeout?: number;
}

export class BashTool implements TronTool {
  readonly name = 'Bash';
  readonly description = 'Execute a shell command. Commands that are potentially destructive require confirmation.';
  readonly parameters = {
    type: 'object' as const,
    properties: {
      command: {
        type: 'string' as const,
        description: 'The shell command to execute',
      },
      timeout: {
        type: 'number' as const,
        description: 'Timeout in milliseconds (max 600000)',
      },
      description: {
        type: 'string' as const,
        description: 'Brief description of what this command does',
      },
    },
    required: ['command'] as string[],
  };

  private config: BashToolConfig;

  constructor(config: BashToolConfig) {
    this.config = config;
  }

  async execute(
    toolCallIdOrArgs: string | Record<string, unknown>,
    argsOrSignal?: Record<string, unknown> | AbortSignal,
    signal?: AbortSignal
  ): Promise<TronToolResult> {
    // Handle both old and new signatures
    let args: Record<string, unknown>;
    let abortSignal: AbortSignal | undefined;

    if (typeof toolCallIdOrArgs === 'string') {
      // New signature: (toolCallId, params, signal)
      args = argsOrSignal as Record<string, unknown>;
      abortSignal = signal;
    } else {
      // Old signature: (params)
      args = toolCallIdOrArgs;
      abortSignal = argsOrSignal instanceof AbortSignal ? argsOrSignal : undefined;
    }

    const command = args.command as string;

    // Validate required parameter (defense against truncated tool calls)
    if (!command || typeof command !== 'string') {
      return {
        content: 'Missing required parameter: command. The tool call may have been truncated.',
        isError: true,
        details: { command },
      };
    }

    const settings = getBashSettings();
    const timeout = Math.min(
      (args.timeout as number) ?? this.config.defaultTimeout ?? settings.defaultTimeoutMs,
      settings.maxTimeoutMs
    );
    const description = args.description as string | undefined;

    logger.debug('Executing command', { command, timeout, description });

    // Check if already aborted
    if (abortSignal?.aborted) {
      return {
        content: 'Command execution was interrupted before it started',
        isError: true,
        details: { command, interrupted: true },
      };
    }

    // Check for dangerous commands
    const dangerCheck = this.checkDangerous(command);
    if (dangerCheck) {
      logger.warn('Blocked dangerous command', { command, reason: dangerCheck });
      return {
        content: `Command blocked for safety: ${dangerCheck}`,
        isError: true,
        details: { command, blocked: true, reason: dangerCheck },
      };
    }

    const startTime = Date.now();

    try {
      const result = await this.runCommand(command, timeout, abortSignal);
      const durationMs = Date.now() - startTime;

      // Handle interrupted command
      if (result.interrupted) {
        logger.info('Command interrupted by user', { command, durationMs });

        // Combine any partial output
        let output = '';
        if (result.stdout) output += result.stdout;
        if (result.stderr) {
          output += output ? '\n' : '';
          output += result.stderr;
        }

        // Truncate if needed
        const maxOutput = settings.maxOutputLength;
        if (output.length > maxOutput) {
          output = output.substring(0, maxOutput) + '\n... [output truncated]';
        }

        return {
          content: output
            ? `Command interrupted. Partial output:\n${output}`
            : 'Command interrupted (no output captured)',
          isError: true,
          details: {
            command,
            exitCode: result.exitCode,
            durationMs,
            interrupted: true,
          },
        };
      }

      logger.debug('Command completed', {
        command,
        exitCode: result.exitCode,
        durationMs,
      });

      // Combine stdout and stderr
      let output = '';
      if (result.stdout) {
        output += result.stdout;
      }
      if (result.stderr) {
        output += output ? '\n' : '';
        output += result.stderr;
      }

      // Truncate if too long
      let truncated = false;
      const maxOutput = settings.maxOutputLength;
      if (output.length > maxOutput) {
        output = output.substring(0, maxOutput) + '\n... [output truncated]';
        truncated = true;
      }

      const isError = result.exitCode !== 0;

      return {
        content: isError
          ? `Command failed with exit code ${result.exitCode}:\n${output}`
          : output || '(no output)',
        isError,
        details: {
          command,
          exitCode: result.exitCode,
          durationMs,
          truncated,
        },
      };
    } catch (error) {
      const err = error as Error;
      const durationMs = Date.now() - startTime;

      logger.error('Command execution failed', { command, error: err.message, durationMs });

      return {
        content: `Command execution failed: ${err.message}`,
        isError: true,
        details: {
          command,
          durationMs,
          error: err.message,
        },
      };
    }
  }

  private checkDangerous(command: string): string | null {
    const patterns = getDangerousPatterns();
    for (const pattern of patterns) {
      if (pattern.test(command)) {
        return `Potentially destructive command pattern detected`;
      }
    }
    return null;
  }

  private runCommand(
    command: string,
    timeout: number,
    signal?: AbortSignal
  ): Promise<{ stdout: string; stderr: string; exitCode: number; interrupted?: boolean }> {
    return new Promise((resolve, reject) => {
      let stdout = '';
      let stderr = '';
      let timedOut = false;
      let interrupted = false;

      const proc = spawn('bash', ['-c', command], {
        cwd: this.config.workingDirectory,
        env: { ...process.env },
      });

      const timeoutId = setTimeout(() => {
        timedOut = true;
        proc.kill('SIGTERM');
        setTimeout(() => {
          if (!proc.killed) {
            proc.kill('SIGKILL');
          }
        }, 1000);
      }, timeout);

      // Handle abort signal
      const abortHandler = () => {
        interrupted = true;
        proc.kill('SIGTERM');
        setTimeout(() => {
          if (!proc.killed) {
            proc.kill('SIGKILL');
          }
        }, 500); // Shorter grace period for user interrupt
      };

      if (signal) {
        signal.addEventListener('abort', abortHandler, { once: true });
      }

      proc.stdout.on('data', (data: Buffer) => {
        stdout += data.toString();
      });

      proc.stderr.on('data', (data: Buffer) => {
        stderr += data.toString();
      });

      proc.on('close', (code: number | null) => {
        clearTimeout(timeoutId);
        if (signal) {
          signal.removeEventListener('abort', abortHandler);
        }

        if (timedOut) {
          reject(new Error(`Command timed out after ${timeout}ms`));
          return;
        }

        if (interrupted) {
          // Return partial output with interrupted flag
          resolve({
            stdout,
            stderr,
            exitCode: code ?? 130, // 130 = terminated by Ctrl+C
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
        if (signal) {
          signal.removeEventListener('abort', abortHandler);
        }
        reject(err);
      });
    });
  }
}
