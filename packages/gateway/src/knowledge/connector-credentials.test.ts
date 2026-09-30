import { randomUUID } from "node:crypto";
import { describe, expect, it } from "vitest";
import { MacKeychainConnectorCredentialStore } from "./connector-credentials.js";

describe("MacKeychainConnectorCredentialStore", () => {
  it.skipIf(process.platform !== "darwin")("writes a credential that can be read back", async () => {
    const service = `Tron Connector Credentials Test ${randomUUID()}`;
    const store = new MacKeychainConnectorCredentialStore(service);
    const reference = `connector:x:keychain-test-${randomUUID()}`;
    const value = `secret-${randomUUID()}`;
    try {
      await store.write(reference, value);
      expect(await store.read(reference)).toBe(value);
    } finally {
      await store.delete(reference);
    }
  });
});
