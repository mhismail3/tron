import { describe, it } from "vitest";
import { runStoreLock } from "../../test-support/tron-store-corpus.js";

describe("gateway/automations store locks", () => {
  it("store-automations: the current owner reads the committed store unchanged", () => runStoreLock("store-automations", import.meta.url));
});
