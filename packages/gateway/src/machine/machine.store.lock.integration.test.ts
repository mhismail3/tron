import { describe, it } from "vitest";
import { runStoreLock } from "../../test-support/tron-store-corpus.js";

/** `gateway/machine` persisted-store lock (restructure plan §6.5, V4; test-support/tron-store-corpus.ts). */
describe("gateway/machine store locks", () => {
  it("store-uploads: the current owner reads the committed store unchanged", () => runStoreLock("store-uploads", import.meta.url));
});
