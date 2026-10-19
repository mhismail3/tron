import { describe, it } from "vitest";
import { runStoreLock } from "../../test-support/tron-store-corpus.js";

/** `gateway/admin` persisted-store lock (restructure plan §6.5, V4; test-support/tron-store-corpus.ts). */
describe("gateway/admin store locks", () => {
  it("store-settings: the current owner reads the committed store unchanged", () => runStoreLock("store-settings", import.meta.url));
});
