import { createHash } from "node:crypto";
import { GatewayError } from "../errors.js";

interface BlobValue {
  data: Buffer;
  mimeType: string;
  touchedAt: number;
}

export const BLOB_MAX_ITEM_BYTES = 25 * 1_048_576;
export const BLOB_MAX_ITEMS = 128;
export const BLOB_MAX_TOTAL_BYTES = 200 * 1_048_576;
export const BLOB_MAX_MIME_TYPE_BYTES = 1_024;

interface BlobStoreLimits {
  maximumItemBytes: number;
  maximumItems: number;
  maximumTotalBytes: number;
}

export class BlobStore {
  private readonly blobs = new Map<string, BlobValue>();
  private totalBytes = 0;

  constructor(
    private readonly limits: BlobStoreLimits = {
      maximumItemBytes: BLOB_MAX_ITEM_BYTES,
      maximumItems: BLOB_MAX_ITEMS,
      maximumTotalBytes: BLOB_MAX_TOTAL_BYTES,
    },
    private readonly now: () => number = Date.now,
  ) {
    if (limits.maximumItemBytes < 0 || limits.maximumItems < 1
      || limits.maximumTotalBytes < limits.maximumItemBytes) {
      throw new Error("Invalid blob store limits");
    }
  }

  register(base64: string, mimeType: string): string {
    const maximumBase64Characters = Math.ceil(this.limits.maximumItemBytes / 3) * 4;
    if (base64.length > maximumBase64Characters) {
      throw new GatewayError("conflict", "Blob exceeds the 25 MiB item limit");
    }
    return this.registerData(Buffer.from(base64, "base64"), mimeType);
  }

  registerData(data: Buffer, mimeType: string): string {
    if (Buffer.byteLength(mimeType) > BLOB_MAX_MIME_TYPE_BYTES) {
      throw new GatewayError("conflict", "Blob MIME type exceeds the metadata limit");
    }
    if (data.length > this.limits.maximumItemBytes) {
      throw new GatewayError("conflict", "Blob exceeds the 25 MiB item limit");
    }
    const id = createHash("sha256").update(mimeType).update("\0").update(data).digest("base64url");
    const existing = this.blobs.get(id);
    if (existing) {
      this.touch(existing);
      return id;
    }
    this.prune();
    if (this.blobs.size >= this.limits.maximumItems
      || data.length > this.limits.maximumTotalBytes - this.totalBytes) {
      throw new GatewayError("busy", "Blob storage is temporarily full", true);
    }
    this.blobs.set(id, {
      data,
      mimeType,
      touchedAt: this.now(),
    });
    this.totalBytes += data.length;
    return id;
  }

  get(id: string): { data: Buffer; mimeType: string } {
    const value = this.blobs.get(id);
    if (!value) throw new GatewayError("not_found", "Blob is not available; refresh the session snapshot");
    this.touch(value);
    return value;
  }

  prune(maxAgeMs = 30 * 60_000): void {
    const cutoff = this.now() - maxAgeMs;
    for (const [id, value] of this.blobs) {
      if (value.touchedAt < cutoff) this.remove(id, value);
    }
  }

  private touch(value: BlobValue): void {
    value.touchedAt = this.now();
  }

  private remove(id: string, value: BlobValue): void {
    if (!this.blobs.delete(id)) return;
    this.totalBytes -= value.data.length;
  }
}
