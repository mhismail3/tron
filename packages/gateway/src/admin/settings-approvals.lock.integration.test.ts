import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { it, onTestFinished } from "vitest";
import { countRandomUUID } from "../../test-support/fixed-recording.js";
import { storePathLock } from "../../test-support/store-path-lock.js";
import { APPROVAL_TTL_MS, SettingsApprovals, type ApprovalRequest, type PendingChange } from "../kernel/settings/settings-approvals.js";
import type { SettingsTarget } from "../kernel/settings/tool-contract.js";

/**
 * `gateway/admin` mutation-path lock for the settings approvals store (plan §6.5 V4,
 * §6.6; test-support/store-path-lock.ts): create, supersede, settle, expire and
 * take-outcomes, their refusals, and the exact `approvals.json` each commits. Request
 * ids are counted, the clock is fixed.
 */
it("settings-approvals-paths: create, supersede, settle, expire, take outcomes and admission", async () => {
  const log = await storePathLock({ module: "gateway/admin", name: "settings-approvals-paths", testFileUrl: import.meta.url, owned: "gateway/settings/approvals.json" });
  onTestFinished(countRandomUUID());
  const approvals = new SettingsApprovals(log.home);
  const mac: SettingsTarget = { kind: "global" };
  const change = (key: string, after: unknown): PendingChange => ({
    changeId: `change-${key}`, key, layer: "global", op: "set", before: false, after, tier: "approve",
    tierBasis: { direction: "widen", floor: "approve", floorSource: "code", web: false, risk: null },
  });
  const create = (sessionId: string, target: SettingsTarget, ...changes: PendingChange[]) =>
    approvals.create({ target, actor: { kind: "agent", id: sessionId, sessionId }, reason: `for ${sessionId}`, changes }, new Date());
  const ids: string[] = [];
  const created = (label: string, sessionId: string, target: SettingsTarget, ...changes: PendingChange[]) => log.step(label, async () => {
    const result = await create(sessionId, target, ...changes);
    ids.push(result.request.requestId);
    return result;
  }, "result");

  await log.step("pending on a missing store is empty", () => approvals.pending());
  await created("create r1 (s1, a.x on mac)", "s1", mac, change("a.x", true));
  log.advance(1_000);
  await created("create r2 (s1, b.y on mac)", "s1", mac, change("b.y", 1));
  log.advance(1_000);
  await created("create r3 (s2, a.x on mac) supersedes r1", "s2", mac, change("a.x", false));
  log.advance(1_000);
  await created("create r4 (s2, a.x on session s9) supersedes nothing", "s2", { kind: "session", sessionId: "s9" }, change("a.x", true));
  await log.step("get r1 and a missing request", async () => ({ r1: await approvals.get(ids[0]!), missing: await approvals.get("missing") ?? null }));
  await log.step("pending lists r2, r3 and r4", () => approvals.pending());
  log.advance(1_000);
  await log.step("settle r2 declined", () => approvals.settle(ids[1]!, "declined", new Date()), "result");
  await log.step("settle r2 again is refused", () => approvals.settle(ids[1]!, "approved", new Date()), "refused");
  await log.step("settle a missing request is refused", () => approvals.settle("missing", "approved", new Date()), "refused");
  await log.step("settle r4 approved is told and dropped", () => approvals.settle(ids[3]!, "approved", new Date()), "result");
  await log.step("settle r3 failed keeps its failure", () => approvals.settle(ids[2]!, "failed", new Date(), "boom"), "result");
  await log.step("take s1 outcomes (superseded r1, declined r2)", () => approvals.takeOutcomes("s1"));
  await log.step("take s1 outcomes again is empty", () => approvals.takeOutcomes("s1"));
  await log.step("take s2 outcomes (failed r3)", () => approvals.takeOutcomes("s2"));
  await created("create r5 (s3)", "s3", mac, change("c.z", "on"));
  await log.step("take s3 outcomes while r5 is pending is empty", () => approvals.takeOutcomes("s3"));
  await log.step("settle r5 declined", () => approvals.settle(ids[4]!, "declined", new Date()), "result");
  await log.step("take s3 outcomes (declined r5, the only untold)", () => approvals.takeOutcomes("s3"));

  await created("create r6 (s5)", "s5", mac, change("e.e", 1));
  log.advance(APPROVAL_TTL_MS / 2);
  await created("create r7 (s5)", "s5", mac, change("f.f", 1));
  log.advance(APPROVAL_TTL_MS / 2 - 1);
  await log.step("expire one millisecond early expires nothing", () => approvals.expire(new Date()));
  log.advance(1);
  await log.step("expire at r6's deadline expires r6 only", () => approvals.expire(new Date()));
  await log.step("take s5 outcomes (expired r6)", () => approvals.takeOutcomes("s5"));

  // Hand-written state: a decided and told request any write would drop, so a step
  // that must not write leaves it in the recorded file.
  const path = join(log.home, "gateway", "settings", "approvals.json");
  const request = (requestId: string, sessionId: string, status: ApprovalRequest["status"], extra: Partial<ApprovalRequest> = {}): ApprovalRequest => ({
    requestId, createdAt: new Date().toISOString(), expiresAt: new Date(Date.now() + APPROVAL_TTL_MS).toISOString(), target: mac,
    actor: { kind: "agent", id: sessionId, sessionId }, changes: [change(`hand.${requestId}`, 1)], digest: "d".repeat(64), status, ...extra,
  });
  await log.step("write a hand-made store with a told request", async () => {
    await writeFile(path, JSON.stringify({ version: 1, requests: [
      request("h-told", "s6", "declined", { told: true, decidedAt: new Date().toISOString(), expiresAt: "2025-01-01T00:00:00.000Z" }),
      request("h-pending", "s6", "pending"),
      request("h-untold", "s7", "declined", { decidedAt: new Date().toISOString() }),
    ] }));
  });
  await log.step("expire with nothing due does not write", () => approvals.expire(new Date()));
  await log.step("take outcomes of a session with none does not write", () => approvals.takeOutcomes("nobody"));
  await log.step("take s6 outcomes with only a pending request does not write", () => approvals.takeOutcomes("s6"));
  await log.step("take s7 outcomes rewrites the store, dropping every told request (s6's too)", () => approvals.takeOutcomes("s7"));

  await log.step("write a version 2 store", () => writeFile(path, JSON.stringify({ version: 2, requests: [] })));
  await log.step("read of version 2 is refused", () => approvals.pending(), "refused");
  await log.step("create on version 2 is refused", () => create("s1", mac, change("a.x", 1)), "refused");
  await log.step("write requests that are not a list", () => writeFile(path, JSON.stringify({ version: 1, requests: {} })));
  await log.step("read of non-list requests is refused", () => approvals.pending(), "refused");
  await log.step("create on non-list requests is refused", () => create("s1", mac, change("a.x", 1)), "refused");

  // The open-request bound, on a separate home so its hundred requests stay out of the trace.
  const flood = new SettingsApprovals(join(log.home, "flood"));
  await mkdir(join(log.home, "flood", "gateway", "settings"), { recursive: true });
  await writeFile(flood.path, JSON.stringify({ version: 1, requests: Array.from({ length: 100 }, (_v, index) => request(`f-${index}`, "s8", "pending")) }));
  await log.step("a hundred open requests refuse another as busy", () => flood.create({ target: mac, actor: { kind: "agent", id: "s8", sessionId: "s8" }, changes: [change("g.g", 1)] }, new Date()), "refused");
  await log.finish();
});
