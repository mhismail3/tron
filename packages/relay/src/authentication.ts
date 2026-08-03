import { RELAY_PATH } from "./contracts";
import {
  constantTimeEqual,
  hexBytes,
  sha256Hex,
} from "./crypto";

const CLOCK_SKEW_SECONDS = 300;

export async function verifyRelaySignature(
  secret: string,
  timestamp: string,
  requestId: string,
  body: Uint8Array,
  provided: string,
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<boolean> {
  if (!/^\d{10,}$/.test(timestamp) || !/^[0-9a-f]{64}$/i.test(provided)) {
    return false;
  }
  const timestampNumber = Number(timestamp);
  if (
    !Number.isSafeInteger(timestampNumber) ||
    Math.abs(nowSeconds - timestampNumber) > CLOCK_SKEW_SECONDS
  ) {
    return false;
  }
  const bodyHash = await sha256Hex(body);
  const canonical = `POST\n${RELAY_PATH}\n${timestamp}\n${requestId}\n${bodyHash}`;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const expected = new Uint8Array(
    await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(canonical)),
  );
  return constantTimeEqual(expected, hexBytes(provided));
}
