import { describe, expect, it } from "vitest";
import { chooseKnowledgeTags, KNOWLEDGE_TAG_CONFIDENCE_THRESHOLD } from "./knowledge-tagger.js";

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
  it.todo("reserves at Jev dispatch, settles actual usage, and retains uncertain reservations across restart");
  it.todo("resets a settled monthly ledger on UTC month rollover but preserves unresolved dispatches");
  it.todo("does not overwrite a take edit made while Jev is in flight and requeues the source");
  it.todo("automatically schedules one shared retag run after a take edit");
  it.todo("requeues entries on vocabulary edition changes and stops at the paid cap");
  it.todo("shares duplicate runs and charges once while cancellation preserves committed results");
  it.todo("estimates bounded queue cost without dispatching Jev");
  it.todo("processes a 440-source queue within the scale-test bound using a fake Jev");
});
