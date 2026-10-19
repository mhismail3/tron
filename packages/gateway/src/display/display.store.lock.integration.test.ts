import { describe, it } from "vitest";
import { runStoreLock } from "../../test-support/tron-store-corpus.js";

/** `gateway/display` persisted-store lock (restructure plan §6.5, V4; test-support/tron-store-corpus.ts). */
describe("gateway/display store locks", () => {
  it("store-display-artifacts: the current owner records and reads its store", () => runStoreLock("store-display-artifacts", import.meta.url));
});
