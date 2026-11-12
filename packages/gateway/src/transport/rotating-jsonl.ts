import { appendFileSync, existsSync, mkdirSync, renameSync, statSync, unlinkSync } from "node:fs";
import { dirname } from "node:path";

const SEGMENT_MAX_BYTES = 5 * 1_024 * 1_024;
const SEGMENT_COUNT = 8;

export class RotatingJsonl {
  private activeBytes: number | undefined;

  constructor(private readonly path: string, private readonly segmentBytes = SEGMENT_MAX_BYTES, readonly segments = SEGMENT_COUNT) {}

  append(record: unknown): void {
    try {
      mkdirSync(dirname(this.path), { recursive: true, mode: 0o700 });
      const line = `${JSON.stringify(record)}\n`;
      const lineBytes = Buffer.byteLength(line);
      if (this.activeBytes === undefined) {
        this.activeBytes = existsSync(this.path) ? statSync(this.path).size : 0;
      }
      if (this.activeBytes > 0 && this.activeBytes + lineBytes > this.segmentBytes) this.rotate();
      appendFileSync(this.path, line, { mode: 0o600 });
      this.activeBytes += lineBytes;
    } catch {
      this.activeBytes = undefined;
    }
  }

  segmentPath(index: number): string {
    return index === 0 ? this.path : `${this.path}.${index}`;
  }

  private rotate(): void {
    try { unlinkSync(this.segmentPath(this.segments - 1)); } catch { }
    for (let index = this.segments - 2; index >= 0; index -= 1) {
      try { renameSync(this.segmentPath(index), this.segmentPath(index + 1)); } catch { }
    }
    this.activeBytes = 0;
  }
}
