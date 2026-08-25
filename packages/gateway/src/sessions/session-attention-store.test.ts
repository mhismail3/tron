import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { atomicWriteJson } from "../util/json.js";
import { SessionAttentionStore } from "./session-attention-store.js";
import { latestSuccessfulAssistantCompletion, successfulAssistantCompletion } from "./runtime-slot.js";

describe("session attention completion admission", () => {
  it("admits only stop and length assistant terminals, including non-text outcomes", () => {
    const entry = (id: string, stopReason: string, role = "assistant") => ({
      id,
      timestamp: `2026-01-01T00:00:0${id.length}.000Z`,
      type: "message",
      message: { role, stopReason },
    });
    for (const excluded of ["pending", "toolUse", "error", "aborted", "deferred"]) {
      expect(latestSuccessfulAssistantCompletion([entry(excluded, excluded)])).toBeUndefined();
    }
    expect(latestSuccessfulAssistantCompletion([entry("stop", "stop")])?.id).toBe("stop");
    expect(latestSuccessfulAssistantCompletion([entry("length", "length")])?.id).toBe("length");
    expect(latestSuccessfulAssistantCompletion([
      entry("success", "stop"),
      entry("tool", "toolUse"),
      entry("maintenance", "stop", "user"),
    ])?.id).toBe("success");
    expect(successfulAssistantCompletion(entry("tool", "toolUse"))).toBeUndefined();
    expect(successfulAssistantCompletion(entry("aborted", "aborted"))).toBeUndefined();
    expect(successfulAssistantCompletion(entry("terminal", "stop"))?.id).toBe("terminal");
  });
});

describe("SessionAttentionStore", () => {
  it("persists completion, stale-safe reads, manual unread, rekey, and delete", async () => {
    const home = await mkdtemp(join(tmpdir(), "tron-attention-"));
    const store = new SessionAttentionStore(home);
    await store.initialize();
    expect(store.projection("s")).toEqual({ completionRevision: 0, attentionRevision: 0, isUnread: false });

    expect((await store.complete("s", "entry-1")).changed).toBe(true);
    expect((await store.complete("s", "entry-1")).changed).toBe(false);
    expect(store.projection("s").isUnread).toBe(true);
    await store.complete("s", "entry-2");
    await store.set("s", false, 1);
    expect(store.projection("s")).toMatchObject({ completionRevision: 2, isUnread: true });
    await store.set("s", false, 2);
    expect(store.projection("s").isUnread).toBe(false);
    await store.set("s", true);
    expect(store.projection("s").isUnread).toBe(true);

    await store.rekey("s", "next");
    expect(store.projection("s").completionRevision).toBe(0);
    expect(store.projection("next")).toMatchObject({ completionRevision: 2, isUnread: true });
    await store.remove("next");
    expect(store.projection("next").isUnread).toBe(false);

    const restarted = new SessionAttentionStore(home);
    await restarted.initialize();
    expect(restarted.projection("next").isUnread).toBe(false);
  });

  it("does not write, create records, or advance revisions for no-op reads", async () => {
    const home = await mkdtemp(join(tmpdir(), "tron-attention-noop-"));
    const write = vi.fn(atomicWriteJson);
    const store = new SessionAttentionStore(home, { write });
    await store.initialize();
    expect((await store.set("empty", false, 0)).changed).toBe(false);
    expect(write).toHaveBeenCalledTimes(1);
    expect(store.projection("empty")).toEqual({ completionRevision: 0, attentionRevision: 0, isUnread: false });

    await store.complete("s", "one");
    await store.set("s", false, 1);
    const writes = write.mock.calls.length;
    const revision = store.projection("s").attentionRevision;
    expect((await store.set("s", false, 1)).changed).toBe(false);
    expect(write).toHaveBeenCalledTimes(writes);
    expect(store.projection("s").attentionRevision).toBe(revision);
  });

  it("deduplicates nonconsecutive callbacks and recovers after an injected write failure", async () => {
    const home = await mkdtemp(join(tmpdir(), "tron-attention-retry-"));
    let rejectNext = false;
    const store = new SessionAttentionStore(home, {
      write: async (path, value) => {
        if (rejectNext) {
          rejectNext = false;
          throw new Error("injected attention write failure");
        }
        await atomicWriteJson(path, value);
      },
    });
    await store.initialize();
    await store.complete("s", "one");
    await store.complete("s", "two");
    expect((await store.complete("s", "one")).changed).toBe(false);
    expect(store.projection("s").completionRevision).toBe(2);

    rejectNext = true;
    await expect(store.complete("s", "three")).rejects.toThrow("injected");
    expect(store.projection("s").completionRevision).toBe(2);
    expect((await store.complete("s", "three")).changed).toBe(true);
    const restarted = new SessionAttentionStore(home);
    await restarted.initialize();
    expect(restarted.projection("s")).toMatchObject({ completionRevision: 3, isUnread: true });
  });

  it("round-trips prototype-special identities without inherited lookup", async () => {
    const home = await mkdtemp(join(tmpdir(), "tron-attention-identities-"));
    const store = new SessionAttentionStore(home);
    await store.initialize();
    for (const id of ["__proto__", "constructor", "toString"]) await store.complete(id, `completion-${id}`);
    const restarted = new SessionAttentionStore(home);
    await restarted.initialize();
    for (const id of ["__proto__", "constructor", "toString"]) {
      expect(restarted.projection(id)).toMatchObject({ completionRevision: 1, isUnread: true });
    }
  });

  it("never overwrites target state during a canonical rekey", async () => {
    const home = await mkdtemp(join(tmpdir(), "tron-attention-rekey-"));
    const store = new SessionAttentionStore(home);
    await store.initialize();
    await store.complete("source", "source-completion");
    await store.complete("target", "target-completion");
    await expect(store.rekey("source", "target")).rejects.toThrow("already has attention");
    expect(store.projection("source").completionRevision).toBe(1);
    expect(store.projection("target").completionRevision).toBe(1);
  });

  it("persists a restart reconciliation cursor only after admitted completions", async () => {
    const home = await mkdtemp(join(tmpdir(), "tron-attention-cursor-"));
    const store = new SessionAttentionStore(home, { now: () => new Date("2026-01-01T00:00:00.000Z") });
    await store.initialize();
    expect(store.reconciliationCursor()).toBe("2026-01-01T00:00:00.000Z");
    await store.complete("s", "recovered-completion");
    await store.advanceReconciliationCursor("2026-01-02T00:00:00.000Z");
    const restarted = new SessionAttentionStore(home);
    await restarted.initialize();
    expect(restarted.reconciliationCursor()).toBe("2026-01-02T00:00:00.000Z");
    expect(restarted.projection("s")).toMatchObject({ completionRevision: 1, isUnread: true });
  });

  it("fails closed on malformed and oversized state", async () => {
    const home = await mkdtemp(join(tmpdir(), "tron-attention-invalid-"));
    const path = join(home, "gateway", "session-attention.json");
    await import("node:fs/promises").then(({ mkdir }) => mkdir(join(home, "gateway"), { recursive: true }));
    await writeFile(path, "{bad");
    await expect(new SessionAttentionStore(home).initialize()).rejects.toThrow();
    await writeFile(path, "x".repeat(2 * 1_048_576 + 1));
    await expect(new SessionAttentionStore(home).initialize()).rejects.toThrow();
  });
});
