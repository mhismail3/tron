import { describe, expect, test } from "vitest";
import { validateNotification, validateRegistration } from "../src/validation";
import { notification } from "./fixtures";

const registration = {
  version: 1,
  proof: "attestation",
  challengeId: "challenge-identifier-0001",
  challenge: "c".repeat(43),
  keyId: "k".repeat(43),
  apnsToken: "ab".repeat(37),
  route: "beta",
  bindingHash: "12".repeat(32),
  attestationObject: "a".repeat(64),
};

const now = 2_000_000_000_000;
const validNotification = { ...notification, expiresAt: new Date(now + 60_000).toISOString() };

describe("closed v3 validation", () => {
  test("admits opaque variable-length APNs tokens and exact official routes", () => {
    expect(validateRegistration(registration)).toEqual({ ok: true, value: registration });
    expect(validateRegistration({ ...registration, route: "other" })).toEqual({ ok: false, error: "invalid_registration" });
    expect(validateRegistration({ ...registration, apnsToken: "AB" })).toEqual({ ok: false, error: "invalid_registration" });
  });

  test("rejects unknown registration and APNs control fields", () => {
    expect(validateRegistration({ ...registration, topic: "com.attacker.app" })).toEqual({ ok: false, error: "unknown_field" });
    expect(validateRegistration({ ...registration, environment: "production" })).toEqual({ ok: false, error: "unknown_field" });
  });

  test("admits only a bounded agent alert", () => {
    expect(validateNotification(validNotification, now)).toEqual({ ok: true, value: validNotification });
    expect(validateNotification({ ...validNotification, badge: 99 }, now)).toEqual({ ok: false, error: "unknown_field" });
    expect(validateNotification({ ...validNotification, message: "x".repeat(513) }, now)).toEqual({ ok: false, error: "invalid_request" });
    expect(validateNotification({ ...validNotification, expiresAt: "2999-01-01T00:00:00Z" }, now)).toEqual({ ok: false, error: "invalid_request" });
  });

  test("bounds message bytes rather than UTF-16 units", () => {
    expect(validateNotification({ ...validNotification, message: "🦆".repeat(128) }, now)).toMatchObject({ ok: true });
    expect(validateNotification({ ...validNotification, message: "🦆".repeat(129) }, now)).toEqual({ ok: false, error: "invalid_request" });
  });
});
