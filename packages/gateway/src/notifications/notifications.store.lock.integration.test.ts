import { describe, it } from "vitest";
import { runStoreLock } from "../../test-support/tron-store-corpus.js";

/** `gateway/notifications` persisted-store lock (packages/gateway/docs/scenario-locks.md#persisted-stores-v4; test-support/tron-store-corpus.ts). */
describe("gateway/notifications store locks", () => {
  it("store-notifications: the current owner reads the committed store unchanged", () => runStoreLock("store-notifications", import.meta.url));
});
