import { expect, it } from "vitest";
import { waitFor } from "../../../test-support/wait-for.js";
import { fixture, profileCall, say, command, maintainer, profileReportFile, recordCase, type Fixture } from "../../../test-support/home-profile-fixture.js";
import type { KnowledgeRecord } from "../../knowledge/knowledge-contract.js";

/**
 * #2050: a profile organization request is an ordinary approval request in the
 * chat that asked for it. Failure modes, written before the fix:
 *  A1 the push names no request ("Home asks to change : …") so it reads as noise;
 *  A2 the review shows raw JSON identity instead of the note and its areas;
 *  A3 `wait` is not offered: Home cannot ask in its chat and wait for the tap;
 *  A4 a decision from Changes leaves the waiting tool or its form behind;
 *  A5 history keeps the request's original fact saying Pending after it settled.
 */
profileReportFile("test-results/home-profile/approval-requests.json");

async function confirmedNote(f: Fixture, title: string, path: string[]) {
  return (await f.store.createNote({ commandId: command("seed-note"), record: { kind: "note", scope: "personal",
    provenance: { actor: "user", source: "fixture", evidence: [] }, relations: [],
    content: { title, role: "fact", confirmed: true, tags: ["home-profile", "kind-fact"], profile: { version: 2, path } } } })).record as Extract<KnowledgeRecord, { kind: "note" }>;
}

async function pendingApprovals(f: Fixture) {
  return (await f.service.invoke(maintainer, "settings.approvals", {}) as unknown as { requests: Array<{ requestId: string; digest: string }> }).requests;
}

async function reorganizeTurn(f: Fixture, note: Extract<KnowledgeRecord, { kind: "note" }>, id: string, wait?: boolean) {
  f.home.push(profileCall({ action: "reorganize", assignments: [{ id: note.id, expectedRevision: note.revisionId, path: "communication/questions" }],
    reason: "Sort the confirmed note", ...(wait === undefined ? {} : { wait }) }, id), say("asked"));
  return f.slot.prompt("Sort that note for me.");
}

it("a waiting profile request appears in its chat, pushes once, settles from Changes and leaves no Pending row", async () => {
  const f = await fixture("approval-requests-wait");
  const note = await confirmedNote(f, "Prefers short morning check-ins over long evening calls.", ["inferred", "review"]);
  const prompting = reorganizeTurn(f, note, "wait-reorganize", true);
  const interaction = await waitFor(() => f.slot.snapshot().extensionPresentation.pendingInteractions[0], "approval form in the requesting chat", { boundMs: 30_000 });
  const [request] = await pendingApprovals(f);
  expect(interaction.form).toMatchObject({ presentation: "approval", questions: [{ id: request!.requestId }] });
  // A1: one push names the request itself and routes to this chat.
  const pushes = f.pushes.filter(push => (push as { category?: string }).category === "settings-approval");
  expect(pushes).toHaveLength(1);
  expect(pushes[0]).toMatchObject({ message: "Home asks for your approval: Review exact profile changes — Sort the confirmed note", route: { sessionId: f.sessionId } });
  // A2: the review names the note and areas, with exact identity kept separately.
  const listed = await f.service.invoke(maintainer, "settings.approvals", {}) as unknown as { requests: Array<{ action: { items: Array<{ label: string; value: string; exact?: string }> } }> };
  const item = listed.requests[0]!.action.items[0]!;
  expect(item).toMatchObject({ label: "Prefers short morning check-ins over long evening calls.", value: "Unsorted › Review → Communication › Questions" });
  expect(item.value).not.toContain("{");
  expect(JSON.parse(item.exact!)).toMatchObject({ id: note.id, revision: note.revisionId });
  // A4: Changes decides; the waiting tool, its form and the pending list all settle.
  const decision = await f.service.invoke(maintainer, "settings.decide", { commandId: command("decide-wait"), requestId: request!.requestId, digest: request!.digest, approved: true }) as unknown as { status: string };
  expect(decision.status).toBe("approved");
  await prompting;
  await waitFor(() => f.slot.snapshot().extensionPresentation.pendingInteractions.length === 0 && !f.slot.isBusy || undefined, "form retired", { boundMs: 30_000 });
  expect(await pendingApprovals(f)).toEqual([]);
  const result = f.slot.snapshot().transcript.find(item => item.kind === "message" && item.role === "toolResult") as { details?: { status?: string; approval?: { requestId?: string } } } | undefined;
  expect(result?.details).toMatchObject({ status: "approved", approval: { requestId: request!.requestId } });
  // A5: the request's history shows its outcome, never a stale Pending fact.
  const page = await f.service.invoke(maintainer, "settings.history", { limit: 200 }) as unknown as { entries: Array<{ requestId?: string; status: string }> };
  const facts = page.entries.filter(entry => entry.requestId === request!.requestId);
  expect(facts.map(entry => entry.status)).toEqual(["approved"]);
  recordCase("wait-profile-request", { requestId: request!.requestId, push: pushes[0], item, facts });
}, 120_000);

it("a profile request by default returns pending at once and its history row follows the decision", async () => {
  const f = await fixture("approval-requests-pending");
  const note = await confirmedNote(f, "Keeps a paper notebook for travel plans.", ["life"]);
  await reorganizeTurn(f, note, "pending-reorganize");
  await waitFor(() => !f.slot.isBusy || undefined, "turn ended without waiting", { boundMs: 30_000 });
  expect(f.slot.snapshot().extensionPresentation.pendingInteractions).toEqual([]);
  const [request] = await pendingApprovals(f);
  // A1 and A2 hold for either mode: the push and the review name the request.
  expect(f.pushes.map(push => push.message)).toEqual([expect.stringMatching(/^Home asks for your approval: Review exact profile changes — Sort the confirmed note$/)]);
  const listed = await f.service.invoke(maintainer, "settings.approvals", {}) as unknown as { requests: Array<{ action: { items: Array<{ label: string; value: string }> } }> };
  expect(listed.requests[0]!.action.items.map(item => [item.label, item.value])).toEqual([["Keeps a paper notebook for travel plans.", "Life & people → Communication › Questions"]]);
  const waiting = await f.service.invoke(maintainer, "settings.history", { limit: 200 }) as unknown as { entries: Array<{ requestId?: string; status: string }> };
  expect(waiting.entries.filter(entry => entry.requestId === request!.requestId).map(entry => entry.status)).toEqual(["pending"]);
  await f.service.invoke(maintainer, "settings.decide", { commandId: command("decline"), requestId: request!.requestId, digest: request!.digest, approved: false });
  const page = await f.service.invoke(maintainer, "settings.history", { limit: 200 }) as unknown as { entries: Array<{ requestId?: string; status: string }> };
  expect(page.entries.filter(entry => entry.requestId === request!.requestId).map(entry => entry.status)).toEqual(["declined"]);
  expect(f.broadcasts.filter(event => event.topic === "settings.approvalsChanged").map(event => (event.payload as { status: string }).status)).toEqual(["pending", "declined"]);
  recordCase("pending-profile-request", { requestId: request!.requestId });
}, 120_000);
