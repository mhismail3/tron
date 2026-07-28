import { describe, expect, test } from "vitest";

import { verifyRelaySignature } from "../src/authentication";

describe("relay authentication", () => {
  test("covers method, path, timestamp, request id, and body hash", async () => {
    const timestamp = "2000000000";
    const body = new TextEncoder().encode('{"kind":"alert"}');
    const bodyHash = await crypto.subtle.digest("SHA-256", body);
    const hashHex = [...new Uint8Array(bodyHash)]
      .map((byte) => byte.toString(16).padStart(2, "0"))
      .join("");
    const canonical = `POST\n/v2/notification\n${timestamp}\ntarget-1\n${hashHex}`;
    const key = await crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode("0123456789abcdef"),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"],
    );
    const signature = [...new Uint8Array(
      await crypto.subtle.sign(
        "HMAC",
        key,
        new TextEncoder().encode(canonical),
      ),
    )]
      .map((byte) => byte.toString(16).padStart(2, "0"))
      .join("");

    await expect(
      verifyRelaySignature(
        "0123456789abcdef",
        timestamp,
        "target-1",
        body,
        signature,
        2000000000,
      ),
    ).resolves.toBe(true);
    await expect(
      verifyRelaySignature(
        "0123456789abcdef",
        timestamp,
        "target-2",
        body,
        signature,
        2000000000,
      ),
    ).resolves.toBe(false);
  });

  test("rejects timestamps outside the five-minute window", async () => {
    await expect(
      verifyRelaySignature(
        "0123456789abcdef",
        "1000",
        "target-1",
        new Uint8Array([1]),
        "00".repeat(32),
        2000,
      ),
    ).resolves.toBe(false);
  });
});
