import { randomBytes } from "node:crypto";
import { mkdir, open, rename, rm } from "node:fs/promises";
import { dirname } from "node:path";
import { performance } from "node:perf_hooks";

/*
 * Every fsync the Gateway performs goes through `syncDurably`, so the rate and
 * time of durable synchronization are counted at one primitive and drained by
 * the transport's resource sampler. A store then needs no record of its own on
 * an interactive path (run markers, upload commits, catalog metadata, session
 * exports, workspace and knowledge state, display artifacts). The counters are
 * process global because the primitive is.
 */
let durableFsyncCount = 0;
let durableFsyncMs = 0;

/** Closes the fsync window: how many synchronizations completed and how long
 * they took, since this call. */
export function drainDurableWriteStats(): { count: number; ms: number } {
  const stats = { count: durableFsyncCount, ms: durableFsyncMs };
  durableFsyncCount = 0;
  durableFsyncMs = 0;
  return stats;
}

/**
 * Synchronizes one durable handle and counts the fsync that completed. Time is
 * the sync call alone, not the write or rename around it, and a failed sync
 * throws without counting: the sample never reports a write that did not land.
 */
export async function syncDurably(handle: { sync(): Promise<void> }): Promise<void> {
  const startedAt = performance.now();
  await handle.sync();
  durableFsyncCount += 1;
  durableFsyncMs += Math.max(0, performance.now() - startedAt);
}

export interface DurableJsonFileSystem {
  mkdir: typeof mkdir;
  open: typeof open;
  rename: typeof rename;
  rm: typeof rm;
}

const productionFileSystem: DurableJsonFileSystem = { mkdir, open, rename, rm };

type DurablePublicationError = Error & { publicationVisible?: true };

/** Returns whether an error happened after the replacement was made visible. */
export function isDurablePublicationUncertain(error: unknown): boolean {
  return typeof error === "object" && error !== null
    && (error as DurablePublicationError).publicationVisible === true;
}

/**
 * Atomically publishes one owner-only JSON document and synchronizes both the
 * document and directory entry before acknowledgement. The unique temporary
 * file is never reused and is removed only when this call created it.
 */
export function durableAtomicWriteJson(
  path: string,
  value: unknown,
  mode = 0o600,
  fileSystem: DurableJsonFileSystem = productionFileSystem,
): Promise<void> {
  return publishAtomicJson(path, value, mode, fileSystem);
}

async function publishAtomicJson(
  path: string,
  value: unknown,
  mode: number,
  fileSystem: DurableJsonFileSystem,
): Promise<void> {
  const directory = dirname(path);
  await fileSystem.mkdir(directory, { recursive: true, mode: 0o700 });
  const temporary = `${path}.${process.pid}.${randomBytes(6).toString("hex")}.tmp`;
  let temporaryExists = false;
  let publicationVisible = false;
  try {
    const handle = await fileSystem.open(temporary, "wx", mode);
    temporaryExists = true;
    try {
      await handle.writeFile(`${JSON.stringify(value, null, 2)}\n`, "utf8");
      await syncDurably(handle);
    } finally {
      await handle.close();
    }
    await fileSystem.rename(temporary, path);
    publicationVisible = true;
    temporaryExists = false;
    const directoryHandle = await fileSystem.open(directory, "r");
    try {
      await syncDurably(directoryHandle);
    } finally {
      await directoryHandle.close();
    }
  } catch (error) {
    if (temporaryExists) await fileSystem.rm(temporary, { force: true }).catch(() => {});
    if (publicationVisible && error && typeof error === "object") {
      (error as DurablePublicationError).publicationVisible = true;
    }
    throw error;
  }
}

/** Publish one bounded owner-written JSON document. The exact encoded size is
 * checked before the atomic replacement, so an oversized document is never
 * written at all. */
export async function durablePublishBoundedJson(
  path: string,
  document: unknown,
  maximumBytes: number,
): Promise<void> {
  const encoded = `${JSON.stringify(document, null, 2)}\n`;
  if (Buffer.byteLength(encoded) > maximumBytes) throw new Error("JSON document exceeds its byte limit");
  await durableAtomicWriteJson(path, document);
}

/** Remove one published document durably. Missing is already the desired state. */
export async function durableRemove(
  path: string,
  fileSystem: Pick<DurableJsonFileSystem, "open" | "rm"> = productionFileSystem,
): Promise<void> {
  const directory = dirname(path);
  try {
    await fileSystem.rm(path);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return;
    throw error;
  }
  // Only a removal that reaches the directory sync is a durable write; removing
  // a file that was already gone fsyncs nothing.
  const directoryHandle = await fileSystem.open(directory, "r");
  try {
    await syncDurably(directoryHandle);
  } finally {
    await directoryHandle.close();
  }
}
