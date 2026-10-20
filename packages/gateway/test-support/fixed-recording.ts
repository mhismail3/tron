import crypto from "node:crypto";
import { syncBuiltinESMExports } from "node:module";
import { vi } from "vitest";

/** The clock every corpus recording runs under. */
export const CORPUS_EPOCH = Date.parse("2026-01-01T00:00:00.000Z");

/**
 * Run a corpus recording under a fixed clock and a counted `randomUUID`, so recording
 * the same store twice writes the same bytes (restructure plan §6.5, V4). Owners keep
 * their production id and clock sources: the test replaces the process's `Date` and
 * `crypto.randomUUID` for the recording only. `syncBuiltinESMExports` carries the
 * replacement to every module's named `randomUUID` import, including the Pi SDK's
 * session entry ids (the first eight characters, so the counter leads).
 */
export async function recordFixed<T>(run: () => Promise<T>): Promise<T> {
  const original = crypto.randomUUID;
  let next = 0;
  crypto.randomUUID = () => `${(++next).toString(16).padStart(8, "0")}-0000-4000-8000-000000000000`;
  syncBuiltinESMExports();
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(CORPUS_EPOCH);
  try {
    return await run();
  } finally {
    vi.useRealTimers();
    crypto.randomUUID = original;
    syncBuiltinESMExports();
  }
}
