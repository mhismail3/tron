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
    await store.clear("session", "older-operation");
    expect(await store.interruptedSessionIds()).toEqual(new Set(["session"]));
    await store.clear("session", "operation");
    expect(await store.interruptedSessionIds()).toEqual(new Set());
  });

  it("cleans lanes after sequential operations across many sessions", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-markers-many-"));
    const store = new RunMarkerStore(root);
    for (let index = 0; index < 100; index += 1) {
      const sessionId = `session-${index}`;
      await store.mark(sessionId, `operation-${index}`);
      await store.clear(sessionId, `operation-${index}`);
    }
    expect((store as unknown as { lanes: Map<string, unknown> }).lanes.size).toBe(0);
  });

  it("keeps queued same-session work serialized and removes the lane after all callers settle", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-markers-queued-"));
    const store = new RunMarkerStore(root);
    await Promise.all([
      ...Array.from({ length: 20 }, (_, index) => store.mark("same-session", `operation-${index}`)),
      ...Array.from({ length: 20 }, (_, index) => store.clear("same-session", `operation-${index}`)),
    ]);
    expect((store as unknown as { lanes: Map<string, unknown> }).lanes.size).toBe(0);
  });
});
