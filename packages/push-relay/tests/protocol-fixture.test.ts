import { describe, expect, it } from "vitest";
import fixture from "../../protocol-fixtures/push-v3.json";
import { canonicalRegistration, sha256Hex } from "../src/crypto";
import { verifyGrantSignature } from "../src/authentication";

interface Fixture {
  registration: { fields: Parameters<typeof canonicalRegistration>[0]; canonicalUTF8: string; clientDataHashHex: string };
  notification: { secret: string; timestamp: string; requestId: string; path: string; bodyUTF8: string; bodyHashHex: string; signatureHex: string };
}

const value = fixture as Fixture;

describe("shared push v3 protocol fixture", () => {
  it("pins registration canonical bytes and notification HMAC", async () => {
    const canonical = canonicalRegistration(value.registration.fields);
    expect(new TextDecoder().decode(canonical)).toBe(value.registration.canonicalUTF8);
    expect(await sha256Hex(canonical)).toBe(value.registration.clientDataHashHex);
    expect(await sha256Hex(new TextEncoder().encode(value.notification.bodyUTF8))).toBe(value.notification.bodyHashHex);
    await expect(verifyGrantSignature({
      secret: value.notification.secret,
      method: "POST",
      path: value.notification.path,
      timestamp: value.notification.timestamp,
      requestId: value.notification.requestId,
      body: new TextEncoder().encode(value.notification.bodyUTF8),
      provided: value.notification.signatureHex,
      nowSeconds: Number(value.notification.timestamp),
    })).resolves.toBe(true);
  });
});
