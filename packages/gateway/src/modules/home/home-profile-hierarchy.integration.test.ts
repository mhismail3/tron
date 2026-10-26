import { mkdir, stat } from "node:fs/promises";
import { expect, it, vi } from "vitest";
import * as durability from "../../util/durable-json.js";
import { fixture, homeActivation, profileCall, profileNotes, profileReportFile, recordCase, say, command, history, undo } from "../../../test-support/home-profile-fixture.js";

profileReportFile("test-results/home-profile/hierarchy.json");

it("malformed partition labels leave valid discovery/read intact and disclose exact repair references", async () => {
  const f = await fixture("hierarchy-malformed");
  const seeded = [];
  for (const [title, labels] of [["Valid context stays readable.", ["kind-fact", "home-file-core"]], ["Bad file remains recoverable.", ["kind-fact", "home-file-unknown"]], ["Ambiguous file stays unassigned.", ["kind-fact", "home-file-core", "home-file-home"]], ["Unknown kind remains a canonical note.", ["kind-unknown"]]] as const) {
    seeded.push((await f.store.createNote({ commandId: command("malformed-seed"), record: { kind: "note", scope: "personal", provenance: { actor: "agent", source: "malformed-fixture", evidence: [] }, relations: [], content: { title, role: "fact", confirmed: false, tags: ["home-profile", ...labels] } } })).record);
  }
  const turn = await homeActivation(f, "Inspect the index without choosing a repair.", [profileCall({ action: "read" }, "malformed-index"), say("inspection only")]);
  const result = turn.last.messages.find(message => message.role === "toolResult" && message.toolCallId === "malformed-index")?.details as { status: string; index: string; unclassified: number };
  expect(result.status).toBe("read");
  expect(result.index).toContain("core: 1 active / 1 total");
  expect(result.unclassified).toBe(3);
  for (const note of seeded.slice(1)) { expect(result.index).toContain(note.id); expect(result.index).toContain(note.revisionId); }
  for (const note of seeded) expect(turn.first.systemPrompt).not.toContain(note.kind === "note" ? note.content.title : "unexpected");
  const read = await homeActivation(f, "Read only Core.", [profileCall({ action: "read", file: "core" }, "malformed-core"), say("read")]);
  const core = read.last.messages.find(message => message.role === "toolResult" && message.toolCallId === "malformed-core")?.details as { items: Array<{ id: string }> };
  expect(core.items.map(item => item.id)).toEqual([seeded[0]!.id]);
  expect(await Promise.all(seeded.map(note => f.store.read(note.id)))).toEqual(seeded);
  recordCase("malformed-partition-isolation", { diagnosticNotes: result.unclassified, coreReadIds: core.items.map(item => item.id), unchangedRevisions: seeded.map(note => note.revisionId) });
});

it("file and diagnostic metadata both page without inserting note text or dropping references", async () => {
  const f = await fixture("hierarchy-pages");
  const scoped = [], diagnostics = [];
  for (let index = 0; index < 17; index++) {
    for (const valid of [true, false]) {
      const record = (await f.store.createNote({ commandId: command("metadata-seed"), record: { kind: "note", scope: "personal", provenance: { actor: "agent", source: "metadata-pages", evidence: [] }, relations: [], content: { title: `Context body ${valid ? "scoped" : "diagnostic"} ${index}.`, role: "fact", confirmed: false, tags: ["home-profile", "kind-fact", valid ? `home-file-scopes-s${index}` : "home-file-unknown"] } } })).record;
      (valid ? scoped : diagnostics).push(record);
    }
  }
  const windows = [];
  for (const offset of [0, 16]) {
    const turn = await homeActivation(f, "Read metadata only.", [profileCall({ action: "read", offset }, `metadata-page-${offset}`), say("read")]);
    const result = turn.last.messages.find(message => message.role === "toolResult" && message.toolCallId === `metadata-page-${offset}`)?.details as { status: string; index: string };
    expect(result.status).toBe("read");
    expect(result.index.split("\n").filter(line => line.startsWith("- ")).length).toBeLessThanOrEqual(32);
    for (const note of [...scoped, ...diagnostics]) if (note.kind === "note") expect(result.index).not.toContain(note.content.title);
    windows.push(result.index);
  }
  expect(windows[0]).toContain("offset=16");
  expect(windows[1]).not.toContain("More metadata");
  for (let index = 0; index < scoped.length; index++) expect(windows.join("\n")).toContain(`- scopes/s${index}:`);
  for (const note of diagnostics) expect(windows.join("\n")).toContain(`id=${note.id} revisionId=${note.revisionId}`);
  expect(await Promise.all([...scoped, ...diagnostics].map(note => f.store.read(note.id)))).toEqual([...scoped, ...diagnostics]);
  recordCase("paged-file-and-diagnostic-discovery", { metadataWindowBytes: windows.map(value => Buffer.byteLength(value)), scopedNotes: scoped.length, diagnosticNotes: diagnostics.length });
});

it("the real Home profile tool retries one original label group and native Changes Undo restores malformed labels at their exact positions", async () => {
  const f = await fixture("hierarchy-organize-tool");
  const original = (await f.store.createNote({ commandId: command("organize-seed"), record: { kind: "note", scope: "personal",
    provenance: { actor: "user", source: "explicit-standing-rule", evidence: [] }, relations: [],
    content: { title: "Never publish without approval.", body: "Preserve the full binding instruction.", role: "decision", confirmed: true,
      tags: ["home-file-unknown", "home-profile", "kind-standing-decision", "home-file-home", "fixture-label"] } } })).record;
  await mkdir(f.record.path, { recursive: true });
  const parent = await stat(f.record.path);
  const sync = durability.syncDurably;
  const fault = vi.spyOn(durability, "syncDurably").mockImplementation(async handle => {
    const actual = await handle.stat();
    if (actual.dev === parent.dev && actual.ino === parent.ino) throw new Error("Owned tool audit publication fault");
    await sync(handle);
  });
  const first = await homeActivation(f, "Explicitly organize this instruction as release context; keep its existing authority.", [
    profileCall({ action: "reorganize", assignments: [{ id: original.id, expectedRevision: original.revisionId, file: "scopes/release" }], reason: "Explicit label-only organization" }, "organize-tool-first"), say("retry needed"),
  ]);
  const pending = first.last.messages.find(message => message.role === "toolResult" && message.toolCallId === "organize-tool-first")?.details as { status: string; commandId: string };
  expect(pending.status).toBe("retry_required");
  expect(await history(f)).toEqual([]);
  const committed = await f.store.read(original.id);
  fault.mockRestore();
  const next = await homeActivation(f, "Retry only the original organization operation.", [profileCall({ action: "retry", commandId: pending.commandId }, "organize-tool-retry"), say("acknowledged")]);
  const organized = next.last.messages.find(message => message.role === "toolResult" && message.toolCallId === "organize-tool-retry")?.details as { status: string; commandId: string; changeIds: string[] };
  expect(organized).toMatchObject({ status: "organized", commandId: pending.commandId });
  expect(organized.changeIds).toHaveLength(1);
  expect(await f.store.read(original.id)).toEqual(committed);
  const audit = await history(f);
  expect(audit).toHaveLength(1);
  expect(audit[0]).toMatchObject({ commandId: pending.commandId, actor: { kind: "home", toolCallId: "organize-tool-first" },
    before: { text: "Never publish without approval.", confirmed: true, fileLabels: [{ index: 0, tag: "home-file-unknown" }, { index: 3, tag: "home-file-home" }] },
    after: { text: "Never publish without approval.", confirmed: true, fileLabels: [{ index: 3, tag: "home-file-scopes-release" }] } });
  await undo(f, organized.changeIds[0]!, "native-undo-labels");
  const restored = await f.store.read(original.id);
  expect({ ...restored, revisionId: original.revisionId }).toEqual(original);
  const undoEntries = (await history(f)).filter(entry => entry.undoOf);
  expect(undoEntries.map(entry => entry.undoOf)).toEqual(organized.changeIds);
  recordCase("tool-original-envelope-retry-native-label-undo", { originalCommand: pending.commandId, originalToolCall: "organize-tool-first", changeIds: organized.changeIds, exactMalformedLabelsRestored: true });
});

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
