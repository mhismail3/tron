import { describe, it } from "vitest";
import { runStoreLock } from "../../test-support/tron-store-corpus.js";

/** `gateway/transport` persisted-store lock (restructure plan §6.5, V4; test-support/tron-store-corpus.ts). */
describe("gateway/transport store locks", () => {
  it("store-command-receipts: the current owner reads the committed store unchanged", () => runStoreLock("store-command-receipts", import.meta.url));
});
