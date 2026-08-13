import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { CommandReceiptStore } from "./command-receipts.js";

describe("CommandReceiptStore", () => {
  it("allows distinct commands to execute concurrently", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-receipts-"));
    const store = new CommandReceiptStore(root);
    let running = 0;
    let maximum = 0;
    const operation = async () => {
      running += 1;
      maximum = Math.max(maximum, running);
      await new Promise((resolve) => setTimeout(resolve, 25));
      running -= 1;
      return { accepted: true };
    };
    await Promise.all([
      store.execute("device", "session.prompt", "command-one", operation),
      store.execute("device", "session.prompt", "command-two", operation),
    ]);
    expect(maximum).toBe(2);
  });

  it("serializes concurrent duplicates of the same command", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-receipts-"));
    const store = new CommandReceiptStore(root);
    const operation = vi.fn(async () => {
      await new Promise((resolve) => setTimeout(resolve, 25));
      return { accepted: true };
    });
    const [first, second] = await Promise.all([
      store.execute("device", "session.prompt", "same-command", operation),
      store.execute("device", "session.prompt", "same-command", operation),
    ]);
    expect(first).toEqual(second);
    expect(operation).toHaveBeenCalledTimes(1);
  });

  it("returns the recorded response without repeating a mutation", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-receipts-"));
    const store = new CommandReceiptStore(root);
    const operation = vi.fn(async () => ({ accepted: true }));
    const first = await store.execute("device", "session.prompt", "command-123", operation);
    const second = await store.execute("device", "session.prompt", "command-123", operation);
    expect(first).toEqual(second);
    expect(operation).toHaveBeenCalledTimes(1);
  });
});
