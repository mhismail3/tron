import { createHash } from "node:crypto";
import { GatewayError } from "../errors.js";

interface BlobValue {
  data: Buffer;
  mimeType: string;
  touchedAt: number;
}

export class BlobStore {
  private readonly blobs = new Map<string, BlobValue>();

  register(base64: string, mimeType: string): string {
    return this.registerData(Buffer.from(base64, "base64"), mimeType);
  }

  registerData(data: Buffer, mimeType: string): string {
    const id = createHash("sha256").update(mimeType).update("\0").update(data).digest("base64url");
    this.blobs.set(id, { data, mimeType, touchedAt: Date.now() });
    return id;
  }

  get(id: string): { data: Buffer; mimeType: string } {
    const value = this.blobs.get(id);
    if (!value) throw new GatewayError("not_found", "Blob is not available; refresh the session snapshot");
    value.touchedAt = Date.now();
    return value;
  }

  prune(maxAgeMs = 30 * 60_000): void {
    const cutoff = Date.now() - maxAgeMs;
    for (const [id, value] of this.blobs) {
      if (value.touchedAt < cutoff) this.blobs.delete(id);
    }
  }
}
