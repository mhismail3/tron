import { describe, it } from "vitest";
import { runStoreLock } from "../../test-support/tron-store-corpus.js";

describe("gateway/display store locks", () => {
  it("store-display-artifacts: the current owner records and reads its store", () => runStoreLock("store-display-artifacts", import.meta.url));
});
