/**
 * @fileoverview Sandbox Adapter
 *
 * Standalone adapter (no orchestrator dependency) that merges container
 * registry records with live container data from the `container` CLI.
 * Shows the union of registry + live containers so nothing is hidden.
 * Reads tailscaleIp from settings for constructing URLs on the client.
 */

import { homedir } from 'os';
import { join } from 'path';
import { ContainerRegistry } from '@capabilities/tools/sandbox/container-registry.js';
import { ContainerRunner } from '@capabilities/tools/sandbox/container-runner.js';
import { getSettings } from '@infrastructure/settings/index.js';
import type { SandboxRpcManager } from '../../../rpc/index.js';

const STATUS_ORDER: Record<string, number> = { running: 0, stopped: 1, gone: 2, unknown: 3 };

interface LiveContainer {
  name: string;
  image: string;
  status: string;
  ports: string[];
}

export function createSandboxAdapter(): SandboxRpcManager {
  return {
    async listContainers() {
      const registryPath = join(homedir(), '.tron', 'artifacts', 'containers.json');
      const registry = new ContainerRegistry(registryPath);
      const records = registry.getAll();

      // null = CLI unavailable/failed, array = successful query
      const liveContainers = await queryLiveContainers();
      const liveMap = new Map<string, LiveContainer>();
      if (liveContainers) {
        for (const lc of liveContainers) {
          liveMap.set(lc.name, lc);
        }
      }

      const seen = new Set<string>();
      const containers: Array<{
        name: string;
        image: string;
        status: string;
        ports: string[];
        purpose?: string;
        createdAt: string;
        createdBySession: string;
        workingDirectory: string;
      }> = [];

      // Registry containers: enrich with live status + live ports
      for (const record of records) {
        seen.add(record.name);
        const live = liveMap.get(record.name);
        containers.push({
          name: record.name,
          image: record.image,
          status: liveContainers === null ? 'unknown' : (live?.status ?? 'gone'),
          ports: live?.ports ?? record.ports,
          purpose: record.purpose,
          createdAt: record.createdAt,
          createdBySession: record.createdBySession,
          workingDirectory: record.workingDirectory,
        });
      }

      // Live containers not in registry: add with CLI data
      if (liveContainers) {
        for (const lc of liveContainers) {
          if (seen.has(lc.name)) continue;
          containers.push({
            name: lc.name,
            image: lc.image,
            status: lc.status,
            ports: lc.ports,
            purpose: undefined,
            createdAt: '',
            createdBySession: '',
            workingDirectory: '',
          });
        }
      }

      containers.sort((a, b) =>
        (STATUS_ORDER[a.status] ?? 99) - (STATUS_ORDER[b.status] ?? 99)
      );

      const settings = getSettings();
      return {
        containers,
        tailscaleIp: settings.server?.tailscaleIp,
      };
    },

    async stopContainer(name: string) {
      return runContainerAction('stop', name);
    },

    async startContainer(name: string) {
      return runContainerAction('start', name);
    },

    async killContainer(name: string) {
      return runContainerAction('kill', name);
    },
  };
}

async function runContainerAction(command: string, name: string): Promise<{ success: boolean }> {
  const runner = new ContainerRunner();
  const result = await runner.run([command, name], { timeout: 30_000 });
  if (result.exitCode !== 0) {
    const msg = result.stderr.trim() || `container ${command} failed with exit code ${result.exitCode}`;
    throw new Error(msg);
  }
  return { success: true };
}

/**
 * Query live containers from the CLI.
 * Returns null if the CLI is unavailable or fails.
 */
async function queryLiveContainers(): Promise<LiveContainer[] | null> {
  const runner = new ContainerRunner();

  const installed = await runner.checkInstalled();
  if (!installed) {
    return null;
  }

  try {
    const result = await runner.run(['list', '--all', '--format', 'json'], { timeout: 10_000 });

    if (result.exitCode !== 0) {
      return null;
    }

    const parsed = JSON.parse(result.stdout);
    if (!Array.isArray(parsed)) {
      return null;
    }

    const containers: LiveContainer[] = [];
    for (const entry of parsed) {
      const cfg = entry.configuration;
      const name = cfg?.id;
      const status = entry.status;
      if (!name || !status) continue;

      // Extract image reference
      const image = cfg?.image?.reference ?? 'unknown';

      // Convert publishedPorts to "hostPort:containerPort" strings
      const ports: string[] = [];
      for (const p of cfg?.publishedPorts ?? []) {
        if (p.hostPort && p.containerPort) {
          ports.push(`${p.hostPort}:${p.containerPort}`);
        }
      }

      containers.push({ name, image, status, ports });
    }
    return containers;
  } catch {
    return null;
  }
}
