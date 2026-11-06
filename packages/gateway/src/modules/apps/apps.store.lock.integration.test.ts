import { describe, it } from "vitest";
import { runStoreLock } from "../../../test-support/tron-store-corpus.js";

/** `gateway/apps` persisted-store lock (packages/gateway/docs/scenario-locks.md#persisted-stores-v4; test-support/tron-store-corpus.ts). */
describe("gateway/apps store locks", () => {
  it("store-swift-apps: the current owner reads the committed store unchanged", () => runStoreLock("store-swift-apps", import.meta.url));
});
