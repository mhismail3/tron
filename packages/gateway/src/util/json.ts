import { mkdir, open, readFile, rm } from "node:fs/promises";
import { dirname } from "node:path";
import lockfile from "proper-lockfile";
import { durableAtomicWriteJson } from "./durable-json.js";

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

/** Read one owner-written JSON document and admit it through `admit`. A missing
 * file is the only admissible absence: an empty, whitespace-only or malformed
 * document throws, because an owner that replaced it would silently discard its
 * state (`readJson`'s fallback exists for optional preferences, not for these). */
export async function readJsonDocument<T>(
  path: string,
  admit: (value: unknown) => T,
  maximumBytes?: number,
): Promise<T | undefined> {
  let content: string;
  try {
    content = maximumBytes === undefined ? await readFile(path, "utf8") : await readFileBounded(path, maximumBytes);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
    throw error;
  }
  if (!content.trim()) throw new Error("JSON document is empty");
  return admit(JSON.parse(content) as unknown);
}

/** Own-property lookup for a null-prototype record dictionary, so a
 * prototype-named key can never resolve to inherited state. */
export function ownRecord<T>(dictionary: Record<string, T>, key: string): T | undefined {
  return Object.prototype.hasOwnProperty.call(dictionary, key) ? dictionary[key] : undefined;
}

/** Copy one record dictionary without carrying its prototype into the result. */
export function cloneDictionary<T>(dictionary: Record<string, T>): Record<string, T> {
  return Object.assign(Object.create(null) as Record<string, T>, dictionary);
}

/** Admitted-document field bounds shared by the Gateway's durable record
 * stores. A record identity is non-empty and byte-bounded; an instant is a
 * bounded ISO-8601 string. */
export function boundedString(value: unknown, maximum: number): value is string {
  return typeof value === "string" && value.length > 0 && Buffer.byteLength(value) <= maximum;
}

export function boundedTimestamp(value: unknown): value is string {
  return typeof value === "string" && value.length <= 40 && Number.isFinite(Date.parse(value));
}

export async function readJson<T>(path: string, fallback: T, maximumBytes?: number): Promise<T> {
  try {
    const content = maximumBytes === undefined ? await readFile(path, "utf8") : await readFileBounded(path, maximumBytes);
    return content.trim() ? (JSON.parse(content) as T) : fallback;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return fallback;
    throw error;
  }
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
    await durableAtomicWriteJson(path, next);
    return next;
  } finally {
    await release();
  }
}

export async function removeIfExists(path: string): Promise<void> {
  await rm(path, { force: true });
}
