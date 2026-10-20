import { createHash } from "node:crypto";
import { mkdir, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { it } from "vitest";
import { GatewayError } from "../errors.js";
import { storePathLock } from "../../test-support/store-path-lock.js";
import { durableAtomicWriteJson } from "../util/durable-json.js";
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
    const { durableAtomicWriteJson } = await import("../util/durable-json.js");
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

/**
 * The receipt store's accounting under concurrency: capacity bounds, an inventory
 * rebuild that lands inside another command's pending or completed write window, and
 * an early prompt response whose lane must
 * outlive the response. Each window is opened from inside the receipt writer,
 * and its outcome is visible only through admission, so the steps pin what each
 * command was told and whether its operation ran.
 */
it("command-receipt-concurrency: bounds, rebuild windows and lane lifetimes", async () => {
  const log = await storePathLock({ module: "gateway/transport", name: "command-receipt-concurrency", testFileUrl: import.meta.url, owned: "gateway/command-receipts" });
  const phone = "device:lock-phone";
  const receiptBytes = 1_048_576 + 4 * 1_024;
  const directory = join(log.home, "gateway", "command-receipts");
  let calls = 0;
  const run = (result: unknown) => async () => { calls += 1; return result as never; };
  const counted = async (work: () => Promise<unknown>) => { const before = calls; const result = await work(); return { result, ran: calls - before }; };
  const outcome = async (work: () => Promise<unknown>) => {
    try { return { result: await work() }; } catch (error) { return { refused: (error as Error).message, code: (error as GatewayError).code ?? null }; }
  };

  for (const [label, capacity, expected] of [
    ["an aggregate below one receipt is refused", { maximumAggregateBytes: receiptBytes - 1 }, "refused"],
    ["an aggregate of exactly one receipt is accepted", { maximumAggregateBytes: receiptBytes }, "result"],
    ["a fractional aggregate is refused", { maximumAggregateBytes: receiptBytes + 0.5 }, "refused"],
    ["a negative age is refused", { maximumAgeMs: -1 }, "refused"],
    ["a zero age is accepted", { maximumAgeMs: 0 }, "result"],
    ["a fractional age is refused", { maximumAgeMs: 0.5 }, "refused"],
    ["a fractional entry count is refused", { maximumEntries: 1.5 }, "refused"],
  ] as const) await log.step(label, () => { new CommandReceiptStore(log.home, undefined, capacity); return capacity; }, expected);
  await log.step("prune before any receipt exists", () => new CommandReceiptStore(log.home).prune(), "result");

  // The writer runs `during` once, right after the named receipt reached the disk.
  let during: { status: string; run: () => Promise<void> } | undefined;
  const writer = async (path: string, value: unknown, mode?: number) => {
    await durableAtomicWriteJson(path, value, mode);
    const hook = during;
    if (hook && (value as { status?: unknown }).status === hook.status) { during = undefined; await hook.run(); }
  };

  // Pending window: room for one in-flight receipt plus 100 bytes, so a rebuild that
  // counted the published but unaccounted pending receipt would refuse the next command.
  let store = new CommandReceiptStore(log.home, writer, { maximumAggregateBytes: 2 * receiptBytes + 100, maximumAgeMs: 60_000 });
  await log.step("a receipt that will expire", () => counted(() => store.execute(phone, "session.rename", "window-0001", run({ first: true }))));
  log.advance(2 * 60_000);
  let inside: unknown;
  during = { status: "pending", run: async () => { inside = await outcome(() => counted(() => store.execute(phone, "session.rename", "window-0003", run({ inside: true })))); } };
  await log.step("a rebuild inside another command's pending write admits the next command", async () =>
    ({ outer: await counted(() => store.execute(phone, "session.rename", "window-0002", run({ outer: true }))), inside }));
  await store.dispose();

  // Completed window: the rebuild credits the pending size, not the larger completed
  // file, and the completion's accounting then counts both receipts exactly once.
  await rm(directory, { recursive: true, force: true });
  store = new CommandReceiptStore(log.home, writer, { maximumEntries: 2, maximumAggregateBytes: 2 * receiptBytes + 600, maximumAgeMs: 60_000 });
  await log.step("a large receipt that will expire", () => counted(() => store.execute(phone, "session.rename", "window-0101", run({ text: "x".repeat(600) }))));
  log.advance(2 * 60_000);
  during = { status: "completed", run: async () => { inside = await outcome(() => counted(() => store.execute(phone, "session.rename", "window-0103", run({ inside: true })))); } };
  await log.step("a rebuild inside another command's completed write admits the next command", async () =>
    ({ outer: await counted(() => store.execute(phone, "session.rename", "window-0102", run({ text: "y".repeat(1_000) }))), inside }));
  await log.step("both receipts are then counted, so a third command waits for capacity", () => store.execute(phone, "session.rename", "window-0104", run({})), "refused");
  await store.dispose();

  // An early prompt response: the lane outlives the response until the completed
  // receipt is durable, so a duplicate waits for it and replays.
  await rm(directory, { recursive: true, force: true });
  let open!: () => void;
  const gate = new Promise<void>((resolve) => { open = resolve; });
  store = new CommandReceiptStore(log.home, async (path, value, mode) => {
    if ((value as { status?: unknown }).status === "completed") await gate;
    await durableAtomicWriteJson(path, value, mode);
  });
  await log.step("a duplicate prompt sent before the first one's completion is durable replays it", async () => {
    const before = calls;
    const first = await store.execute(phone, "session.prompt", "prompt-0101", run({ accepted: 1 }), { respondBeforeCompletion: true });
    const duplicate = outcome(() => store.execute(phone, "session.prompt", "prompt-0101", run({ accepted: 2 }), { respondBeforeCompletion: true }));
    open();
    return { first, duplicate: await duplicate, ran: calls - before };
  });
  // A receipt stored under this command's name but naming another command is never replayed or overwritten.
  const identityHash = createHash("sha256").update(phone).digest("base64url");
  const key = createHash("sha256").update(identityHash).update("\0").update("session.rename").update("\0").update("mismatch-0001").digest("base64url");
  await writeFile(join(directory, `${key}.json`), JSON.stringify({ version: 1, identityHash, commandId: "mismatch-0002",
    method: "session.rename", status: "pending", createdAt: "2026-01-01T00:00:00.000Z" }));
  await log.step("execute over a receipt for another command is refused without running", () =>
    counted(() => store.execute(phone, "session.rename", "mismatch-0001", run({}))), "refused");
  // The same under a receipt that names another method or identity: each field alone is checked,
  // by the status read and by execution.
  for (const [commandId, forged] of [["mismatch-0003", { method: "session.archive" }], ["mismatch-0004", { identityHash: "B".repeat(43) }]] as const) {
    const name = createHash("sha256").update(identityHash).update("\0").update("session.rename").update("\0").update(commandId).digest("base64url");
    await writeFile(join(directory, `${name}.json`), JSON.stringify({ version: 1, identityHash, commandId,
      method: "session.rename", status: "completed", createdAt: "2026-01-01T00:00:00.000Z", result: { replayed: true }, ...forged }));
    await log.step(`status of a receipt naming another ${Object.keys(forged)[0]} is refused`, () => store.status(phone, "session.rename", commandId), "refused");
    await log.step(`execute over a receipt naming another ${Object.keys(forged)[0]} is refused without running`, () =>
      counted(() => store.execute(phone, "session.rename", commandId, run({}))), "refused");
  }
  await store.dispose();
  await log.finish();
});
