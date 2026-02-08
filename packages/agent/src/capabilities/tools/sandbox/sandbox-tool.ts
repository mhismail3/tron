/**
 * @fileoverview Sandbox tool for container management
 *
 * Creates and manages sandboxed Linux containers via Apple's `container` CLI.
 * Uses a persistent JSON registry so the agent never loses track of containers
 * across sessions.
 *
 * Actions: create, exec, stop, start, remove, list, logs
 */

import * as path from 'path';
import { randomBytes } from 'crypto';
import type { TronTool, TronToolResult } from '@core/types/index.js';
import { createLogger } from '@infrastructure/logging/index.js';
import { ContainerRunner } from './container-runner.js';
import { ContainerRegistry } from './container-registry.js';
import type { SandboxParams, SandboxToolConfig, ContainerRecord } from './types.js';

const logger = createLogger('tool:sandbox');

const DEFAULT_IMAGE = 'ubuntu:latest';
const DEFAULT_EXEC_TIMEOUT = 120_000;

const NOT_INSTALLED_ERROR = `Error: Apple Container CLI not found.
Install from: https://github.com/apple/container/releases
Requires macOS 26+ on Apple Silicon.
After installing, run: container system start`;

export class SandboxTool implements TronTool<SandboxParams> {
  readonly name = 'Sandbox';
  readonly label = 'Sandbox';
  readonly category = 'shell' as const;
  readonly executionContract = 'contextual' as const;

  readonly description = `Create and manage sandboxed Linux containers. Containers persist across sessions and are tracked in a registry.

Actions:
- create: Create + start a new container (default: ubuntu:latest). Mounts workspace at /workspace.
- exec: Execute a command inside a running container. Requires name + command. Supports full shell syntax (pipes, &&, redirects). Use detach: true for long-running processes (servers, daemons).
- stop: Stop a running container.
- start: Resume a stopped container.
- remove: Stop + delete a container.
- list: List all tracked containers with their current status.
- logs: Get container logs.

Interactive UIs: To build something the user can interact with on their phone:
1. Create a container with port mappings (e.g. ports: ["3000:3000"])
2. Install dependencies and start a dev server inside the container
3. Use OpenURL to open the app via Tailscale hostname`;

  readonly parameters = {
    type: 'object' as const,
    properties: {
      action: {
        type: 'string' as const,
        enum: ['create', 'exec', 'stop', 'start', 'remove', 'list', 'logs'],
        description: 'The action to perform',
      },
      name: {
        type: 'string' as const,
        description: 'Container name. Optional for create (auto-generated if omitted). Required for exec, stop, start, remove, logs.',
      },
      image: {
        type: 'string' as const,
        description: 'OCI image for create (default: ubuntu:latest)',
      },
      command: {
        type: 'string' as const,
        description: 'Command to execute (required for exec)',
      },
      cpus: {
        type: 'number' as const,
        description: 'CPU count for create',
      },
      memory: {
        type: 'string' as const,
        description: 'Memory limit for create (e.g. "2g")',
      },
      ports: {
        type: 'array' as const,
        items: { type: 'string' as const },
        description: 'Port mappings for create (e.g. ["8080:80"])',
      },
      env: {
        type: 'array' as const,
        items: { type: 'string' as const },
        description: 'Environment variables (e.g. ["KEY=value"])',
      },
      volumes: {
        type: 'array' as const,
        items: { type: 'string' as const },
        description: 'Additional volume mounts for create (e.g. ["/host:/container"])',
      },
      workdir: {
        type: 'string' as const,
        description: 'Working directory for exec',
      },
      timeout: {
        type: 'number' as const,
        description: 'Timeout in ms for exec (default: 120000)',
      },
      detach: {
        type: 'boolean' as const,
        description: 'Run exec command in background (detached). Process persists after exec returns. Use for long-running services.',
      },
      tail: {
        type: 'number' as const,
        description: 'Number of log lines for logs action',
      },
    },
    required: ['action'] as string[],
  };

  private config: SandboxToolConfig;
  private runner: ContainerRunner;
  private registry: ContainerRegistry;
  private installChecked: boolean | null = null;

  constructor(config: SandboxToolConfig) {
    this.config = config;
    this.runner = new ContainerRunner();
    const registryPath = path.join(config.tronHome, 'artifacts', 'containers.json');
    this.registry = new ContainerRegistry(registryPath);
  }

  async execute(
    toolCallIdOrArgs: string | SandboxParams,
    argsOrSignal?: SandboxParams | AbortSignal,
    signal?: AbortSignal,
  ): Promise<TronToolResult> {
    let params: SandboxParams;
    let abortSignal: AbortSignal | undefined;

    if (typeof toolCallIdOrArgs === 'string') {
      params = argsOrSignal as SandboxParams;
      abortSignal = signal;
    } else {
      params = toolCallIdOrArgs;
      abortSignal = argsOrSignal instanceof AbortSignal ? argsOrSignal : undefined;
    }

    // Install check (cached)
    if (this.installChecked === null) {
      this.installChecked = await this.runner.checkInstalled();
    }
    if (!this.installChecked) {
      return { content: NOT_INSTALLED_ERROR, isError: true };
    }

    try {
      switch (params.action) {
        case 'create':
          return await this.handleCreate(params);
        case 'exec':
          return await this.handleExec(params, abortSignal);
        case 'stop':
          return await this.handleStop(params);
        case 'start':
          return await this.handleStart(params);
        case 'remove':
          return await this.handleRemove(params);
        case 'list':
          return await this.handleList();
        case 'logs':
          return await this.handleLogs(params);
        default:
          return { content: `Unknown action: ${params.action}`, isError: true };
      }
    } catch (error) {
      const err = error as Error;
      logger.error('Sandbox tool error', { action: params.action, error: err.message });
      return { content: `Error: ${err.message}`, isError: true };
    }
  }

  private async handleCreate(params: SandboxParams): Promise<TronToolResult> {
    const name = params.name ?? `tron-${randomBytes(4).toString('hex')}`;
    const image = params.image ?? DEFAULT_IMAGE;
    const ports = params.ports ?? [];

    const args: string[] = ['run', '--detach', '--name', name];

    // Workspace volume
    args.push('--volume', `${this.config.workingDirectory}:/workspace`);

    // Optional resource limits
    if (params.cpus) {
      args.push('--cpus', String(params.cpus));
    }
    if (params.memory) {
      args.push('--memory', params.memory);
    }

    // Port mappings
    for (const port of ports) {
      args.push('--publish', port);
    }

    // Environment variables
    if (params.env) {
      for (const env of params.env) {
        args.push('--env', env);
      }
    }

    // Additional volumes
    if (params.volumes) {
      for (const vol of params.volumes) {
        args.push('--volume', vol);
      }
    }

    // Image + keep-alive command
    // Detached containers need a long-running process or they exit immediately.
    // `sleep infinity` keeps the container alive for exec calls.
    args.push(image, 'sleep', 'infinity');

    const result = await this.runner.run(args);

    if (result.exitCode !== 0) {
      const output = [result.stdout, result.stderr].filter(Boolean).join('\n');
      return { content: `Failed to create container:\n${output}`, isError: true };
    }

    const record: ContainerRecord = {
      name,
      image,
      createdAt: new Date().toISOString(),
      createdBySession: this.config.sessionId,
      workingDirectory: this.config.workingDirectory,
      ports,
    };
    this.registry.add(record);

    const portInfo = ports.length > 0 ? `\nPorts: ${ports.join(', ')}` : '';
    return {
      content: `Container created: ${name}\nImage: ${image}\nWorkspace: /workspace${portInfo}`,
    };
  }

  private async handleExec(params: SandboxParams, signal?: AbortSignal): Promise<TronToolResult> {
    if (!params.name) {
      return { content: 'Error: name is required for exec', isError: true };
    }
    if (!params.command) {
      return { content: 'Error: command is required for exec', isError: true };
    }

    const args: string[] = ['exec'];

    if (params.detach) {
      args.push('--detach');
    }
    if (params.workdir) {
      args.push('--workdir', params.workdir);
    }
    if (params.env) {
      for (const env of params.env) {
        args.push('--env', env);
      }
    }

    // Wrap command in sh -c so shell syntax (pipes, &&, redirects, etc.) works.
    // Without this, the container CLI treats the entire string as an executable path.
    args.push(params.name, 'sh', '-c', params.command);

    const result = await this.runner.run(args, {
      timeout: params.timeout ?? DEFAULT_EXEC_TIMEOUT,
      signal,
    });

    if (params.detach) {
      return {
        content: result.exitCode === 0
          ? `Process started in background: ${params.command}`
          : `Failed to start background process:\n${[result.stdout, result.stderr].filter(Boolean).join('\n')}`,
        isError: result.exitCode !== 0,
      };
    }

    const output = [result.stdout, result.stderr].filter(Boolean).join('\n');
    const interrupted = result.interrupted ? '\n[Interrupted]' : '';
    const exitInfo = result.exitCode !== 0 ? `\n[Exit code: ${result.exitCode}]` : '';

    return {
      content: `${output}${interrupted}${exitInfo}`.trim() || '(no output)',
      isError: result.exitCode !== 0,
    };
  }

  private async handleStop(params: SandboxParams): Promise<TronToolResult> {
    if (!params.name) {
      return { content: 'Error: name is required for stop', isError: true };
    }

    const result = await this.runner.run(['stop', params.name]);

    if (result.exitCode !== 0) {
      const output = [result.stdout, result.stderr].filter(Boolean).join('\n');
      return { content: `Failed to stop container:\n${output}`, isError: true };
    }

    return { content: `Container stopped: ${params.name}` };
  }

  private async handleStart(params: SandboxParams): Promise<TronToolResult> {
    if (!params.name) {
      return { content: 'Error: name is required for start', isError: true };
    }

    const result = await this.runner.run(['start', params.name]);

    if (result.exitCode !== 0) {
      const output = [result.stdout, result.stderr].filter(Boolean).join('\n');
      return { content: `Failed to start container:\n${output}`, isError: true };
    }

    return { content: `Container started: ${params.name}` };
  }

  private async handleRemove(params: SandboxParams): Promise<TronToolResult> {
    if (!params.name) {
      return { content: 'Error: name is required for remove', isError: true };
    }

    // Stop first (ignore errors — may already be stopped)
    await this.runner.run(['stop', params.name]);

    const result = await this.runner.run(['delete', params.name]);

    if (result.exitCode !== 0) {
      const output = [result.stdout, result.stderr].filter(Boolean).join('\n');
      return { content: `Failed to remove container:\n${output}`, isError: true };
    }

    this.registry.remove(params.name);
    return { content: `Container removed: ${params.name}` };
  }

  private async handleList(): Promise<TronToolResult> {
    const records = this.registry.getAll();

    // Get live container statuses
    const liveResult = await this.runner.run(['list', '--all', '--json']);
    let liveStatuses = new Map<string, string>();

    if (liveResult.exitCode === 0 && liveResult.stdout.trim()) {
      try {
        const liveContainers = JSON.parse(liveResult.stdout) as Array<{ name: string; status: string }>;
        for (const c of liveContainers) {
          liveStatuses.set(c.name, c.status);
        }
      } catch {
        // If JSON parsing fails, proceed without live statuses
      }
    }

    if (records.length === 0) {
      return { content: 'No containers tracked.' };
    }

    const lines: string[] = ['Name | Image | Status | Ports | Created | Session', '--- | --- | --- | --- | --- | ---'];

    for (const r of records) {
      const status = liveStatuses.has(r.name)
        ? liveStatuses.get(r.name)!
        : 'gone';
      const ports = r.ports.length > 0 ? r.ports.join(', ') : '-';
      const created = r.createdAt.replace('T', ' ').slice(0, 19);
      const session = r.createdBySession.slice(0, 12);
      lines.push(`${r.name} | ${r.image} | ${status} | ${ports} | ${created} | ${session}`);
    }

    // Reconcile: remove entries for gone containers only if user explicitly cleans up
    // We keep them in the list so the agent knows about them

    return { content: lines.join('\n') };
  }

  private async handleLogs(params: SandboxParams): Promise<TronToolResult> {
    if (!params.name) {
      return { content: 'Error: name is required for logs', isError: true };
    }

    const args: string[] = ['logs'];
    if (params.tail) {
      args.push('--tail', String(params.tail));
    }
    args.push(params.name);

    const result = await this.runner.run(args);

    if (result.exitCode !== 0) {
      const output = [result.stdout, result.stderr].filter(Boolean).join('\n');
      return { content: `Failed to get logs:\n${output}`, isError: true };
    }

    return { content: result.stdout || '(no logs)' };
  }
}
