import { existsSync, mkdtempSync, readFileSync, rmSync, statSync, truncateSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { GatewayLogger } from "./logger.js";

const temporaryDirectories: string[] = [];

function logPath(): string {
  const directory = mkdtempSync(join(tmpdir(), "tron-logs-"));
  temporaryDirectories.push(directory);
  return join(directory, "gateway.jsonl");
}

function lines(path: string): Array<Record<string, unknown>> {
  return readFileSync(path, "utf8").trim().split("\n").filter(Boolean).map((line) => JSON.parse(line) as Record<string, unknown>);
}

beforeEach(() => {
  vi.spyOn(process.stdout, "write").mockImplementation(() => true);
  vi.spyOn(process.stderr, "write").mockImplementation(() => true);
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
  for (const directory of temporaryDirectories.splice(0)) rmSync(directory, { recursive: true, force: true });
});

describe("GatewayLogger", () => {
  it("stamps process identity and bounded correlation fields in the shared record format", () => {
    const path = logPath();
    const logger = new GatewayLogger(path, { runtimeEpoch: "epoch-1", payloadVersion: "1.2.3" });
    logger.log("warning", "RPC failed", { event: "rpc.error", method: "session.processTranscript.open",
      requestID: "request-7", sessionId: "session-1", connectionId: "connection-1", commandId: "command 1",
      code: "busy", reason: "viewer_capacity", outcome: "failure", durationMs: 1541.6 });
    expect(lines(path)[0]).toMatchObject({
      level: "warning", event: "rpc.error", process: "gateway", runtimeEpoch: "epoch-1", payloadVersion: "1.2.3",
      sessionId: "session-1", connectionId: "connection-1", commandId: "command_1", requestID: "request-7",
      code: "busy", reason: "viewer_capacity", outcome: "failure", durationMs: 1542,
    });
    expect(new GatewayLogger(path).recent(1)[0]).toMatchObject({ runtimeEpoch: "epoch-1", commandId: "command_1" });
  });

  it("persists workspace unavailability causes as bounded diagnostic fields", () => {
    const path = logPath();
    const logger = new GatewayLogger(path);
    logger.log("warning", "Tron internal workspace is unavailable", {
      event: "workspace.unavailable", source: "workspace", cause: "x".repeat(200),
    });

    expect(lines(path)[0]).toMatchObject({ event: "workspace.unavailable", source: "workspace", cause: "x".repeat(64) });
  });

  it("keeps the request span breakdown beside the request it explains", () => {
    const path = logPath();
    const logger = new GatewayLogger(path);
    const long = `${"catalog.walk=1234ms×2;".repeat(60)}frame.serialize=12ms/610KB`;
    logger.log("warning", "RPC session.open completed", {
      event: "rpc.completed", method: "session.open", durationMs: 1_500, stages: long, unaccountedMs: 12.4 });
    logger.log("warning", "RPC session.open completed", {
      event: "rpc.completed", method: "session.open", durationMs: 1_500,
      stages: "frame.serialize=12ms/610KB", unaccountedMs: -5 });

    const [truncated, separators] = lines(path) as Array<Record<string, unknown>>;
    // Bounded by bytes with its `=`, `;`, `×` and `/` separators intact, not
    // escaped into a diagnostic ID or cut at the 160-character field bound.
    expect(Buffer.byteLength(truncated!.stages as string, "utf8")).toBeLessThanOrEqual(1_024);
    expect(truncated!.stages).toMatch(/^catalog\.walk=1234ms×2;/u);
    expect(truncated!.stages).not.toContain("frame.serialize");
    expect(truncated!.unaccountedMs).toBe(12);
    expect(separators!.stages).toBe("frame.serialize=12ms/610KB");
    expect(separators!.unaccountedMs).toBe(0);
    // The restored persisted tail keeps both fields, since it is the same
    // normalization.
    const restored = new GatewayLogger(path).recent(2)[0]!;
    expect(restored.stages).toMatch(/^catalog\.walk=1234ms×2;/u);
    expect(restored.unaccountedMs).toBe(12);
  });

  it("persists the stage a cancellation interrupted, bounded like a diagnostic ID", () => {
    const path = logPath();
    const logger = new GatewayLogger(path);
    logger.log("warning", "RPC session.open was cancelled in catalog.walk after 1500ms", {
      event: "rpc.cancelled", method: "session.open", requestID: "open-1", outcome: "cancelled",
      stage: "catalog.walk", durationMs: 1_500 });
    logger.log("warning", "RPC session.open was cancelled", {
      event: "rpc.cancelled", stage: "x".repeat(200) });

    const [record, longStage] = lines(path) as Array<Record<string, unknown>>;
    expect(record!.stage).toBe("catalog.walk");
    expect((longStage!.stage as string)).toHaveLength(64);
    // The restored persisted tail keeps the field, since it is the same
    // normalization the writer applied.
    expect(new GatewayLogger(path).recent(2)[0]!.stage).toBe("catalog.walk");
  });

  it("persists the protocol version a refused hello asked for", () => {
    const path = logPath();
    const logger = new GatewayLogger(path);
    logger.log("warning", "Socket upgrade rejected at hello", {
      event: "http.upgrade", reason: "protocol_mismatch", peerProtocolVersion: 5 });
    logger.log("warning", "Socket upgrade rejected at hello", {
      event: "http.upgrade", reason: "protocol_mismatch", peerProtocolVersion: 5.5 });

    const [record, fractional] = lines(path) as Array<Record<string, unknown>>;
    expect(record!.peerProtocolVersion).toBe(5);
    // Only an integer is a protocol version; the writer keeps nothing else.
    expect(fractional).not.toHaveProperty("peerProtocolVersion");
    expect(new GatewayLogger(path).recent(2)[0]!.peerProtocolVersion).toBe(5);
  });

  it.each([["1", false], ["0", true]])("mirrors persisted records to process streams only when TRON_GATEWAY_SUPERVISED is %s", (supervised, mirrors) => {
    vi.stubEnv("TRON_GATEWAY_SUPERVISED", supervised);
    const path = logPath();
    const logger = new GatewayLogger(path);

    logger.log("info", "lifecycle", { event: "gateway.started" });
    logger.log("error", "fault", { event: "gateway.fault" });

    expect(lines(path).map((record) => record.event)).toEqual(["gateway.started", "gateway.fault"]);
    const mirrored = [process.stdout, process.stderr]
      .map((stream) => vi.mocked(stream.write).mock.calls.map(([chunk]) => String(chunk)).join(""))
      .join("");
    if (mirrors) {
      expect(mirrored).toContain("lifecycle");
      expect(mirrored).toContain("fault");
    } else {
      expect(mirrored).toBe("");
    }
  });

  it("sanitizes and bounds client-supplied correlation IDs", () => {
    const logger = new GatewayLogger();
    logger.log("warning", "RPC completed", { event: "rpc.completed", requestID: "id with spaces/".repeat(30) });
    const requestID = logger.recent(1)[0]?.requestID ?? "";
    expect(requestID).toMatch(/^[A-Za-z0-9._:-]+$/u);
    expect(requestID.length).toBe(160);
  });

  it("bounds the named counters one record carries", () => {
    const path = logPath();
    const longName = `n${"x".repeat(200)}`;
    const counts: Record<string, number> = {
      files: 12, unproven: -3, added: 1.6, huge: Number.MAX_SAFE_INTEGER + 10,
      "not a name": 1, "1leading": 2, missing: Number.NaN, infinite: Number.POSITIVE_INFINITY,
      [longName]: 4,
    };
    // A record that names more counters than the field holds keeps the ones it
    // accepted and drops the rest, rather than writing a payload.
    for (let index = 0; index < 20; index += 1) counts[`field${index}`] = index;
    const logger = new GatewayLogger(path);
    logger.log("warning", "Session catalog reconciled", { event: "catalog.reconciled", counts });

    // The persisted line and the restored tail are the same normalization.
    const persisted = lines(path)[0]!.counts as Record<string, number>;
    const restored = new GatewayLogger(path).recent(1)[0]!.counts as Record<string, number>;
    expect(restored).toEqual(persisted);
    expect(Object.keys(persisted)).toEqual([
      "files", "unproven", "added", "huge", `n${"x".repeat(31)}`,
      ...Array.from({ length: 11 }, (_, index) => `field${index}`),
    ]);
    expect(persisted).toMatchObject({ files: 12, unproven: 0, added: 2, huge: Number.MAX_SAFE_INTEGER });
  });

  it("keeps a bounded lifecycle step name across restart", () => {
    const path = logPath();
    new GatewayLogger(path).log("info", "Gateway startup step session-registry took 8 ms", {
      event: "gateway.startup-step", step: "session-registry", durationMs: 8.4,
    });
    expect(new GatewayLogger(path).recent(1)[0]).toMatchObject({ event: "gateway.startup-step", step: "session-registry", durationMs: 8 });
    const logger = new GatewayLogger();
    logger.log("info", "step", { step: `bad step/${"x".repeat(100)}` });
    expect(logger.recent(1)[0]?.step).toMatch(/^bad_step_x+$/u);
    expect(logger.recent(1)[0]?.step?.length).toBe(64);
  });

  it("records a bounded, redacted structured error with one level of cause", () => {
    const path = logPath();
    const logger = new GatewayLogger(path);
    const error = Object.assign(new Error(`outer password=abc ${"x".repeat(5_000)}`, { cause: new Error("root", { cause: new Error("hidden") }) }), { code: "EFAIL" });
    logger.log("error", "Unexpected fault", { event: "rpc.error", error });
    const record = lines(path)[0]!;
    const logged = record.error as { name: string; code: string; message: string; stack: string; cause: { message: string; cause?: unknown } };
    expect(logged.name).toBe("Error");
    expect(logged.code).toBe("EFAIL");
    expect(logged.message).not.toContain("abc");
    expect(Buffer.byteLength(logged.message)).toBeLessThanOrEqual(1_000);
    expect(Buffer.byteLength(logged.stack)).toBeLessThanOrEqual(4_000);
    expect(logged.cause.message).toBe("root");
    expect(logged.cause.cause).toBeUndefined();
  });

  it("re-bounds and redacts a structured error restored from a persisted line", () => {
    const path = logPath();
    const oversized = { name: "Error", code: "EFAIL", message: `password=abc ${"m".repeat(5_000)}`, stack: "s".repeat(9_000),
      cause: { name: "Error", message: "root", cause: { name: "Error", message: "hidden" } } };
    writeFileSync(path, `${JSON.stringify({ timestamp: "2026-09-24T00:00:00.000Z", level: "error", message: "fault", error: oversized })}\n`);
    const restored = new GatewayLogger(path).recent(1)[0]?.error;
    expect(restored?.message).not.toContain("abc");
    expect(Buffer.byteLength(restored?.message ?? "")).toBeLessThanOrEqual(1_000);
    expect(Buffer.byteLength(restored?.stack ?? "")).toBeLessThanOrEqual(4_000);
    expect(restored?.cause?.message).toBe("root");
    expect(restored?.cause?.cause).toBeUndefined();
  });

  it("keeps debug records out of the file and client tail but available to exports", () => {
    vi.stubEnv("TRON_GATEWAY_SUPERVISED", "0");
    const path = logPath();
    const logger = new GatewayLogger(path);
    logger.log("debug", "fast RPC", { event: "rpc.completed" });
    logger.log("info", "opened", { event: "connection.opened" });
    expect(lines(path).map((record) => record.event)).toEqual(["connection.opened"]);
    expect(logger.recent().map((record) => record.event)).toEqual(["connection.opened"]);
    expect(logger.debugTail().map((record) => record.event)).toEqual(["rpc.completed"]);
    const mirrored = vi.mocked(process.stdout.write).mock.calls.map(([chunk]) => String(chunk)).join("");
    expect(mirrored).toContain("opened");
    expect(mirrored).not.toContain("fast RPC");
  });

  it("bounds the debug buffer by count and bytes, evicting the oldest", () => {
    const logger = new GatewayLogger();
    for (let index = 0; index < 5_000; index += 1) logger.log("debug", `record-${index}`);
    const tail = logger.debugTail();
    expect(tail.length).toBe(4_000);
    expect(tail.at(-1)?.message).toBe("record-4999");
    for (let index = 0; index < 1_500; index += 1) logger.log("debug", `${index}-${"y".repeat(1_900)}`);
    const bytes = logger.debugTail().reduce((total, record) => total + Buffer.byteLength(JSON.stringify(record)), 0);
    expect(bytes).toBeLessThanOrEqual(2 * 1_024 * 1_024);
    expect(logger.debugTail().at(-1)?.message).toMatch(/^1499-/u);
  });

  it("rotates across eight 5 MB segments within the 40 MB budget", () => {
    const path = logPath();
    const segmentBytes = 5 * 1_024 * 1_024;
    // Pre-fill sparse segments to the rotation boundary: this exercises the
    // same on-disk capacity transition without spending thousands of logger
    // calls to manufacture 40 MB of fixture data under parallel suite load.
    writeFileSync(`${path}.7`, "record-0-oldest\n");
    truncateSync(`${path}.7`, segmentBytes);
    for (let index = 1; index < 7; index += 1) {
      writeFileSync(`${path}.${index}`, "");
      truncateSync(`${path}.${index}`, segmentBytes);
    }
    writeFileSync(path, "active-segment-prefill\n");
    const activePrefillBytes = segmentBytes - 4 * 1_024;
    truncateSync(path, activePrefillBytes);
    const logger = new GatewayLogger(path);
    for (let index = 0; index < 4; index += 1) {
      logger.log("info", `boundary-record-${index}-${"x".repeat(1_900)}`);
    }
    const segments = [path, ...Array.from({ length: 7 }, (_, index) => `${path}.${index + 1}`)];
    expect(segments.every((segment) => existsSync(segment))).toBe(true);
    expect(existsSync(`${path}.8`)).toBe(false);
    const total = segments.reduce((sum, segment) => sum + statSync(segment).size, 0);
    for (const segment of segments) expect(statSync(segment).size).toBeLessThanOrEqual(segmentBytes);
    expect(total).toBeLessThanOrEqual(8 * segmentBytes);
    expect(readFileSync(`${path}.7`, "utf8")).not.toContain("record-0-");
    const previous = readFileSync(`${path}.1`, "utf8");
    expect(previous).toContain("boundary-record-0-");
    expect(previous).toContain("boundary-record-1-");
    expect(previous).not.toContain("boundary-record-2-");
    expect(previous).not.toContain("boundary-record-3-");
    expect(lines(path).at(-1)?.message).toMatch(/^boundary-record-3-/u);
  });

  it("restores the client tail from the newest segments after restart", () => {
    const path = logPath();
    writeFileSync(`${path}.1`, `${JSON.stringify({ timestamp: "t1", level: "info", message: "older" })}\n`);
    writeFileSync(path, [
      JSON.stringify({ timestamp: "t2", level: "debug", message: "never persisted" }),
      JSON.stringify({ timestamp: "t3", level: "warning", message: "newer" }),
      "{partial",
    ].join("\n"));
    expect(new GatewayLogger(path).recent().map((record) => record.message)).toEqual(["older", "newer"]);
  });

  it("redacts secrets before retaining or persisting records", () => {
    const path = logPath();
    const logger = new GatewayLogger(path);
    logger.log("error", "authorization: Bearer secret-value api_key=another-secret", { event: "auth.failed", source: "transport" });
    const record = logger.recent(1)[0];
    expect(record?.message).toContain("[REDACTED]");
    expect(readFileSync(path, "utf8")).not.toContain("secret-value");
    expect(new GatewayLogger(path).recent(1)[0]).toMatchObject({ event: "auth.failed", source: "transport" });
  });
});
