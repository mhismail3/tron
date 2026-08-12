import { randomBytes } from "node:crypto";
import { mkdir, open, readFile, rename, rm, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import lockfile from "proper-lockfile";

export async function readJson<T>(path: string, fallback: T): Promise<T> {
  try {
    const content = await readFile(path, "utf8");
    return content.trim() ? JSON.parse(content) as T : fallback;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return fallback;
    throw error;
  }
}

export async function atomicWriteJson(path: string, value: unknown, mode = 0o600): Promise<void> {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = `${path}.${process.pid}.${randomBytes(6).toString("hex")}.tmp`;
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode });
  await rename(temporary, path);
}

export async function updateJsonLocked<T>(
  path: string,
  fallback: T,
  update: (current: T) => T,
): Promise<T> {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  let handle;
  try {
    handle = await open(path, "a", 0o600);
  } finally {
    await handle?.close();
  }
  const release = await lockfile.lock(path, {
    realpath: false,
    retries: { retries: 10, minTimeout: 20, maxTimeout: 100 },
  });
  try {
    const current = await readJson(path, fallback);
    const next = update(current);
    await atomicWriteJson(path, next);
    return next;
  } finally {
    await release();
  }
}

export async function removeIfExists(path: string): Promise<void> {
  await rm(path, { force: true });
}
