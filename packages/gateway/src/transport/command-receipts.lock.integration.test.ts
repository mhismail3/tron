import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { it } from "vitest";
import { GatewayError } from "../errors.js";
import { storePathLock } from "../../test-support/store-path-lock.js";
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

  await log.step("refuse an unstable command id", () => store.execute(phone, "session.rename", "short", run({ ok: true })));
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
  await log.step("the fenced command is refused without running", () => counted(() => store.execute(phone, "session.fork", "fork-0001", run({ forked: true }))));
  await log.step("operations run so far", () => calls);
  const routes: string[] = [];
  const bound = { onRouteBound: (category: string) => { routes.push(category); }, resolveBinding: () => ({ homeId: "home-1", bindingRevision: 2, physicalSessionId: "chapter-1" }) };
  await log.step("a bound command records its route", async () => ({ result: await store.execute(phone, "home.steerTask", "steer-0001", run({ steered: true }), bound), routes: [...routes] }));
  await log.step("its replay reports a replayed route", async () => ({ result: await store.execute(phone, "home.steerTask", "steer-0001", run({ steered: false }), bound), routes: [...routes] }));
  await log.step("an early response is refused for a non-prompt method", () => store.execute(phone, "session.rename", "early-0001", run({}), { respondBeforeCompletion: true }));
  const completions: Promise<void>[] = [];
  await log.step("a prompt answers before its completion is durable", async () => {
    const result = await store.execute(phone, "session.prompt", "prompt-0001", run({ accepted: true }), { respondBeforeCompletion: true, onCompletion: (completion) => { completions.push(completion); } });
    await Promise.all(completions);
    return { result, completions: completions.length };
  });
  await log.step("an oversized result is refused and stays fenced", () => store.execute(phone, "session.export", "export-0001", run({ text: "x".repeat(1_100_000) })));
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
  await log.step("an invalid capacity is refused", () => new CommandReceiptStore(log.home, undefined, { maximumEntries: 0 }));
  const forged = async (label: string, method: string, commandId: string, content: string) => log.step(label, async () => {
    const { createHash } = await import("node:crypto");
    const identityHash = createHash("sha256").update(phone).digest("base64url");
    const key = createHash("sha256").update(identityHash).update("\0").update(method).update("\0").update(commandId).digest("base64url");
    await writeFile(join(log.home, "gateway", "command-receipts", `${key}.json`), content.replaceAll("<identity>", identityHash));
    return store.status(phone, method, commandId);
  });
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
  await log.step("execute over a malformed receipt is refused without running", () => counted(() => store.execute(phone, "session.rename", "broken-0001", run({}))));
  await log.step("operations run so far", () => calls);
  await store.dispose();
  await log.step("a disposed store refuses work", () => store.execute(phone, "session.rename", "late-0001", run({})));
  await log.finish();
});
