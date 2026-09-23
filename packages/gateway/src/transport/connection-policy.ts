import contract from "../../../protocol-fixtures/gateway-connection-contract.json" with { type: "json" };

/** Shared transport bounds consumed by the Gateway and checked against the native client contract. */
export const GATEWAY_CONNECTION_POLICY = Object.freeze({
  heartbeatIntervalMs: contract.serverHeartbeatInterval.milliseconds,
  missedHeartbeatLimit: contract.serverMissedHeartbeatLimit.count,
  helloDeadlineMs: contract.serverHelloDeadline.milliseconds,
  perIdentitySocketCap: contract.perIdentitySocketCap.count,
});
