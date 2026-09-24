import { existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
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

  it("keeps debug records out of the file and client tail but available to exports", () => {
    const path = logPath();
    const logger = new GatewayLogger(path);
    logger.log("debug", "fast RPC", { event: "rpc.completed" });
    logger.log("info", "opened", { event: "connection.opened" });
    expect(lines(path).map((record) => record.event)).toEqual(["connection.opened"]);
    expect(logger.recent().map((record) => record.event)).toEqual(["connection.opened"]);
    expect(logger.debugTail().map((record) => record.event)).toEqual(["rpc.completed"]);
    expect(process.stdout.write).toHaveBeenCalledTimes(1);
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
    const logger = new GatewayLogger(path);
    // ~2 KB per record; 24,000 records is ~48 MB, forcing the oldest segment out.
    for (let index = 0; index < 24_000; index += 1) logger.log("info", `record-${index}-${"x".repeat(1_900)}`);
    const segments = [path, ...Array.from({ length: 7 }, (_, index) => `${path}.${index + 1}`)];
    expect(segments.every((segment) => existsSync(segment))).toBe(true);
    expect(existsSync(`${path}.8`)).toBe(false);
    const total = segments.reduce((sum, segment) => sum + statSync(segment).size, 0);
    for (const segment of segments) expect(statSync(segment).size).toBeLessThanOrEqual(5 * 1_024 * 1_024);
    expect(total).toBeLessThanOrEqual(40 * 1_024 * 1_024);
    expect(readFileSync(`${path}.7`, "utf8")).not.toContain("record-0-");
    expect(lines(path).at(-1)?.message).toMatch(/^record-23999-/u);
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
