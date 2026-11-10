import crypto from "node:crypto";
import { syncBuiltinESMExports } from "node:module";
import { vi } from "vitest";

export const CORPUS_EPOCH = Date.parse("2026-01-01T00:00:00.000Z");

export async function recordFixed<T>(run: () => Promise<T>): Promise<T> {
  const restore = countRandomUUID();
  try {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(CORPUS_EPOCH);
    return await run();
  } finally {
    vi.useRealTimers();
    restore();
  }
}

function countRandomUUID(): () => void {
  const original = crypto.randomUUID;
  let next = 0;
  crypto.randomUUID = () => `${(++next).toString(16).padStart(8, "0")}-0000-4000-8000-000000000000`;
  syncBuiltinESMExports();
  return () => {
    crypto.randomUUID = original;
    syncBuiltinESMExports();
  };
}
