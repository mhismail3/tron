import { describe, it } from "vitest";
import { runStoreLock } from "../../../test-support/tron-store-corpus.js";

describe("gateway/apps store locks", () => {
  it("store-swift-apps: the current owner reads the committed store unchanged", () => runStoreLock("store-swift-apps", import.meta.url));
});
