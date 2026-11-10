import { constants } from "node:fs";
import { lstat, open } from "node:fs/promises";

const MAX_SECURE_JSON_BYTES = 64 * 1_048_576;

type SecureJsonRead<T> =
  | { present: false }
  | { present: true; value: T };

export class SecureJsonFileError extends Error {
  constructor(readonly kind: "unsafe" | "invalid", message: string) {
    super(message);
    this.name = "SecureJsonFileError";
  }
}

export async function readSecureJson<T>(path: string, maximumBytes: number): Promise<SecureJsonRead<T>> {
  const read = await readSecureText(path, maximumBytes);
  if (!read.present) return read;
  try {
    return { present: true, value: JSON.parse(read.value) as T };
  } catch {
    throw new SecureJsonFileError("invalid", "JSON file is malformed");
  }
}

export async function readSecureText(path: string, maximumBytes: number): Promise<SecureJsonRead<string>> {
  if (!Number.isSafeInteger(maximumBytes) || maximumBytes <= 0 || maximumBytes > MAX_SECURE_JSON_BYTES) {
    throw new RangeError(`maximumBytes must be an integer from 1 through ${MAX_SECURE_JSON_BYTES}`);
  }

  const ownerUid = process.getuid?.();
  if (ownerUid === undefined || typeof constants.O_NOFOLLOW !== "number") {
    throw new SecureJsonFileError("unsafe", "JSON file ownership or symlink safety cannot be verified");
  }

  let entry;
  try {
    entry = await lstat(path);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return { present: false };
    throw new SecureJsonFileError("unsafe", "JSON file could not be securely inspected");
  }
  if (!entry.isFile() || entry.uid !== ownerUid || (entry.mode & 0o077) !== 0
    || entry.size <= 0 || entry.size > maximumBytes) {
    throw new SecureJsonFileError("unsafe", "JSON file is not a bounded owner-only regular file");
  }

  let handle;
  try {
    handle = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
    const metadata = await handle.stat();
    if (!metadata.isFile() || metadata.uid !== ownerUid || (metadata.mode & 0o077) !== 0
      || metadata.size <= 0 || metadata.size > maximumBytes || metadata.size !== entry.size
      || metadata.dev !== entry.dev || metadata.ino !== entry.ino) {
      throw new SecureJsonFileError("unsafe", "JSON file changed its secure boundary during read");
    }

    const buffer = Buffer.alloc(metadata.size + 1);
    let offset = 0;
    while (offset < buffer.length) {
      const { bytesRead } = await handle.read(buffer, offset, buffer.length - offset, offset);
      if (bytesRead === 0) break;
      offset += bytesRead;
    }
    if (offset !== metadata.size) {
      throw new SecureJsonFileError("unsafe", "JSON file changed during bounded read");
    }
    const afterRead = await handle.stat();
    if (afterRead.size !== metadata.size || afterRead.uid !== metadata.uid
      || (afterRead.mode & 0o077) !== 0 || afterRead.dev !== metadata.dev || afterRead.ino !== metadata.ino) {
      throw new SecureJsonFileError("unsafe", "JSON file changed its secure boundary during read");
    }

    return { present: true, value: buffer.subarray(0, metadata.size).toString("utf8") };
  } catch (error) {
    if (error instanceof SecureJsonFileError) throw error;
    if ((error as NodeJS.ErrnoException).code) {
      throw new SecureJsonFileError("unsafe", "JSON file could not be securely read");
    }
    throw error;
  } finally {
    await handle?.close();
  }
}
