import { appendFileSync, mkdirSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { tronHomePath } from "../foundation/tron-home-layout.js";
import { resolveTronHome } from "../tron-home.js";

/**
 * Proof traffic recorder (tools/proof/README.md "Traffic corpus"): at a seam where a proof block will replace
 * TypeScript logic, `recordSeam` appends the exact typed inputs the TypeScript function received and the
 * output it returned, so `scripts/tron proof shadow <block> --days N` can replay them through the compiled
 * core offline. It never feeds anything back and never throws into its caller.
 *
 * It runs only on the Debug Gateway, only when `scripts/tron dev --proof-traffic` set TRON_PROOF_TRAFFIC=1:
 * any other channel (Stable, a Release build) ignores the variable, and the Stable home is refused outright.
 * Records go to <Debug home>/gateway/proof-traffic/<block>/<yyyy-mm-dd>.jsonl (UTC days), at most
 * DAILY_RECORD_CAP per block and day, keeping the newest RETAINED_DAYS days. Seams pass typed values only
 * (times, trigger shapes, policies); free text and identities are never recorded.
 */
export const TRAFFIC_SCHEMA = "tron-proof-traffic/1";
export const DAILY_RECORD_CAP = 20_000;
export const RETAINED_DAYS = 14;

export interface TrafficRecorder {
  record(block: string, seam: string, input: unknown, output: unknown): void;
}

/** The recorder this environment allows, or null (the default everywhere but an opted-in Debug Gateway). */
export function openTrafficRecorder(environment: NodeJS.ProcessEnv = process.env, now: () => number = Date.now): TrafficRecorder | null {
  if (environment.TRON_PROOF_TRAFFIC !== "1" || environment.TRON_GATEWAY_CHANNEL !== "dev") return null;
  const home = resolveTronHome(environment);
  if (home === resolve(homedir(), ".tron")) return null;
  return new FileTrafficRecorder(tronHomePath(home, "gateway/proof-traffic"), now);
}

class FileTrafficRecorder implements TrafficRecorder {
  private seq = 0;
  // Records already in today's file per block, read once per block and day so the cap holds across restarts.
  private readonly counts = new Map<string, { day: string; count: number }>();

  constructor(private readonly root: string, private readonly now: () => number) {}

  record(block: string, seam: string, input: unknown, output: unknown): void {
    try {
      const at = new Date(this.now()).toISOString();
      const day = at.slice(0, 10);
      const directory = join(this.root, ...block.split("/"));
      const file = join(directory, `${day}.jsonl`);
      let today = this.counts.get(block);
      if (!today || today.day !== day) {
        mkdirSync(directory, { recursive: true, mode: 0o700 });
        today = { day, count: lineCount(file) };
        this.counts.set(block, today);
        prune(directory);
      }
      if (today.count >= DAILY_RECORD_CAP) return;
      const line = JSON.stringify({ schema: TRAFFIC_SCHEMA, block, seam, seq: ++this.seq, at, input, output: output ?? null });
      appendFileSync(file, `${line}\n`, { mode: 0o600 });
      today.count++;
    } catch {
      // Recording is diagnostic: a full disk or a removed directory must not change scheduling.
    }
  }
}

function lineCount(file: string): number {
  try {
    return readFileSync(file, "utf8").split("\n").filter(Boolean).length;
  } catch {
    return 0;
  }
}

/** Keeps the newest RETAINED_DAYS day files of one block. */
function prune(directory: string): void {
  const days = readdirSync(directory).filter((name) => /^\d{4}-\d{2}-\d{2}\.jsonl$/.test(name)).sort();
  for (const name of days.slice(0, Math.max(0, days.length - RETAINED_DAYS))) rmSync(join(directory, name), { force: true });
}

let shared: TrafficRecorder | null | undefined;

/** Records one seam call through the process's recorder; a no-op unless the recorder is enabled. */
export function recordSeam(block: string, seam: string, input: unknown, output: unknown): void {
  if (shared === undefined) shared = openTrafficRecorder();
  shared?.record(block, seam, input, output);
}
