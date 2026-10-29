import { createHash } from "node:crypto";
import { lstat } from "node:fs/promises";
import { Readable } from "node:stream";
import { GatewayError } from "../../errors.js";
import type { ByteLease, ByteRange } from "../../util/byte-stream.js";
import { fileIdentity, fileStamp, openAppFile, snapshotDigest, snapshotSize, type AppFileSnapshot } from "./apps-folder-files.js";

interface ReadLease { id: string; revision: string; lease: ByteLease }
function changed(): never { throw new GatewayError("conflict", "Artifact changed; reopen its current version", true, { reason: "entry_changed" }); }
/** Index-owned disposable descriptor lifetimes. No membership, grants, path
 * discovery or second manifest reader lives here. */
export class AppPreviewLeases {
  private readonly active = new Set<ReadLease>();
  private closed = false;
  async acquire(input: { id: string; revision: string; root: string; identity: string; path: string; file: AppFileSnapshot; mimeType: string }, range?: ByteRange, signal?: AbortSignal): Promise<ByteLease> {
    signal?.throwIfAborted();
    if (this.closed) changed();
    if (this.active.size >= 4) throw new GatewayError("busy", "Too many artifact readers", true);
    const size = snapshotSize(input.file), start = range?.start ?? 0, end = Math.min(range?.end ?? size - 1, size - 1);
    if (range && (!Number.isSafeInteger(start) || start < 0 || start >= size || range.end !== undefined && (!Number.isSafeInteger(range.end) || range.end < start))) {
      throw new GatewayError("invalid_request", "Artifact range is not satisfiable", false, { rangeUnsatisfiable: true, totalSize: size });
    }
    if (fileIdentity(await lstat(input.root)) !== input.identity) changed();
    const { handle, stat } = await openAppFile(input.root, input.path);
    try {
      const stamp = fileStamp(stat);
      if (stat.size !== size || fileIdentity(await lstat(input.root)) !== input.identity) changed();
      if (!Buffer.isBuffer(input.file)) {
        if (stamp !== input.file.stamp) changed();
      } else {
        // Buffered text owns immutable admitted bytes. Reopening a descriptor
        // still has to prove those exact bytes, not borrow a fresh stat stamp
        // for a file changed between index admission and lease acquisition.
        const hash = createHash("sha256"), scratch = Buffer.alloc(64 * 1024);
        let offset = 0;
        while (offset < size) {
          signal?.throwIfAborted();
          const read = await handle.read(scratch, 0, Math.min(size - offset, scratch.length), offset);
          if (!read.bytesRead) changed();
          hash.update(scratch.subarray(0, read.bytesRead)); offset += read.bytesRead;
        }
        if (hash.digest("hex") !== snapshotDigest(input.file) || fileStamp(await handle.stat()) !== stamp) changed();
      }
      signal?.throwIfAborted();
      if (this.closed) changed();
      let stopped = false, closing: Promise<void> | undefined;
      let record: ReadLease;
      const closeFile = (): Promise<void> => closing ??= handle.close().finally(() => {
        this.active.delete(record); signal?.removeEventListener("abort", abort);
      });
      const release = (): Promise<void> => {
        stopped = true; stream.destroy(); return closeFile();
      };
      async function* chunks(): AsyncGenerator<Buffer> {
        let position = start;
        try {
          while (position <= end) {
            if (stopped || fileStamp(await handle.stat()) !== stamp) changed();
            const buffer = Buffer.alloc(Math.min(64 * 1024, end - position + 1));
            const read = await handle.read(buffer, 0, buffer.length, position);
            if (stopped || !read.bytesRead || fileStamp(await handle.stat()) !== stamp) changed();
            position += read.bytesRead;
            yield buffer.subarray(0, read.bytesRead);
          }
        } finally { await closeFile(); }
      }
      const stream = Readable.from(chunks(), { objectMode: false, highWaterMark: 64 * 1024 });
      const lease: ByteLease = { mimeType: input.mimeType, size: Math.max(0, end - start + 1), totalSize: size, rangeStart: start, rangeEnd: end, stream, release };
      record = { id: input.id, revision: input.revision, lease }; this.active.add(record);
      stream.on("error", () => {}); // An unconsumed cancelled lease is still disposable.
      stream.once("close", () => { void closeFile().catch(error => stream.destroy(error as Error)); });
      const abort = (): void => { void release().catch(error => stream.destroy(error as Error)); };
      signal?.addEventListener("abort", abort, { once: true });
      if (signal?.aborted) { await release(); signal.throwIfAborted(); }
      return lease;
    } catch (error) { await handle.close(); throw error; }
  }
  async retireStale(revision: (id: string) => string | undefined): Promise<void> {
    await Promise.all([...this.active].filter(read => revision(read.id) !== read.revision).map(read => read.lease.release()));
  }
  async dispose(): Promise<void> {
    this.closed = true; await this.retireStale(() => undefined);
  }
}
