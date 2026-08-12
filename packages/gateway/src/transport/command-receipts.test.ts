import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { CommandReceiptStore } from "./command-receipts.js";

describe("CommandReceiptStore", () => {
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
