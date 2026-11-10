import { randomBytes } from "node:crypto";
import { mkdir, open, rename, rm } from "node:fs/promises";
import { dirname } from "node:path";
import { performance } from "node:perf_hooks";

let durableFsyncCount = 0;
let durableFsyncMs = 0;

export function drainDurableWriteStats(): { count: number; ms: number } {
  const stats = { count: durableFsyncCount, ms: durableFsyncMs };
  durableFsyncCount = 0;
  durableFsyncMs = 0;
  return stats;
}

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

export function isDurablePublicationUncertain(error: unknown): boolean {
  return typeof error === "object" && error !== null
    && (error as DurablePublicationError).publicationVisible === true;
}

export async function durableAtomicWriteJson(
  path: string,
  value: unknown,
  mode = 0o600,
  fileSystem: DurableJsonFileSystem = productionFileSystem,
): Promise<void> {
  await durableAtomicWriteText(path, `${JSON.stringify(value, null, 2)}\n`, mode, fileSystem);
}

export async function durableAtomicWriteText(
  path: string,
  text: string,
  mode = 0o600,
  fileSystem: DurableJsonFileSystem = productionFileSystem,
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
      await handle.writeFile(text, "utf8");
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

export async function durablePublishBoundedJson(
  path: string,
  document: unknown,
  maximumBytes: number,
): Promise<void> {
  const encoded = `${JSON.stringify(document, null, 2)}\n`;
  if (Buffer.byteLength(encoded) > maximumBytes) throw new Error("JSON document exceeds its byte limit");
  await durableAtomicWriteJson(path, document);
}

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
  const directoryHandle = await fileSystem.open(directory, "r");
  try {
    await syncDurably(directoryHandle);
  } finally {
    await directoryHandle.close();
  }
}
