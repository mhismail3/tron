import { mkdir } from "node:fs/promises";
import { join, resolve } from "node:path";
import lockfile from "proper-lockfile";
import { GatewayError } from "../errors.js";

const LOCK_NAME = ".tron-gateway-runtime.lock";

export async function acquireAgentRuntimeLock(agentDir: string): Promise<() => Promise<void>> {
  const directory = resolve(agentDir);
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const path = join(directory, LOCK_NAME);
  let unlock: () => Promise<void>;
  try {
    unlock = await lockfile.lock(path, {
      realpath: false,
      retries: 0,
      stale: 60_000,
      update: 10_000,
    });
  } catch {
    throw new GatewayError(
      "conflict",
      "Another Tron Gateway already owns an agent directory; use a separate agent directory for another runtime.",
      false,
    );
  }
  let release: Promise<void> | undefined;
  return (): Promise<void> => {
    release ??= unlock();
    return release;
  };
}
