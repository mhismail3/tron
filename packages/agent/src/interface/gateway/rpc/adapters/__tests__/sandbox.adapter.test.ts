/**
 * @fileoverview Tests for Sandbox Adapter
 *
 * The sandbox adapter merges container registry records with live
 * container data from the CLI (union of both sources) and includes
 * tailscaleIp from settings.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';

vi.mock('@capabilities/tools/sandbox/container-registry.js', () => ({
  ContainerRegistry: vi.fn(),
}));

vi.mock('@capabilities/tools/sandbox/container-runner.js', () => ({
  ContainerRunner: vi.fn(),
}));

vi.mock('@infrastructure/settings/index.js', () => ({
  getSettings: vi.fn(),
}));

import { ContainerRegistry } from '@capabilities/tools/sandbox/container-registry.js';
import { ContainerRunner } from '@capabilities/tools/sandbox/container-runner.js';
import { getSettings } from '@infrastructure/settings/index.js';
import { createSandboxAdapter } from '../sandbox.adapter.js';

describe('SandboxAdapter', () => {
  let mockGetAll: ReturnType<typeof vi.fn>;
  let mockRun: ReturnType<typeof vi.fn>;
  let mockCheckInstalled: ReturnType<typeof vi.fn>;

  const registryContainers = [
    {
      name: 'web-app-1',
      image: 'nginx:latest',
      createdAt: '2025-01-15T10:00:00Z',
      createdBySession: 'sess-1',
      workingDirectory: '/Users/test/project',
      ports: ['3000:3000', '8080:80'],
      purpose: 'Web server',
    },
    {
      name: 'db-1',
      image: 'postgres:16',
      createdAt: '2025-01-14T10:00:00Z',
      createdBySession: 'sess-2',
      workingDirectory: '/Users/test/project',
      ports: ['5432:5432'],
    },
    {
      name: 'redis-1',
      image: 'redis:7',
      createdAt: '2025-01-13T10:00:00Z',
      createdBySession: 'sess-3',
      workingDirectory: '/Users/test/other',
      ports: [],
      purpose: 'Cache layer',
    },
  ];

  // Apple `container` CLI format
  const liveCliOutput = [
    {
      configuration: {
        id: 'web-app-1',
        image: { reference: 'docker.io/library/nginx:latest' },
        publishedPorts: [
          { hostPort: 3000, containerPort: 3000, proto: 'tcp' },
          { hostPort: 8080, containerPort: 80, proto: 'tcp' },
        ],
      },
      status: 'running',
    },
    {
      configuration: {
        id: 'db-1',
        image: { reference: 'docker.io/library/postgres:16' },
        publishedPorts: [
          { hostPort: 5432, containerPort: 5432, proto: 'tcp' },
        ],
      },
      status: 'stopped',
    },
  ];

  beforeEach(() => {
    mockGetAll = vi.fn().mockReturnValue(registryContainers);
    mockRun = vi.fn().mockResolvedValue({
      stdout: JSON.stringify(liveCliOutput),
      stderr: '',
      exitCode: 0,
    });
    mockCheckInstalled = vi.fn().mockResolvedValue(true);

    vi.mocked(ContainerRegistry).mockImplementation(() => ({
      getAll: mockGetAll,
      add: vi.fn(),
      remove: vi.fn(),
      reconcile: vi.fn(),
    }) as any);

    vi.mocked(ContainerRunner).mockImplementation(() => ({
      run: mockRun,
      checkInstalled: mockCheckInstalled,
    }) as any);

    vi.mocked(getSettings).mockReturnValue({
      server: { tailscaleIp: '100.64.1.1' },
    } as any);
  });

  it('should return containers with live statuses merged', async () => {
    const adapter = createSandboxAdapter();
    const result = await adapter.listContainers();

    expect(result.containers).toHaveLength(3);
    expect(result.containers[0].name).toBe('web-app-1');
    expect(result.containers[0].status).toBe('running');
    expect(result.containers[1].name).toBe('db-1');
    expect(result.containers[1].status).toBe('stopped');
    expect(result.containers[2].name).toBe('redis-1');
    expect(result.containers[2].status).toBe('gone');
    expect(result.tailscaleIp).toBe('100.64.1.1');
  });

  it('should sort running containers before stopped/gone', async () => {
    const adapter = createSandboxAdapter();
    const result = await adapter.listContainers();

    const statuses = result.containers.map(c => c.status);
    const runningIndex = statuses.indexOf('running');
    const stoppedIndex = statuses.indexOf('stopped');
    const goneIndex = statuses.indexOf('gone');
    expect(runningIndex).toBeLessThan(stoppedIndex);
    expect(runningIndex).toBeLessThan(goneIndex);
  });

  it('should return empty containers when registry is empty and no live containers', async () => {
    mockGetAll.mockReturnValue([]);
    mockRun.mockResolvedValue({
      stdout: JSON.stringify([]),
      stderr: '',
      exitCode: 0,
    });

    const adapter = createSandboxAdapter();
    const result = await adapter.listContainers();

    expect(result.containers).toEqual([]);
    expect(result.tailscaleIp).toBe('100.64.1.1');
  });

  it('should fall back to unknown status when CLI fails', async () => {
    mockRun.mockResolvedValue({
      stdout: '',
      stderr: 'container: command not found',
      exitCode: 1,
    });

    const adapter = createSandboxAdapter();
    const result = await adapter.listContainers();

    expect(result.containers).toHaveLength(3);
    for (const c of result.containers) {
      expect(c.status).toBe('unknown');
    }
  });

  it('should fall back to unknown status when CLI returns invalid JSON', async () => {
    mockRun.mockResolvedValue({
      stdout: 'not valid json',
      stderr: '',
      exitCode: 0,
    });

    const adapter = createSandboxAdapter();
    const result = await adapter.listContainers();

    for (const c of result.containers) {
      expect(c.status).toBe('unknown');
    }
  });

  it('should return undefined tailscaleIp when not in settings', async () => {
    vi.mocked(getSettings).mockReturnValue({
      server: {},
    } as any);

    const adapter = createSandboxAdapter();
    const result = await adapter.listContainers();

    expect(result.tailscaleIp).toBeUndefined();
  });

  it('should use live ports from CLI instead of stale registry ports', async () => {
    const adapter = createSandboxAdapter();
    const result = await adapter.listContainers();

    const webApp = result.containers.find(c => c.name === 'web-app-1')!;
    expect(webApp.ports).toEqual(['3000:3000', '8080:80']);
  });

  it('should fall back to registry ports when container is gone', async () => {
    const adapter = createSandboxAdapter();
    const result = await adapter.listContainers();

    // redis-1 is not in live output → gone, uses registry ports
    const redis = result.containers.find(c => c.name === 'redis-1')!;
    expect(redis.ports).toEqual([]);
  });

  it('should include purpose when present and undefined when absent', async () => {
    const adapter = createSandboxAdapter();
    const result = await adapter.listContainers();

    const webApp = result.containers.find(c => c.name === 'web-app-1')!;
    expect(webApp.purpose).toBe('Web server');

    const db = result.containers.find(c => c.name === 'db-1')!;
    expect(db.purpose).toBeUndefined();
  });

  it('should preserve all container record fields', async () => {
    const adapter = createSandboxAdapter();
    const result = await adapter.listContainers();

    const webApp = result.containers.find(c => c.name === 'web-app-1')!;
    expect(webApp.image).toBe('nginx:latest');
    expect(webApp.createdAt).toBe('2025-01-15T10:00:00Z');
    expect(webApp.createdBySession).toBe('sess-1');
    expect(webApp.workingDirectory).toBe('/Users/test/project');
  });

  it('should fall back to unknown when CLI is not installed', async () => {
    mockCheckInstalled.mockResolvedValue(false);

    const adapter = createSandboxAdapter();
    const result = await adapter.listContainers();

    for (const c of result.containers) {
      expect(c.status).toBe('unknown');
    }
    expect(mockRun).not.toHaveBeenCalled();
  });

  it('should handle runner throwing an error', async () => {
    mockCheckInstalled.mockResolvedValue(true);
    mockRun.mockRejectedValue(new Error('spawn ENOENT'));

    const adapter = createSandboxAdapter();
    const result = await adapter.listContainers();

    for (const c of result.containers) {
      expect(c.status).toBe('unknown');
    }
  });

  it('should include live containers not in registry', async () => {
    // Add an extra live container not in registry
    const extendedLive = [
      ...liveCliOutput,
      {
        configuration: {
          id: 'unregistered-box',
          image: { reference: 'docker.io/library/alpine:latest' },
          publishedPorts: [
            { hostPort: 9090, containerPort: 9090, proto: 'tcp' },
          ],
        },
        status: 'running',
      },
    ];
    mockRun.mockResolvedValue({
      stdout: JSON.stringify(extendedLive),
      stderr: '',
      exitCode: 0,
    });

    const adapter = createSandboxAdapter();
    const result = await adapter.listContainers();

    expect(result.containers).toHaveLength(4);
    const unregistered = result.containers.find(c => c.name === 'unregistered-box')!;
    expect(unregistered).toBeDefined();
    expect(unregistered.status).toBe('running');
    expect(unregistered.image).toBe('docker.io/library/alpine:latest');
    expect(unregistered.ports).toEqual(['9090:9090']);
    expect(unregistered.createdAt).toBe('');
    expect(unregistered.createdBySession).toBe('');
  });

  it('should not include unregistered containers when CLI fails', async () => {
    mockRun.mockResolvedValue({
      stdout: '',
      stderr: 'error',
      exitCode: 1,
    });

    const adapter = createSandboxAdapter();
    const result = await adapter.listContainers();

    // Only registry containers, all with unknown status
    expect(result.containers).toHaveLength(3);
  });

  describe('stopContainer', () => {
    it('should run container stop command', async () => {
      mockRun.mockResolvedValue({ stdout: '', stderr: '', exitCode: 0 });

      const adapter = createSandboxAdapter();
      const result = await adapter.stopContainer('web-app-1');

      expect(result).toEqual({ success: true });
      expect(mockRun).toHaveBeenCalledWith(['stop', 'web-app-1'], { timeout: 30_000 });
    });

    it('should throw on CLI failure', async () => {
      mockRun.mockResolvedValue({ stdout: '', stderr: 'no such container', exitCode: 1 });

      const adapter = createSandboxAdapter();
      await expect(adapter.stopContainer('nonexistent')).rejects.toThrow('no such container');
    });

    it('should throw with default message when stderr is empty', async () => {
      mockRun.mockResolvedValue({ stdout: '', stderr: '', exitCode: 1 });

      const adapter = createSandboxAdapter();
      await expect(adapter.stopContainer('web-app-1')).rejects.toThrow('container stop failed with exit code 1');
    });
  });

  describe('startContainer', () => {
    it('should run container start command', async () => {
      mockRun.mockResolvedValue({ stdout: '', stderr: '', exitCode: 0 });

      const adapter = createSandboxAdapter();
      const result = await adapter.startContainer('db-1');

      expect(result).toEqual({ success: true });
      expect(mockRun).toHaveBeenCalledWith(['start', 'db-1'], { timeout: 30_000 });
    });

    it('should throw on CLI failure', async () => {
      mockRun.mockResolvedValue({ stdout: '', stderr: 'container is already running', exitCode: 1 });

      const adapter = createSandboxAdapter();
      await expect(adapter.startContainer('web-app-1')).rejects.toThrow('container is already running');
    });
  });

  describe('killContainer', () => {
    it('should run container kill command', async () => {
      mockRun.mockResolvedValue({ stdout: '', stderr: '', exitCode: 0 });

      const adapter = createSandboxAdapter();
      const result = await adapter.killContainer('web-app-1');

      expect(result).toEqual({ success: true });
      expect(mockRun).toHaveBeenCalledWith(['kill', 'web-app-1'], { timeout: 30_000 });
    });

    it('should throw on CLI failure', async () => {
      mockRun.mockResolvedValue({ stdout: '', stderr: 'no such container', exitCode: 1 });

      const adapter = createSandboxAdapter();
      await expect(adapter.killContainer('nonexistent')).rejects.toThrow('no such container');
    });
  });
});
