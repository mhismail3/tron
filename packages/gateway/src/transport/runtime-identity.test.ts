import { describe, expect, it } from "vitest";
import { runtimeIdentity } from "./runtime-identity.js";

describe("Gateway runtime identity", () => {
  it("returns only supervisor-supplied identity fields", () => {
    expect(runtimeIdentity({
      TRON_GATEWAY_SOURCE_REVISION: "abc-dirty",
      TRON_GATEWAY_BUILD_FINGERPRINT: "fingerprint",
      TRON_GATEWAY_RUNTIME_EPOCH: "epoch-1",
    })).toEqual({ sourceRevision: "abc-dirty", buildFingerprint: "fingerprint", runtimeEpoch: "epoch-1" });
  });

  it("fails closed for unsafe or oversized identity values", () => {
    expect(runtimeIdentity({
      TRON_GATEWAY_SOURCE_REVISION: "bad\nrevision",
      TRON_GATEWAY_BUILD_FINGERPRINT: "x".repeat(257),
      TRON_GATEWAY_RUNTIME_EPOCH: "",
    })).toEqual({});
  });
});
