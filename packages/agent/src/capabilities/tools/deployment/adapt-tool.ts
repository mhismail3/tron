import { spawnSync, spawn } from 'child_process';
import { readFileSync, existsSync, unlinkSync, writeFileSync } from 'fs';
import { join } from 'path';
import type { TronTool, TronToolResult, ToolExecutionOptions } from '@core/types/tools.js';
import type { AdaptToolConfig, AdaptParams, DeploymentRecord } from './types.js';

export class AdaptTool implements TronTool<AdaptParams> {
  readonly name = 'Adapt';

  readonly description = `Self-deploy the Tron agent to production. Builds, tests, and hot-swaps the running server.

Available actions:
- deploy: Build and test, then swap the production binary (server restarts automatically)
- status: Check the result of the last deployment
- rollback: Restore the previous deployment from backup

The deploy action runs build+test synchronously, then triggers a detached swap script that survives the server restart. After reconnecting, use status to verify the deployment succeeded.`;

  readonly parameters = {
    type: 'object' as const,
    properties: {
      action: {
        type: 'string' as const,
        enum: ['deploy', 'status', 'rollback'] as string[],
        description: 'The deployment action to perform',
      },
    },
    required: ['action'] as string[],
  };

  readonly requiresConfirmation = true;
  readonly category = 'custom' as const;
  readonly executionContract = 'options' as const;

  private readonly config: AdaptToolConfig;
  private readonly tronScript: string;
  private readonly lockPath: string;
  private readonly resultPath: string;

  constructor(config: AdaptToolConfig) {
    this.config = config;
    this.tronScript = config.tronScript ?? join(config.repoRoot, 'scripts', 'tron');
    this.lockPath = join(config.tronHome, 'deploy.lock');
    this.resultPath = join(config.tronHome, 'app', 'last-deployment.json');
  }

  async execute(args: AdaptParams, _options?: ToolExecutionOptions): Promise<TronToolResult> {
    const { action } = args;
    switch (action) {
      case 'deploy':  return this.deploy();
      case 'status':  return this.status();
      case 'rollback': return this.rollback();
      default: return { content: `Unknown action: ${action}`, isError: true };
    }
  }

  private deploy(): TronToolResult {
    if (this.isLockHeld()) {
      return { content: 'A deployment is already in progress (locked by another process).', isError: true };
    }

    this.acquireLock();

    const result = spawnSync(this.tronScript, ['deploy', '--prepare'], {
      cwd: this.config.repoRoot,
      encoding: 'utf-8',
      timeout: 600_000,
    });

    if (result.status !== 0) {
      this.releaseLock();
      const output = [result.stdout, result.stderr].filter(Boolean).join('\n');
      return {
        content: `Build/test failed:\n${output}`,
        isError: true,
      };
    }

    const child = spawn(this.tronScript, ['deploy', '--swap', '--delay', '3'], {
      cwd: this.config.repoRoot,
      detached: true,
      stdio: 'ignore',
    });
    child.unref();

    return {
      content: 'Build and tests passed. Deployment swap starts in 3 seconds. The server will restart — after reconnecting, use `Adapt` with action `status` to verify.',
      isError: false,
    };
  }

  private status(): TronToolResult {
    if (!existsSync(this.resultPath)) {
      return { content: 'No deployment recorded yet.', isError: false };
    }

    try {
      const raw = readFileSync(this.resultPath, 'utf-8');
      const record: DeploymentRecord = JSON.parse(raw);

      const lines = [
        `Last deployment:`,
        `  Status:          ${record.status}`,
        `  Timestamp:       ${record.timestamp}`,
        `  Commit:          ${record.commit}`,
        `  Previous commit: ${record.previousCommit}`,
      ];
      if (record.error) {
        lines.push(`  Error:           ${record.error}`);
      }

      return { content: lines.join('\n'), isError: false };
    } catch (err) {
      return {
        content: `Failed to read deployment status: ${err instanceof Error ? err.message : String(err)}`,
        isError: true,
      };
    }
  }

  private rollback(): TronToolResult {
    if (this.isLockHeld()) {
      return { content: 'A deployment is already in progress (locked by another process).', isError: true };
    }

    this.acquireLock();

    const child = spawn(this.tronScript, ['rollback', '--yes', '--delay', '3'], {
      cwd: this.config.repoRoot,
      detached: true,
      stdio: 'ignore',
    });
    child.unref();

    return {
      content: 'Rollback initiated. The server will restart in ~3 seconds. After reconnecting, use `Adapt` with action `status` to verify.',
      isError: false,
    };
  }

  private acquireLock(): void {
    writeFileSync(this.lockPath, String(process.pid));
  }

  private releaseLock(): void {
    try {
      unlinkSync(this.lockPath);
    } catch {
      // Lock may already be cleaned
    }
  }

  private isLockHeld(): boolean {
    if (!existsSync(this.lockPath)) return false;

    try {
      const pid = parseInt(readFileSync(this.lockPath, 'utf-8').trim(), 10);
      if (isNaN(pid)) {
        this.releaseLock();
        return false;
      }

      process.kill(pid, 0);
      return true;
    } catch {
      this.releaseLock();
      return false;
    }
  }
}
