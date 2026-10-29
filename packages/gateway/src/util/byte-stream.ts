import type { Readable } from "node:stream";

/** Disposable ranged bytes. The supplying resource owner retains admission,
 * mutation fencing, bounds and lifetime; transports consume/release the lease. */
export interface ByteLease {
  mimeType: string;
  size: number;
  totalSize: number;
  rangeStart: number;
  rangeEnd: number;
  stream: Readable;
  release(): Promise<void>;
}
export interface ByteRange { start: number; end?: number }
