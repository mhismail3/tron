import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it, vi } from "vitest";

vi.mock("./gateway-main.js", () => {
  throw Object.assign(
    new Error("Cannot find module '/payload/protocol-fixtures/contract.json' imported from /payload/app/dist/transport/connection-policy.js"),
    { code: "ERR_MODULE_NOT_FOUND" },
  );
});

let home: string | undefined;
afterEach(async () => {
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
  if (home) await rm(home, { recursive: true, force: true });
});

// Regression: a candidate payload once crashed while loading its module graph
// and left no trace, so the deploy could only report a generic identity timeout.
it("records one fatal-startup cause when the Gateway fails to load", async () => {
  home = await mkdtemp(join(tmpdir(), "tron-fatal-startup-"));
  vi.stubEnv("TRON_DATA_DIR", home);
  vi.stubEnv("TRON_GATEWAY_PAYLOAD_ROOT", "/payload");
  vi.stubEnv("TRON_GATEWAY_RUNTIME_EPOCH", "epoch-1");
  vi.stubEnv("TRON_GATEWAY_PAYLOAD_VERSION", "version-1");
  const exit = vi.spyOn(process, "exit").mockImplementation(() => undefined as never);
  vi.spyOn(process.stderr, "write").mockImplementation(() => true);

  await import("./index.js");

  expect(exit).toHaveBeenCalledWith(1);
  const lines = (await readFile(join(home, "logs", "gateway.jsonl"), "utf8")).trim().split("\n");
  expect(lines).toHaveLength(1);
  const record = JSON.parse(lines[0]!);
  expect(record).toMatchObject({
    level: "error",
    event: "gateway.fatal-startup",
    runtimeEpoch: "epoch-1",
    payloadVersion: "version-1",
  });
  // The test runner wraps the thrown error; the recorded cause keeps the root
  // reason with the payload prefix shortened rather than redacted away.
  const root = record.error.cause ?? record.error;
  expect(root.code).toBe("ERR_MODULE_NOT_FOUND");
  expect(root.message).toContain("<payload>/protocol-fixtures/contract.json");
});
