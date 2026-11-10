import { describe, it } from "vitest";
import { runStoreLock } from "../../test-support/tron-store-corpus.js";

describe("gateway/admin store locks", () => {
  it("store-settings: the current owner reads the committed store unchanged", () => runStoreLock("store-settings", import.meta.url));
});
