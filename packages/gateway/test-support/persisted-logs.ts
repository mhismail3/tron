import { existsSync, readFileSync } from "node:fs";
import type { LogRecord } from "../src/transport/logger.js";
import { RotatingJsonl } from "../src/transport/rotating-jsonl.js";

export function persistedLogRecords(path: string, limit = Number.POSITIVE_INFINITY): LogRecord[] {
  const file = new RotatingJsonl(path);
  const lines: string[] = [];
  for (let index = file.segments - 1; index >= 0; index -= 1) {
    const candidate = file.segmentPath(index);
    if (existsSync(candidate)) lines.push(...readFileSync(candidate, "utf8").split("\n").filter(Boolean));
  }
  return lines.slice(-limit).map((line) => JSON.parse(line) as LogRecord);
}
