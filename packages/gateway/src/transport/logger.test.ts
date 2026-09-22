import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { GatewayLogger } from "./logger.js";

const temporaryDirectories: string[] = [];

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) rmSync(directory, { recursive: true, force: true });
});

describe("GatewayLogger", () => {
  it("retains safe RPC correlation and distinct admission reasons across restart", () => {
    const directory = mkdtempSync(join(tmpdir(), "tron-logs-"));
    temporaryDirectories.push(directory);
    const path = join(directory, "gateway.jsonl");
    const logger = new GatewayLogger(path);
    logger.log("error", "RPC failed", { event: "rpc.error", method: "session.processTranscript.open",
      requestID: "request-7", code: "busy", reason: "viewer_capacity", outcome: "failure", durationMs: 1542 });
    expect(new GatewayLogger(path).recent(1)[0]).toMatchObject({ method: "session.processTranscript.open",
      requestID: "request-7", code: "busy", reason: "viewer_capacity", outcome: "failure", durationMs: 1542 });
  });

  it("retains bounded structured request attribution without logging payloads", () => {
    const logger = new GatewayLogger();
    logger.log("warning", "RPC session.list completed", {
      event: "rpc.completed", source: "transport", requestID: "id with spaces/".repeat(30),
      method: "session.list", outcome: "timeout", code: "timeout", durationMs: 12_345.6,
    });

    const record = logger.recent(1)[0];
    expect(record).toMatchObject({
      event: "rpc.completed", source: "transport", method: "session.list",
      outcome: "timeout", code: "timeout", durationMs: 12_346,
    });
    expect(record?.requestID).toMatch(/^[A-Za-z0-9._:/-]+$/u);
    expect(record?.requestID?.length).toBeLessThanOrEqual(160);
    expect(record?.message).not.toContain("id with spaces");
  });

  it("redacts secrets before retaining or persisting records", () => {
    const directory = mkdtempSync(join(tmpdir(), "tron-logger-"));
    temporaryDirectories.push(directory);
    const path = join(directory, "gateway.jsonl");
    const logger = new GatewayLogger(path);
    logger.log("error", "authorization: Bearer secret-value api_key=another-secret", { event: "auth.failed", source: "transport" });

    const record = logger.recent(1)[0];
    expect(record?.message).toContain("[REDACTED]");
    expect(record?.message).not.toContain("secret-value");
    expect(record?.event).toBe("auth.failed");
    expect(new GatewayLogger(path).recent(1)[0]).toMatchObject({ event: "auth.failed", source: "transport" });
  });
});
