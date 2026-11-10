export const GATEWAY_CONNECTION_POLICY = Object.freeze({
  heartbeatIntervalMs: 25_000,
  missedHeartbeatLimit: 3,
  helloDeadlineMs: 5_000,
  perIdentitySocketCap: 4,
});
