/**
 * @fileoverview Bash tool for shell command execution
 *
 * Executes shell commands with safety checks and timeout support.
 */

import { spawn } from 'child_process';
import type { TronTool, TronToolResult } from '../types/index.js';
import { createLogger } from '../logging/logger.js';

const logger = createLogger('tool:bash');

const DEFAULT_TIMEOUT = 120000; // 2 minutes
const MAX_OUTPUT_LENGTH = 30000;

// Dangerous command patterns
const DANGEROUS_PATTERNS = [
  /^rm\s+(-rf?|--force)\s+\/\s*$/i,
  /^rm\s+-rf?\s+\/\s*$/i,
  /rm\s+-rf?\s+\//i,
  /^sudo\s+/i,
  /^chmod\s+777\s+\/\s*$/i,
  /^mkfs\./i,
  /^dd\s+if=.*of=\/dev\//i,
  />\s*\/dev\/sd[a-z]/i,
  /^:\(\)\s*\{\s*:\|\s*:\s*&\s*\}\s*;\s*:/,  // Fork bomb
];

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

  async execute(args: Record<string, unknown>): Promise<TronToolResult> {
    const command = args.command as string;
    const timeout = Math.min(
      (args.timeout as number) ?? this.config.defaultTimeout ?? DEFAULT_TIMEOUT,
      600000
    );
    const description = args.description as string | undefined;

    logger.debug('Executing command', { command, timeout, description });

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
      const result = await this.runCommand(command, timeout);
      const durationMs = Date.now() - startTime;

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
      if (output.length > MAX_OUTPUT_LENGTH) {
        output = output.substring(0, MAX_OUTPUT_LENGTH) + '\n... [output truncated]';
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
    for (const pattern of DANGEROUS_PATTERNS) {
      if (pattern.test(command)) {
        return `Potentially destructive command pattern detected`;
      }
    }
    return null;
  }

  private runCommand(
    command: string,
    timeout: number
  ): Promise<{ stdout: string; stderr: string; exitCode: number }> {
    return new Promise((resolve, reject) => {
      let stdout = '';
      let stderr = '';
      let timedOut = false;

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

      proc.stdout.on('data', (data: Buffer) => {
        stdout += data.toString();
      });

      proc.stderr.on('data', (data: Buffer) => {
        stderr += data.toString();
      });

      proc.on('close', (code: number | null) => {
        clearTimeout(timeoutId);

        if (timedOut) {
          reject(new Error(`Command timed out after ${timeout}ms`));
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
        reject(err);
      });
    });
  }
}
