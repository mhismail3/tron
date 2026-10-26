import { afterEach, expect, it } from "vitest";
import { createHash } from "node:crypto";
import { mkdir, writeFile } from "node:fs/promises";
import { fauxAssistantMessage, fauxToolCall, getCurrentSystemPrompt, type TranscriptContext } from "@earendil-works/pi-ai";
import { fixture, disposeFixtures, dispatch, reportCall } from "../../../test-support/home-task-fixture.js";
import { setHomeMemoryModels } from "../../../test-support/settings-dependencies.js";
import { waitFor } from "../../../test-support/wait-for.js";
import { homeOwnerOf } from "../../../test-support/gateway-registry.js";
import { workspaceModule } from "../../workspace/workspace-module.js";
import { KnowledgeService } from "../../knowledge/knowledge-service.js";
import { KnowledgeStore } from "../../knowledge/knowledge-store.js";
import { readHomeProfileIndex } from "./home-profile.js";
import { registerProfileApprovals } from "./home-profile-approvals.js";
import type { KnowledgeRecord } from "../../knowledge/knowledge-contract.js";

type Note = Extract<KnowledgeRecord, { kind: "note" }>;
let knowledge: KnowledgeService | undefined;
const evidence: unknown[] = [];
afterEach(async () => {
  knowledge?.dispose(); knowledge = undefined;
  await disposeFixtures();
  await mkdir("test-results/home-profile", { recursive: true });
  await writeFile("test-results/home-profile/triage.json", JSON.stringify(evidence, null, 2));
});
async function setup() {
  const f = await fixture(false, false, undefined, false, undefined, { knowledge: () => knowledge });
  await setHomeMemoryModels(f.registry, [{ provider: f.model.provider, id: f.model.id }]);
  const greeting = await f.registry.acquire(f.home.sessionId);
  f.faux.setResponses([fauxAssistantMessage("Hello.")]);
  await greeting.prompt("Start this isolated fixture conversation.");
  await waitFor(() => greeting.snapshot().operation === undefined && greeting.snapshot().configurationBlocker === null, "greeting settled");
  // The runtime captures its tool owners when built. Reopen with Knowledge
  // installed before acquiring the successor runtime, as gateway-main does.
  let registry = await f.restartToReadiness();
  f.registry = registry;
  knowledge = new KnowledgeService(new KnowledgeStore(registry.moduleHost.contract(workspaceModule), () => {}));
  registerProfileApprovals(f.settings.settingsChanges, () => knowledge);
  await homeOwnerOf(registry).recoverTasks();
  return {
    f,
    async restart() {
      knowledge!.dispose(); knowledge = undefined;
      registry = await f.restartToReadiness();
      f.registry = registry;
      knowledge = new KnowledgeService(new KnowledgeStore(registry.moduleHost.contract(workspaceModule), () => {}));
      registerProfileApprovals(f.settings.settingsChanges, () => knowledge);
      await homeOwnerOf(registry).recoverTasks();
    },
    async turn(input: string, args?: Record<string, unknown>, callId = "triage-call") {
      const captured: Array<{ system: string; messages: Array<Record<string, unknown>> }> = [];
      const replies = args ? [fauxAssistantMessage(fauxToolCall("profile", args, { id: callId }), { stopReason: "toolUse" }), fauxAssistantMessage("Done.")] : [fauxAssistantMessage("Done.")];
      f.faux.setResponses(replies.map(reply => (context: TranscriptContext) => {
        captured.push({ system: getCurrentSystemPrompt(context.messages), messages: context.messages as unknown as Array<Record<string, unknown>> });
        return reply;
      }));
      const home = await registry.acquire(f.home.sessionId);
      await home.prompt(input);
      await waitFor(() => home.snapshot().operation === undefined && home.snapshot().configurationBlocker === null, "Home settled");
      return { first: captured[0]!, result: captured.at(-1)!.messages.find(message => message.role === "toolResult" && message.toolCallId === callId)?.details as Record<string, unknown> };
    },
  };
}
async function seed(index: number): Promise<Note> {
  return (await knowledge!.store.createNote({ commandId: `triage-seed-${index}`, record: {
    kind: "note", scope: "personal", provenance: { actor: "agent", source: "home", evidence: [] }, relations: [],
    content: { title: `Inferred example ${index}`, role: "fact", confirmed: false, tags: ["home-profile", "kind-fact"], profile: { version: 2, path: ["inferred", "review"] } },
  } })).record as Note;
}

it("receipts Not now durably; cold restart, edits, moves and old-command replay cannot reset or renew suppression", async () => {
  const p = await setup();
  const originals: Note[] = [];
  for (let index = 0; index < 8; index++) originals.push(await seed(index));
  const visibleVersion = (await readHomeProfileIndex(knowledge!)).sorting.version;
  const hidden = await seed(99);
  await knowledge!.store.setExclusion("triage-hide-old", hidden.id, true, hidden.revisionId);
  const index = await readHomeProfileIndex(knowledge!);
  expect(index.items).toHaveLength(8);
  expect(index.sorting.version).toBe(visibleVersion);
  const version = index.sorting.version;
  const result = await p.turn("Not now. Do not offer sorting until a new note arrives.", { action: "defer", version }, "defer-first");
  expect(result.result).toMatchObject({ status: "deferred", version });
  const commandId = `profile-${createHash("sha256").update(`${p.f.home.sessionId}\0defer-first`).digest("hex").slice(0, 48)}`;
  const saved = await knowledge!.store.deferProfileSorting(commandId, version);
  expect(saved).toEqual(result.result);
  const stateBeforeReplay = (await knowledge!.store.status()).stateRevision;
  expect(await knowledge!.store.deferProfileSorting(commandId, version)).toEqual(saved);
  expect((await knowledge!.store.status()).stateRevision).toBe(stateBeforeReplay);
  await p.restart();
  expect((await readHomeProfileIndex(knowledge!)).sorting.deferred).toBe(true);
  await knowledge!.store.setExclusion("triage-unhide-old", hidden.id, false, hidden.revisionId);
  expect((await readHomeProfileIndex(knowledge!)).sorting.deferred).toBe(true);
  await knowledge!.store.setExclusion("triage-rehide-old", hidden.id, true, hidden.revisionId);
  const old = originals[0]!;
  await knowledge!.store.updateNote({ commandId: "triage-edit-existing", recordId: old.id, expectedRevision: old.revisionId,
    record: { ...old, content: { ...old.content, title: "An edit is not a new note", profile: { version: 2, path: ["communication", "answers"] } } } });
  const suppressed = await p.turn("Continue with another question.");
  expect(suppressed.first.system).toContain("Sorting offer: deferred");
  expect((await readHomeProfileIndex(knowledge!)).sorting.version).toBe(version);
  const newNote = await seed(8);
  expect((await readHomeProfileIndex(knowledge!)).sorting.deferred).toBe(false);
  await expect(knowledge!.store.deferProfileSorting("triage-stale-deferral", version)).rejects.toThrow(/new profile notes|snapshot changed/i);
  expect(await knowledge!.store.deferProfileSorting(commandId, version)).toEqual(saved);
  expect((await readHomeProfileIndex(knowledge!)).sorting.deferred).toBe(false);
  const resumed = await p.turn("Start another maintainer turn.");
  expect(resumed.first.system).toContain("Sorting offer: eligible");
  expect((await knowledge!.store.read(newNote.id) as Note).content.confirmed).toBe(false);
  await knowledge!.store.forget("triage-forget-new", newNote.id, "Explicit fixture forget", newNote.revisionId);
  expect((await readHomeProfileIndex(knowledge!)).sorting.deferred).toBe(false);
  evidence.push({ durableNotNow: true, coldRestart: true, editsAndMovesDoNotReset: true, receiptReplayDoesNotMutate: true, newNoteResumes: true, staleDeferralRefused: true });
}, 120_000);

it("keeps explicitly stated sensitive data unsorted, refuses inferred sensitive capture, and hides excluded/forgotten content at real Home reads", async () => {
  const p = await setup();
  const text = "My synthetic health constraint is that I cannot climb stairs.";
  const inferred = await p.turn("Do not infer a health condition from my short reply.", { action: "learn", kind: "fact", text, sensitive: true }, "sensitive-inference");
  expect(inferred.result).toMatchObject({ status: "refused" });
  expect((await readHomeProfileIndex(knowledge!)).items).toHaveLength(0);
  const placed = await p.turn(text, { action: "learn", kind: "fact", text, sensitive: true, path: "life/health" }, "sensitive-personal");
  expect(placed.result).toMatchObject({ status: "refused" });
  expect((await readHomeProfileIndex(knowledge!)).items).toHaveLength(0);
  const stated = await p.turn(text, { action: "learn", kind: "fact", text, sensitive: true }, "sensitive-stated");
  expect(stated.result.status).toBe("saved");
  const note = await knowledge!.store.read(stated.result.id as string) as Note;
  expect(note.content.profile).toEqual({ version: 2, path: ["inferred", "review"] });
  expect(note.content.confirmed).toBe(false);
  expect(note.content.privacyScope).toBe("private");
  const move = await p.turn("Propose a place for that sensitive note.", { action: "reorganize", assignments: [{ id: note.id, expectedRevision: note.revisionId, path: "life/health" }], reason: "Exact review before moving private material" }, "sensitive-review");
  evidence.push({ sensitivePlacementReview: move.result });
  expect(move.result).toMatchObject({ status: "pending" });
  expect((await knowledge!.store.read(note.id) as Note).revisionId).toBe(note.revisionId);
  const metadata = await p.turn("What is available to read?", { action: "read" }, "sensitive-index");
  expect(metadata.first.system).not.toContain(text);
  expect(metadata.result.status).toBe("read");
  expect(JSON.stringify(metadata.result)).not.toContain(text);
  await knowledge!.store.setExclusion("sensitive-exclude", note.id, true, note.revisionId, "Explicit fixture exclusion");
  const excluded = await p.turn("Read the holding area.", { action: "read", path: "inferred" }, "excluded-sensitive");
  evidence.push({ excludedRead: excluded.result });
  expect(excluded.result.items).toEqual([]);
  await knowledge!.store.forget("sensitive-forget", note.id, "Explicit fixture forget", note.revisionId);
  await p.restart();
  const forgotten = await p.turn("Read only current profile records.", { action: "read", path: "inferred", includeInactive: true }, "forgotten-sensitive");
  evidence.push({ forgottenRead: forgotten.result });
  expect(forgotten.result.items).toEqual([]);
  expect(forgotten.first.system).not.toContain(text);
  expect(await knowledge!.store.read(note.id)).toBeNull();
  evidence.push({ declaredSensitiveInferenceRefused: true, explicitSensitiveUnsorted: true, metadataBodyFree: true, excludedAndForgottenAbsentFromHomeReads: true, coldRestart: true });
}, 120_000);

it("lets Home retire its own unconfirmed standing proposal with a reason but requires exact review for refinement", async () => {
  const p = await setup();
  const learned = await p.turn("Propose this standing decision for my review.", { action: "learn", kind: "standing-decision", text: "Proposed synthetic standing decision" }, "own-standing");
  expect(learned.result.status).toBe("saved");
  const id = learned.result.id as string;
  const original = await knowledge!.store.read(id) as Note;
  expect(original.content.confirmed).toBe(false);
  const refine = await p.turn("Propose exact revised wording.", { action: "refine", id, text: "Revised synthetic standing decision", reason: "Exact wording review" }, "own-refine-review");
  evidence.push({ exactRefinementReview: refine.result });
  expect(refine.result.status).toBe("pending");
  expect((await knowledge!.store.read(id) as Note).revisionId).toBe(original.revisionId);
  const retired = await p.turn("Withdraw your unconfirmed proposal.", { action: "retire", id, reason: "Withdrawing my own unconfirmed proposal" }, "own-standing-retire");
  expect(retired.result).toMatchObject({ status: "saved", action: "retire", id });
  const current = await knowledge!.store.read(id) as Note;
  expect(current.content.retired).toBe(true);
  expect(current.content.confirmed).toBe(false);
  expect(current.content.title).toBe(original.content.title);
  expect(current.provenance.reason).toBe("Withdrawing my own unconfirmed proposal");
  evidence.push({ ownStandingProposalRetiredWithoutApproval: true, reasonRecorded: true, refinementWaitedForExactReview: true });
}, 120_000);

it("does not offer sorting or accept Not now during a real worker-completion wake, even with an old maintainer message", async () => {
  const p = await setup();
  for (let index = 0; index < 8; index++) await seed(index);
  const version = (await readHomeProfileIndex(knowledge!)).sorting.version;
  const requests: Array<{ system: string; messages: Array<Record<string, unknown>> }> = [];
  const homeReplies = [fauxAssistantMessage(fauxToolCall("profile", { action: "defer", version }, { id: "wake-defer" }), { stopReason: "toolUse" }), fauxAssistantMessage("Worker result acknowledged.")];
  p.f.faux.setResponses(Array.from({ length: 8 }, () => (context: TranscriptContext) => {
    const system = getCurrentSystemPrompt(context.messages);
    if (!system.includes("## Tron Home")) return fauxAssistantMessage([reportCall("triage-worker", "Bounded fixture work completed")], { stopReason: "toolUse" });
    requests.push({ system, messages: context.messages as unknown as Array<Record<string, unknown>> });
    const reply = homeReplies.shift();
    if (!reply) throw new Error("Unexpected Home request");
    return reply;
  }));
  const run = await dispatch(p.f, "profile-triage-wake");
  await run.completion;
  await waitFor(async () => (await homeOwnerOf(p.f.registry).taskResult(run.taskId)).wake?.state === "acknowledged", "profile wake acknowledged");
  expect(requests).toHaveLength(2);
  expect(requests[0]!.system).toContain("Sorting offer: on-demand only; not a maintainer turn start");
  const result = requests[1]!.messages.find(message => message.role === "toolResult" && message.toolCallId === "wake-defer")?.details;
  expect(result).toMatchObject({ status: "refused", action: "defer" });
  expect((await readHomeProfileIndex(knowledge!)).sorting.deferred).toBe(false);
  evidence.push({ realWorkerCompletionWake: true, noAutomaticSortingOffer: true, oldUserMessageCannotAuthorizeDeferral: true });
}, 120_000);
