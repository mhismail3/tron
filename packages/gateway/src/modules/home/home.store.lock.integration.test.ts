import { describe, it } from "vitest";
import { runStoreLock } from "../../../test-support/tron-store-corpus.js";

describe("gateway/home store locks", () => {
  it("store-home-tasks: the current owner reads the committed store unchanged", () => runStoreLock("store-home-tasks", import.meta.url));
  it("store-home-designation: the current owner reads the committed store unchanged", () => runStoreLock("store-home-designation", import.meta.url));
  it("store-home-profile: the current owners record and read the learned profile", () => runStoreLock("store-home-profile", import.meta.url));
});
