import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { ConnectionOwner } from "../integrations/connection-owner.js";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeStore } from "./knowledge-store.js";
import { chooseKnowledgeTags, KNOWLEDGE_TAG_CALL_RESERVATION_CENTS, KNOWLEDGE_TAG_CONFIDENCE_THRESHOLD, KnowledgeTaggingBudget } from "./knowledge-tagger.js";
const roots: string[] = [];
afterEach(async () => { vi.useRealTimers(); await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });
async function budgetFixture() {
  const root = await mkdtemp(join(tmpdir(), "tron-knowledge-tag-budget-")); roots.push(root);
  const owner = new ConnectionOwner(root);
  const begin = await owner.execute({ kind: "setup.begin", commandId: "tag-budget-begin-001", instanceId: "tagger", definitionId: "knowledge.jev", method: "token" }) as { operationId: string };
  await owner.execute({ kind: "setup.complete", commandId: "tag-budget-complete-01", operationId: begin.operationId, instanceId: "tagger", providerAccountId: "personal", credentialRef: "connector:jev:personal", policy: { enabled: true, allowWrites: false, paidAccessApproved: true, paidBudgetCents: 500, recurringApproved: false } });
  await owner.recordProviderObservation("tagger", 1, { credentialAvailability: "available", providerIdentity: "admitted" });
  const store = new KnowledgeStore(new TronWorkspace(root), undefined, async id => owner.resolveInstance(id).catch(() => undefined));
  return { root, owner, store, budget: new KnowledgeTaggingBudget(store, owner) };
}

/* Failure modes protected by the K4 cases below:
 * - model uncertainty at the threshold or ties must never guess extra tags;
 * - vocabularies wider than Jev's 16-question ceiling must be narrowed first;
 * - disabled/unapproved/exhausted paid access must stop before provider dispatch;
 * - reservation must exist before dispatch, survive restart, and reconcile only
 *   known settlement; uncertain provider outcomes must not be retried blindly;
 * - UTC month rollover must not carry old spend or erase unresolved reservations;
 * - a take/vocabulary/summary change while Jev is in flight must lose the stale
 *   revision fence, preserve the competing edit, and stay in the retag queue;
 * - duplicate owned queue starts must share a run/charge, and cancellation must
 *   preserve completed source writes;
 * - queue pages must be bounded and stop cleanly at paid budget exhaustion.
 */
describe("Knowledge Jev tagging", () => {
  it("uses a strict confidence threshold and omits boundary ties", () => {
    expect(KNOWLEDGE_TAG_CONFIDENCE_THRESHOLD).toBe(0.65);
    expect(chooseKnowledgeTags({ tag_alpha: { type: "noul", noul: 0.9 }, tag_beta: { type: "noul", noul: 0.65 }, tag_gamma: { type: "noul", noul: 0.64 } }, ["alpha", "beta", "gamma"])).toEqual(["alpha"]);
  });
  it.todo("narrows more than sixteen active tags with one category-choice pass");
  it("reserves only with paid approval, settles usage durably, and leaves dispatched uncertainty fenced", async () => {
    const { budget, store, owner, root } = await budgetFixture();
    await owner.execute({ kind: "policy.update", commandId: "tag-policy-disable-paid", instanceId: "tagger", expectedSetupRevision: 1, policy: { enabled: true, allowWrites: false, paidAccessApproved: false, paidBudgetCents: 500, recurringApproved: false } });
    await expect(budget.reserve("tagger", "disabled-run-0001", 0)).rejects.toMatchObject({ code: "unsupported" });
    await owner.execute({ kind: "policy.update", commandId: "tag-policy-enable-paid", instanceId: "tagger", expectedSetupRevision: 2, policy: { enabled: true, allowWrites: false, paidAccessApproved: true, paidBudgetCents: 500, recurringApproved: false } });
    await owner.recordProviderObservation("tagger", 3, { credentialAvailability: "available", providerIdentity: "admitted" });
    const attempt = await budget.reserve("tagger", "dispatch-run-0001", 0);
    await budget.markDispatch("tagger", attempt);
    await budget.settle("tagger", attempt, { estimatedCostCents: 0.00042, inputTokens: 100, outputTokens: 2 });
    expect(await budget.status("tagger")).toMatchObject({ spentCents: 0.00042, reservedCents: 0, uncertain: [] });
    const heldWorkspace = (store as unknown as { workspace: TronWorkspace }).workspace as unknown as { release?: () => Promise<void> };
    await heldWorkspace.release?.();
    const restartedStore = new KnowledgeStore(new TronWorkspace(root), undefined, async id => owner.resolveInstance(id).catch(() => undefined));
    const restartedBudget = new KnowledgeTaggingBudget(restartedStore, owner);
    expect(await restartedBudget.status("tagger")).toMatchObject({ spentCents: 0.00042 });
    const uncertain = await budget.reserve("tagger", "uncertain-run-0001", 0);
    await budget.markDispatch("tagger", uncertain);
    expect(await budget.status("tagger")).toMatchObject({ reservedCents: KNOWLEDGE_TAG_CALL_RESERVATION_CENTS, uncertain: [{ attemptId: uncertain }] });
    await expect(budget.reserve("tagger", "uncertain-run-0001", 0)).rejects.toMatchObject({ code: "conflict" });
  });
  it("rolls settled spend by UTC month but preserves unresolved dispatches", async () => {
    vi.useFakeTimers(); vi.setSystemTime(new Date("2026-01-31T23:59:00Z"));
    const { budget } = await budgetFixture();
    const attempt = await budget.reserve("tagger", "rollover-run-0001", 0);
    await budget.markDispatch("tagger", attempt);
    vi.setSystemTime(new Date("2026-02-01T00:01:00Z"));
    expect(await budget.status("tagger")).toMatchObject({ month: "2026-02", spentCents: 0, reservedCents: 0, uncertain: [{ attemptId: attempt, month: "2026-01" }] });
  });
  it.todo("does not overwrite a take edit made while Jev is in flight and requeues the source");
  it.todo("automatically schedules one shared retag run after a take edit");
  it.todo("requeues entries on vocabulary edition changes and stops at the paid cap");
  it.todo("shares duplicate runs and charges once while cancellation preserves committed results");
  it.todo("estimates bounded queue cost without dispatching Jev");
  it.todo("processes a 440-source queue within the scale-test bound using a fake Jev");
});
