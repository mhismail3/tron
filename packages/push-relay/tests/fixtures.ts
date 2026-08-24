import type { NotificationRequest } from "../src/contracts";

export const notification = {
  version: 1,
  kind: "agent_alert",
  requestId: "request-identifier-0001",
  message: "Tron needs your input.",
  expiresAt: "2099-01-01T00:00:00.000Z",
} satisfies NotificationRequest;

export const testGrant = {
  grantId: "grant-identifier-00001",
  secret: "test-grant-secret-with-enough-entropy",
  installationId: "installation-identifier-00001",
  bindingHash: "ab".repeat(32),
  deviceToken: "cd".repeat(48),
  keyId: "k".repeat(43),
};
