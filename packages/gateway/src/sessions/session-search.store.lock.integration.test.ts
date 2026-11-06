import { describe, it } from "vitest";
import { runStoreLock } from "../../test-support/tron-store-corpus.js";

/** `gateway/session-search` persisted-store lock (packages/gateway/docs/scenario-locks.md#persisted-stores-v4; test-support/tron-store-corpus.ts). */
describe("gateway/session-search store locks", () => {
  it("store-session-search: the current owner reads the committed index unchanged", () => runStoreLock("store-session-search", import.meta.url));
});
