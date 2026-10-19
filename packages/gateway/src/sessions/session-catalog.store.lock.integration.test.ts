import { describe, it } from "vitest";
import { runStoreLock } from "../../test-support/tron-store-corpus.js";

/** `gateway/session-catalog` persisted-store lock (restructure plan §6.5, V4; test-support/tron-store-corpus.ts). */
describe("gateway/session-catalog store locks", () => {
  it("store-session-archive-attention: the current owner reads the committed store unchanged", () => runStoreLock("store-session-archive-attention", import.meta.url));
});
