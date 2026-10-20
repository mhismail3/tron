import { describe, it } from "vitest";
import { runStoreLock } from "../../test-support/tron-store-corpus.js";

/** `gateway/providers` persisted-store lock (restructure plan §6.5, V4; test-support/tron-store-corpus.ts). */
describe("gateway/providers store locks", () => {
  it("store-model-recents: the current owner reads the committed store unchanged", () => runStoreLock("store-model-recents", import.meta.url));
  it("store-model-queue: a child reads the committed projection unchanged", () => runStoreLock("store-model-queue", import.meta.url));
  it("store-model-release-dates: the current owner reads the committed cache unchanged", () => runStoreLock("store-model-release-dates", import.meta.url));
});
