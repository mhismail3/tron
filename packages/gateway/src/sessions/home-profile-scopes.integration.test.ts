import { describe, expect, it } from "vitest";
import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { waitFor } from "../../test-support/wait-for.js";
import { readFile, writeFile, rm } from "node:fs/promises";
import { join } from "node:path";
import type { KnowledgeRecord } from "../knowledge/knowledge-contract.js";
import { fixture, profileReportFile, homeActivation, profileCall, profileResults, profileSection, profileNotes, noteAt, say, recordCase, change, undo, command, report, holdTerminalWrite, retireFixtures, type Step } from "../../test-support/home-profile-fixture.js";
profileReportFile("scopes.json");
describe("Tron Home scoped profile", () => {
  it.skipIf(!process.env.TRON_PROFILE_MEASUREMENT_INPUT)("F18: measure the saved 21-item profile through real Home renders", async () => {
    const f = await fixture("measurement");
    const saved = JSON.parse(await readFile(process.env.TRON_PROFILE_MEASUREMENT_INPUT!, "utf8")) as Array<{ id: string; file: string; content: { title: string; role: "fact" | "preference" | "decision" | "workflow"; confirmed: boolean; tags: string[] } }>;
    expect(saved).toHaveLength(21);
    for (const item of saved) await f.store.createNote({ commandId: command("measurement-seed"), record: { id: item.id, kind: "note", scope: "personal", provenance: { actor: "user", source: "measurement-fixture", evidence: [] }, relations: [], content: item.content } });
    const before = await homeActivation(f, "Baseline profile", [say("measured")]);
    recordCase("actual-21-baseline-render", { bytes: Buffer.byteLength(profileSection(before.first.systemPrompt)), notes: saved.length });
    const notes = await profileNotes(f);
    await change(f, [{ action: "migrate", assignments: saved.map(item => ({ id: item.id, file: item.file, expectedRevision: notes.find(note => note.id === item.id)!.revisionId })) }], "measurement-layout");
    const after = await homeActivation(f, "Scoped profile", [say("measured")]);
    recordCase("actual-21-scoped-render", { bytes: Buffer.byteLength(profileSection(after.first.systemPrompt)), notes: saved.length });
    for (const item of saved.filter(item => item.file === "core" || item.file === "home")) expect(after.first.systemPrompt).toContain(item.content.title);
  });

  it("F20: a rejected migration leaves all original profile heads untouched", async () => {
    const f = await fixture("migration-refusal");
    const created = [];
    for (const [title, extra] of [["First valid rule", []], ["Rule at its label bound", Array.from({ length: 6 }, (_, i) => `owner-${i}`)]] as const) {
      created.push((await f.store.createNote({ commandId: command("failure-seed"), record: { kind: "note", scope: "personal", provenance: { actor: "user", source: "fixture", evidence: [] }, relations: [], content: { title, role: "preference", confirmed: false, tags: ["home-profile", "kind-preference", ...extra] } } })).record);
    }
    await expect(change(f, [{ action: "migrate", assignments: created.map(note => ({ id: note.id, expectedRevision: note.revisionId, file: "core" })) }], "migration-refusal")).rejects.toThrow(/note tags/i);
    for (const note of created) expect(await noteAt(f, note.id)).toEqual(note);
    report.cases.push({ id: "F20", failedMigrationKeptAllHeads: true });
  });

  it("F19: scoped caps and explicit contradiction flags refuse before changing Knowledge", async () => {
    const f = await fixture("scope-cap");
    const turns: Step[] = [];
    for (let index = 0; index < 9; index += 1) turns.push(profileCall({ action: "learn", kind: "fact", text: `Scope item ${index}: ${"z".repeat(450)}`, file: "scopes/ios-release", reason: "Relevant release context." }, `scope-cap-${index}`));
    turns.push(say("done"));
    const turn = await homeActivation(f, "Remember release context", turns);
    const results = profileResults(turn.last.messages);
    expect(results.some(result => result.status === "saved")).toBe(true);
    expect(results.at(-1)).toMatchObject({ status: "refused", reason: expect.stringMatching(/scopes\/ios-release.*\d+.*bytes/) });
    const notes = await profileNotes(f);
    const conflict = await homeActivation(f, "This conflicts with an existing item", [profileCall({ action: "learn", kind: "preference", text: "A contradictory proposed rule.", contradicts: [notes[0]!.id] }, "conflicting-save"), say("done")]);
    expect(profileResults(conflict.last.messages).at(-1)).toMatchObject({ status: "refused", reason: expect.stringContaining(notes[0]!.id) });
    expect((await profileNotes(f)).map(note => note.revisionId)).toEqual(notes.map(note => note.revisionId));
    const read = await homeActivation(f, "Read release scope", [profileCall({ action: "read", file: "scopes/ios-release" }, "read-scope"), say("done")]);
    expect(JSON.stringify(read.last.messages)).toContain("Relevant release context.");
    report.cases.push({ id: "F19", accepted: notes.length, refusedWithoutWrites: true, onDemandRead: true });
  });

  it("F17: corrupt and missing Knowledge files diagnose visibly without suppressing healthy profile files", async () => {
    const f = await fixture("damaged-file");
    const notes = [];
    for (const [file, text] of [["core", "Keep accepted core rules."], ["home", "Keep accepted Home rules."], ["scopes/ios-ui", "Scoped context."]]) {
      notes.push((await f.store.createNote({ commandId: command("damaged-seed"), record: { kind: "note", scope: "personal",
        provenance: { actor: "user", source: "fixture", evidence: [] }, relations: [],
        content: { title: text!, role: "fact", confirmed: true, tags: ["home-profile", "kind-fact", `home-file-${file!.replace("/", "-")}`] } } })).record);
    }
    const damaged = notes[2]!;
    const descriptor = await f.registry.knowledgeWorkspace().describe();
    const path = join(descriptor.root, "state", "knowledge", "records", damaged.id, `${damaged.revisionId}.json`);
    await writeFile(path, "{broken", { mode: 0o600 });
    for (const state of ["corrupt", "missing"]) {
      if (state === "missing") await rm(path);
      const turn = await homeActivation(f, `Read ${state} files`, [say("done")]);
      expect(turn.first.systemPrompt).toContain("Keep accepted core rules.");
      expect(turn.first.systemPrompt).toContain("Keep accepted Home rules.");
      expect(turn.first.systemPrompt).toContain(`${damaged.revisionId}.json is missing or corrupt`);
      expect(f.broadcasts.filter(event => event.topic === "session.diagnostic").map(event => (event.payload as { data: unknown }).data)).toContainEqual(expect.objectContaining({ code: "home-profile-load", message: expect.stringContaining(damaged.id) }));
    }
    report.cases.push({ id: "F17", isolatedFailures: ["corrupt", "missing"] });
  });

  it("F16: migration backs up all 21 notes atomically, preserves history, is idempotent and Changes undo restores the flat layout", async () => {
    const f = await fixture("migration");
    for (let index = 0; index < 21; index += 1) {
      await f.store.createNote({ commandId: command("migration-seed"), record: { kind: "note", scope: "personal",
        provenance: { actor: "user", source: "fixture", evidence: [] }, relations: [],
        content: { title: `Durable fixture rule ${index}`, role: index === 20 ? "fact" : "preference", confirmed: index % 2 === 0,
          ...(index === 19 ? { retired: true } : {}), tags: ["home-profile", index === 20 ? "kind-fact" : "kind-preference"] } } });
    }
    const oldest = (await profileNotes(f))[0]!;
    await f.store.updateNote({ commandId: command("earlier-edition"), recordId: oldest.id, expectedRevision: oldest.revisionId, record: { kind: "note", scope: oldest.scope, provenance: oldest.provenance, relations: oldest.relations, content: { ...oldest.content, body: "An additional retained edition." } } });
    const before = await profileNotes(f);
    const assignments = before.map(note => ({ id: note.id, expectedRevision: note.revisionId,
      file: note.content.role === "fact" ? "scopes/ios-ui" : note.content.title.endsWith("0") ? "home" : "core" }));
    await expect(change(f, [{ action: "migrate", assignments: assignments.map((item, index) => index ? item : { ...item, expectedRevision: "stale-revision" }) }], "migration-stale")).rejects.toThrow(/stale/i);
    expect((await profileNotes(f)).map(note => note.revisionId)).toEqual(before.map(note => note.revisionId));
    const migrated = await change(f, [{ action: "migrate", assignments }], "migration");
    expect(migrated.changes).toHaveLength(21);
    const descriptor = await f.registry.knowledgeWorkspace().describe();
    const backupName = (migrated.saved[0] as unknown as { backup: string }).backup;
    const backup = JSON.parse(await readFile(join(descriptor.root, "state", "knowledge", backupName), "utf8")) as { notes: KnowledgeRecord[] };
    expect(backup.notes).toHaveLength(21);
    for (const original of before) {
      const current = await noteAt(f, original.id);
      expect(current.content.title).toBe(original.content.title);
      expect(current.content.role).toBe(original.content.role);
      expect(current.content.confirmed).toBe(original.content.confirmed);
      expect(current.content.retired).toBe(original.content.retired);
      expect(current.content.tags?.filter(tag => tag.startsWith("home-file-"))).toHaveLength(1);
      expect(await noteAt(f, original.id, original.revisionId)).toEqual(original);
    }
    expect(await noteAt(f, oldest.id, oldest.revisionId)).toEqual(oldest);
    const now = await profileNotes(f);
    const repeated = await change(f, [{ action: "migrate", assignments: assignments.map(item => ({ ...item, expectedRevision: now.find(note => note.id === item.id)!.revisionId })) }], "migration-repeat");
    expect(repeated.changes).toEqual([]);
    expect((await profileNotes(f)).map(note => note.revisionId)).toEqual(now.map(note => note.revisionId));
    await undo(f, migrated.changes[0]!.changeId, "migration-undo");
    for (const original of before) expect((await noteAt(f, original.id)).content).toEqual(original.content);
    report.cases.push({ id: "F16", count: before.length, backup: backupName, undo: "restored all original note contents", repeatedChanges: repeated.changes.length });
  });

  it("F14: an over-cap profile save is visibly refused before changing Knowledge", async () => {
    const f = await fixture("cap-admission");
    for (let index = 0; index < 24; index += 1) {
      await f.store.createNote({ commandId: command("seed-cap"), record: { kind: "note", scope: "personal",
        provenance: { actor: "user", source: "fixture", evidence: [] }, relations: [],
        content: { title: `${index}: ${"x".repeat(450)}`, role: "preference", confirmed: true, tags: ["home-profile", "kind-preference"] } } });
    }
    const before = await profileNotes(f);
    const turn = await homeActivation(f, "Save one more preference", [
      profileCall({ action: "learn", kind: "preference", text: "An additional binding rule" }, "over-cap"), say("done"),
    ]);
    const result = profileResults(turn.last.messages).at(-1);
    expect(result?.status).toBe("refused");
    expect(result && "reason" in result ? result.reason : "").toMatch(/core.*\d+.*bytes/i);
    expect((await profileNotes(f)).map(note => note.revisionId)).toEqual(before.map(note => note.revisionId));
    report.cases.push({ id: "F14", result });
  });

  it("F15: an overflowing legacy load retains every binding rule and exposes its file diagnostic", async () => {
    const f = await fixture("cap-load");
    const texts = Array.from({ length: 24 }, (_, index) => `Binding rule ${index}: ${"y".repeat(450)}`);
    for (const text of texts) {
      await f.store.createNote({ commandId: command("seed-load"), record: { kind: "note", scope: "personal",
        provenance: { actor: "user", source: "fixture", evidence: [] }, relations: [],
        content: { title: text, role: "preference", confirmed: true, tags: ["home-profile", "kind-preference"] } } });
    }
    const turn = await homeActivation(f, "Read my rules", [say("done")]);
    for (const text of texts) expect(profileSection(turn.first.systemPrompt)).toContain(text);
    expect(profileSection(turn.first.systemPrompt)).toMatch(/core.*\d+.*bytes/i);
    expect(f.broadcasts.filter(event => event.topic === "session.diagnostic").map(event => (event.payload as { data: unknown }).data)).toContainEqual(expect.objectContaining({ code: "home-profile-load", message: expect.stringMatching(/core.*\d+.*bytes/i) }));
    report.cases.push({ id: "F15", loadedBytes: Buffer.byteLength(profileSection(turn.first.systemPrompt)) });
  });

  it.each([
    { name: "iOS UI change", scopes: ["ios-ui"], ui: true, release: false },
    { name: "iOS release TestFlight", scopes: ["ios-release"], ui: false, release: true },
    { name: "Gateway kernel restructure", scopes: [], ui: false, release: false },
    { name: "web mini-app UI", scopes: ["ios-ui"], ui: true, release: false },
    { name: "game logic project", scopes: ["unknown-game"], ui: false, release: false },
    { name: "settings design UI", scopes: ["ios-ui"], ui: true, release: false },
  ])("F9: deterministic relevant preferences reach a $name brief", async ({ name, scopes, ui, release }) => {
    const f = await fixture("delegate");
    await homeActivation(f, "remember", [
      profileCall({ action: "learn", kind: "delegation-default", text: "Prefer the cheaper model for reviews.", file: "core" }, "call-deleg-1"),
      profileCall({ action: "learn", kind: "standing-decision", text: "Home records decisions in Changes.", file: "home" }, "call-deleg-2"),
      profileCall({ action: "learn", kind: "fact", text: "UI reference: component examples.", file: "scopes/ios-ui" }, "call-deleg-3"),
      profileCall({ action: "learn", kind: "fact", text: "Release reference: signing examples.", file: "scopes/ios-release" }, "call-deleg-4"),
      say("saved"),
    ]);
    const item = (await profileNotes(f)).find(note => note.content.title === "Prefer the cheaper model for reviews.");
    const scoped = (await profileNotes(f)).find(note => note.content.title === "UI reference: component examples.")!;
    await homeActivation(f, "Update scoped context before delegating", [profileCall({ action: "refine", id: scoped.id, text: "UI reference: updated component examples." }, "hot-reload-scope"), say("updated")]);
    // The worker's replies are queued before the delegating activation can start it.
    f.worker.push(() => fauxAssistantMessage(fauxToolCall("report", { resultId: "profile-result-0001", outcome: "final", text: "Reviewed.", evidence: ["checked"] }, { id: "worker-report-0001" }), { stopReason: "toolUse" }));
    f.worker.push(say("done"));
    // The model supplies no preference text: only Gateway selection can deliver it.
    const delegate: Step = (context) => {
      const profile = profileSection(context.systemPrompt);
      expect(profile).toContain("Prefer the cheaper model for reviews.");
      expect(profile).toContain("Home records decisions in Changes.");
      expect(profile).toContain("scopes/ios-ui");
      expect(profile).toContain("scopes/ios-release");
      expect(profile).not.toContain("UI reference: component examples.");
      expect(profile).not.toContain("Release reference: signing examples.");
      return fauxAssistantMessage(fauxToolCall("delegate", { taskId: "profile-task-0001", intent: `Review the ${name} change.`, scopes, target: f.project }, { id: "delegate-call-0001" }), { stopReason: "toolUse" });
    };
    // The delegated task's terminal store write is held at the Home task store boundary, so it is live when
    // teardown starts. Teardown may not return while that write is live (#1020).
    const terminal = holdTerminalWrite(f.registry);
    let teardown: Promise<void> | undefined;
    try {
      await homeActivation(f, "review it", [delegate, say("delegated")]);
      // The canonical initiating chapter retains the exact result even if a fast
      // worker has already woken another chapter or its provider view is folded.
      const admission = f.slot.canonicalSessionEntries().flatMap(entry => entry.type === "message"
        && entry.message.role === "toolResult" && entry.message.toolCallId === "delegate-call-0001" ? [entry.message] : [])[0];
      expect(admission, JSON.stringify(admission)).toMatchObject({ isError: false, details: { taskId: "profile-task-0001",
        sessionId: expect.any(String), operationId: expect.any(String),
        // The resolved worker choice, as the brief states it, for the delegate tool's detail (#957).
        worker: { model: expect.any(String), thinking: expect.any(String), modelSource: expect.any(String), thinkingSource: expect.any(String) } } });
      await waitFor(() => f.captured.some((request) => !request.home && request.blob.includes("Preferences applied")) || undefined, "the worker's first request", { boundMs: 60_000 });
      const worker = f.captured.find((request) => !request.home && request.blob.includes("Preferences applied"))!;
      expect(worker.blob).toContain(`note ${item!.id}`);
      expect(worker.blob).toContain("Prefer the cheaper model for reviews.");
      expect(worker.blob.includes("UI reference: updated component examples.")).toBe(ui);
      expect(worker.blob).not.toContain("UI reference: component examples.");
      expect(worker.blob.includes("Release reference: signing examples.")).toBe(release);
      if (scopes.includes("unknown-game")) {
        expect(worker.blob).toContain("unknown or missing; core remains applied");
        expect(JSON.stringify(admission)).toContain("unknown or missing; core remains applied");
      }
      expect(worker.blob).not.toContain("Home records decisions in Changes.");
      recordCase("scoped-render-bytes", { name, scopes, homeBytes: Buffer.byteLength(profileSection(f.captured.find(request => request.home && request.systemPrompt.includes("scopes/ios-ui"))!.systemPrompt)), briefBytes: Buffer.byteLength(worker.messages.flatMap(message => typeof message.content === "string" ? [message.content] : Array.isArray(message.content) ? message.content.filter(part => part.type === "text").map(part => part.text as string) : []).find(text => text.includes("## Preferences applied"))?.split("## Preferences applied")[1] ?? ""), appliedNoteId: item!.id });
      await terminal.requested;
      teardown = retireFixtures();
      const barrier = await Promise.race([terminal.settling.then(() => "settling" as const), teardown.then(() => "returned" as const)]);
      expect(barrier, "teardown returned before the held terminal write settled").toBe("settling");
      terminal.release();
      await teardown;
      expect(terminal.outcome(), "the held terminal write must be accepted before teardown returns").toBe("accepted");
    } finally {
      terminal.release();
      await terminal.finished();
      // The body has already surfaced any teardown failure; this only ensures teardown is not left pending.
      await teardown?.catch(() => undefined);
    }
    recordCase("brief-carries-preferences", { noteId: item!.id });
  }, 120_000);

});
