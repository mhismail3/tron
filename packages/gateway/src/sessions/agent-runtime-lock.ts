import { mkdir } from "node:fs/promises";
import { join, resolve } from "node:path";
import lockfile from "proper-lockfile";
import { GatewayError } from "../errors.js";

const LOCK_NAME = ".tron-gateway-runtime.lock";

/**
 * The embedded session format has no cross-process lock. Keep one Gateway
 * owner per agent directory so two homes cannot accidentally share canonical
 * JSONL sessions (or their model/settings stores).
 */
export async function acquireAgentRuntimeLock(agentDir: string): Promise<() => Promise<void>> {
  const directory = resolve(agentDir);
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const path = join(directory, LOCK_NAME);
  try {
    return await lockfile.lock(path, {
      realpath: false,
      retries: 0,
      stale: 60_000,
      update: 10_000,
    });
  } catch {
    throw new GatewayError(
      "conflict",
      "Another Tron Gateway already owns a canonical session directory; use a separate agent or session directory for another runtime.",
      false,
    );
  }
}

export async function acquireAgentRuntimeLocks(
  directories: string[],
): Promise<() => Promise<void>> {
  const unique = [...new Set(directories.map(directory => resolve(directory)))];
  const releases: Array<() => Promise<void>> = [];
  try {
    for (const directory of unique) releases.push(await acquireAgentRuntimeLock(directory));
  } catch (error) {
    for (const release of releases.reverse()) await release();
    throw error;
  }
  return async () => {
    for (const release of releases.reverse()) await release();
  };
}
