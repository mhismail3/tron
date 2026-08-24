import { describe, expect, test } from "vitest";
import { verifyGrantSignature } from "../src/authentication";
import { hmacHex, sha256Hex, utf8 } from "../src/crypto";

async function signature(secret: string, method: "POST" | "DELETE", path: string, timestamp: string, requestId: string, body: Uint8Array) {
  const bodyHash = await sha256Hex(body);
  return hmacHex(secret, `${method}\n${path}\n${timestamp}\n${requestId}\n${bodyHash}`);
}

describe("endpoint-scoped request authentication", () => {
  test("covers method, exact path, timestamp, request ID, and body", async () => {
    const secret = "endpoint-secret";
    const body = utf8('{"version":1}');
    const provided = await signature(secret, "POST", "/v3/notifications", "2000000000", "request-identifier-0001", body);
    const common = { secret, method: "POST" as const, path: "/v3/notifications", timestamp: "2000000000", requestId: "request-identifier-0001", body, provided, nowSeconds: 2_000_000_000 };
    await expect(verifyGrantSignature(common)).resolves.toBe(true);
    await expect(verifyGrantSignature({ ...common, path: "/v3/installations" })).resolves.toBe(false);
    await expect(verifyGrantSignature({ ...common, requestId: "request-identifier-0002" })).resolves.toBe(false);
    await expect(verifyGrantSignature({ ...common, body: utf8("{}") })).resolves.toBe(false);
  });

  test("rejects stale, malformed, and wrong-secret requests", async () => {
    const body = new Uint8Array();
    const provided = await signature("secret", "DELETE", "/v3/grants/grant-identifier-00001", "2000000000", "request-identifier-0001", body);
    const input = { secret: "secret", method: "DELETE" as const, path: "/v3/grants/grant-identifier-00001", timestamp: "2000000000", requestId: "request-identifier-0001", body, provided, nowSeconds: 2_000_000_000 };
    await expect(verifyGrantSignature({ ...input, nowSeconds: 2_000_301 })).resolves.toBe(false);
    await expect(verifyGrantSignature({ ...input, provided: "xyz" })).resolves.toBe(false);
    await expect(verifyGrantSignature({ ...input, secret: "other" })).resolves.toBe(false);
  });
});
