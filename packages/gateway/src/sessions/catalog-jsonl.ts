import type { FileHandle } from "node:fs/promises";

const MAX_CATALOG_LINE_BYTES = 64 * 1_048_576;
export class CatalogLineLimitError extends Error {
  constructor() { super("Catalog JSONL line exceeds 64 MiB"); }
}

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
