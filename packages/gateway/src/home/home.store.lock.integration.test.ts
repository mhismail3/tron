import { describe, it } from "vitest";
import { runStoreLock } from "../../test-support/tron-store-corpus.js";

/** `gateway/home` persisted-store lock (restructure plan §6.5, V4; test-support/tron-store-corpus.ts). */
describe("gateway/home store locks", () => {
  it("store-home-tasks: the current owner reads the committed store unchanged", () => runStoreLock("store-home-tasks", import.meta.url));
});
