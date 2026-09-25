import { describe, expect, it } from "vitest";
import { validateProviderCatalog } from "./gateway-service.js";

function provider(id: string, name = id) {
  return {
    id,
    name,
    usageSupported: false,
    localOnly: false,
    authSource: null,
    credentialType: null,
    authMethods: [] as string[],
  };
}

describe("provider catalog bounds", () => {
  it("accepts the exact item boundary and rejects overflow", () => {
    validateProviderCatalog(Array.from({ length: 1_000 }, (_, index) => provider(`p-${index}`)));
    expect(() => validateProviderCatalog(
      Array.from({ length: 1_001 }, (_, index) => provider(`p-${index}`)),
    )).toThrow(/item limit/);
  });

  it("rejects duplicate identities, malformed usage flags, and strings generic projection would truncate", () => {
    expect(() => validateProviderCatalog([provider("same"), provider("same")]))
      .toThrow(/duplicate IDs/);
    expect(() => validateProviderCatalog([{ ...provider("p"), usageSupported: "yes" as unknown as boolean }]))
      .toThrow(/invalid usage flag/);
    expect(() => validateProviderCatalog([{ ...provider("p"), localOnly: "yes" as unknown as boolean }]))
      .toThrow(/invalid local-only flag/);
    expect(() => validateProviderCatalog([provider("large", "x".repeat(100_001))]))
      .toThrow(/string limit/);
  });
});
