import { describe, expect, test } from "vitest";
import { buildApnsPayload } from "../src/apns";
import { notification } from "./fixtures";

describe("closed APNs payload", () => {
  test("projects one fixed alert without badge, routing, or arbitrary data", () => {
    const payload = JSON.parse(buildApnsPayload(notification));
    expect(payload).toEqual({
      aps: {
        alert: { title: "Tron", body: "Tron needs your input." },
        sound: "default",
        category: "TRON_AGENT_NOTIFICATION",
      },
      tron: { kind: "agent_notification", requestId: "request-identifier-0001" },
    });
    expect(new TextEncoder().encode(JSON.stringify(payload)).byteLength).toBeLessThanOrEqual(4096);
    expect(JSON.stringify(payload)).not.toContain("deviceToken");
  });
});
