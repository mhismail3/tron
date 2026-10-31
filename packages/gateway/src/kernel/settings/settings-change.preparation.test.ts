import { afterEach, expect, it } from "vitest";
import { fixture, disposeFixtures } from "../../test-support/home-task-fixture.js";
import { workspaceModule } from "../../workspace/workspace-module.js";
import { ProfileStore } from "../../modules/home/profile-store.js";
import { HomeProfileItems } from "../../modules/home/home-profile.js";
import type { SubjectWrite } from "./settings-change.js";

let knowledge: ProfileStore | undefined;
afterEach(async () => { knowledge = undefined; await disposeFixtures(); });

it("prepares a cold-readable, idempotent Home audit without applying domain writes", async () => {
  const f = await fixture(false, false, undefined, false, undefined, { knowledge: () => knowledge });
  knowledge = new ProfileStore(f.registry.moduleHost.contract(workspaceModule));
  const changes = f.settings.settingsChanges;
  const context = { commandId: "prepared-profile-command", actor: { kind: "ui" as const, id: "fixture" }, reason: "Profile placement" };
  const replayAt = "2026-01-01T12:00:00.000Z";
  const writes: SubjectWrite[] = [
    { id: "prepared-first", before: null, after: { text: "First" }, direction: "widen" },
    { id: "prepared-second", before: { text: "Old" }, after: { text: "Second" }, direction: "widen", undoOf: "prior-change" },
  ];
  const profile = new HomeProfileItems(() => knowledge);
  const before = [...await profile.values(writes.map(write => write.id))];
  const ref = await changes.prepareSubjectAudit(writes, context, replayAt);
  expect(await changes.prepareSubjectAudit(writes, context, replayAt)).toEqual(ref);
  expect(await changes.readPreparedSubjectAudit(ref)).toEqual({ writes, context, replayAt });
  expect([...await profile.values(writes.map(write => write.id))]).toEqual(before);
  expect((await changes.history({ key: "home.profile.item" })).entries.map(entry => entry.status)).toEqual(["started", "started"]);
  await expect(changes.prepareSubjectAudit([{ ...writes[0]!, direction: "narrow" }], context, replayAt)).rejects.toMatchObject({ code: "invalid_request" });
  await expect(changes.prepareSubjectAudit([{ ...writes[0]!, after: { text: "Conflicting" } }, writes[1]!], context, replayAt))
    .rejects.toMatchObject({ code: "conflict" });
  await expect(changes.readPreparedSubjectAudit({ ...ref, digest: "0".repeat(64) })).rejects.toMatchObject({ code: "conflict" });

  const cold = await f.restartToReadiness();
  knowledge = new ProfileStore(cold.moduleHost.contract(workspaceModule));
  const coldChanges = f.settings.settingsChanges;
  expect(await coldChanges.readPreparedSubjectAudit(ref)).toEqual({ writes, context, replayAt });
  const published = await coldChanges.publishSubjectAudit(writes, context, replayAt);
  expect(published.status).toBe("applied");
  expect((await coldChanges.history({ key: "home.profile.item" })).entries.filter(entry => entry.status === "applied")).toHaveLength(2);
  expect(await coldChanges.prepareSubjectAudit(writes, context, replayAt)).toEqual(ref);
  expect((await coldChanges.history({ key: "home.profile.item" })).entries.filter(entry => entry.status === "started")).toHaveLength(2);
}, 60_000);
