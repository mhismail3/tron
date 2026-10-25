import { expect, it } from "vitest";
import { fixture, homeActivation, profileCall, profileNotes, profileReportFile, say, command } from "../../../test-support/home-profile-fixture.js";

profileReportFile("test-results/home-profile/hierarchy.json");

it("new profile content is discoverable but never automatically inserted into Home", async () => {
  const f = await fixture("hierarchy-default");
  await homeActivation(f, "Remember this contextual fact.", [profileCall({ action: "learn", kind: "fact", text: "Context only: the fixture service is named Cedar." }, "hierarchy-learn"), say("saved")]);
  const notes = await profileNotes(f);
  expect(notes).toHaveLength(1);
  expect(notes[0]!.content.confirmed).toBe(false);
  const next = await homeActivation(f, "Plan unrelated work.", [say("ready")]);
  expect(next.first.systemPrompt).not.toContain("the fixture service is named Cedar");
  expect(next.first.systemPrompt).toContain("core");
  const read = await homeActivation(f, "Read Core.", [profileCall({ action: "read", file: "core" }, "hierarchy-read"), say("read")]);
  expect(JSON.stringify(read.last.messages)).toContain("Context only: the fixture service is named Cedar.");
  expect((await profileNotes(f))[0]!.revisionId).toBe(notes[0]!.revisionId);
});

it("Home cannot rewrite existing confirmed instruction-kind authority or promote its own inference", async () => {
  const f = await fixture("hierarchy-binding");
  const original = (await f.store.createNote({ commandId: command("binding-seed"), record: { kind: "note", scope: "personal", provenance: { actor: "user", source: "explicit-standing-rule", evidence: [], reason: "Maintainer explicitly confirmed this standing constraint." }, relations: [], content: { title: "Never publish without approval.", body: "Keep this exact binding constraint intact.", role: "decision", confirmed: true, tags: ["home-profile", "kind-standing-decision", "home-file-core"] } } })).record;
  for (const [index, operation] of [{ action: "refine", text: "Publish without asking." }, { action: "supersede", kind: "standing-decision", text: "Approval is optional." }, { action: "retire", reason: "Assumed irrelevant." }].entries()) {
    const callId = `binding-refusal-${index}`;
    const turn = await homeActivation(f, "Consider changing this rule.", [profileCall({ ...operation, id: original.id }, callId), say("review needed")]);
    expect(turn.last.messages.find(message => message.role === "toolResult" && message.toolCallId === callId)?.details).toMatchObject({ status: "refused" });
    expect(await f.store.read(original.id)).toEqual(original);
  }
  await homeActivation(f, "Record this as a proposal, not authority.", [profileCall({ action: "learn", kind: "standing-decision", file: "home", text: "Proposal: approval might be optional for fixtures." }, "binding-proposal"), say("proposal saved")]);
  const notes = await profileNotes(f);
  expect(notes.find(note => note.id === original.id)).toEqual(original);
  const proposed = notes.find(note => note.id !== original.id)!;
  expect(proposed.content.confirmed).toBe(false);
  expect(proposed.provenance.actor).toBe("agent");
  expect(proposed.content.tags).toContain("home-file-home");
});

it("explicit reads preserve exact standing-rule status/provenance and isolate named scopes", async () => {
  const f = await fixture("hierarchy-read");
  const seeded = [];
  for (const [file, title, role, confirmed] of [["core", "Never publish without approval.", "decision", true], ["home", "Keep orchestration concise.", "preference", false], ["scopes/ui", "UI context: Cedar controls.", "fact", false], ["scopes/release", "Release context: Maple signing.", "fact", false]] as const) {
    seeded.push((await f.store.createNote({ commandId: command("hierarchy-seed"), record: { kind: "note", scope: "personal", provenance: { actor: "user", source: "hierarchy-fixture", evidence: [], reason: "Explicit standing instruction or contextual reference." }, relations: [], content: { title, role, confirmed, tags: ["home-profile", role === "decision" ? "kind-standing-decision" : `kind-${role}`, `home-file-${file.replace("/", "-")}`] } } })).record);
  }
  const turn = await homeActivation(f, "Read UI context.", [profileCall({ action: "read", file: "scopes/ui" }, "hierarchy-ui"), say("read")]);
  expect(turn.first.systemPrompt).not.toContain("UI context: Cedar controls.");
  expect(turn.first.systemPrompt).not.toContain("Release context: Maple signing.");
  const result = turn.last.messages.filter(message => message.role === "toolResult" && message.toolCallId === "hierarchy-ui");
  expect(JSON.stringify(result)).toContain("UI context: Cedar controls.");
  expect(JSON.stringify(result)).not.toContain("Release context: Maple signing.");
  const rules = await homeActivation(f, "Read standing rules.", [profileCall({ action: "read", file: "core" }, "hierarchy-core"), say("read")]);
  const ruleResult = JSON.stringify(rules.last.messages.filter(message => message.role === "toolResult" && message.toolCallId === "hierarchy-core"));
  expect(ruleResult).toContain("Never publish without approval.");
  expect(ruleResult).toContain("hierarchy-fixture");
  expect(ruleResult).toContain('"confirmed":true');
  expect((await profileNotes(f)).map(note => note.revisionId).sort()).toEqual(seeded.map(note => note.revisionId).sort());
});
