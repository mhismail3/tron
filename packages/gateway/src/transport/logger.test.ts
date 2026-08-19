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
