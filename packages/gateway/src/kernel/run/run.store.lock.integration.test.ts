import { describe, it } from "vitest";
import { runStoreLock } from "../../../test-support/tron-store-corpus.js";

describe("gateway/run store locks", () => {
  it("store-run-markers: the current owner reads the committed store unchanged", () => runStoreLock("store-run-markers", import.meta.url));
});
