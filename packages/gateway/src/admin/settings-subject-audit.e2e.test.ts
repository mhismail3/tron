import * as fs from "node:fs/promises";
import { join } from "node:path";
import { afterEach, expect, it, vi } from "vitest";
import { fixture, disposeFixtures } from "../../test-support/home-task-fixture.js";
import { workspaceModule } from "../workspace/workspace-module.js";
import { KnowledgeStore } from "../knowledge/knowledge-store.js";
import { KnowledgeService } from "../knowledge/knowledge-service.js";
import { HomeProfileItems } from "../modules/home/home-profile.js";
import type { SubjectWrite } from "../kernel/settings/settings-change.js";
import * as durability from "../foundation/durable-json.js";

const evidence: unknown[] = [];
let knowledge: KnowledgeService | undefined;
afterEach(async () => {
  vi.restoreAllMocks(); knowledge?.dispose(); knowledge = undefined;
  await disposeFixtures();
  await fs.mkdir("test-results", { recursive: true });
  await fs.writeFile("test-results/settings-subject-audit.json", JSON.stringify(evidence, null, 2));
});

it("publishes one original Home audit group through file/parent faults, cold retry and real grouped undo", async () => {
  const f = await fixture(false, false, undefined, false, undefined, { knowledge: () => knowledge });
  knowledge = new KnowledgeService(new KnowledgeStore(f.registry.moduleHost.contract(workspaceModule), () => {}));
  const profile = new HomeProfileItems(() => knowledge);
  const changes = f.settings.settingsChanges;
  const context = { commandId: "original-home-audit", actor: { kind: "ui" as const, id: "fixture" }, reason: "Original label plan", web: false };
  const replayAt = "2026-01-01T12:00:00.000Z";
  expect(() => changes.validateSubjectAudit([{ id: "oversize", before: null, after: "x".repeat(1024 * 1024), direction: "widen" }], context, replayAt)).toThrow(/bound/);

  // Real domain effects, deliberately separate from publication/recovery.
  const one = await profile.apply({ action: "learn", kind: "preference", text: "First original instruction" }, { kind: "maintainer" }, "domain-first");
  const two = await profile.apply({ action: "learn", kind: "preference", text: "Second original instruction" }, { kind: "maintainer" }, "domain-second");
  const writes: SubjectWrite[] = [...one.writes, ...two.writes].map(write => ({ ...write, direction: "widen" }));
  changes.validateSubjectAudit(writes, context, replayAt);
  const heads = [...await profile.values(writes.map(write => write.id))];
  await fs.mkdir(changes.record.path, { recursive: true });
  const parent = await fs.stat(changes.record.path); let fileInode: number | undefined;
  let fault: "file" | "directory" | undefined = "directory";
  const sync = durability.syncDurably;
  vi.spyOn(durability, "syncDurably").mockImplementation(async handle => {
    const value = await handle.stat();
    if (fault === "directory" && value.dev === parent.dev && value.ino === parent.ino) throw new Error("Owned audit directory sync fault");
    if (fault === "file" && value.ino === fileInode && value.dev === parent.dev) throw new Error("Owned audit file sync fault");
    await sync(handle);
  });
  await expect(changes.publishSubjectAudit(writes, context, replayAt)).rejects.toThrow("Owned audit directory sync fault");
  expect((await changes.history({ key: "home.profile.item" })).entries).toEqual([]);
  const [name] = (await fs.readdir(changes.record.path)).filter(name => name.startsWith("once-") && name.endsWith(".jsonl"));
  expect(name).toBeDefined(); fileInode = (await fs.stat(join(changes.record.path, name!))).ino;
  fault = "file";
  await expect(changes.publishSubjectAudit(writes, context, replayAt)).rejects.toThrow("Owned audit file sync fault");
  expect((await changes.history({ key: "home.profile.item" })).entries).toEqual([]);
  fault = "directory";
  await expect(changes.publishSubjectAudit(writes, context, replayAt)).rejects.toThrow("Owned audit directory sync fault");
  expect((await changes.history({ key: "home.profile.item" })).entries).toEqual([]);
  fault = undefined;
  const published = await changes.publishSubjectAudit(writes, context, replayAt);
  const original = (await changes.history({ key: "home.profile.item" })).entries;
  expect(original).toHaveLength(2);
  expect(original.every(entry => entry.at === replayAt && entry.commandId === context.commandId && entry.group?.size === 2 && entry.status === "applied")).toBe(true);
  expect(original.map(entry => entry.qualifiers?.note)).toEqual(writes.map(write => write.id).reverse());
  expect([...await profile.values(writes.map(write => write.id))]).toEqual(heads);
  await expect(changes.publishSubjectAudit([...writes].reverse(), context, replayAt)).rejects.toMatchObject({ code: "conflict" });
  expect((await changes.history({ key: "home.profile.item" })).entries).toEqual(original);

  vi.restoreAllMocks(); knowledge.dispose();
  const cold = await f.restartToReadiness();
  knowledge = new KnowledgeService(new KnowledgeStore(cold.moduleHost.contract(workspaceModule), () => {}));
  const current = f.settings.settingsChanges;
  expect(await current.publishSubjectAudit(writes, context, replayAt)).toEqual(published);
  expect((await current.history({ key: "home.profile.item" })).entries).toEqual(original);
  expect([...await profile.values(writes.map(write => write.id))]).toEqual(heads);
  await current.undo(published.changes[0]!.changeId, { actor: { kind: "ui", id: "fixture" }, commandId: "undo-original-group" });
  const restored = [...await profile.values(writes.map(write => write.id))];
  expect(restored.map(([, value]) => value?.state)).toEqual(["retired", "retired"]);
  const audit = (await current.history({ key: "home.profile.item" })).entries;
  expect(audit.filter(entry => entry.undoOf).map(entry => entry.undoOf).sort()).toEqual(published.changes.map(change => change.changeId).sort());
  evidence.push({ published, original, restored, audit });
}, 60_000);
