import { describe, it } from "vitest";
import { runStoreLock } from "../../test-support/tron-store-corpus.js";

describe("gateway/machine store locks", () => {
  it("store-uploads: the current owner reads the committed store unchanged", () => runStoreLock("store-uploads", import.meta.url));
});
