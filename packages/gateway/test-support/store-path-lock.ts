import { mkdtemp, readFile, readdir, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";
import { expect, onTestFinished, vi } from "vitest";
import { normalizeStoreValue } from "./tron-store-corpus.js";
import { compareWithGolden, lockPaths, lockUpdateRequested, type TraceNormalization, type TraceValue } from "./scenario-lock.js";

/**
 * A store mutation-path lock (restructure plan §6.5 V4, §6.6): drive one persisted
 * store's real owner through every write path, against a real home directory, and pin
 * each step's result (or refusal) plus the exact persisted bytes after it. The store
 * locks in `tron-store-corpus.ts` prove the committed corpus reads back; these prove
 * what each write commits, so a changed write is a golden diff.
 *
 * Only `Date` is faked (fixed clock, advanced per step). Values are kept exactly, with
 * the temporary root replaced: counters, revisions and timestamps are the contract.
 * A value the host file system assigns (a device and inode identity) is named by an
 * alias instead: equal values share one, so which steps agree is still pinned.
 */
export interface StorePathLog {
  readonly home: string;
  /**
   * Run one step, record its result or refusal, then the store's persisted files.
   * `expected` makes a step that must refuse (or must succeed) fail the lock otherwise.
   */
  step(label: string, run: () => unknown, expected?: "refused" | "result"): Promise<void>;
  /** Advance the fake clock. */
  advance(ms: number): void;
  /** Record the trace and compare it with the module's golden. */
  finish(): Promise<void>;
}

const STORE_PATH_EPOCH = Date.parse("2026-01-01T00:00:00.000Z");

export async function storePathLock(options: {
  module: string;
  name: string;
  testFileUrl: string;
  /** Home-relative directory or file the store owns; its files are recorded after each step. */
  owned: string;
  /** Keys whose string values the host assigns; each distinct value becomes `<key#n shape>` in first-seen order. */
  aliases?: readonly string[];
}): Promise<StorePathLog> {
  const root = await mkdtemp(join(tmpdir(), `tron-store-path-${options.name}-`));
  const home = join(root, "home");
  const normalization: TraceNormalization = { roots: [root, await realpath(root)] };
  const named = new Map<string, string>();
  const keys = new Set(options.aliases ?? []);
  const normalize = (value: unknown): TraceValue => JSON.parse(JSON.stringify(normalizeStoreValue(value, normalization), (key, item: unknown) => {
    if (!keys.has(key) || typeof item !== "string") return item;
    // The alias keeps the value's shape (digits as `n`), so a changed representation still differs.
    if (!named.has(item)) named.set(item, `<${key}#${named.size + 1} ${item.replace(/[0-9]+/gu, "n")}>`);
    return named.get(item);
  })) as TraceValue;
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(STORE_PATH_EPOCH);
  // Released on every exit, including a failure outside a step.
  onTestFinished(async () => {
    vi.useRealTimers();
    await rm(root, { recursive: true, force: true });
  });
  const steps: TraceValue[] = [];
  const unexpected: string[] = [];
  let failures = 0;
  return {
    home,
    advance: (ms) => { vi.setSystemTime(Date.now() + ms); },
    async step(label, run, expected) {
      let outcome: TraceValue;
      try {
        const value = await run();
        outcome = { result: normalize(value === undefined ? "<void>" : value) };
      } catch (error) {
        failures += 1;
        // A Gateway error's code, retryability and details are part of the refusal contract.
        const gateway = error as { name?: unknown; code?: unknown; retryable?: unknown; details?: unknown };
        outcome = { refused: normalize(gateway?.name === "GatewayError"
          ? { message: (error as Error).message, code: gateway.code, retryable: gateway.retryable, details: gateway.details ?? null }
          : error instanceof Error ? error.message : String(error)) };
      }
      if (expected !== undefined && !(expected in (outcome as Record<string, TraceValue>))) unexpected.push(`${label}: ${JSON.stringify(outcome)}`);
      steps.push({ step: label, ...(outcome as Record<string, TraceValue>), files: normalize(await ownedFiles(home, options.owned, normalization)) });
    },
    async finish() {
      vi.useRealTimers();
      expect(unexpected, "steps whose outcome contradicts their declared expectation").toEqual([]);
      await compareWithGolden({
        module: options.module, ...lockPaths(options.testFileUrl, options.name),
        trace: { store: options.name, module: options.module, steps },
        update: lockUpdateRequested(options.module),
        validate: () => {
          expect(steps.length, "a mutation-path lock drives several writes").toBeGreaterThan(3);
          expect(failures, "a mutation-path lock pins at least one refusal").toBeGreaterThan(0);
        },
      });
    },
  };
}

/** The owned files' content: JSON parsed, other files by size, temporaries by name only. */
async function ownedFiles(home: string, owned: string, normalization: TraceNormalization): Promise<TraceValue> {
  const target = join(home, owned);
  let paths: string[];
  try {
    const entries = await readdir(target, { recursive: true, withFileTypes: true });
    paths = entries.filter((entry) => entry.isFile()).map((entry) => join(entry.parentPath, entry.name)).sort();
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    if (code === "ENOENT") return {};
    if (code !== "ENOTDIR") throw error;
    paths = [target];
  }
  const files: Record<string, TraceValue> = {};
  for (const path of paths) {
    const bytes = await readFile(path).catch(() => undefined);
    if (bytes === undefined) continue;
    let content: TraceValue;
    try { content = normalizeStoreValue(JSON.parse(bytes.toString("utf8")), normalization); }
    catch { content = `<${bytes.length} bytes>`; }
    files[relative(home, path)] = content;
  }
  return files;
}
