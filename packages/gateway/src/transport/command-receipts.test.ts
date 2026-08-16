import { mkdtemp, readFile, readdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { GatewayError } from "../errors.js";
import { atomicWriteJson } from "../util/json.js";
import { CommandReceiptStore } from "./command-receipts.js";

async function receiptFiles(root: string): Promise<string[]> {
  const directory = join(root, "gateway", "command-receipts");
  return (await readdir(directory)).map((name) => join(directory, name)).sort();
}

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

  it("removes pending state after a definitive application rejection", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-receipts-"));
    const store = new CommandReceiptStore(root);
    await expect(store.execute(
      "device",
      "session.prompt",
      "retryable-rejection",
      async () => { throw new GatewayError("busy", "Try later", true); },
    )).rejects.toMatchObject({ code: "busy", retryable: true });
    await expect(store.status("device", "session.prompt", "retryable-rejection"))
      .resolves.toEqual({ status: "missing" });

    const retry = vi.fn(async () => ({ accepted: true }));
    await expect(store.execute("device", "session.prompt", "retryable-rejection", retry))
      .resolves.toEqual({ accepted: true });
    expect(retry).toHaveBeenCalledTimes(1);
  });

  it("retains pending state when successful completion cannot be persisted", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-receipts-"));
    let writes = 0;
    const store = new CommandReceiptStore(root, async (path, value, mode) => {
      writes += 1;
      if (writes === 2) throw new Error("synthetic completion write failure");
      await atomicWriteJson(path, value, mode);
    });
    const operation = vi.fn(async () => ({ accepted: true }));

    await expect(store.execute("device", "session.prompt", "completion-failure", operation))
      .rejects.toThrow("synthetic completion write failure");
    await expect(store.status("device", "session.prompt", "completion-failure"))
      .resolves.toEqual({ status: "pending" });
    await expect(store.execute("device", "session.prompt", "completion-failure", operation))
      .rejects.toMatchObject({ code: "conflict" });
    expect(operation).toHaveBeenCalledTimes(1);
  });

  it.each([
    ["empty", ""],
    ["whitespace", "  \n"],
    ["null", "null"],
    ["malformed", "{not-json"],
    ["oversized", "x".repeat(1_048_576 + 4 * 1_024 + 1)],
  ])("treats %s receipt evidence as outcome-unknown and never replays", async (_label, content) => {
    const root = await mkdtemp(join(tmpdir(), "tron-receipts-corrupt-"));
    const store = new CommandReceiptStore(root);
    await store.execute("device", "session.prompt", "uncertain-command", async () => ({ accepted: true }));
    const [path] = await receiptFiles(root);
    await writeFile(path!, content);

    await expect(store.status("device", "session.prompt", "uncertain-command")).rejects.toMatchObject({
      code: "conflict",
      details: { outcomeUnknown: true },
    });
    const replay = vi.fn(async () => ({ accepted: true }));
    await expect(store.execute("device", "session.prompt", "uncertain-command", replay)).rejects.toMatchObject({
      code: "conflict",
      details: { outcomeUnknown: true },
    });
    expect(replay).not.toHaveBeenCalled();
    expect(await readFile(path!, "utf8")).toBe(content);
  });

  it("prunes expired valid neighbors without deleting uncertain receipt evidence", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-receipts-prune-"));
    const store = new CommandReceiptStore(root);
    await store.execute("device", "session.prompt", "corrupt-command", async () => ({ accepted: true }));
    const [corruptPath] = await receiptFiles(root);
    await store.execute("device", "session.prompt", "expired-command", async () => ({ accepted: true }));
    const expiredPath = (await receiptFiles(root)).find((path) => path !== corruptPath)!;
    await store.execute("device", "session.prompt", "mismatch-command", async () => ({ accepted: true }));
    const mismatchPath = (await receiptFiles(root)).find((path) => path !== corruptPath && path !== expiredPath)!;
    await writeFile(corruptPath!, "{not-json");
    const expired = JSON.parse(await readFile(expiredPath, "utf8"));
    expired.createdAt = "2000-01-01T00:00:00.000Z";
    await writeFile(expiredPath, JSON.stringify(expired));
    const mismatch = JSON.parse(await readFile(mismatchPath, "utf8"));
    mismatch.createdAt = "2000-01-01T00:00:00.000Z";
    mismatch.method = "session.rename";
    await writeFile(mismatchPath, JSON.stringify(mismatch));

    await store.prune();

    expect(await receiptFiles(root)).toEqual([corruptPath, mismatchPath].sort());
  });

  it("rejects noncanonical receipt timestamps without pruning the evidence", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-receipts-timestamp-"));
    const store = new CommandReceiptStore(root);
    await store.execute("device", "session.prompt", "timestamp-command", async () => ({ accepted: true }));
    const [path] = await receiptFiles(root);
    const receipt = JSON.parse(await readFile(path!, "utf8"));
    receipt.createdAt = "0";
    await writeFile(path!, JSON.stringify(receipt));

    await expect(store.status("device", "session.prompt", "timestamp-command")).rejects.toMatchObject({
      details: { outcomeUnknown: true },
    });
    await store.prune(0);
    expect(await receiptFiles(root)).toEqual([path]);
  });

  it("admits the exact persisted-byte boundary and rejects one byte beyond it", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-receipts-exact-boundary-"));
    const store = new CommandReceiptStore(root);
    await store.execute("device", "session.prompt", "boundary-command", async () => ({ accepted: true }));
    const [path] = await receiptFiles(root);
    const receipt = JSON.parse(await readFile(path!, "utf8"));
    receipt.result = { padding: "" };
    const maximumBytes = 1_048_576 + 4 * 1_024;
    const emptyBytes = Buffer.byteLength(`${JSON.stringify(receipt, null, 2)}\n`);
    receipt.result.padding = "x".repeat(maximumBytes - emptyBytes);
    const exact = `${JSON.stringify(receipt, null, 2)}\n`;
    expect(Buffer.byteLength(exact)).toBe(maximumBytes);
    await writeFile(path!, exact);
    await expect(store.status("device", "session.prompt", "boundary-command"))
      .resolves.toMatchObject({ status: "completed" });

    receipt.result.padding += "x";
    await writeFile(path!, `${JSON.stringify(receipt, null, 2)}\n`);
    await expect(store.status("device", "session.prompt", "boundary-command"))
      .rejects.toMatchObject({ details: { outcomeUnknown: true } });
  });

  it("retains pending uncertainty when a successful result exceeds receipt capacity", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-receipts-result-bound-"));
    const store = new CommandReceiptStore(root);
    const operation = vi.fn(async () => ({ value: "x".repeat(1_100_000) }));

    await expect(store.execute("device", "session.prompt", "oversized-result", operation)).rejects.toMatchObject({
      code: "conflict",
      details: { outcomeUnknown: true },
    });
    await expect(store.status("device", "session.prompt", "oversized-result"))
      .resolves.toEqual({ status: "pending" });
    await expect(store.execute("device", "session.prompt", "oversized-result", operation)).rejects.toMatchObject({
      code: "conflict",
      details: { outcomeUnknown: true },
    });
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
