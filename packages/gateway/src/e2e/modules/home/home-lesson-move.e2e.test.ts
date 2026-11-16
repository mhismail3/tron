import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { afterEach, expect, it } from "vitest";
import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { disposeFixtures, fixture } from "../../../../test-support/home-task-fixture.js";
import { displayOwnerOf, homeOwnerOf } from "../../../../test-support/gateway-registry.js";
import { answerChangeCard, maintainerChange } from "../../../../test-support/native-change.js";
import { setHomeMemoryModels } from "../../../../test-support/settings-dependencies.js";
import { waitFor } from "../../../../test-support/wait-for.js";
import { workspaceModule } from "../../../workspace/workspace-module.js";
import { ProfileStore } from "../../../modules/home/profile-store.js";
import { HomeProfileItems } from "../../../modules/home/home-profile.js";
import { CommandReceiptStore } from "../../../transport/command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../../../transport/gateway-service.js";

let knowledge: ProfileStore | undefined;
afterEach(async () => { knowledge = undefined; await disposeFixtures(); });

const phone = { id: "phone", identity: "device:phone", isLocal: false, isSubscribed: () => true, isRevoked: () => false } as unknown as ClientContext;

it("moves a lesson from Profile notes into the global rules through the exact card, refuses stale notes, and Undo restores both", async () => {
  const f = await fixture(false, false, undefined, false, undefined, { knowledge: () => knowledge });
  knowledge = new ProfileStore(f.registry.moduleHost.contract(workspaceModule));
  const profile = new HomeProfileItems(() => knowledge);
  const service = new GatewayService({ display: displayOwnerOf(f.registry), config: { tronHome: f.tronHome, agentDir: f.agentDir },
    modelRuntime: f.gateway, trust: f.trust, settingsModel: f.settings.settingsModel, settingsChanges: f.settings.settingsChanges,
    sessions: f.registry, home: homeOwnerOf(f.registry), receipts: new CommandReceiptStore(f.tronHome), broadcast: () => {},
  } as unknown as GatewayServiceDependencies);
  const rules = join(f.agentDir, "AGENTS.md");
  const original = "# Global rules\n\n- Keep work scoped.\n";
  await writeFile(rules, original);
  const notes = [];
  for (const text of ["Run the owning test first.", "Owning test before the suite.", "Start with the owning test."]) {
    const { saved } = await profile.apply({ action: "learn", kind: "preference", text }, { kind: "maintainer" }, `lesson-note-${notes.length}`);
    notes.push({ id: saved.id, revisionId: saved.revisionId! });
  }
  const move = (revisions: typeof notes) => ({ destination: { kind: "global-rule", file: "AGENTS.md", anchor: "- Keep work scoped." },
    text: "- Run the changed module's owning test before any suite.", retire: { notes: revisions } });
  const model = f.faux.getModel();
  await setHomeMemoryModels(f.registry, [{ provider: model.provider, id: model.id }]);
  const home = await f.registry.acquire(f.home.sessionId);
  const propose = async (lesson: string, value: unknown) => {
    f.faux.setResponses([
      fauxAssistantMessage([fauxToolCall("settings", { action: "change", reason: "Three notes repeat one lesson",
        changes: [{ key: "context.lesson", qualifiers: { lesson }, layer: "global", op: "set", value }] })], { stopReason: "toolUse" }),
      fauxAssistantMessage("Proposed."),
    ]);
    await home.prompt(`Move the lesson ${lesson}`);
    const { interaction, response } = await answerChangeCard(service, phone, home, true, `answer-${lesson}`);
    const outcome = await response.then(() => undefined, (error: Error) => error);
    await waitFor(() => !home.isBusy && home.snapshot().configurationBlocker === null || undefined, "Home settled");
    return { interaction, outcome };
  };

  const first = await propose("owning-test-first", move(notes));
  expect(first.outcome).toBeUndefined();
  expect(JSON.stringify(first.interaction)).toContain("Lesson move");
  expect(JSON.stringify(first.interaction)).toContain("Applying changes the instructions every chat and worker reads.");
  const moved = `# Global rules\n\n- Keep work scoped.\n- Run the changed module's owning test before any suite.\n`;
  expect(await readFile(rules, "utf8")).toBe(moved);
  const afterMove = (await profile.read()).items.filter(item => notes.some(note => note.id === item.id));
  expect(afterMove.map(item => item.status)).toEqual(["retired", "retired", "retired"]);
  const entry = (await f.settings.settingsChanges.history({ key: "context.lesson" }, { kind: "ui", id: "maintainer" })).entries[0]!;
  expect(entry).toMatchObject({ key: "context.lesson", qualifiers: { lesson: "owning-test-first" }, status: "applied" });

  expect((await propose("stale-notes", move(notes))).outcome).toMatchObject({ message: expect.stringMatching(/retired; only an active item can change/u) });
  expect(await readFile(rules, "utf8")).toBe(moved);
  expect((await f.settings.settingsChanges.history({ key: "context.lesson" }, { kind: "ui", id: "maintainer" })).entries
    .filter(row => row.qualifiers?.lesson === "stale-notes" && row.status === "applied")).toEqual([]);

  await maintainerChange(service, phone, "settings.undo", { commandId: "undo-lesson", changeId: entry.changeId });
  expect(await readFile(rules, "utf8")).toBe(original);
  const restored = (await profile.read()).items.filter(item => notes.some(note => note.id === item.id));
  expect(restored.map(item => item.status)).toEqual(["active", "active", "active"]);
}, 60_000);
