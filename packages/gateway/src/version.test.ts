import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { GatewayService, type GatewayServiceDependencies } from "./transport/gateway-service.js";
import { GATEWAY_VERSION, MIN_PROTOCOL_VERSION, PI_VERSION, PROTOCOL_VERSION } from "./version.js";
import { PINNED_PI_VERSION } from "./extensions/compatibility-manifest.js";

const gatewayPackage = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8")) as {
  dependencies: Record<string, string>;
};
const expectedPiVersions = [
  "@earendil-works/pi-agent-core",
  "@earendil-works/pi-ai",
  "@earendil-works/pi-coding-agent",
  "@earendil-works/pi-tui",
].map((name) => gatewayPackage.dependencies[name]);
const expectedPiVersion = expectedPiVersions[0];

describe("Gateway runtime identity", () => {
  it("derives the Pi version from package.json and shares it with the compatibility manifest", () => {
    expect(new Set(expectedPiVersions)).toEqual(new Set([expectedPiVersion]));
    expect(PI_VERSION).toBe(PINNED_PI_VERSION);
    expect(PI_VERSION).toBe(expectedPiVersion);
  });

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
