import { randomBytes } from "node:crypto";
import { mkdir, open, readFile, rename, rm, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import lockfile from "proper-lockfile";

const MAX_BOUNDED_JSON_BYTES = 64 * 1_048_576;

async function readFileBounded(path: string, maximumBytes: number): Promise<string> {
  if (!Number.isSafeInteger(maximumBytes) || maximumBytes < 0 || maximumBytes > MAX_BOUNDED_JSON_BYTES) {
    throw new RangeError(`maximumBytes must be an integer from 0 through ${MAX_BOUNDED_JSON_BYTES}`);
  }
  const handle = await open(path, "r");
  try {
    const metadata = await handle.stat();
    if (metadata.size > maximumBytes) throw new RangeError(`JSON file exceeds its ${maximumBytes}-byte limit`);
    const buffer = Buffer.alloc(metadata.size + 1);
    let offset = 0;
    while (offset < buffer.length) {
      const { bytesRead } = await handle.read(buffer, offset, buffer.length - offset, offset);
      if (bytesRead === 0) break;
      offset += bytesRead;
    }
    if (offset > metadata.size) throw new RangeError("JSON file changed during its bounded read");
    return buffer.subarray(0, offset).toString("utf8");
  } finally {
    await handle.close();
  }
}

export async function readJson<T>(path: string, fallback: T, maximumBytes?: number): Promise<T> {
  try {
    const content = maximumBytes === undefined ? await readFile(path, "utf8") : await readFileBounded(path, maximumBytes);
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
  maximumBytes?: number,
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
    const current = await readJson(path, fallback, maximumBytes);
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
