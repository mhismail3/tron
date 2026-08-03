import { describe, expect, test } from "vitest";

import { validateNotificationRequest } from "../src/validation";
import { alert } from "./fixtures";

describe("closed request validation", () => {
  test("accepts the fixed alert shape", () => {
    expect(validateNotificationRequest(alert)).toEqual({
      ok: true,
      value: alert,
    });
  });

  test("rejects arbitrary APNs and device-control fields", () => {
    for (const field of [
      "payload",
      "url",
      "sound",
      "priority",
      "actions",
      "media",
      "customData",
    ]) {
      expect(
        validateNotificationRequest({ ...alert, [field]: "untrusted" }),
      ).toEqual({ ok: false, error: "unknown_field" });
    }
  });

  test("allows only the fixed topic and environment pairs", () => {
    expect(
      validateNotificationRequest({ ...alert, environment: "production" }),
    ).toEqual({ ok: false, error: "invalid_request" });
    expect(
      validateNotificationRequest({
        ...alert,
        topic: "com.tron.mobile",
        environment: "sandbox",
      }),
    ).toMatchObject({ ok: true });
    expect(
      validateNotificationRequest({
        ...alert,
        topic: "com.tron.mobile",
        environment: "production",
      }),
    ).toMatchObject({ ok: true });
  });
});
