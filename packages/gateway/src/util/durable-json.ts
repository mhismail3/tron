import { randomBytes } from "node:crypto";
import { mkdir, open, rename, rm } from "node:fs/promises";
import { dirname } from "node:path";

export interface DurableJsonFileSystem {
  mkdir: typeof mkdir;
  open: typeof open;
  rename: typeof rename;
  rm: typeof rm;
}

const productionFileSystem: DurableJsonFileSystem = { mkdir, open, rename, rm };

/**
 * Atomically publishes one owner-only JSON document and synchronizes both the
 * document and directory entry before acknowledgement. The unique temporary
 * file is never reused and is removed only when this call created it.
 */
export async function durableAtomicWriteJson(
  path: string,
  value: unknown,
  mode = 0o600,
  fileSystem: DurableJsonFileSystem = productionFileSystem,
): Promise<void> {
  const directory = dirname(path);
  await fileSystem.mkdir(directory, { recursive: true, mode: 0o700 });
  const temporary = `${path}.${process.pid}.${randomBytes(6).toString("hex")}.tmp`;
  let temporaryExists = false;
  try {
    const handle = await fileSystem.open(temporary, "wx", mode);
    temporaryExists = true;
    try {
      await handle.writeFile(`${JSON.stringify(value, null, 2)}\n`, "utf8");
      await handle.sync();
    } finally {
      await handle.close();
    }
    await fileSystem.rename(temporary, path);
    temporaryExists = false;
    const directoryHandle = await fileSystem.open(directory, "r");
    try {
      await directoryHandle.sync();
    } finally {
      await directoryHandle.close();
    }
  } catch (error) {
    if (temporaryExists) await fileSystem.rm(temporary, { force: true }).catch(() => {});
    throw error;
  }
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
  const directoryHandle = await fileSystem.open(directory, "r");
  try {
    await directoryHandle.sync();
  } finally {
    await directoryHandle.close();
  }
}
