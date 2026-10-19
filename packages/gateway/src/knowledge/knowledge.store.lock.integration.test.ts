import { describe, it } from "vitest";
import { runStoreLock } from "../../test-support/tron-store-corpus.js";

/** `gateway/knowledge` persisted-store lock (restructure plan §6.5, V4; test-support/tron-store-corpus.ts). */
describe("gateway/knowledge store locks", () => {
  it("store-knowledge: the current owner reads the committed store unchanged", () => runStoreLock("store-knowledge", import.meta.url));
});
