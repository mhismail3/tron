import { describe, it } from "vitest";
import { runStoreLock } from "../../test-support/tron-store-corpus.js";

describe("gateway/session-catalog store locks", () => {
  it("store-session-archive-attention: the current owner reads the committed store unchanged", () => runStoreLock("store-session-archive-attention", import.meta.url));
});
