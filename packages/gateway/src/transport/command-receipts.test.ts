import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { GatewayError, asUncertainOutcome } from "../errors.js";
import { atomicWriteJson } from "../util/json.js";
import { CommandReceiptStore } from "./command-receipts.js";

// Every case owns one temporary tron home; release them all so a long-lived
// suite cannot accumulate receipt evidence in the shared temporary root.
const temporaryRoots: string[] = [];

async function temporaryRoot(prefix: string): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), prefix));
  temporaryRoots.push(root);
  return root;
}

afterEach(async () => {
  await Promise.all(temporaryRoots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

async function receiptFiles(root: string): Promise<string[]> {
  const directory = join(root, "gateway", "command-receipts");
  return (await readdir(directory)).map((name) => join(directory, name)).sort();
}

describe("CommandReceiptStore", () => {
  it("allows distinct commands to execute concurrently", async () => {
    const root = await temporaryRoot("tron-receipts-");
    const store = new CommandReceiptStore(root);
    let running = 0;
    let maximum = 0;
    let started = 0;
    let signalBothStarted!: () => void;
    const bothStarted = new Promise<void>((resolve) => { signalBothStarted = resolve; });
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const operation = async () => {
      running += 1;
      started += 1;
      maximum = Math.max(maximum, running);
      if (started === 2) signalBothStarted();
      await gate;
      running -= 1;
      return { accepted: true };
    };
    const executions = Promise.all([
      store.execute("device", "session.prompt", "command-one", operation),
      store.execute("device", "session.prompt", "command-two", operation),
    ]);
    await bothStarted;
    expect(maximum).toBe(2);
    release();
    await executions;
  });

  it("serializes duplicates of the same command and returns the recorded response", async () => {
    const root = await temporaryRoot("tron-receipts-");
    const store = new CommandReceiptStore(root);
    const operation = vi.fn(async () => ({ accepted: true }));
    const [first, second] = await Promise.all([
      store.execute("device", "session.prompt", "same-command", operation),
      store.execute("device", "session.prompt", "same-command", operation),
    ]);
    expect(first).toEqual(second);
    expect(operation).toHaveBeenCalledTimes(1);

    // A later sequential duplicate reads the same completed receipt.
    await expect(store.execute("device", "session.prompt", "same-command", operation)).resolves.toEqual(first);
    expect(operation).toHaveBeenCalledTimes(1);
  });

  it("does not prune a completed receipt while its duplicate lane is active", async () => {
    const root = await temporaryRoot("tron-receipts-active-lane-");
    const store = new CommandReceiptStore(root, atomicWriteJson, { maximumAgeMs: 0 });
    let releaseOperation: (() => void) | undefined;
    let signalStarted: (() => void) | undefined;
    const started = new Promise<void>((resolve) => { signalStarted = resolve; });
    const release = new Promise<void>((resolve) => { releaseOperation = resolve; });
    const operation = vi.fn(async () => {
      signalStarted?.();
      await release;
      return { accepted: true };
    });

    const first = store.execute("device", "session.prompt", "same-expiring-command", operation);
    await started;
    const duplicate = store.execute("device", "session.prompt", "same-expiring-command", operation);
    releaseOperation?.();

    await expect(Promise.all([first, duplicate])).resolves.toEqual([
      { accepted: true },
      { accepted: true },
    ]);
    expect(operation).toHaveBeenCalledTimes(1);

    await expect(store.execute(
      "device",
      "session.prompt",
      "same-expiring-command",
      operation,
    )).resolves.toEqual({ accepted: true });
    expect(operation).toHaveBeenCalledTimes(2);
  });

  it("removes pending state after a definitive application rejection", async () => {
    const root = await temporaryRoot("tron-receipts-");
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

  it("retains pending uncertainty after an operation reports an unknown outcome", async () => {
    const root = await temporaryRoot("tron-receipts-uncertain-");
    const store = new CommandReceiptStore(root);
    let effects = 0;
    const performed = async () => {
      effects += 1;
      throw new GatewayError("conflict", "Effect applied but its receipt could not be persisted", false, { outcomeUnknown: true });
    };

    await expect(store.execute("device", "session.bash", "uncertain-effect", performed)).rejects.toMatchObject({
      code: "conflict",
      details: { outcomeUnknown: true },
    });
    // The pending receipt is the durable fence: status stays uncertain and the
    // identical command can never be replayed into a second effect.
    await expect(store.status("device", "session.bash", "uncertain-effect")).resolves.toEqual({ status: "pending" });
    await expect(store.execute("device", "session.bash", "uncertain-effect", performed)).rejects.toMatchObject({
      code: "conflict",
      details: { outcomeUnknown: true },
    });
    await store.prune(0);
    await expect(store.status("device", "session.bash", "uncertain-effect")).resolves.toEqual({ status: "pending" });
    expect(effects).toBe(1);

    // A new commandId is the supported recovery path and must still execute.
    const recovered = vi.fn(async () => ({ accepted: true }));
    await expect(store.execute("device", "session.bash", "uncertain-effect-retry", recovered))
      .resolves.toEqual({ accepted: true });
    expect(recovered).toHaveBeenCalledTimes(1);
  });

  it("never advertises replayability after a retryable owner error becomes uncertain", async () => {
    const root = await temporaryRoot("tron-receipts-uncertain-classification-");
    const store = new CommandReceiptStore(root);
    await expect(store.execute("device", "packages.update", "partial-owner-error", async () => {
      throw asUncertainOutcome(new GatewayError("busy", "post-effect cleanup failed", true), "Package update may have applied");
    })).rejects.toMatchObject({ retryable: false, details: { outcomeUnknown: true } });
    expect(await store.status("device", "packages.update", "partial-owner-error")).toEqual({ status: "pending" });
  });

  it.each<[string, { maximumEntries: number; maximumAggregateBytes: number }]>([
    ["entry count", { maximumEntries: 1, maximumAggregateBytes: 2 * 1_048_576 }],
    ["aggregate bytes", { maximumEntries: 10, maximumAggregateBytes: 1_048_576 + 4 * 1_024 + 1 }],
  ])("rejects new mutations before execution when %s capacity is full", async (_label, limits) => {
    const root = await temporaryRoot("tron-receipts-capacity-");
    const store = new CommandReceiptStore(root, atomicWriteJson, limits);
    await store.execute("device", "session.prompt", "first-command", async () => ({ accepted: true }));
    const rejected = vi.fn(async () => ({ accepted: true }));

    await expect(store.execute("device", "session.prompt", "second-command", rejected))
      .rejects.toMatchObject({ code: "busy", retryable: true });
    expect(rejected).not.toHaveBeenCalled();
    expect(await receiptFiles(root)).toHaveLength(1);
  });

  it("removes only owned interrupted receipt writes before capacity admission", async () => {
    const root = await temporaryRoot("tron-receipts-temporary-");
    const directory = join(root, "gateway", "command-receipts");
    await mkdir(directory, { recursive: true });
    await writeFile(join(directory, `${"a".repeat(43)}.json.123.123456789abc.tmp`), "interrupted write");
    const store = new CommandReceiptStore(root, atomicWriteJson, {
      maximumEntries: 1,
      maximumAggregateBytes: 2 * 1_048_576,
    });

    await expect(store.execute("device", "session.prompt", "first-command", async () => ({ accepted: true })))
      .resolves.toEqual({ accepted: true });
    expect(await receiptFiles(root)).toHaveLength(1);
  });

  it("expires completed editor updates quickly without shortening other receipt retention", async () => {
    const root = await temporaryRoot("tron-receipts-editor-expiry-");
    const store = new CommandReceiptStore(root, atomicWriteJson, {
      maximumEntries: 2,
      maximumAggregateBytes: 2 * 1_048_576,
    });
    await store.execute("device", "extension.editor.update", "editor-command-one", async () => ({ revision: 1 }));
    await store.execute("device", "session.prompt", "prompt-command-one", async () => ({ accepted: true }));
    const paths = await receiptFiles(root);
    const editorReceiptPath = (await Promise.all(paths.map(async (path) => ({
      path,
      receipt: JSON.parse(await readFile(path, "utf8")),
    })))).find(({ receipt }) => receipt.commandId === "editor-command-one")!.path;
    const editorReceipt = JSON.parse(await readFile(editorReceiptPath, "utf8"));
    editorReceipt.createdAt = new Date(Date.now() - 11 * 60_000).toISOString();
    await writeFile(editorReceiptPath, JSON.stringify(editorReceipt));

    const execute = vi.fn(async () => ({ revision: 2 }));
    await expect(store.execute("device", "extension.editor.update", "editor-command-two", execute))
      .resolves.toEqual({ revision: 2 });
    expect(execute).toHaveBeenCalledTimes(1);
    expect(await receiptFiles(root)).toHaveLength(2);
    await expect(store.status("device", "session.prompt", "prompt-command-one"))
      .resolves.toMatchObject({ status: "completed" });
  });

  it("retains pending state when successful completion cannot be persisted", async () => {
    const root = await temporaryRoot("tron-receipts-");
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
    const root = await temporaryRoot("tron-receipts-corrupt-");
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
    const root = await temporaryRoot("tron-receipts-prune-");
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
    const root = await temporaryRoot("tron-receipts-timestamp-");
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
    const root = await temporaryRoot("tron-receipts-exact-boundary-");
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
    const root = await temporaryRoot("tron-receipts-result-bound-");
    const store = new CommandReceiptStore(root);
    const operation = vi.fn(async () => ({ value: "x".repeat(1_100_000) }));

    await expect(store.execute("device", "session.prompt", "oversized-result", operation)).rejects.toMatchObject({
      code: "conflict",
      details: { outcomeUnknown: true },
    });
    await expect(store.status("device", "session.prompt", "oversized-result"))
      .resolves.toEqual({ status: "pending" });
    await store.prune(0);
    await expect(store.status("device", "session.prompt", "oversized-result"))
      .resolves.toEqual({ status: "pending" });
    await expect(store.execute("device", "session.prompt", "oversized-result", operation)).rejects.toMatchObject({
      code: "conflict",
      details: { outcomeUnknown: true },
    });
    expect(operation).toHaveBeenCalledTimes(1);
  });
});
