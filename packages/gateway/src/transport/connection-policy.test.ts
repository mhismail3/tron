import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { GATEWAY_CONNECTION_POLICY } from "./connection-policy.js";

describe("Gateway connection contract", () => {
  it("matches shared heartbeat, hello, and socket admission values", () => {
    const contract = JSON.parse(readFileSync(new URL("../../../protocol-fixtures/gateway-connection-contract.json", import.meta.url), "utf8"));
    expect(GATEWAY_CONNECTION_POLICY).toEqual({
      heartbeatIntervalMs: contract.serverHeartbeatInterval.milliseconds,
      missedHeartbeatLimit: contract.serverMissedHeartbeatLimit.count,
      helloDeadlineMs: contract.serverHelloDeadline.milliseconds,
      perIdentitySocketCap: contract.perIdentitySocketCap.count,
    });
  });
});
