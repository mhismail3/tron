import { describe, it } from "vitest";
import { runStoreLock } from "../../test-support/tron-store-corpus.js";

/** `gateway/security` persisted-store lock (restructure plan §6.5, V4; test-support/tron-store-corpus.ts). */
describe("gateway/security store locks", () => {
  it("store-devices: the current owner reads the committed store unchanged", () => runStoreLock("store-devices", import.meta.url));
});
