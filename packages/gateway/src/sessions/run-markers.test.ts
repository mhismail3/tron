import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { RunMarkerStore } from "./run-markers.js";

describe("RunMarkerStore", () => {
  it("records accepted work without storing the prompt", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-markers-"));
    const store = new RunMarkerStore(root);
    await store.mark("session", "operation");
    expect(await store.interruptedSessionIds()).toEqual(new Set(["session"]));
    await store.clear("session");
    expect(await store.interruptedSessionIds()).toEqual(new Set());
  });
});
