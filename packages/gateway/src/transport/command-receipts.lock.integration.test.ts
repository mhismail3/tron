import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it, onTestFinished, vi } from "vitest";
import { GatewayError } from "../errors.js";
import { storePathLock } from "../../test-support/store-path-lock.js";
import { durableAtomicWriteJson } from "../foundation/durable-json.js";
import { CommandReceiptStore } from "./command-receipts.js";

/**
 * `gateway/transport` mutation-path lock for command receipts (plan §6.5 V4, §6.6;
 * test-support/store-path-lock.ts): fresh execution, replay, definitive and uncertain
 * failures, route bindings, early prompt responses, bounds, capacity, expiry, malformed
 * evidence and shutdown, each with the exact receipt files it leaves.
 */
it("command-receipt-paths: execute, replay, fence, bound, prune and dispose", async () => {
  const log = await storePathLock({ module: "gateway/transport", name: "command-receipt-paths", testFileUrl: import.meta.url, owned: "gateway/command-receipts" });
  const phone = "device:lock-phone";
  const other = "device:lock-tablet";
  let calls = 0;
  const run = (result: unknown) => async () => { calls += 1; return result as never; };
  const fail = (error: Error) => async () => { calls += 1; throw error; };
  const uncertain = () => new GatewayError("conflict", "effect may have applied", false, { outcomeUnknown: true });
  let store = new CommandReceiptStore(log.home);
  const counted = async (work: () => Promise<unknown>) => { const before = calls; const result = await work(); return { result, ran: calls - before }; };

  await log.step("refuse an unstable command id", () => store.execute(phone, "session.rename", "short", run({ ok: true })), "refused");
  await log.step("status of a missing receipt", () => store.status(phone, "session.rename", "rename-0001"));
  await log.step("execute fresh", () => counted(() => store.execute(phone, "session.rename", "rename-0001", run({ updated: true }))));
  await log.step("replay returns the stored result without running", () => counted(() => store.execute(phone, "session.rename", "rename-0001", run({ updated: false }))));
  await log.step("status of a completed receipt", () => store.status(phone, "session.rename", "rename-0001"));
  await log.step("the same command id from another identity runs", () => counted(() => store.execute(other, "session.rename", "rename-0001", run({ updated: "other" }))));
  await log.step("the same command id for another method runs", () => counted(() => store.execute(phone, "session.archive", "rename-0001", run(null))));
  await log.step("a definitive rejection leaves no receipt", () => store.execute(phone, "session.delete", "delete-0001", fail(new GatewayError("not_found", "no such session"))));
  await log.step("the rejected command may run again", () => counted(() => store.execute(phone, "session.delete", "delete-0001", run({ deleted: true }))));
  await log.step("an uncertain failure keeps a pending fence", () => store.execute(phone, "session.fork", "fork-0001", fail(uncertain())));
  await log.step("status of the pending fence", () => store.status(phone, "session.fork", "fork-0001"));
  await log.step("the fenced command is refused without running", () => counted(() => store.execute(phone, "session.fork", "fork-0001", run({ forked: true }))), "refused");
  await log.step("operations run so far", () => calls);
  const routes: string[] = [];
  const bound = { onRouteBound: (category: string) => { routes.push(category); }, resolveBinding: () => ({ homeId: "home-1", bindingRevision: 2, physicalSessionId: "chapter-1" }) };
  await log.step("a bound command records its route", async () => ({ result: await store.execute(phone, "home.steerTask", "steer-0001", run({ steered: true }), bound), routes: [...routes] }));
  await log.step("its replay reports a replayed route", async () => ({ result: await store.execute(phone, "home.steerTask", "steer-0001", run({ steered: false }), bound), routes: [...routes] }));
  await log.step("an early response is refused for a non-prompt method", () => store.execute(phone, "session.rename", "early-0001", run({}), { respondBeforeCompletion: true }), "refused");
  const completions: Promise<void>[] = [];
  await log.step("a prompt answers before its completion is durable", async () => {
    const result = await store.execute(phone, "session.prompt", "prompt-0001", run({ accepted: true }), { respondBeforeCompletion: true, onCompletion: (completion) => { completions.push(completion); } });
    await Promise.all(completions);
    return { result, completions: completions.length };
  });
  await log.step("an oversized result is refused and stays fenced", () => store.execute(phone, "session.export", "export-0001", run({ text: "x".repeat(1_100_000) })), "refused");
  await log.step("status of the oversized command", () => store.status(phone, "session.export", "export-0001"));
  await log.step("an editor update", () => store.execute(phone, "extension.editor.update", "editor-0001", run({ saved: true })));
  await mkdir(join(log.home, "gateway", "command-receipts"), { recursive: true });
  await writeFile(join(log.home, "gateway", "command-receipts", `${"A".repeat(43)}.json.123.0123456789ab.tmp`), "{");
  log.advance(11 * 60_000);
  await log.step("prune after eleven minutes drops the editor update and the crash temporary", () => store.prune());
  log.advance(24 * 60 * 60_000);
  await log.step("prune after a day drops completed receipts and keeps pending fences", () => store.prune());
  await log.step("a pruned command runs again", () => counted(() => store.execute(phone, "session.rename", "rename-0001", run({ updated: "again" }))));
  await store.dispose();
  store = new CommandReceiptStore(log.home, undefined, { maximumEntries: 4, maximumAgeMs: 60_000 });
  await log.step("a full store refuses new commands while fences remain", async () => {
    await store.execute(phone, "session.rename", "fill-0001", run({}));
    return store.execute(phone, "session.rename", "fill-0002", run({}));
  });
  log.advance(2 * 60_000);
  await log.step("an expired receipt is pruned at the capacity boundary to admit a command", () => counted(() => store.execute(phone, "session.rename", "fill-0003", run({ admitted: true }))));
  await log.step("an invalid capacity is refused", () => new CommandReceiptStore(log.home, undefined, { maximumEntries: 0 }), "refused");
  const forged = async (label: string, method: string, commandId: string, content: string) => log.step(label, async () => {
    const { createHash } = await import("node:crypto");
    const identityHash = createHash("sha256").update(phone).digest("base64url");
    const key = createHash("sha256").update(identityHash).update("\0").update(method).update("\0").update(commandId).digest("base64url");
    await writeFile(join(log.home, "gateway", "command-receipts", `${key}.json`), content.replaceAll("<identity>", identityHash));
    return store.status(phone, method, commandId);
  }, label.startsWith("admit") ? "result" : "refused");
  await forged("refuse an empty receipt", "session.rename", "empty-0001", "");
  await forged("refuse a malformed receipt", "session.rename", "broken-0001", "{");
  await forged("refuse a receipt with an unknown key", "session.rename", "extra-0001",
    JSON.stringify({ version: 1, identityHash: "<identity>", commandId: "extra-0001", method: "session.rename", status: "pending", createdAt: "2026-01-01T00:00:00.000Z", note: 1 }));
  await forged("refuse a receipt for another command", "session.rename", "other-0001",
    JSON.stringify({ version: 1, identityHash: "<identity>", commandId: "other-0002", method: "session.rename", status: "pending", createdAt: "2026-01-01T00:00:00.000Z" }));
  await forged("refuse a completed receipt without a result", "session.rename", "noresult-0001",
    JSON.stringify({ version: 1, identityHash: "<identity>", commandId: "noresult-0001", method: "session.rename", status: "completed", createdAt: "2026-01-01T00:00:00.000Z" }));
  await forged("refuse a version 2 receipt without a binding", "session.rename", "nobind-0001",
    JSON.stringify({ version: 2, identityHash: "<identity>", commandId: "nobind-0001", method: "session.rename", status: "pending", createdAt: "2026-01-01T00:00:00.000Z" }));
  const receipt = (commandId: string, extra: Record<string, unknown>) => JSON.stringify({ version: 2, identityHash: "<identity>", commandId,
    method: "session.rename", status: "pending", createdAt: "2026-01-01T00:00:00.000Z", ...extra });
  const binding = { homeId: "home-1", bindingRevision: 1, physicalSessionId: "chapter-1" };
  await forged("refuse a null receipt", "session.rename", "null-0001", "null");
  await forged("refuse an array receipt", "session.rename", "array-0001", "[]");
  await forged("admit a version 2 receipt with a binding", "session.rename", "bound-0001", receipt("bound-0001", { binding }));
  await forged("refuse a null binding", "session.rename", "bind-0001", receipt("bind-0001", { binding: null }));
  await forged("refuse an array binding", "session.rename", "bind-0002", receipt("bind-0002", { binding: [] }));
  await forged("refuse an empty home id", "session.rename", "bind-0003", receipt("bind-0003", { binding: { ...binding, homeId: "" } }));
  await forged("refuse a long home id", "session.rename", "bind-0004", receipt("bind-0004", { binding: { ...binding, homeId: "h".repeat(201) } }));
  await forged("refuse a zero binding revision", "session.rename", "bind-0005", receipt("bind-0005", { binding: { ...binding, bindingRevision: 0 } }));
  await forged("refuse a fractional binding revision", "session.rename", "bind-0006", receipt("bind-0006", { binding: { ...binding, bindingRevision: 1.5 } }));
  await forged("refuse an empty physical session", "session.rename", "bind-0007", receipt("bind-0007", { binding: { ...binding, physicalSessionId: "" } }));
  await forged("refuse a long physical session", "session.rename", "bind-0008", receipt("bind-0008", { binding: { ...binding, physicalSessionId: "p".repeat(201) } }));
  await forged("refuse a binding with an extra key", "session.rename", "bind-0009", receipt("bind-0009", { binding: { ...binding, chapter: 1 } }));
  await forged("refuse a version 1 receipt with a binding", "session.rename", "bind-0010", receipt("bind-0010", { version: 1, binding }));
  await forged("refuse an unknown version", "session.rename", "bind-0011", receipt("bind-0011", { version: 3 }));
  await forged("refuse a bad identity hash", "session.rename", "hash-0001", receipt("hash-0001", { version: 1, identityHash: "short" }));
  await forged("refuse an unknown status", "session.rename", "status-0001", receipt("status-0001", { version: 1, status: "running" }));
  await forged("refuse a pending receipt with a result", "session.rename", "result-0001", receipt("result-0001", { version: 1, result: 1 }));
  await forged("refuse a bad creation time", "session.rename", "time-0001", receipt("time-0001", { version: 1, createdAt: "yesterday" }));
  await log.step("execute over a malformed receipt is refused without running", () => counted(() => store.execute(phone, "session.rename", "broken-0001", run({}))), "refused");
  await log.step("operations run so far", () => calls);
  await store.dispose();
  await log.step("a disposed store refuses work", () => store.execute(phone, "session.rename", "late-0001", run({})), "refused");
  log.advance(60 * 60_000);
  // One receipt's worth of aggregate bytes: a second receipt only fits once the first expires.
  let failWrite: "pending" | "completed" | undefined;
  const writer = async (path: string, value: unknown, mode?: number) => {
    if (failWrite !== undefined && (value as { status?: unknown }).status === failWrite) {
      failWrite = undefined;
      throw new Error(`injected ${(value as { status: string }).status} receipt write failure`);
    }
    const { durableAtomicWriteJson } = await import("../foundation/durable-json.js");
    await durableAtomicWriteJson(path, value, mode);
    const hook = afterCompleted;
    if (hook && (value as { status?: unknown }).status === "completed") { afterCompleted = undefined; await hook(); }
  };
  let afterCompleted: (() => Promise<void>) | undefined;
  const { rm } = await import("node:fs/promises");
  await rm(join(log.home, "gateway", "command-receipts"), { recursive: true, force: true });
  store = new CommandReceiptStore(log.home, writer, { maximumAggregateBytes: 1_048_576 + 4 * 1_024, maximumAgeMs: 60_000 });
  failWrite = "pending";
  await log.step("a failed pending write leaves no receipt and no reservation", () => store.execute(phone, "session.rename", "bytes-0001", run({})));
  await log.step("one receipt fits the aggregate bytes", () => counted(() => store.execute(phone, "session.rename", "bytes-0002", run({ first: true }))));
  await log.step("a second receipt exceeds them", () => store.execute(phone, "session.rename", "bytes-0003", run({})));
  log.advance(2 * 60_000);
  await log.step("an explicit prune frees the bytes", () => store.prune());
  await log.step("the second receipt then fits", () => counted(() => store.execute(phone, "session.rename", "bytes-0003", run({ second: true }))));
  log.advance(2 * 60_000);
  await store.prune();
  failWrite = "completed";
  await log.step("a failed completed write keeps the pending fence", () => store.execute(phone, "session.rename", "bytes-0004", run({})));
  await log.step("status after the failed completed write", () => store.status(phone, "session.rename", "bytes-0004"));
  await store.dispose();
  await rm(join(log.home, "gateway", "command-receipts"), { recursive: true, force: true });
  store = new CommandReceiptStore(log.home, writer);
  // A prune that lands while the command still owns its lane must keep the receipt the
  // command's duplicates are about to read.
  afterCompleted = async () => { log.advance(1_000); await store.prune(0); };
  await log.step("a prune during the command's own completion keeps its receipt", () => counted(() => store.execute(phone, "session.rename", "lane-0001", run({ once: true }))));
  await log.step("so its duplicate replays instead of running", () => counted(() => store.execute(phone, "session.rename", "lane-0001", run({ twice: true }))));
  await store.dispose();
  await log.finish();
});

const EPOCH = Date.parse("2026-01-01T00:00:00.000Z");
const PHONE = "device:lock-phone";
const RECEIPT_BYTES = 1_048_576 + 4 * 1_024;

/**
 * A disposable home under a fixed clock (receipts carry `createdAt`, so expiry
 * follows `advance`). `receipts()` reads every persisted receipt back by command
 * id; the on-disk layout itself is pinned by `command-receipt-paths` and the
 * `store-command-receipts` corpus.
 */
async function receiptHome() {
  const home = await mkdtemp(join(tmpdir(), "tron-command-receipts-"));
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(EPOCH);
  onTestFinished(async () => { vi.useRealTimers(); await rm(home, { recursive: true, force: true }); });
  const directory = join(home, "gateway", "command-receipts");
  let calls = 0;
  return {
    home, directory,
    advance: (ms: number) => { vi.setSystemTime(Date.now() + ms); },
    run: (result: unknown) => async () => { calls += 1; return result as never; },
    fail: (error: Error) => async () => { calls += 1; throw error; },
    /** The operations run (`ran`) while `work` was outstanding. */
    async counted(work: () => Promise<unknown>) { const before = calls; const result = await work(); return { result, ran: calls - before }; },
    async receipts(): Promise<Record<string, { method: string; status: string; createdAt: string; result?: unknown }>> {
      const names = await readdir(directory).catch((error: NodeJS.ErrnoException) => { if (error.code === "ENOENT") return []; throw error; });
      const receipts: Record<string, { method: string; status: string; createdAt: string; result?: unknown }> = {};
      for (const name of names) {
        expect(name, "only receipt files remain").toMatch(/^[A-Za-z0-9_-]{43}\.json$/u);
        const { commandId, method, status, createdAt, result } = JSON.parse(await readFile(join(directory, name), "utf8"));
        receipts[commandId] = { method, status, createdAt, ...(result === undefined ? {} : { result }) };
      }
      return receipts;
    },
  };
}

/** What `work` was told: its result, or its refusal's message, code, retryability and details. */
async function outcome(work: () => Promise<unknown>) {
  try { return { result: await work() }; } catch (error) {
    const { code, retryable, details } = error as GatewayError;
    return { refused: (error as Error).message, code: code ?? null, retryable: retryable ?? null, details: details ?? null };
  }
}

const CAPACITY_FULL = { refused: "Command receipt capacity is full; completed receipts expire, but unresolved outcomes retain replay protection and require operator reconciliation",
  code: "busy", retryable: true, details: null };
const IDENTITY_MISMATCH = { refused: "Idempotency receipt identity mismatch; refresh authoritative state instead of replaying",
  code: "conflict", retryable: false, details: { outcomeUnknown: true } };
const rename = (createdAt: string, result?: unknown) => ({ method: "session.rename", status: "completed", createdAt, ...(result === undefined ? {} : { result }) });

/**
 * The receipt store's accounting under concurrency: capacity bounds, an inventory
 * rebuild that lands inside another command's pending or completed write window, and
 * an early prompt response whose lane must outlive the response. Each window is
 * opened from inside the receipt writer, and its outcome is visible only through
 * admission, so each check names what each command was told and whether its
 * operation ran.
 */
it("command-receipt-concurrency: bounds, rebuild windows and lane lifetimes", async () => {
  const h = await receiptHome();

  for (const capacity of [{ maximumAggregateBytes: RECEIPT_BYTES - 1 }, { maximumAggregateBytes: RECEIPT_BYTES + 0.5 },
    { maximumAgeMs: -1 }, { maximumAgeMs: 0.5 }, { maximumEntries: 1.5 }]) {
    expect(() => new CommandReceiptStore(h.home, undefined, capacity), JSON.stringify(capacity)).toThrow("Invalid command receipt capacity");
  }
  for (const capacity of [{ maximumAggregateBytes: RECEIPT_BYTES }, { maximumAgeMs: 0 }]) {
    expect(() => new CommandReceiptStore(h.home, undefined, capacity), JSON.stringify(capacity)).not.toThrow();
  }
  await expect(new CommandReceiptStore(h.home).prune(), "prune before any receipt exists").resolves.toBeUndefined();
  expect(await h.receipts()).toEqual({});

  // The writer runs `during` once, right after the named receipt reached the disk.
  let during: { status: string; run: () => Promise<void> } | undefined;
  const writer = async (path: string, value: unknown, mode?: number) => {
    await durableAtomicWriteJson(path, value, mode);
    const hook = during;
    if (hook && (value as { status?: unknown }).status === hook.status) { during = undefined; await hook.run(); }
  };

  // Pending window: room for one in-flight receipt plus 100 bytes, so a rebuild that
  // counted the published but unaccounted pending receipt would refuse the next command.
  let store = new CommandReceiptStore(h.home, writer, { maximumAggregateBytes: 2 * RECEIPT_BYTES + 100, maximumAgeMs: 60_000 });
  expect(await h.counted(() => store.execute(PHONE, "session.rename", "window-0001", h.run({ first: true })))).toEqual({ result: { first: true }, ran: 1 });
  h.advance(2 * 60_000);
  let inside: unknown;
  during = { status: "pending", run: async () => { inside = await outcome(() => h.counted(() => store.execute(PHONE, "session.rename", "window-0003", h.run({ inside: true })))); } };
  expect(await h.counted(() => store.execute(PHONE, "session.rename", "window-0002", h.run({ outer: true }))), "the outer command").toEqual({ result: { outer: true }, ran: 2 });
  expect(inside, "a rebuild inside another command's pending write admits the next command").toEqual({ result: { result: { inside: true }, ran: 1 } });
  expect(await h.receipts(), "the expired receipt is pruned").toEqual({
    "window-0002": rename("2026-01-01T00:02:00.000Z", { outer: true }), "window-0003": rename("2026-01-01T00:02:00.000Z", { inside: true }) });
  await store.dispose();

  // Completed window: the rebuild credits the pending size, not the larger completed
  // file, and the completion's accounting then counts both receipts exactly once.
  await rm(h.directory, { recursive: true, force: true });
  store = new CommandReceiptStore(h.home, writer, { maximumEntries: 2, maximumAggregateBytes: 2 * RECEIPT_BYTES + 600, maximumAgeMs: 60_000 });
  const large = { text: "x".repeat(600) };
  expect(await h.counted(() => store.execute(PHONE, "session.rename", "window-0101", h.run(large)))).toEqual({ result: large, ran: 1 });
  h.advance(2 * 60_000);
  during = { status: "completed", run: async () => { inside = await outcome(() => h.counted(() => store.execute(PHONE, "session.rename", "window-0103", h.run({ inside: true })))); } };
  const larger = { text: "y".repeat(1_000) };
  expect(await h.counted(() => store.execute(PHONE, "session.rename", "window-0102", h.run(larger))), "the outer command").toEqual({ result: larger, ran: 2 });
  expect(inside, "a rebuild inside another command's completed write admits the next command").toEqual({ result: { result: { inside: true }, ran: 1 } });
  expect(await outcome(() => store.execute(PHONE, "session.rename", "window-0104", h.run({}))), "both receipts are counted, so a third command waits").toEqual(CAPACITY_FULL);
  expect(await h.receipts()).toEqual({
    "window-0102": rename("2026-01-01T00:04:00.000Z", larger), "window-0103": rename("2026-01-01T00:04:00.000Z", { inside: true }) });
  await store.dispose();

  // An early prompt response: the lane outlives the response until the completed
  // receipt is durable, so a duplicate waits for it and replays.
  await rm(h.directory, { recursive: true, force: true });
  let open!: () => void;
  const gate = new Promise<void>((resolve) => { open = resolve; });
  store = new CommandReceiptStore(h.home, async (path, value, mode) => {
    if ((value as { status?: unknown }).status === "completed") await gate;
    await durableAtomicWriteJson(path, value, mode);
  });
  const prompt = await h.counted(async () => {
    const first = await store.execute(PHONE, "session.prompt", "prompt-0101", h.run({ accepted: 1 }), { respondBeforeCompletion: true });
    const duplicate = outcome(() => store.execute(PHONE, "session.prompt", "prompt-0101", h.run({ accepted: 2 }), { respondBeforeCompletion: true }));
    open();
    return { first, duplicate: await duplicate };
  });
  expect(prompt, "a duplicate prompt sent before the first one's completion is durable replays it")
    .toEqual({ result: { first: { accepted: 1 }, duplicate: { result: { accepted: 1 } } }, ran: 1 });
  const prompted = { "prompt-0101": { method: "session.prompt", status: "completed", createdAt: "2026-01-01T00:04:00.000Z", result: { accepted: 1 } } };
  expect(await h.receipts()).toEqual(prompted);

  // A receipt stored under this command's name but naming another command, method or
  // identity is never replayed or overwritten, by the status read or by execution.
  const identityHash = createHash("sha256").update(PHONE).digest("base64url");
  const forge = async (commandId: string, receipt: Record<string, unknown>) => {
    const key = createHash("sha256").update(identityHash).update("\0").update("session.rename").update("\0").update(commandId).digest("base64url");
    await writeFile(join(h.directory, `${key}.json`), JSON.stringify({ version: 1, identityHash, commandId,
      method: "session.rename", createdAt: "2026-01-01T00:00:00.000Z", ...receipt }));
  };
  await forge("mismatch-0001", { commandId: "mismatch-0002", status: "pending" });
  expect(await outcome(() => h.counted(() => store.execute(PHONE, "session.rename", "mismatch-0001", h.run({})))), "another command id").toEqual(IDENTITY_MISMATCH);
  for (const [commandId, forged] of [["mismatch-0003", { method: "session.archive" }], ["mismatch-0004", { identityHash: "B".repeat(43) }]] as const) {
    await forge(commandId, { status: "completed", result: { replayed: true }, ...forged });
    expect(await outcome(() => store.status(PHONE, "session.rename", commandId)), `status of a receipt naming another ${Object.keys(forged)[0]}`).toEqual(IDENTITY_MISMATCH);
    expect(await outcome(() => h.counted(() => store.execute(PHONE, "session.rename", commandId, h.run({})))), `execute over a receipt naming another ${Object.keys(forged)[0]}`).toEqual(IDENTITY_MISMATCH);
  }
  expect(await h.receipts(), "forged receipts are left untouched").toEqual({ ...prompted,
    "mismatch-0002": { method: "session.rename", status: "pending", createdAt: "2026-01-01T00:00:00.000Z" },
    "mismatch-0003": { method: "session.archive", status: "completed", createdAt: "2026-01-01T00:00:00.000Z", result: { replayed: true } },
    "mismatch-0004": rename("2026-01-01T00:00:00.000Z", { replayed: true }) });
  await store.dispose();
});

/**
 * The three lane windows a concurrent prune or rebuild can land in, each opened
 * deterministically: the async mutex admits in call order, a mutex call takes the
 * lock synchronously when it is free, and an inventory pass waits for file-system
 * I/O, so work queued from a route callback or a few microtasks later is ordered
 * behind it. Only a broken lane makes an outcome timing-sensitive; correct code
 * reaches the same outcome every run.
 */
it("command-receipt-races: lane lifetime, prune and rebuild inside a duplicate's lane", async () => {
  const h = await receiptHome();

  // A lane stays registered while any duplicate holds it. The first command fails
  // definitively while a duplicate waits on its lane; the duplicate then runs, and a
  // third copy sent during its operation must queue behind it and replay, never open
  // a second lane that reads the duplicate's pending receipt as an uncertain fence.
  let store = new CommandReceiptStore(h.home);
  let third: Promise<unknown> | undefined;
  let thirdSettledDuringOperation: boolean | undefined;
  const first = outcome(() => store.execute(PHONE, "session.rename", "race-0001", h.fail(new GatewayError("not_found", "no such session"))));
  const second = h.counted(() => store.execute(PHONE, "session.rename", "race-0001", async () => {
    await h.run(undefined)();
    third = outcome(() => h.counted(() => store.execute(PHONE, "session.rename", "race-0001", h.run({ third: true }))));
    // Correct code cannot settle the third copy before this operation returns.
    thirdSettledDuringOperation = await Promise.race([third.then(() => true),
      new Promise<boolean>((resolve) => { setTimeout(() => resolve(false), 300); })]);
    return { second: true };
  }));
  expect(await first).toEqual({ refused: "no such session", code: "not_found", retryable: false, details: null });
  expect(await second, "the duplicate runs once the definitive failure frees the lane").toEqual({ result: { second: true }, ran: 2 });
  expect(thirdSettledDuringOperation, "a copy sent while the lane's second holder runs waits for it").toBe(false);
  expect(await third, "and replays it").toEqual({ result: { result: { second: true }, ran: 0 } });
  expect(await h.receipts()).toEqual({ "race-0001": rename("2026-01-01T00:00:00.000Z", { second: true }) });
  await store.dispose();

  // A lane that never wrote does not preserve the receipt it replays: a prune that
  // holds the inventory when the duplicate arrives still expires that receipt, so the
  // duplicate runs again instead of replaying it.
  await rm(h.directory, { recursive: true, force: true });
  store = new CommandReceiptStore(h.home);
  expect(await h.counted(() => store.execute(PHONE, "session.rename", "race-0101", h.run({ first: true })))).toEqual({ result: { first: true }, ran: 1 });
  h.advance(1_000);
  const prune = store.prune(0);
  const duplicate = h.counted(() => store.execute(PHONE, "session.rename", "race-0101", h.run({ again: true })));
  await prune;
  expect(await duplicate, "a prune holding the inventory when a duplicate arrives expires its receipt").toEqual({ result: { again: true }, ran: 1 });
  expect(await h.receipts()).toEqual({ "race-0101": rename("2026-01-01T00:00:01.000Z", { again: true }) });
  await store.dispose();

  // A rebuild counts a receipt whose lane has not written: a replaying duplicate's
  // lane, registered while another command's admission rebuilds the inventory, must
  // not hide the receipt it replays. One entry fits, and the kept receipt fills it.
  await rm(h.directory, { recursive: true, force: true });
  store = new CommandReceiptStore(h.home);
  expect(await h.counted(() => store.execute(PHONE, "session.rename", "race-0201", h.run({ kept: true })))).toEqual({ result: { kept: true }, ran: 1 });
  await store.dispose();
  store = new CommandReceiptStore(h.home, undefined, { maximumEntries: 1 });
  let replay: Promise<unknown> | undefined;
  expect(await outcome(() => store.execute(PHONE, "session.rename", "race-0202", h.run({ admitted: true }), {
    resolveBinding: () => {
      // Registered after this command's rebuild is queued, before that rebuild reads the directory.
      replay = (async () => {
        for (let hop = 0; hop < 20; hop += 1) await Promise.resolve();
        return h.counted(() => store.execute(PHONE, "session.rename", "race-0201", h.run({ replayed: false })));
      })();
      return { homeId: "home-1", bindingRevision: 1, physicalSessionId: "chapter-1" };
    },
  })), "a rebuild while a replaying duplicate holds its lane counts its receipt, so the store is full").toEqual(CAPACITY_FULL);
  expect(await replay, "the duplicate replays the kept receipt").toEqual({ result: { kept: true }, ran: 0 });
  expect(await h.receipts()).toEqual({ "race-0201": rename("2026-01-01T00:00:01.000Z", { kept: true }) });
  await store.dispose();
});
