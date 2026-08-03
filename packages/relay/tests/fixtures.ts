import type { AlertRequest } from "../src/contracts";

export const alert = {
  kind: "alert",
  requestId: "target-1",
  deviceToken: "ab".repeat(32),
  topic: "com.tron.mobile.beta",
  environment: "sandbox",
  expiresAt: "2099-01-01T00:00:00Z",
  collapseId: "delivery-1",
  title: "Reminder",
  body: "Do the thing.",
  threadKey: "reminders",
  category: "TRON_REMINDER",
  badge: 1,
  serverId: "server-1",
  deliveryId: "delivery-1",
} satisfies AlertRequest;
