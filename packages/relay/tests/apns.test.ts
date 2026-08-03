import { describe, expect, test } from "vitest";

import { buildApnsPayload } from "../src/apns";
import { alert } from "./fixtures";

describe("closed APNs payload projection", () => {
  test("projects only the fixed alert payload", () => {
    const payload = JSON.parse(buildApnsPayload(alert));
    expect(payload).toEqual({
      aps: {
        alert: { title: "Reminder", body: "Do the thing." },
        sound: "default",
        category: "TRON_REMINDER",
        badge: 1,
        "thread-id": "reminders",
      },
      tron: {
        kind: "notification",
        serverId: "server-1",
        deliveryId: "delivery-1",
      },
    });
    expect(JSON.stringify(payload).length).toBeLessThan(4096);
  });

  test("projects quiet refresh without alert content", () => {
    const payload = JSON.parse(buildApnsPayload({
      kind: "background",
      requestId: "target-2",
      deviceToken: "ab".repeat(32),
      topic: "com.tron.mobile",
      environment: "production",
      expiresAt: "2099-01-01T00:00:00Z",
      collapseId: "refresh-1",
      badge: 2,
      serverId: "server-1",
    }));
    expect(payload).toEqual({
      aps: { "content-available": 1, badge: 2 },
      tron: {
        kind: "notification_state_refresh",
        serverId: "server-1",
      },
    });
  });
});
