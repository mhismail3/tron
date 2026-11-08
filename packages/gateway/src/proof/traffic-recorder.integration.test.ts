import { mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { DAILY_RECORD_CAP, RETAINED_DAYS, TRAFFIC_SCHEMA, openTrafficRecorder } from "./traffic-recorder.js";

/**
 * The Debug-only proof traffic recorder (tools/proof/README.md "Traffic corpus"): refused everywhere but an
 * opted-in Debug Gateway; a seeded schedule journey through the real seams writes a corpus that replays
 * through the same TypeScript to the recorded outputs; the daily cap and retention hold.
 */
const homes: string[] = [];
const home = (): string => { const dir = mkdtempSync(join(tmpdir(), "tron-proof-traffic-")); homes.push(dir); return dir; };
afterEach(() => {
  vi.unstubAllEnvs();
  vi.resetModules();
  for (const dir of homes.splice(0)) rmSync(dir, { recursive: true, force: true });
});

const corpus = (dataDir: string): Array<Record<string, unknown>> => {
  const dir = join(dataDir, "gateway/proof-traffic/schedule/occurrence");
  return readdirSync(dir).sort().flatMap((name) => readFileSync(join(dir, name), "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line)));
};

describe("proof traffic recorder", () => {
  it("is refused outside an opted-in Debug Gateway", () => {
    const dataDir = home();
    const debug = { TRON_PROOF_TRAFFIC: "1", TRON_GATEWAY_CHANNEL: "dev", TRON_DATA_DIR: dataDir };
    expect(openTrafficRecorder({ ...debug, TRON_GATEWAY_CHANNEL: "stable" })).toBeNull();
    expect(openTrafficRecorder({ TRON_PROOF_TRAFFIC: "1", TRON_DATA_DIR: dataDir })).toBeNull();
    expect(openTrafficRecorder({ TRON_GATEWAY_CHANNEL: "dev", TRON_DATA_DIR: dataDir })).toBeNull();
    expect(openTrafficRecorder({ ...debug, TRON_PROOF_TRAFFIC: "true" })).toBeNull();
    expect(openTrafficRecorder({ ...debug, TRON_DATA_DIR: join(homedir(), ".tron") })).toBeNull();
    expect(openTrafficRecorder({ TRON_PROOF_TRAFFIC: "1", TRON_GATEWAY_CHANNEL: "dev", TRON_HOME_NAME: ".tron" })).toBeNull();
    // Inside the Stable home by a subdirectory or a symlink, or a home that does not resolve: refused, never thrown.
    expect(openTrafficRecorder({ ...debug, TRON_DATA_DIR: join(homedir(), ".tron", "proof-scratch") })).toBeNull();
    const link = join(home(), "stable-link");
    symlinkSync(join(homedir(), ".tron"), link);
    expect(openTrafficRecorder({ ...debug, TRON_DATA_DIR: link })).toBeNull();
    expect(openTrafficRecorder({ ...debug, TRON_DATA_DIR: join(link, "nested") })).toBeNull();
    expect(openTrafficRecorder({ ...debug, TRON_DATA_DIR: "relative/home" })).toBeNull();
    expect(openTrafficRecorder(debug)).not.toBeNull();
  });

  it("records a seeded schedule journey that replays to the recorded outputs", async () => {
    const dataDir = home();
    vi.stubEnv("TRON_PROOF_TRAFFIC", "1");
    vi.stubEnv("TRON_GATEWAY_CHANNEL", "dev");
    vi.stubEnv("TRON_DATA_DIR", dataDir);
    vi.resetModules();
    const recorded = await import("../automations/schedule.js");
    let seed = 5;
    const rnd = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
    const base = Date.parse("2026-11-01T00:00:00.000Z");
    const calls: Array<[string, unknown[]]> = [];
    for (let i = 0; i < 200; i++) {
      const anchor = base + Math.floor(rnd() * 1e9);
      const trigger = rnd() < 0.3 ? { kind: "once" as const, at: new Date(anchor).toISOString() }
        : { kind: "interval" as const, anchorAt: new Date(anchor).toISOString(), everySeconds: [60, 3600, 86400][Math.floor(rnd() * 3)]! };
      const now = anchor + Math.floor((rnd() - 0.3) * 1e8);
      calls.push(["next", [trigger, now]], ["first", [trigger, now]],
        ["classify", [trigger, recorded.firstAutomationOccurrence(trigger, anchor - 1)!, now, rnd() < 0.5 ? "latest" : "skip"]]);
    }
    const calendar = { kind: "calendar" as const, timezone: "UTC", localTime: "09:00", weekdays: [1, 2, 3, 4, 5, 6, 7] };
    const run = (m: typeof recorded, [seam, args]: [string, unknown[]]): unknown => {
      if (seam === "next") return m.nextAutomationOccurrence(args[0] as never, args[1] as number);
      if (seam === "first") return m.firstAutomationOccurrence(args[0] as never, args[1] as number);
      return m.classifyDueOccurrence(args[0] as never, args[1] as string, args[2] as number, args[3] as never);
    };
    const outputs = calls.map((call) => run(recorded, call));
    recorded.nextAutomationOccurrence(calendar as never, base);

    const records = corpus(dataDir);
    // One record per seam call (the 200 helper first() calls above included), none for the calendar trigger
    // and none for first()'s nested next().
    expect(records).toHaveLength(calls.length + 200);
    expect(new Set(records.map((r) => r.schema))).toEqual(new Set([TRAFFIC_SCHEMA]));
    expect(records.map((r) => r.seq)).toEqual(records.map((_, i) => i + 1));
    expect(records.every((r) => r.block === "schedule/occurrence" && ["next", "first", "classify"].includes(r.seam as string))).toBe(true);

    // Replay: the same TypeScript, recorder off, gives every recorded output back.
    vi.unstubAllEnvs();
    vi.resetModules();
    const plain = await import("../automations/schedule.js");
    for (const record of records) {
      const input = record.input as Record<string, unknown>;
      const args = record.seam === "next" ? [input.trigger, input.afterMs] : record.seam === "first" ? [input.trigger, input.nowMs]
        : [input.trigger, input.nextOccurrenceAt, input.nowMs, input.policy];
      expect(JSON.parse(JSON.stringify(run(plain, [record.seam as string, args]) ?? null))).toEqual(record.output);
    }
    const journey = records.slice(200);
    expect(journey.map((r) => r.output)).toEqual(outputs.map((o) => JSON.parse(JSON.stringify(o ?? null))));
  });

  it("keeps at most the daily cap per block and the newest retained days", () => {
    const dataDir = home();
    const dir = join(dataDir, "gateway/proof-traffic/schedule/occurrence");
    mkdirSync(dir, { recursive: true });
    for (let day = 1; day <= RETAINED_DAYS + 2; day++) writeFileSync(join(dir, `2026-10-${String(day).padStart(2, "0")}.jsonl`), "{}\n");
    writeFileSync(join(dir, "2026-11-08.jsonl"), "{}\n".repeat(DAILY_RECORD_CAP - 1));
    const recorder = openTrafficRecorder({ TRON_PROOF_TRAFFIC: "1", TRON_GATEWAY_CHANNEL: "dev", TRON_DATA_DIR: dataDir }, () => Date.parse("2026-11-08T12:00:00Z"))!;
    recorder.record("schedule/occurrence", "next", { afterMs: 1 }, null);
    recorder.record("schedule/occurrence", "next", { afterMs: 2 }, null);
    expect(readFileSync(join(dir, "2026-11-08.jsonl"), "utf8").split("\n").filter(Boolean)).toHaveLength(DAILY_RECORD_CAP);
    const days = readdirSync(dir).sort();
    expect(days).toHaveLength(RETAINED_DAYS);
    expect(days.at(-1)).toBe("2026-11-08.jsonl");
    expect(days[0]).toBe("2026-10-04.jsonl");
  });
});
