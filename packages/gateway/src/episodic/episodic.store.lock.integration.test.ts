import { describe, it } from "vitest";
import { runStoreLock } from "../../test-support/tron-store-corpus.js";

/** `gateway/episodic` persisted-store lock (restructure plan §6.5, V4; test-support/tron-store-corpus.ts). */
describe("gateway/episodic store locks", () => {
  it("store-episodic: the current owner reads the committed store unchanged", () => runStoreLock("store-episodic", import.meta.url));
});
