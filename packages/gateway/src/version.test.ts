import { describe, expect, it } from "vitest";
import { GatewayService, type GatewayServiceDependencies } from "./transport/gateway-service.js";
import { GATEWAY_VERSION, MIN_PROTOCOL_VERSION, PI_VERSION, PROTOCOL_VERSION } from "./version.js";

describe("Gateway runtime identity", () => {
  it("publishes the client-visible version and protocol contract", () => {
    const service = new GatewayService({
      config: { machineId: "machine", machineName: "Mac", tronHome: "/tmp/tron-runtime-identity" },
      sessions: {},
    } as unknown as GatewayServiceDependencies);
    expect(service.info()).toMatchObject({
      gatewayVersion: GATEWAY_VERSION,
      piVersion: PI_VERSION,
      protocolVersion: PROTOCOL_VERSION,
      minProtocolVersion: MIN_PROTOCOL_VERSION,
    });
  });
});
