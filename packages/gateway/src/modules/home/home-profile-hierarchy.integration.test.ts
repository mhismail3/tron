import { mkdir, stat } from "node:fs/promises";
import { SettingsChangePath } from "../../kernel/settings/settings-change.js";
import { legacyProfileFixture } from "../../../test-support/profile-v1-fixture.js";
import { answerChangeCard } from "../../../test-support/native-change.js";
import { expect, it, vi } from "vitest";
import * as durability from "../../foundation/durable-json.js";
import { fixture, homeActivation, profileCall, profileNotes, profileReportFile, recordCase, say, command, history, undo, maintainer } from "../../../test-support/home-profile-fixture.js";

profileReportFile("test-results/home-profile/hierarchy.json");

it("malformed partition labels leave valid discovery/read intact and disclose exact repair references", async () => {
  const f = await fixture("hierarchy-malformed");
  const seeded = [];
  for (const [title, labels] of [["Valid context stays readable.", ["kind-fact", "home-file-core"]], ["Bad file remains recoverable.", ["kind-fact", "home-file-unknown"]], ["Ambiguous file stays unassigned.", ["kind-fact", "home-file-core", "home-file-home"]], ["Unknown kind remains a canonical note.", ["kind-unknown"]]] as const) {
    const record = { kind: "note" as const, scope: "personal" as const, provenance: { actor: "agent" as const, source: "malformed-fixture", evidence: [] }, relations: [], content: { title, role: "fact" as const, confirmed: false, tags: ["home-profile", ...labels] } };
    seeded.push(labels.length === 2 && labels[1] === "home-file-core"
      ? (await f.store.createNote({ commandId: command("valid-seed"), record: { ...record, content: { ...record.content, tags: ["home-profile", "kind-fact"], profile: { version: 2, path: ["communication"] } } } })).record
      : await legacyProfileFixture(f.workspace, command("malformed-seed"), record));
  }
  const turn = await homeActivation(f, "Inspect the index without choosing a repair.", [profileCall({ action: "read" }, "malformed-index"), say("inspection only")]);
  const result = turn.last.messages.find(message => message.role === "toolResult" && message.toolCallId === "malformed-index")?.details as { status: string; index: string; unclassified: number };
  expect(result.status).toBe("read");
  expect(result.index).toContain("Communication (communication): 1 active / 1 total");
  expect(result.unclassified).toBe(3);
  for (const note of seeded.slice(1)) { expect(result.index).toContain(note.id); expect(result.index).toContain(note.revisionId); }
  for (const note of seeded) expect(turn.first.systemPrompt).not.toContain(note.kind === "note" ? note.content.title : "unexpected");
  const read = await homeActivation(f, "Read only Communication, not malformed Prior organization.", [profileCall({ action: "read", path: "communication" }, "malformed-core"), say("read")]);
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
      const record = (await f.store.createNote({ commandId: command("metadata-seed"), record: { kind: "note", scope: "personal", provenance: { actor: "agent", source: "metadata-pages", evidence: [] }, relations: [], content: { title: `Context body ${valid ? "scoped" : "diagnostic"} ${index}.`, role: "fact", confirmed: false, tags: ["home-profile", valid ? "kind-fact" : "kind-unknown"], profile: { version: 2, path: ["engineering", `s${index}`] } } } })).record;
      (valid ? scoped : diagnostics).push(record);
    }
  }
  const windows = [];
  for (const offset of [0, 16]) {
    const turn = await homeActivation(f, "Read metadata only.", [profileCall({ action: "read", offset }, `metadata-page-${offset}`), say("read")]);
    const result = turn.last.messages.find(message => message.role === "toolResult" && message.toolCallId === `metadata-page-${offset}`)?.details as { status: string; index: string };
    expect(result.status).toBe("read");
    expect(result.index.split("\n").filter(line => line.startsWith("- ")).length).toBeLessThanOrEqual(16);
    expect(Buffer.byteLength(result.index)).toBeLessThanOrEqual(8192);
    for (const note of [...scoped, ...diagnostics]) if (note.kind === "note") expect(result.index).not.toContain(note.content.title);
    windows.push(result.index);
  }
  expect(windows[0]).toContain("offset=16");
  expect(windows[1]).not.toContain("More metadata");
  expect(windows.join("\n")).toContain("Engineering (engineering): 17 active / 17 total");
  // Areas aggregate metadata in v2; explicit cursor pages, not invented file rows,
  // must retain every scoped reference across the 16-note boundary.
  const readIds: string[] = [];
  let cursor: string | undefined;
  for (let page = 0; page < 4; page++) {
    const turn = await homeActivation(f, "Read the next Engineering page.", [profileCall({ action: "read", path: "engineering", ...(cursor ? { cursor } : {}) }, `scoped-page-${page}`), say("read")]);
    const result = turn.last.messages.find(message => message.role === "toolResult" && message.toolCallId === `scoped-page-${page}`)?.details as { items: Array<{ id: string }>; nextCursor?: string };
    expect(result.items.length).toBeLessThanOrEqual(16);
    readIds.push(...result.items.map(item => item.id));
    cursor = result.nextCursor;
    if (!cursor) break;
  }
  expect(cursor).toBeUndefined();
  expect(readIds.sort()).toEqual(scoped.map(note => note.id).sort());
  for (const note of diagnostics) expect(windows.join("\n")).toContain(`id=${note.id} revisionId=${note.revisionId}`);
  expect(await Promise.all([...scoped, ...diagnostics].map(note => f.store.read(note.id)))).toEqual([...scoped, ...diagnostics]);
  recordCase("paged-file-and-diagnostic-discovery", { metadataWindowBytes: windows.map(value => Buffer.byteLength(value)), scopedNotes: scoped.length, diagnosticNotes: diagnostics.length });
});

it("the real Home profile tool retries one original label group and native Changes Undo restores malformed labels at their exact positions", async () => {
  const f = await fixture("hierarchy-organize-tool");
  const original = await legacyProfileFixture(f.workspace, command("organize-seed"), { kind: "note", scope: "personal",
    provenance: { actor: "user", source: "explicit-standing-rule", evidence: [] }, relations: [],
    content: { title: "Never publish without approval.", body: "Preserve the full binding instruction.", role: "decision", confirmed: true,
      tags: ["home-file-unknown", "home-profile", "kind-standing-decision", "home-file-home", "fixture-label"] } });
  await mkdir(f.record.path, { recursive: true });
  const parent = await stat(f.record.path);
  const sync = durability.syncDurably;
  let failed = false, prepared = false;
  const prepare = SettingsChangePath.prototype.prepareSubjectAudit;
  const preparation = vi.spyOn(SettingsChangePath.prototype, "prepareSubjectAudit").mockImplementation(async function (this: SettingsChangePath, ...args) {
    const reference = await prepare.apply(this, args); prepared = true; return reference;
  });
  const fault = vi.spyOn(durability, "syncDurably").mockImplementation(async handle => {
    const actual = await handle.stat();
    if (prepared && !failed && actual.dev === parent.dev && actual.ino === parent.ino) { failed = true; throw new Error("Owned tool audit publication fault"); }
    await sync(handle);
  });
  const settled = await homeActivation(f, "Put this note in Engineering / Release, preserving the confirmed instruction.", [
    profileCall({ action: "reorganize", assignments: [{ id: original.id, expectedRevision: original.revisionId, path: "engineering/release" }], reason: "Explicit placement-only organization" }, "organize-tool-first"), say("the operation needs its original publication retry"),
  ]);
  expect(failed).toBe(true);
  expect(f.slot.snapshot().extensionPresentation.pendingInteractions).toEqual([]);
  const advertised = settled.last.messages.find(message => message.role === "toolResult" && message.toolCallId === "organize-tool-first")?.details as { status: string; commandId: string };
  expect(advertised).toMatchObject({ status: "retry_required" });
  const recovery = await f.store.profilePartitionRecovery(advertised.commandId);
  expect(recovery.committed).toBe(true);
  if (!recovery.committed) throw new Error("Expected a committed publication proof");
  const originalPreparation = await f.record.group(recovery.reference.groupId, recovery.reference.size);
  expect(originalPreparation).toHaveLength(1);
  const pending = originalPreparation[0]!;
  expect(pending.actor.toolCallId).toBe("organize-tool-first");
  expect(advertised.commandId).toBe(pending.commandId);
  expect((await history(f)).map(entry => entry.status)).toEqual(["started"]);
  const committed = await f.store.read(original.id) as typeof original;
  expect(committed).toEqual({ ...original, revisionId: committed.revisionId, content: { ...original.content,
    tags: original.content.tags!.filter(tag => !tag.startsWith("home-file-")), profile: { version: 2, path: ["engineering", "release"] } } });
  fault.mockRestore(); preparation.mockRestore();
  const next = await homeActivation(f, "Retry only the original organization operation.", [profileCall({ action: "retry", commandId: advertised.commandId }, "organize-tool-retry"), say("acknowledged")]);
  const organized = next.last.messages.find(message => message.role === "toolResult" && message.toolCallId === "organize-tool-retry")?.details as { status: string; commandId: string; changeIds: string[] };
  expect(organized).toMatchObject({ status: "organized", commandId: pending.commandId });
  expect(organized.changeIds).toHaveLength(1);
  expect(await f.store.read(original.id)).toEqual(committed);
  const completeHistory = await history(f);
  expect(completeHistory).toHaveLength(2);
  const audit = completeHistory.filter(entry => entry.status === "applied");
  expect(audit).toHaveLength(1);
  expect(audit[0]).toMatchObject({ commandId: pending.commandId, actor: { kind: "home", toolCallId: "organize-tool-first" },
    before: { text: "Never publish without approval.", confirmed: true, fileLabels: [{ index: 0, tag: "home-file-unknown" }, { index: 3, tag: "home-file-home" }] },
    after: { text: "Never publish without approval.", confirmed: true, profile: { version: 2, path: ["engineering", "release"] } } });
  expect(audit[0]!.after).not.toHaveProperty("fileLabels");
  await undo(f, organized.changeIds[0]!, "native-undo-labels");
  const restored = await f.store.read(original.id);
  expect({ ...restored, revisionId: original.revisionId }).toEqual(original);
  const undoEntries = (await history(f)).filter(entry => entry.undoOf && entry.status === "applied");
  expect(undoEntries.map(entry => entry.undoOf)).toEqual(organized.changeIds);
  recordCase("tool-original-envelope-retry-native-label-undo", { originalCommand: pending.commandId, originalToolCall: "organize-tool-first", changeIds: organized.changeIds, exactMalformedLabelsRestored: true });
});

it("a stale organization revision is refused, not advertised as a recoverable audit failure", async () => {
  const f = await fixture("stale-organization");
  const original = (await f.store.createNote({ commandId: command("stale-seed"), record: { kind: "note", scope: "personal",
    provenance: { actor: "user", source: "fixture", evidence: [] }, relations: [],
    content: { title: "Original instruction.", role: "decision", confirmed: true, tags: ["home-profile", "kind-standing-decision"], profile: { version: 2, path: ["communication"] } } } })).record;
  await f.service.invoke(maintainer, "home.profileChange", { commandId: command("new-native-edit"), changes: [{ action: "refine", id: original.id, expectedRevision: original.revisionId, text: "New native instruction." }] });
  const current = await f.store.read(original.id);
  const turn = await homeActivation(f, "Put the earlier revision in Engineering / Release.", [profileCall({ action: "reorganize", assignments: [{ id: original.id, expectedRevision: original.revisionId, path: "engineering/release" }], reason: "Exact placement" }, "stale-organize"), say("refused")]);
  expect(f.slot.snapshot().extensionPresentation.pendingInteractions).toEqual([]);
  const result = turn.last.messages.find(message => message.role === "toolResult" && message.toolCallId === "stale-organize")?.details;
  expect(result).toMatchObject({ status: "refused", action: "reorganize", reason: expect.stringMatching(/revision is stale/) });
  expect(result).not.toHaveProperty("commandId");
  expect(await f.store.read(original.id)).toEqual(current);
});

it.each(["migrate", "reorganize"] as const)("maintainer profileChange %s repairs its audit with original-command retry and supports Undo", async action => {
  const f = await fixture(`native-${action}-retry`);
  const original = await legacyProfileFixture(f.workspace, command("native-seed"), { kind: "note", scope: "personal",
    provenance: { actor: "user", source: "fixture", evidence: [] }, relations: [],
    content: { title: "Keep this exact instruction.", role: "decision", confirmed: true, tags: ["home-profile", "kind-standing-decision", "home-file-core"] } });
  await mkdir(f.record.path, { recursive: true });
  const parent = await stat(f.record.path);
  const sync = durability.syncDurably;
  let failed = false, prepared = false;
  const prepare = SettingsChangePath.prototype.prepareSubjectAudit;
  const preparation = vi.spyOn(SettingsChangePath.prototype, "prepareSubjectAudit").mockImplementation(async function (this: SettingsChangePath, ...args) {
    const reference = await prepare.apply(this, args); prepared = true; return reference;
  });
  const fault = vi.spyOn(durability, "syncDurably").mockImplementation(async handle => {
    const actual = await handle.stat();
    if (prepared && !failed && actual.dev === parent.dev && actual.ino === parent.ino) { failed = true; throw new Error("Owned native profile audit fault"); }
    await sync(handle);
  });
  const originalCommand = command(`native-${action}`);
  await expect(f.service.invoke(maintainer, "home.profileChange", { commandId: originalCommand, reason: "Exact native placement",
    changes: [{ action, assignments: [{ id: original.id, expectedRevision: original.revisionId, path: "engineering/release" }] }] })).rejects.toThrow("Owned native profile audit fault");
  fault.mockRestore(); preparation.mockRestore();
  expect((await history(f)).map(entry => entry.status)).toEqual(["started"]);
  const committed = await f.store.read(original.id) as typeof original;
  expect(committed.content.profile).toEqual({ version: 2, path: ["engineering", "release"] });
  const retry = () => f.service.invoke(maintainer, "home.profileChange", { commandId: command("native-repair"), changes: [{ action: "retry", commandId: originalCommand }] }) as Promise<{ status: string; changes: Array<{ changeId: string }> }>;
  const repaired = await retry();
  expect(repaired.status).toBe("applied");
  expect(repaired.changes).toHaveLength(1);
  expect((await retry()).changes).toEqual(repaired.changes);
  expect(await f.store.read(original.id)).toEqual(committed);
  const completeHistory = await history(f);
  expect(completeHistory).toHaveLength(2);
  expect(completeHistory.filter(entry => entry.status === "applied")).toEqual([expect.objectContaining({ commandId: originalCommand, actor: { kind: "ui", id: maintainer.identity } })]);
  await undo(f, repaired.changes[0]!.changeId, "native-organization-undo");
  expect({ ...await f.store.read(original.id), revisionId: original.revisionId }).toEqual(original);
});

it("new profile content is discoverable but never automatically inserted into Home", async () => {
  const f = await fixture("hierarchy-default");
  await homeActivation(f, "Remember this contextual fact.", [profileCall({ action: "learn", kind: "fact", text: "Context only: the fixture service is named Cedar." }, "hierarchy-learn"), say("saved")]);
  const notes = await profileNotes(f);
  expect(notes).toHaveLength(1);
  expect(notes[0]!.content.confirmed).toBe(false);
  const next = await homeActivation(f, "Plan unrelated work.", [say("ready")]);
  expect(next.first.systemPrompt).not.toContain("the fixture service is named Cedar");
  expect(next.first.systemPrompt).toContain("Unsorted (inferred): 1 active / 1 total");
  const read = await homeActivation(f, "Read Unsorted.", [profileCall({ action: "read", path: "inferred" }, "hierarchy-read"), say("read")]);
  expect(JSON.stringify(read.last.messages)).toContain("Context only: the fixture service is named Cedar.");
  expect((await profileNotes(f))[0]!.revisionId).toBe(notes[0]!.revisionId);
});

it("Home cannot rewrite existing confirmed instruction-kind authority or promote its own inference", async () => {
  const f = await fixture("hierarchy-binding");
  const original = (await f.store.createNote({ commandId: command("binding-seed"), record: { kind: "note", scope: "personal", provenance: { actor: "user", source: "explicit-standing-rule", evidence: [], reason: "Maintainer explicitly confirmed this standing constraint." }, relations: [], content: { title: "Never publish without approval.", body: "Keep this exact binding constraint intact.", role: "decision", confirmed: true, tags: ["home-profile", "kind-standing-decision"], profile: { version: 2, path: ["communication"] } } } })).record;
  for (const [index, operation] of [{ action: "refine", text: "Publish without asking." }, { action: "supersede", kind: "standing-decision", text: "Approval is optional." }, { action: "retire", reason: "Assumed irrelevant." }].entries()) {
    const callId = `binding-refusal-${index}`;
    const turn = homeActivation(f, "Consider changing this rule.", [profileCall({ ...operation, id: original.id, reason: "reason" in operation ? operation.reason : "Review the exact proposed authority change" }, callId), say("review needed")]);
    // Home cannot change it alone: the turn waits on the exact card, and a decline applies nothing.
    const { interaction, response } = await answerChangeCard(f.service, maintainer, f.slot, false, command(`decline-${index}`));
    expect(interaction.review!.items[0]!.before).toBe("Confirmed standing decision");
    await response;
    expect((await turn).last.messages.find(message => message.role === "toolResult" && message.toolCallId === callId)?.details).toMatchObject({ status: "declined" });
    expect(await f.store.read(original.id)).toEqual(original);
  }
  await homeActivation(f, "Record this as a proposal, not authority.", [profileCall({ action: "learn", kind: "standing-decision", text: "Proposal: approval might be optional for fixtures." }, "binding-proposal"), say("proposal saved")]);
  const notes = await profileNotes(f);
  expect(notes.find(note => note.id === original.id)).toEqual(original);
  const proposed = notes.find(note => note.id !== original.id)!;
  expect(proposed.content.confirmed).toBe(false);
  expect(proposed.provenance.actor).toBe("agent");
  expect(proposed.content.profile).toEqual({ version: 2, path: ["inferred", "review"] });
});

it("explicit reads preserve exact standing-rule status/provenance and isolate named scopes", async () => {
  const f = await fixture("hierarchy-read");
  const seeded = [];
  for (const [file, title, role, confirmed] of [["communication", "Never publish without approval.", "decision", true], ["routines", "Keep orchestration concise.", "preference", false], ["projects/ui", "UI context: Cedar controls.", "fact", false], ["projects/release", "Release context: Maple signing.", "fact", false]] as const) {
    seeded.push((await f.store.createNote({ commandId: command("hierarchy-seed"), record: { kind: "note", scope: "personal", provenance: { actor: "user", source: "hierarchy-fixture", evidence: [], reason: "Explicit standing instruction or contextual reference." }, relations: [], content: { title, role, confirmed, tags: ["home-profile", role === "decision" ? "kind-standing-decision" : `kind-${role}`], profile: { version: 2, path: file.split("/") } } } })).record);
  }
  const turn = await homeActivation(f, "Read UI context.", [profileCall({ action: "read", path: "projects/ui" }, "hierarchy-ui"), say("read")]);
  expect(turn.first.systemPrompt).not.toContain("UI context: Cedar controls.");
  expect(turn.first.systemPrompt).not.toContain("Release context: Maple signing.");
  const result = turn.last.messages.filter(message => message.role === "toolResult" && message.toolCallId === "hierarchy-ui");
  expect(JSON.stringify(result)).toContain("UI context: Cedar controls.");
  expect(JSON.stringify(result)).not.toContain("Release context: Maple signing.");
  const rules = await homeActivation(f, "Read standing rules.", [profileCall({ action: "read", path: "communication" }, "hierarchy-core"), say("read")]);
  const ruleResult = JSON.stringify(rules.last.messages.filter(message => message.role === "toolResult" && message.toolCallId === "hierarchy-core"));
  expect(ruleResult).toContain("Never publish without approval.");
  expect(ruleResult).toContain("hierarchy-fixture");
  expect(ruleResult).toContain('"confirmed":true');
  expect((await profileNotes(f)).map(note => note.revisionId).sort()).toEqual(seeded.map(note => note.revisionId).sort());
});
