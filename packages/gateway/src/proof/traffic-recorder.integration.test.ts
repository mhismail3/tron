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

const corpus = (dataDir: string, block: string): Array<Record<string, unknown>> => {
  const dir = join(dataDir, "gateway/proof-traffic", block);
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
    const zones = ["UTC", "America/New_York", "Australia/Lord_Howe"];
    for (let i = 0; i < 200; i++) {
      const anchor = base + Math.floor(rnd() * 1e9);
      const kind = rnd();
      const trigger = kind < 0.25 ? { kind: "once" as const, at: new Date(anchor).toISOString() }
        : kind < 0.75 ? { kind: "interval" as const, anchorAt: new Date(anchor).toISOString(), everySeconds: [60, 3600, 86400][Math.floor(rnd() * 3)]! }
        : { kind: "calendar" as const, timezone: zones[Math.floor(rnd() * 3)]!, localTime: `0${Math.floor(rnd() * 10)}:${10 + Math.floor(rnd() * 50)}`,
          weekdays: [1, 2, 3, 4, 5, 6, 7].filter((day) => day === 3 || rnd() < 0.3) };
      const now = anchor + Math.floor((rnd() - 0.3) * 1e8);
      calls.push(["next", [trigger, now]], ["first", [trigger, now]],
        ["classify", [trigger, recorded.firstAutomationOccurrence(trigger, anchor - 1)!, now, rnd() < 0.5 ? "latest" : "skip"]]);
    }
    const run = (m: typeof recorded, [seam, args]: [string, unknown[]]): unknown => {
      if (seam === "next") return m.nextAutomationOccurrence(args[0] as never, args[1] as number);
      if (seam === "first") return m.firstAutomationOccurrence(args[0] as never, args[1] as number);
      return m.classifyDueOccurrence(args[0] as never, args[1] as string, args[2] as number, args[3] as never);
    };
    const outputs = calls.map((call) => run(recorded, call));

    // One record per seam call (the 200 helper first() calls above included) and none for a nested internal
    // call; once and interval triggers go to block schedule/occurrence, calendar triggers to schedule/calendar.
    const records = [...corpus(dataDir, "schedule/occurrence"), ...corpus(dataDir, "schedule/calendar")]
      .sort((left, right) => (left.seq as number) - (right.seq as number));
    expect(records).toHaveLength(calls.length + 200);
    expect(new Set(records.map((r) => r.schema))).toEqual(new Set([TRAFFIC_SCHEMA]));
    expect(records.map((r) => r.seq)).toEqual(records.map((_, i) => i + 1));
    expect(records.every((r) => ["next", "first", "classify"].includes(r.seam as string))).toBe(true);
    for (const record of records) {
      const kind = ((record.input as Record<string, unknown>).trigger as { kind: string }).kind;
      expect(record.block).toBe(kind === "calendar" ? "schedule/calendar" : "schedule/occurrence");
    }
    expect(records.filter((r) => r.block === "schedule/calendar").length).toBeGreaterThan(100);

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

  it("records the settings precedence fold of every resolved key, with tokens instead of values", async () => {
    const dataDir = home();
    vi.stubEnv("TRON_PROOF_TRAFFIC", "1");
    vi.stubEnv("TRON_GATEWAY_CHANNEL", "dev");
    vi.stubEnv("TRON_DATA_DIR", dataDir);
    vi.resetModules();
    const { resolveSettings, targetLayers } = await import("../kernel/settings/settings-resolver.js");
    const { scopeForStore } = await import("../kernel/settings/scope-resolution.js");
    const { TEST_SETTINGS_SCHEMA } = await import("../../test-support/settings-schema.js");
    const target = { kind: "session" as const, sessionId: "s" };
    // An untrusted project whose per-model thinking value would beat the chat's own value.
    const resolution = resolveSettings(TEST_SETTINGS_SCHEMA, target, {
      layers: targetLayers(target, { project: true }), gateway: {}, trust: {}, macTerminal: {},
      global: { defaultProvider: "anthropic", defaultModel: "sentinel-model-id", defaultThinkingLevel: "low" },
      project: { root: "/sentinel-project", document: { modelThinkingLevels: { "anthropic/sentinel-model-id": "high" } }, applied: false },
      session: { thinking: "minimal", settings: {} },
    }, { format: { modelName: () => undefined }, options: { clamp: (_source, _dependency, value) => value } });

    const records = corpus(dataDir, "settings/precedence");
    expect(records.every((r) => r.schema === TRAFFIC_SCHEMA && r.block === "settings/precedence" && r.seam === "resolve")).toBe(true);
    // Exactly one record per resolved key instance, in resolution order, after the chat model's own resolution
    // (which the model-qualified keys read), each with the fold's layer and not-applied layer.
    expect(records.map((r) => (r.input as { key: string }).key)).toEqual(["model.ref[role=chat]", ...resolution.keys.map((row) => row.key)]);
    for (const [index, row] of resolution.keys.entries()) {
      const output = records[index + 1]!.output as { layer: string; notApplied: string | null };
      expect(scopeForStore(output.layer as never)).toBe(row.layer);
      expect(output.notApplied === null).toBe(row.applied);
    }
    const thinking = records.find((r) => (r.input as { key: string }).key === "model.thinking[role=chat]")!;
    expect(thinking.output).toMatchObject({ layer: "session", notApplied: "project" });
    // No setting value, model id or project path is recorded: values are tokens.
    const text = JSON.stringify(records);
    for (const secret of ["sentinel", "minimal", "high", "anthropic"]) expect(text).not.toContain(secret);
  });

  it("records tool selection compose and encode calls with tool names as tokens", async () => {
    const dataDir = home();
    vi.stubEnv("TRON_PROOF_TRAFFIC", "1");
    vi.stubEnv("TRON_GATEWAY_CHANNEL", "dev");
    vi.stubEnv("TRON_DATA_DIR", dataDir);
    vi.resetModules();
    const { toolSelectionType } = await import("../kernel/settings/settings-types.js");
    const { resolveSettings, targetLayers } = await import("../kernel/settings/settings-resolver.js");
    const { TEST_SETTINGS_SCHEMA } = await import("../../test-support/settings-schema.js");
    const type = toolSelectionType();
    const below = ["read", "bash", "sentinel_alpha"];
    const composed = [
      type.compose!(below, ["+sentinel_beta", "-bash"]), type.compose!(undefined, ["-read"]), type.compose!(below, ["sentinel_gamma", "+read"]),
    ];
    const encoded = [
      type.encode!(["sentinel_alpha", "read", "sentinel_beta"], below, undefined), type.encode!(["read", "bash"], below, ["sentinel_gamma"]),
      type.encode!(["+web"], below, []),
    ];
    // Outside the block's domain (a non-string below): the selection is unchanged and nothing is recorded.
    expect(type.compose!(["read", 5], ["+web"])).toEqual(["read", 5, "web"]);
    expect(type.encode!(["read"], below, ["bash", 7])).toEqual(["read"]);
    const selection = corpus(dataDir, "settings/tool-selection");
    expect(selection.map((r) => r.seam)).toEqual(["compose", "compose", "compose", "encode", "encode", "encode"]);
    expect(selection.every((r) => r.schema === TRAFFIC_SCHEMA && r.block === "settings/tool-selection")).toBe(true);
    // Tokens follow first appearance in the call: the empty name 0, the selection below first, then the entries
    // (or the chosen list and the current entries), then the defaults.
    expect(selection[0]!.input).toEqual({ below: [1, 2, 3], entries: [{ kind: "plus", name: 4 }, { kind: "minus", name: 2 }], defaults: [1, 2, 5, 6] });
    expect(selection[0]!.output).toEqual([1, 3, 4]);
    expect(selection[1]!.input).toEqual({ below: null, entries: [{ kind: "minus", name: 1 }], defaults: [1, 2, 3, 4] });
    expect(selection[1]!.output).toEqual([2, 3, 4]);
    expect(selection[3]!.input).toEqual({ chosen: [{ kind: "plain", name: 3 }, { kind: "plain", name: 1 }, { kind: "plain", name: 4 }],
      below: [1, 2, 3], current: [], defaults: [1, 2, 5, 6] });
    expect(selection[3]!.output).toEqual([{ kind: "plain", name: 3 }, { kind: "plain", name: 1 }, { kind: "plain", name: 4 }]);
    expect(selection[4]!.input).toEqual({ chosen: [{ kind: "plain", name: 1 }, { kind: "plain", name: 2 }], below: [1, 2, 3],
      current: [{ kind: "plain", name: 4 }], defaults: [1, 2, 5, 6] });
    expect(composed[0]).toEqual(["read", "sentinel_alpha", "sentinel_beta"]);
    expect(selection[4]!.output).toEqual([{ kind: "plain", name: 1 }, { kind: "plain", name: 2 }]);
    expect(encoded[1]).toEqual(["read", "bash"]);
    expect(selection[5]!.output).toEqual([{ kind: "plus", name: 4 }]);
    expect(JSON.stringify(selection)).not.toContain("sentinel");

    // A real resolution composes the chat's tools through the same seam.
    const target = { kind: "session" as const, sessionId: "s" };
    resolveSettings(TEST_SETTINGS_SCHEMA, target, { layers: targetLayers(target, { project: false }), gateway: {}, trust: {}, macTerminal: {},
      global: { defaultTools: ["read", "bash"] }, session: { tools: ["+web"], settings: {} } },
    { format: { modelName: () => undefined }, options: { clamp: (_source, _dependency, value) => value } });
    const resolved = corpus(dataDir, "settings/tool-selection").slice(selection.length);
    expect(resolved.length).toBeGreaterThan(0);
    expect(resolved.some((r) => r.seam === "compose" && JSON.stringify(r.input).includes("plus"))).toBe(true);
    expect(JSON.stringify(resolved)).not.toMatch(/"(read|bash|edit|write|web)"/);
  });

  it("records invocation receipt folds with identities as tokens, refusals included, bounded and once each", async () => {
    const dataDir = home();
    vi.stubEnv("TRON_PROOF_TRAFFIC", "1");
    vi.stubEnv("TRON_GATEWAY_CHANNEL", "dev");
    vi.stubEnv("TRON_DATA_DIR", dataDir);
    vi.resetModules();
    const { invocationProjection, makeInvocationReceipt } = await import("../kernel/receipts/invocation-receipts.js");
    let n = 0;
    const at = (second: number) => new Date(Date.parse("2026-11-09T12:00:00.000Z") + second * 1_000).toISOString();
    const receipt = (invocationId: string, fields: Record<string, unknown>) => makeInvocationReceipt({
      receiptId: `sentinel-receipt-${n++}`, version: 1, invocationId, operationId: `sentinel-op-${invocationId}`, sessionId: "sentinel-session",
      source: "plain", sequence: 1, createdAt: at(n), ...fields } as never);
    const start = (id: string) => receipt(id, { receiptKind: "start", lifecycle: "staged", origin: { kind: "user", confidence: "receipt", title: "sentinel title" } });
    const history = [start("sentinel-a"), receipt("sentinel-a", { receiptKind: "transition", lifecycle: "running" }), start("sentinel-b"),
      receipt("sentinel-a", { receiptKind: "terminal", lifecycle: "completed", retryable: false }),
      receipt("sentinel-a", { receiptKind: "binding", canonicalEntryId: "sentinel-entry" })];
    const projected = invocationProjection(history);
    expect(invocationProjection(history)).toEqual(projected);
    const contradictory = [...history, receipt("sentinel-a", { receiptKind: "terminal", lifecycle: "failed" })];
    expect(() => invocationProjection(contradictory)).toThrow("contradictory terminal invocation receipt");
    // Above the bound a history is projected as before but not recorded.
    const long = [start("sentinel-c"), ...Array.from({ length: 64 }, () => receipt("sentinel-c", { receiptKind: "transition", lifecycle: "running" }))];
    expect(() => invocationProjection(long)).toThrow("illegal invocation transition");

    const records = corpus(dataDir, "receipts/invocation-lifecycle");
    // The repeated history is recorded once; the refusal is recorded with its reason.
    expect(records).toHaveLength(2);
    expect(records.every((r) => r.schema === TRAFFIC_SCHEMA && r.seam === "project")).toBe(true);
    expect(records[0]!.input).toEqual([
      { inv: 0, op: 1, src: "plain", kind: "start", life: "staged", name: null, origin: 0, entry: null, retryable: null, sequence: 1, at: 0 },
      { inv: 0, op: 1, src: "plain", kind: "transition", life: "running", name: null, origin: null, entry: null, retryable: null, sequence: 1, at: 1 },
      { inv: 2, op: 3, src: "plain", kind: "start", life: "staged", name: null, origin: 0, entry: null, retryable: null, sequence: 1, at: 2 },
      { inv: 0, op: 1, src: "plain", kind: "terminal", life: "completed", name: null, origin: null, entry: null, retryable: false, sequence: 1, at: 3 },
      { inv: 0, op: 1, src: "plain", kind: "binding", life: null, name: null, origin: null, entry: 0, retryable: null, sequence: 1, at: 4 },
    ]);
    expect(records[0]!.output).toEqual({ projections: [
      { inv: 0, op: 1, src: "plain", name: null, origin: 0, life: "completed", entry: 0, retryable: false, sequence: 1, updated: 4 },
      { inv: 2, op: 3, src: "plain", name: null, origin: 0, life: "staged", entry: null, retryable: null, sequence: 1, updated: 2 },
    ] });
    expect(projected.map((p) => [p.invocationId, p.lifecycle, p.canonicalEntryId])).toEqual([["sentinel-a", "completed", "sentinel-entry"], ["sentinel-b", "staged", undefined]]);
    expect(records[1]!.output).toEqual({ refused: "ContradictoryTerminal" });
    expect(JSON.stringify(records)).not.toContain("sentinel");
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
