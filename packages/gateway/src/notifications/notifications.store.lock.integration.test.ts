import { describe, it } from "vitest";
import { runStoreLock } from "../../test-support/tron-store-corpus.js";

describe("gateway/notifications store locks", () => {
  it("store-notifications: the current owner reads the committed store unchanged", () => runStoreLock("store-notifications", import.meta.url));
});
