import { describe, expect, it } from "vitest";
import { redactCredentials } from "./credential-redaction.js";

/*
 * The credential-only rule set is shared by the process preview and the
 * episodic projection. Its control is the negative direction: text that is not
 * a credential (a path, a digest, an identifier) must survive, because the
 * memory has to keep it readable.
 */
describe("credential redaction", () => {
  it("masks provider credentials, bearer tokens, JWTs and PEM blocks", () => {
    const secrets = [
      "sk-abcdefghijklmnopqrstuvwxyz012345",
      "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
      "AKIAIOSFODNN7EXAMPLE",
      "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
      "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA\n-----END RSA PRIVATE KEY-----",
    ];
    for (const secret of secrets) {
      const redacted = redactCredentials(`here it is: ${secret} ok`);
      expect(redacted).not.toContain(secret);
      expect(redacted).toContain("[REDACTED");
    }
    expect(redactCredentials("Authorization: Bearer abcdefghijklmnop")).toBe("Authorization: Bearer [REDACTED]");
    expect(redactCredentials("sent Bearer abcdefghijklmnop")).toBe("sent Bearer [REDACTED]");
  });

  it("keeps paths, digests and identifiers readable", () => {
    const kept = [
      "/Users/example/project/packages/gateway/src/episodic/episodic-memory.ts",
      "4f9a1c2b3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8",
      "episodic-memory.e2e.test.ts",
      "sha256:abcdef0123456789abcdef0123456789",
    ];
    for (const value of kept) expect(redactCredentials(value)).toBe(value);
  });
});
