import { describe, it } from "vitest";
import { runStoreLock } from "../../test-support/tron-store-corpus.js";

describe("gateway/security store locks", () => {
  it("store-devices: the current owner reads the committed store unchanged", () => runStoreLock("store-devices", import.meta.url));
});
