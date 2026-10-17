import type { FileHandle } from "node:fs/promises";

// Above Tron's largest admitted prompt line (including base64 uploads), but
// below V8's string ceiling. Catalog metadata must never accumulate an arbitrary
// canonical line inside readline's stream callback, outside its owner's catch.
const MAX_CATALOG_LINE_BYTES = 64 * 1_048_576;
export class CatalogLineLimitError extends Error {
  constructor() { super("Catalog JSONL line exceeds 64 MiB"); }
}

/** The caller owns the handle and its identity/stability checks. Decode only
 * after bounding bytes, preserving UTF-8 split across reads and readline's final
 * unterminated-line behavior. Pieces are joined once, not copied on every read. */
export async function* readCatalogLines(handle: FileHandle, start = 0, endExclusive = Infinity): AsyncGenerator<string> {
  const buffer = Buffer.alloc(64 * 1_024);
  let position = start;
  let pieces: Buffer[] = [];
  let pendingBytes = 0;
  while (position < endExclusive) {
    const { bytesRead } = await handle.read(buffer, 0, Math.min(buffer.length, endExclusive - position), position);
    if (bytesRead === 0) break;
    position += bytesRead;
    let from = 0;
    while (from < bytesRead) {
      const newline = buffer.indexOf(10, from);
      const end = newline >= 0 && newline < bytesRead ? newline : bytesRead;
      const length = end - from;
      if (pendingBytes + length > MAX_CATALOG_LINE_BYTES) throw new CatalogLineLimitError();
      if (length > 0) pieces.push(Buffer.from(buffer.subarray(from, end)));
      pendingBytes += length;
      if (end === bytesRead) break;
      const line = Buffer.concat(pieces, pendingBytes).toString("utf8");
      pieces = [];
      pendingBytes = 0;
      yield line.endsWith("\r") ? line.slice(0, -1) : line;
      from = end + 1;
    }
  }
  if (pendingBytes > 0) {
    const line = Buffer.concat(pieces, pendingBytes).toString("utf8");
    yield line.endsWith("\r") ? line.slice(0, -1) : line;
  }
}
