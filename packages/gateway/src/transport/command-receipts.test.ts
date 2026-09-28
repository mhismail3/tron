import { mkdir, mkdtemp, open, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { GatewayError, asUncertainOutcome } from "../errors.js";
import { durableAtomicWriteJson } from "../util/durable-json.js";
import { CommandReceiptStore } from "./command-receipts.js";

// How often an admission listed the receipt directory. The store caches its
// totals between prunes, so a regression that makes every writing command force
// the next admission to rescan is only observable here; the store gets no
// production hook for it.
const directoryScans = vi.hoisted(() => ({ readdir: 0 }));
vi.mock("node:fs/promises", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:fs/promises")>();
  const countReaddir = async (...args: unknown[]) => {
    directoryScans.readdir += 1;
    return (actual.readdir as (...callArgs: unknown[]) => Promise<unknown>)(...args);
  };
  return { ...actual, readdir: countReaddir as unknown as typeof actual.readdir };
});

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

/** Writes one valid completed receipt into a fresh root and backdates it, so an
 * explicit `prune(0)` reclaims it. A prune that changes the directory discards
 * the cached totals, which is how a concurrent admission comes to rescan the
 * inventory. The seeder store is separate so its capacity and lanes never
 * affect the case that uses the seed. */async function seededBackdatedReceipt(root: string, commandId: string): Promise<void> {
  const seeder = new CommandReceiptStore(root);
  await seeder.execute("seed", "session.prompt", commandId, async () => ({ accepted: true }));
  const [path] = await receiptFiles(root);
  if (!path) throw new Error("seed receipt was not written");
  const receipt = JSON.parse(await readFile(path, "utf8"));
  receipt.createdAt = new Date(Date.now() - 60_000).toISOString();
  await writeFile(path, JSON.stringify(receipt));
}

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

  it("does not serialize one command's durable receipt write behind the inventory mutex", async () => {
    const root = await temporaryRoot("tron-receipts-write-overlap-");
    let writing = 0;
    let maximumWriting = 0;
    let writers = 0;
    let signalSecondWriter!: () => void;
    const secondWriter = new Promise<void>((resolve) => { signalSecondWriter = resolve; });
    const writeReceipt = async (path: string, value: unknown, mode?: number): Promise<void> => {
      writers += 1;
      writing += 1;
      maximumWriting = Math.max(maximumWriting, writing);
      if (writers === 2) signalSecondWriter();
      try {
        // Hold the first command's real durable write open so the second
        // command's admission must overlap it. Waiting on `secondWriter` with
        // no ceiling keeps this a liveness assertion: with the accounting
        // mutex held across the fsync the second writer never starts and the
        // case fails on the suite's per-test timeout instead of on host load.
        if (writers === 1) await secondWriter;
        await durableAtomicWriteJson(path, value, mode);
      } finally {
        writing -= 1;
      }
    };
    const store = new CommandReceiptStore(root, writeReceipt);
    const operation = async () => ({ accepted: true });

    await expect(Promise.all([
      store.execute("device", "session.prompt", "overlapping-one", operation),
      store.execute("device", "session.prompt", "overlapping-two", operation),
    ])).resolves.toEqual([{ accepted: true }, { accepted: true }]);
    expect(maximumWriting).toBe(2);
  });

  it("counts an unrecorded receipt's bytes while its write is in flight", async () => {
    const root = await temporaryRoot("tron-receipts-write-reservation-");
    let writers = 0;
    let signalFirstWriter!: () => void;
    const firstWriter = new Promise<void>((resolve) => { signalFirstWriter = resolve; });
    let signalSecondSettled!: () => void;
    const secondSettled = new Promise<void>((resolve) => { signalSecondSettled = resolve; });
    const writeReceipt = async (path: string, value: unknown, mode?: number): Promise<void> => {
      writers += 1;
      if (writers === 1) {
        signalFirstWriter();
        // Hold the first pending write until the second admission settles,
        // rather than for a fixed delay: on a loaded host a fixed hold lets the
        // second admission arrive after this write, and the case would then
        // also pass on a store that released the reservation at admission.
        await secondSettled;
      }
      await durableAtomicWriteJson(path, value, mode);
    };
    // Only one command's reserved receipt fits, so the second admission has to
    // be rejected while the first command's receipt is still unwritten:
    // releasing the reservation before the inventory carries the bytes would
    // admit both and put two receipts past the aggregate cap on disk.
    const store = new CommandReceiptStore(root, writeReceipt, {
      maximumEntries: 10,
      maximumAggregateBytes: 1_048_576 + 4 * 1_024 + 1,
    });
    const operation = async () => ({ accepted: true });

    const first = store.execute("device", "session.prompt", "reserved-one", operation);
    await firstWriter;
    const second = store.execute("device", "session.prompt", "reserved-two", operation);
    second.then(signalSecondSettled, signalSecondSettled);
    const outcomes = await Promise.allSettled([first, second]);

    expect(outcomes.map((outcome) => outcome.status).sort()).toEqual(["fulfilled", "rejected"]);
    expect((outcomes.find((outcome) => outcome.status === "rejected") as PromiseRejectedResult).reason)
      .toMatchObject({ code: "busy", retryable: true });
    const persisted = (await receiptFiles(root)).map((path) => readFile(path, "utf8"));
    const bytes = (await Promise.all(persisted)).reduce((total, content) => total + Buffer.byteLength(content), 0);
    expect(bytes).toBeLessThanOrEqual(1_048_576 + 4 * 1_024 + 1);
  });

  it("does not scavenge a temporary receipt whose command is still writing", async () => {
    const root = await temporaryRoot("tron-receipts-inflight-temporary-");
    let signalHeld!: () => void;
    const held = new Promise<void>((resolve) => { signalHeld = resolve; });
    let release!: () => void;
    const released = new Promise<void>((resolve) => { release = resolve; });
    const writeReceipt = async (path: string, value: unknown, mode?: number): Promise<void> => {
      // The real durable write, with only the completed receipt's publication
      // held open, so its temporary exists on disk while the prune below runs.
      if ((value as { status: string }).status !== "completed") {
        await durableAtomicWriteJson(path, value, mode);
        return;
      }
      await durableAtomicWriteJson(path, value, mode, {
        mkdir,
        open,
        rm,
        rename: async (from: string, to: string) => {
          signalHeld();
          await released;
          await rename(from, to);
        },
      });
    };
    const store = new CommandReceiptStore(root, writeReceipt);
    const operation = vi.fn(async () => ({ accepted: true }));

    const command = store.execute("device", "session.prompt", "in-flight-write", operation);
    await held;
    // Receipt writes run outside `inventoryMutex`, so a prune in another
    // command's admission can meet this write's temporary. Removing it fails
    // the rename with ENOENT after the operation already ran, and the receipt
    // stays pending forever.
    await store.prune();
    release();

    await expect(command).resolves.toEqual({ accepted: true });
    expect(operation).toHaveBeenCalledTimes(1);
    await expect(store.status("device", "session.prompt", "in-flight-write"))
      .resolves.toEqual({ status: "completed", result: { accepted: true } });
    expect(await receiptFiles(root)).toHaveLength(1);
  });

  it("does not double-count a receipt whose pending write spans a directory rescan", async () => {
    const root = await temporaryRoot("tron-receipts-pending-rebuild-");
    await seededBackdatedReceipt(root, "backdated-seed");
    let signalPublished!: () => void;
    const published = new Promise<void>((resolve) => { signalPublished = resolve; });
    let release!: () => void;
    const released = new Promise<void>((resolve) => { release = resolve; });
    let signalSecondAdmitted!: () => void;
    const secondAdmitted = new Promise<void>((resolve) => { signalSecondAdmitted = resolve; });
    const commandIdOf = (value: unknown): string | undefined => (value as { commandId?: string }).commandId;
    const statusOf = (value: unknown): string => (value as { status: string }).status;
    const writeReceipt = async (path: string, value: unknown, mode?: number): Promise<void> => {
      if (commandIdOf(value) === "pending-rebuild-first" && statusOf(value) === "pending") {
        // Publish the pending receipt, then hold before reporting success so
        // the second admission's rescan meets this receipt on disk.
        await durableAtomicWriteJson(path, value, mode, {
          mkdir,
          open,
          rm,
          rename: async (from: string, to: string) => {
            await rename(from, to);
            signalPublished();
            await released;
          },
        });
        return;
      }
      if (commandIdOf(value) === "pending-rebuild-second" && statusOf(value) === "pending") {
        // This write starts only after that admission finished its rescan.
        signalSecondAdmitted();
      }
      await durableAtomicWriteJson(path, value, mode);
    };
    // Room for one receipt beyond the two that finish here: a store that adds
    // the rescanned receipt a second time reports three and rejects the third
    // command with a false `busy`.
    const store = new CommandReceiptStore(root, writeReceipt, { maximumEntries: 3 });
    const operation = vi.fn(async () => ({ accepted: true }));

    const first = store.execute("device", "session.prompt", "pending-rebuild-first", operation);
    await published;
    await store.prune(0);
    const second = store.execute("device", "session.prompt", "pending-rebuild-second", operation);
    await secondAdmitted;
    release();
    await expect(Promise.all([first, second])).resolves.toEqual([{ accepted: true }, { accepted: true }]);

    expect(await receiptFiles(root)).toHaveLength(2);
    const third = vi.fn(async () => ({ accepted: true }));
    await expect(store.execute("device", "session.prompt", "pending-rebuild-third", third))
      .resolves.toEqual({ accepted: true });
    expect(third).toHaveBeenCalledTimes(1);
  });

  it("rescans the receipt directory once per prune invalidation while writes overlap", async () => {
    const root = await temporaryRoot("tron-receipts-single-rescan-");
    await mkdir(join(root, "gateway", "command-receipts"), { recursive: true });

    const overlapping = ["overlap-one", "overlap-two", "overlap-three", "overlap-four"];
    let held = 0;
    let releaseHeld!: () => void;
    const heldWritesReleased = new Promise<void>((resolve) => { releaseHeld = resolve; });
    let signalAllHeld!: () => void;
    const allHeld = new Promise<void>((resolve) => { signalAllHeld = resolve; });
    const writeReceipt = async (path: string, value: unknown, mode?: number): Promise<void> => {
      // Hold the pending writes of the overlapping commands, so their receipt
      // publications all span the rescan below. The warm-up command's own
      // pending write is released immediately.
      const status = (value as { status: string }).status;
      if (status === "pending" && overlapping.includes((value as { commandId: string }).commandId)) {
        held += 1;
        if (held === overlapping.length) signalAllHeld();
        await heldWritesReleased;
      }
      await durableAtomicWriteJson(path, value, mode);
    };
    const store = new CommandReceiptStore(root, writeReceipt);
    const operation = async () => ({ accepted: true });

    // Warm the cache. The first admission also runs the interval prune, so the
    // crash leftover below is planted after it and then survives every
    // admission until the explicit prune, because those return early until the
    // interval passes.
    await store.execute("device", "session.prompt", "overlap-warm", operation);
    // A crash leftover whose command key holds no lane. Removing it is the one
    // change that discards the cached totals.
    await writeFile(
      join(root, "gateway", "command-receipts", `${"z".repeat(43)}.json.123.123456789abc.tmp`),
      "interrupted write",
    );
    const writes = overlapping.map((commandId) => store.execute("device", "session.prompt", commandId, operation));
    await allHeld;

    await store.prune();
    const scansBefore = directoryScans.readdir;

    // The first admission after the invalidation reconciles the totals while
    // all four writes are in flight. Those writes then land their accounting on
    // the reconciled totals; a store that discarded them instead would make
    // this admission and the next one scan the directory again.
    await store.execute("device", "session.prompt", "overlap-five", operation);
    releaseHeld();
    await Promise.all(writes);
    await store.execute("device", "session.prompt", "overlap-six", operation);

    expect(directoryScans.readdir - scansBefore).toBe(1);
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
    const store = new CommandReceiptStore(root, durableAtomicWriteJson, { maximumAgeMs: 0 });
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
    const store = new CommandReceiptStore(root, durableAtomicWriteJson, limits);
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
    const store = new CommandReceiptStore(root, durableAtomicWriteJson, {
      maximumEntries: 1,
      maximumAggregateBytes: 2 * 1_048_576,
    });

    await expect(store.execute("device", "session.prompt", "first-command", async () => ({ accepted: true })))
      .resolves.toEqual({ accepted: true });
    expect(await receiptFiles(root)).toHaveLength(1);
  });

  it("expires completed editor updates quickly without shortening other receipt retention", async () => {
    const root = await temporaryRoot("tron-receipts-editor-expiry-");
    const store = new CommandReceiptStore(root, durableAtomicWriteJson, {
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
      await durableAtomicWriteJson(path, value, mode);
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
