import { constantTimeEqual, hexBytes, hmacHex, sha256Hex } from "./crypto";

const CLOCK_SKEW_SECONDS = 300;

interface VerifiedGrantSignature {
  bodyHash: string;
}

export async function verifyGrantSignature(input: {
  secret: string;
  method: "POST" | "DELETE";
  path: string;
  timestamp: string;
  requestId: string;
  body: Uint8Array;
  provided: string;
  nowSeconds?: number;
}): Promise<VerifiedGrantSignature | undefined> {
  if (!/^\d{10}$/.test(input.timestamp) || !/^[0-9a-f]{64}$/.test(input.provided)) return undefined;
  const timestamp = Number(input.timestamp);
  const now = input.nowSeconds ?? Math.floor(Date.now() / 1000);
  if (!Number.isSafeInteger(timestamp) || Math.abs(now - timestamp) > CLOCK_SKEW_SECONDS) return undefined;
  const bodyHash = await sha256Hex(input.body);
  const canonical = `${input.method}\n${input.path}\n${input.timestamp}\n${input.requestId}\n${bodyHash}`;
  const expected = hexBytes(await hmacHex(input.secret, canonical));
  if (!constantTimeEqual(expected, hexBytes(input.provided))) return undefined;
  return { bodyHash };
}
