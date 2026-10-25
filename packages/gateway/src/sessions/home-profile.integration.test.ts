import { describe, expect, it } from "vitest";
import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { waitFor } from "../../test-support/wait-for.js";
import { PROVIDER, MODEL_ID, PROFILE_HEADING, maintainer, latestMaintainerEntryId, listed, itemText, history, fixture, profileReportFile, homeActivation, profileCall, profileResults, profileSection, profileNotes, noteAt, say, recordCase, change, undo, command, report, holdTerminalWrite, retireFixtures, type Step } from "../../test-support/home-profile-fixture.js";
profileReportFile("report.json");
describe("Tron Home learned profile", () => {
  it("F1/F2: learn writes one unconfirmed, tagged note with its evidence, and the next activation carries it verbatim", async () => {
    const f = await fixture("learn");
    const turn = await homeActivation(f, "Please remember: I prefer short replies.", [
      profileCall({ action: "learn", kind: "preference", text: "I prefer short replies." }, "call-learn-1"),
      say("Saved."),
    ]);
    // The tool call is visible in the transcript, and its result states what was saved.
    const [saved] = profileResults(turn.last.messages);
    expect(saved).toMatchObject({ status: "saved", action: "learn", kind: "preference" });
    expect(JSON.stringify(turn.last.messages)).toContain("I prefer short replies.");

    const [note] = await profileNotes(f);
    expect(note).toBeDefined();
    expect(saved).toMatchObject({ id: note!.id, revisionId: note!.revisionId });
    expect(note!.scope).toBe("personal");
    expect(note!.content.title).toBe("I prefer short replies.");
    expect(note!.content.confirmed).toBe(false);
    expect(note!.content.tags).toEqual(["home-profile", "kind-preference", "home-file-core"]);
    expect(note!.provenance).toEqual({
      actor: "agent",
      source: "home",
      sessionId: f.sessionId,
      evidence: [{ sessionEntry: { sessionId: f.sessionId, entryId: latestMaintainerEntryId(f) } }],
    });

    const next = await homeActivation(f, "What do you know about me?", [say("Short.")]);
    const section = profileSection(next.first.systemPrompt);
    expect(section.startsWith(PROFILE_HEADING)).toBe(true);
    expect(section).toContain(`note ${note!.id}`);
    expect(section).toContain("preference, inferred");
    expect(section).toContain("I prefer short replies.");
    recordCase("learn-and-next-activation", { noteId: note!.id, tags: note!.content.tags });
  }, 120_000);

  it("F6: the system prompt is byte-identical across activations while the profile is unchanged", async () => {
    const f = await fixture("stable");
    const before = await homeActivation(f, "hello", [say("hi")]);
    const again = await homeActivation(f, "hello again", [say("hi again")]);
    expect(again.first.systemPrompt).toBe(before.first.systemPrompt);

    // A profile change moves the prompt once; the activation after it is stable again.
    await homeActivation(f, "Remember: answer in English.", [
      profileCall({ action: "learn", kind: "preference", text: "Answer in English." }, "call-stable-1"),
      say("Saved."),
    ]);
    const changed = await homeActivation(f, "one more", [say("ok")]);
    expect(changed.first.systemPrompt).not.toBe(before.first.systemPrompt);
    const settled = await homeActivation(f, "and again", [say("ok")]);
    expect(settled.first.systemPrompt).toBe(changed.first.systemPrompt);
    recordCase("prompt-stability", { stableWhileUnchanged: true, movesOnChange: true });
  }, 120_000);

  it("F3: refine keeps the prior revision and replaces the injected text; supersede and retire leave injection", async () => {
    const f = await fixture("lifecycle");
    await homeActivation(f, "remember a", [
      profileCall({ action: "learn", kind: "preference", text: "Use metric units." }, "call-life-1"),
      say("saved"),
    ]);
    const [original] = await profileNotes(f);
    const originalRevision = original!.revisionId;

    const refine = await homeActivation(f, "refine it", [
      profileCall({ action: "refine", id: original!.id, text: "Use metric units everywhere." }, "call-life-2"),
      say("refined"),
    ]);
    // Each change names the text it replaced, so its tool detail can show it (#957).
    expect(profileResults(refine.last.messages)).toEqual([expect.objectContaining({ status: "saved", action: "refine", id: original!.id, previousText: "Use metric units." })]);
    const refined = await noteAt(f, original!.id);
    expect(refined.revisionId).not.toBe(originalRevision);
    expect(refined.content.title).toBe("Use metric units everywhere.");
    expect(refined.content.confirmed).toBe(false);
    expect(refined.content.tags).toEqual(["home-profile", "kind-preference", "home-file-core"]);
    expect((await noteAt(f, original!.id, originalRevision)).content.title).toBe("Use metric units.");
    const afterRefine = await homeActivation(f, "after refine", [say("ok")]);
    const refinedSection = profileSection(afterRefine.first.systemPrompt);
    expect(refinedSection).toContain("Use metric units everywhere.");
    expect(refinedSection.split(original!.id).length - 1).toBe(1);

    const supersede = await homeActivation(f, "replace it", [
      profileCall({ action: "supersede", id: original!.id, kind: "preference", text: "Use metric units, and state conversions." }, "call-life-3"),
      say("superseded"),
    ]);
    const [replaced] = profileResults(supersede.last.messages);
    expect(replaced).toMatchObject({ status: "saved", action: "supersede", supersededId: original!.id, previousText: "Use metric units everywhere." });
    const afterSupersede = await homeActivation(f, "after supersede", [say("ok")]);
    expect(afterSupersede.first.systemPrompt).not.toContain(`note ${original!.id}`);
    expect(afterSupersede.first.systemPrompt).toContain("Use metric units, and state conversions.");
    const replacement = await noteAt(f, (replaced as { id: string }).id);
    expect(replacement.relations).toEqual([{ type: "supersedes", recordId: original!.id, revisionId: refined.revisionId }]);
    // The superseded record stays readable as history.
    expect((await noteAt(f, original!.id)).content.title).toBe("Use metric units everywhere.");

    const retire = await homeActivation(f, "retire it", [
      profileCall({ action: "retire", id: replacement.id, reason: "The maintainer changed topic." }, "call-life-4"),
      say("retired"),
    ]);
    expect(profileResults(retire.last.messages)).toEqual([expect.objectContaining({ status: "saved", action: "retire", id: replacement.id,
      previousText: "Use metric units, and state conversions." })]);
    // `home.profileList` (Manage Home's Profile row) classifies the notes as the instructions do.
    const listed = await f.registry.homeOwner().profileList();
    expect(listed.unclassified).toBe(0);
    expect(listed.items.map(({ id, kind, text, confirmed, status }) => ({ id, kind, text, confirmed, status }))).toEqual([
      { id: original!.id, kind: "preference", text: "Use metric units everywhere.", confirmed: false, status: "superseded" },
      { id: replacement.id, kind: "preference", text: "Use metric units, and state conversions.", confirmed: false, status: "retired" },
    ]);
    const afterRetire = await homeActivation(f, "after retire", [say("ok")]);
    expect(afterRetire.first.systemPrompt).not.toContain(`note ${replacement.id}`);
    const retired = await noteAt(f, replacement.id);
    expect(retired.content.retired).toBe(true);
    expect(retired.provenance.reason).toBe("The maintainer changed topic.");
    recordCase("refine-supersede-retire", { refinedRevisionKept: true, supersededLeftInjection: true, retiredLeftInjection: true });
  }, 120_000);

  it("F4: a retired item cannot be refined, and a superseded item cannot be superseded again", async () => {
    const f = await fixture("refusals");
    await homeActivation(f, "remember two", [
      profileCall({ action: "learn", kind: "fact", text: "The office is in Lisbon." }, "call-refuse-1"),
      profileCall({ action: "learn", kind: "fact", text: "The team is in Porto." }, "call-refuse-2"),
      say("saved"),
    ]);
    const byText = (text: string) => (async () => (await profileNotes(f)).find((note) => note.content.title === text))();
    const lisbon = await byText("The office is in Lisbon.");
    const porto = await byText("The team is in Porto.");
    await homeActivation(f, "the office moved", [
      profileCall({ action: "supersede", id: lisbon!.id, kind: "fact", text: "The office is in Madrid." }, "call-refuse-3"),
      say("superseded"),
    ]);
    // The superseded item is refused; its replacement stays active.
    const again = await homeActivation(f, "supersede it again", [
      profileCall({ action: "supersede", id: lisbon!.id, kind: "fact", text: "The office is in Rome." }, "call-refuse-4"),
      say("refused"),
    ]);
    expect(profileResults(again.last.messages)).toEqual([expect.objectContaining({ status: "refused", action: "supersede" })]);
    const profileAfterSupersede = await profileNotes(f);
    expect(profileAfterSupersede.map((note) => note.content.title).sort()).toEqual(["The office is in Madrid.", "The office is in Lisbon.", "The team is in Porto."].sort());

    // A retired item is refused by refine, and its revision does not move.
    await homeActivation(f, "retire the team", [
      profileCall({ action: "retire", id: porto!.id, reason: "stale" }, "call-refuse-5"),
      say("retired"),
    ]);
    const revisionBefore = (await noteAt(f, porto!.id)).revisionId;
    const refusal = await homeActivation(f, "refine a retired item", [
      profileCall({ action: "refine", id: porto!.id, text: "Changed." }, "call-refuse-6"),
      say("refused"),
    ]);
    const [result] = profileResults(refusal.last.messages);
    expect(result).toMatchObject({ status: "refused", action: "refine" });
    expect((await noteAt(f, porto!.id)).revisionId).toBe(revisionBefore);
    expect((await noteAt(f, porto!.id)).content.title).toBe("The team is in Porto.");
    recordCase("superseded-and-retired-refused", { supersedeRefused: true, refineRefused: true, revisionUnchanged: true });
  }, 120_000);

  it("F7: a native confirmation keeps the item in the profile, now marked confirmed", async () => {
    const f = await fixture("native");
    await homeActivation(f, "remember", [
      profileCall({ action: "learn", kind: "delegation-default", text: "Delegate reviews to a cheaper model." }, "call-native-1"),
      say("saved"),
    ]);
    const [item] = await profileNotes(f);
    // The native owner edits from its typed draft, which models neither tags nor retirement.
    const { tags: _tags, ...typedContent } = item!.content;
    await f.knowledge.invoke({ operation: "knowledge.note.update", request: {
      commandId: "native-confirm-0001",
      recordId: item!.id,
      expectedRevision: item!.revisionId,
      confirmedByUser: true,
      record: { kind: "note", scope: item!.scope, provenance: item!.provenance, relations: item!.relations, content: { ...typedContent, confirmed: true } },
    } });
    const next = await homeActivation(f, "after confirm", [say("ok")]);
    expect(next.first.systemPrompt).toContain(`note ${item!.id}`);
    expect(next.first.systemPrompt).toContain("delegation-default, confirmed");
    expect((await noteAt(f, item!.id)).content.tags).toEqual(["home-profile", "kind-delegation-default", "home-file-core"]);

    // A native correction, from the same typed model, keeps the item too, now corrected.
    const confirmed = await noteAt(f, item!.id);
    await f.knowledge.invoke({ operation: "knowledge.correction", request: {
      commandId: "native-correct-0001",
      confirmedByUser: true,
      recordId: item!.id,
      expectedRevision: confirmed.revisionId,
      replacement: { kind: "note", scope: confirmed.scope, provenance: confirmed.provenance, relations: confirmed.relations,
        content: { title: "Delegate reviews to a cheaper model, by default.", role: "workflow", confirmed: true } },
      relation: { type: "corrects", recordId: item!.id, revisionId: confirmed.revisionId },
    } });
    const corrected = await homeActivation(f, "after correction", [say("ok")]);
    expect(corrected.first.systemPrompt).toContain("Delegate reviews to a cheaper model, by default.");
    expect(corrected.first.systemPrompt.split(item!.id).length - 1).toBe(1);
    expect((await noteAt(f, item!.id)).content.tags).toEqual(["home-profile", "kind-delegation-default", "home-file-core"]);
    recordCase("native-confirm-keeps-profile", { injectedMarkedConfirmed: true, correctionKeepsProfile: true });
  }, 120_000);

  it("F10: an ordinary session never receives the profile tool", async () => {
    const f = await fixture("ordinary");
    const ordinary = await f.registry.create(f.project);
    await ordinary.setModel(PROVIDER, MODEL_ID);
    const context = await ordinary.context() as unknown as { availableTools: Array<{ name: string }> };
    const names = context.availableTools.map((tool) => tool.name);
    expect(names).not.toContain("profile");
    recordCase("ordinary-has-no-profile-tool", { tools: names.length });
  }, 120_000);

  it("F11: the maintainer confirms, refines, supersedes and retires learned items over RPC, and undo restores each", async () => {
    const f = await fixture("maintainer");
    const info = await f.service.invoke(maintainer, "system.info", {}) as unknown as { capabilities: string[] };
    expect(info.capabilities).toContain("home-profile-edit.v1");
    await homeActivation(f, "Remember two things.", [
      profileCall({ action: "learn", kind: "preference", text: "I prefer short replies." }, "call-m-1"),
      profileCall({ action: "learn", kind: "fact", text: "The office is in Lisbon." }, "call-m-2"),
      say("Saved both."),
    ]);

    // a. confirm: the maintainer's confirmation is the note's own confirmed state, with his provenance.
    const a = await itemText(f, "I prefer short replies.");
    const confirmed = await change(f, [{ action: "confirm", id: a.id, expectedRevision: a.revisionId }], "confirm-a");
    expect(confirmed).toMatchObject({ status: "applied", changes: [{ key: "home.profile.item", qualifiers: { note: a.id },
      before: { confirmed: false }, after: { confirmed: true } }], saved: [{ action: "confirm", id: a.id }] });
    expect(confirmed.changes).toHaveLength(1);
    const noteA = await noteAt(f, a.id);
    expect(noteA.content.confirmed).toBe(true);
    expect(noteA.provenance.actor).toBe("user");

    // b. refine text and kind: the note keeps its ID, takes the new kind label, and is confirmed by the maintainer.
    const b = await itemText(f, "The office is in Lisbon.");
    const refined = await change(f, [{ action: "refine", id: b.id, expectedRevision: b.revisionId, text: "The office is in Lisbon, where I work.", kind: "preference" }], "refine-b");
    expect(refined).toMatchObject({ status: "applied", saved: [{ action: "refine", id: b.id, kind: "preference", previousText: "The office is in Lisbon." }] });
    const noteB = await noteAt(f, b.id);
    expect(noteB.id).toBe(b.id);
    expect(noteB.content).toMatchObject({ title: "The office is in Lisbon, where I work.", confirmed: true });
    expect(noteB.content.tags).toEqual(expect.arrayContaining(["home-profile", "kind-preference", "home-file-core"]));

    // c. supersede a: one group of two entries; the old item is superseded, the new one active and confirmed.
    const a2 = await itemText(f, "I prefer short replies.");
    const superseded = await change(f, [{ action: "supersede", id: a.id, expectedRevision: a2.revisionId, kind: "preference", text: "I prefer short, plain replies." }], "supersede-a");
    expect(superseded).toMatchObject({ status: "applied", saved: [{ action: "supersede", supersededId: a.id, kind: "preference", previousText: "I prefer short replies." }] });
    const replacementId = superseded.saved[0]!.id;
    expect(superseded.changes).toHaveLength(2);
    const supersedeEntries = (await history(f)).filter(entry => superseded.changes.some(change => change.changeId === entry.changeId));
    expect(supersedeEntries).toHaveLength(2);
    expect(new Set(supersedeEntries.map(entry => entry.group?.id)).size).toBe(1);
    expect(supersedeEntries.every(entry => entry.group?.size === 2)).toBe(true);
    const oldEntry = supersedeEntries.find(entry => entry.qualifiers?.note === a.id)!;
    const newEntry = supersedeEntries.find(entry => entry.qualifiers?.note === replacementId)!;
    expect(oldEntry).toMatchObject({ before: { state: "active", confirmed: true }, after: { state: "superseded" } });
    expect(superseded.changes.find(change => change.qualifiers.note === replacementId)!.before).toBeNull();
    expect(newEntry).toMatchObject({ after: { state: "active", confirmed: true } });

    // d. retire b with a reason.
    const b2 = await itemText(f, "The office is in Lisbon, where I work.");
    const retired = await change(f, [{ action: "retire", id: b.id, expectedRevision: b2.revisionId, reason: "The maintainer moved offices." }], "retire-b");
    expect(retired.changes).toMatchObject([{ qualifiers: { note: b.id }, after: { state: "retired" } }]);

    // e. the maintainer's changes are in history, presented as the Changes list shows them.
    const mine = (await history(f)).filter(entry => entry.actor.kind === "ui");
    expect(mine).toHaveLength(5);
    for (const entry of mine) {
      expect(entry.presentation).toMatchObject({ label: "Profile item", actor: "You" });
      expect(entry.presentation.display.before).not.toBe("");
      expect(entry.presentation.display.after).not.toBe("");
    }

    // f. undo the supersede through one of its changes: both notes revert together.
    const undoSupersede = await undo(f, superseded.changes[0]!.changeId, "undo-supersede");
    expect(undoSupersede).toMatchObject({ status: "applied", changes: expect.any(Array) });
    const afterSupersedeUndo = await listed(f);
    expect(afterSupersedeUndo.find(item => item.id === a.id)).toMatchObject({ status: "active", text: "I prefer short replies.", confirmed: true });
    expect(afterSupersedeUndo.find(item => item.id === replacementId)).toMatchObject({ status: "retired" });
    const undone = (await history(f)).filter(entry => entry.undoOf !== undefined);
    expect(undone.map(entry => entry.undoOf).sort()).toEqual(superseded.changes.map(change => change.changeId).sort());

    // f. undo the retire: b is active again, which clears the note's retirement in Knowledge.
    const undoRetire = await undo(f, retired.changes[0]!.changeId, "undo-retire");
    expect(undoRetire).toMatchObject({ status: "applied" });
    expect((await listed(f)).find(item => item.id === b.id)).toMatchObject({ status: "active", text: "The office is in Lisbon, where I work.", confirmed: true });
    // Knowledge drops the cleared flag rather than storing false; the note is no longer retired.
    expect((await noteAt(f, b.id)).content.retired).toBeFalsy();

    // g. the next activation carries a and b as they now stand, and not the superseding text.
    const next = await homeActivation(f, "What do you know about me?", [say("ok")]);
    const section = profileSection(next.first.systemPrompt);
    expect(section.split("\n")).toContain(`- note ${a.id} (preference, confirmed): I prefer short replies.`);
    expect(section.split("\n")).toContain(`- note ${b.id} (preference, confirmed): The office is in Lisbon, where I work.`);
    expect(section).not.toContain("I prefer short, plain replies.");
    expect(section).not.toContain(replacementId);
    recordCase("maintainer-journey", { confirmed: a.id, refined: b.id, superseded: { old: a.id, replacement: replacementId, group: supersedeEntries[0]!.group },
      retired: b.id, historyEntries: mine.length, undoEntries: undone.length, sectionBytes: Buffer.byteLength(section, "utf8") });
  }, 120_000);

  it("F12: a stale maintainer edit and a stale undo are refused with the current state, and nothing is overwritten", async () => {
    const f = await fixture("conflict");
    await homeActivation(f, "remember two", [
      profileCall({ action: "learn", kind: "preference", text: "Use tabs." }, "call-c-0"),
      profileCall({ action: "learn", kind: "fact", text: "Launch is Friday." }, "call-c-0b"),
      say("saved"),
    ]);

    // Home refines the item after the maintainer read it: his edit from that read is stale.
    const tabs = await itemText(f, "Use tabs.");
    await homeActivation(f, "tabs are wrong", [
      profileCall({ action: "refine", id: tabs.id, text: "Use two spaces." }, "call-c-1"),
      say("refined"),
    ]);
    await expect(change(f, [{ action: "refine", id: tabs.id, expectedRevision: tabs.revisionId, text: "Use four spaces." }], "stale-refine"))
      .rejects.toMatchObject({ code: "conflict", details: { current: { id: tabs.id, text: "Use two spaces." } } });
    expect((await noteAt(f, tabs.id)).content.title).toBe("Use two spaces.");

    // The maintainer confirms an item; Home then refines it, which makes it inferred again.
    // The maintainer's undo of the confirmation is refused, and the note keeps Home's text.
    const launch = await itemText(f, "Launch is Friday.");
    const confirmed = await change(f, [{ action: "confirm", id: launch.id, expectedRevision: launch.revisionId }], "confirm-launch");
    await homeActivation(f, "launch moved", [
      profileCall({ action: "refine", id: launch.id, text: "Launch is Monday." }, "call-c-2"),
      say("refined"),
    ]);
    await expect(undo(f, confirmed.changes[0]!.changeId, "stale-undo"))
      .rejects.toMatchObject({ code: "conflict", details: { display: { current: "Inferred fact: Launch is Monday.", after: "Confirmed fact: Launch is Friday." } } });
    expect((await noteAt(f, launch.id)).content).toMatchObject({ title: "Launch is Monday.", confirmed: false });
    recordCase("stale-edit-and-undo-refused", { staleRefine: tabs.id, staleUndo: launch.id });
  }, 120_000);

  it("F13: Home's own profile changes are recorded, and the maintainer's undo of one retires the learned note", async () => {
    const f = await fixture("home-recorded");
    await homeActivation(f, "Remember I like dry humour.", [
      profileCall({ action: "learn", kind: "preference", text: "I like dry humour." }, "call-h-1"),
      say("saved"),
    ]);
    const [learned] = await profileNotes(f);
    const learnedId = learned!.id;
    const entry = (await history(f)).find(candidate => candidate.actor.kind === "home" && candidate.qualifiers?.note === learnedId);
    expect(entry).toMatchObject({ key: "home.profile.item", after: { confirmed: false, state: "active", text: "I like dry humour." },
      presentation: { label: "Profile item", actor: "Home" } });
    const before = await homeActivation(f, "still there?", [say("ok")]);
    expect(profileSection(before.first.systemPrompt)).toContain(`note ${learnedId} (preference, inferred): I like dry humour.`);

    const undone = await undo(f, entry!.changeId, "undo-home-learn");
    expect(undone).toMatchObject({ status: "applied" });
    const after = await homeActivation(f, "and now?", [say("ok")]);
    expect(profileSection(after.first.systemPrompt)).not.toContain(learnedId);
    expect((await noteAt(f, learnedId)).content.retired).toBe(true);
    recordCase("home-change-recorded-and-undone", { note: learnedId, historyActor: "Home" });
  }, 120_000);
});
