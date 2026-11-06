import { describe, it } from "vitest";
import { runStoreLock } from "../../test-support/tron-store-corpus.js";

/** `gateway/automations` persisted-store lock (packages/gateway/docs/scenario-locks.md#persisted-stores-v4; test-support/tron-store-corpus.ts). */
describe("gateway/automations store locks", () => {
  it("store-automations: the current owner reads the committed store unchanged", () => runStoreLock("store-automations", import.meta.url));
});
