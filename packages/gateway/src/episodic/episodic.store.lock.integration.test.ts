import { describe, it } from "vitest";
import { runStoreLock } from "../../test-support/tron-store-corpus.js";

describe("gateway/episodic store locks", () => {
  it("store-episodic: the current owner reads the committed store unchanged", () => runStoreLock("store-episodic", import.meta.url));
});
