/**
 * Shared transport bounds consumed by the Gateway. The cross-client contract
 * and each value's rationale live in packages/protocol-fixtures/
 * gateway-connection-contract.json; connection-policy.test.ts keeps these in
 * parity. The fixture is not imported here because the installed payload only
 * ships this package.
 */
export const GATEWAY_CONNECTION_POLICY = Object.freeze({
  heartbeatIntervalMs: 25_000,
  missedHeartbeatLimit: 3,
  helloDeadlineMs: 5_000,
  perIdentitySocketCap: 4,
});
