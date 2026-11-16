import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { parseFrontmatter } from "@earendil-works/pi-coding-agent";
import { afterEach, expect, it, vi } from "vitest";
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
afterEach(async () => { vi.restoreAllMocks(); knowledge = undefined; await disposeFixtures(); });

const phone = { id: "phone", identity: "device:phone", isLocal: false, isSubscribed: () => true, isRevoked: () => false } as unknown as ClientContext;

async function setup() {
  const f = await fixture(false, false, undefined, false, undefined, { knowledge: () => knowledge });
  knowledge = new ProfileStore(f.registry.moduleHost.contract(workspaceModule));
  const profile = new HomeProfileItems(() => knowledge);
  const service = new GatewayService({ display: displayOwnerOf(f.registry), config: { tronHome: f.tronHome, agentDir: f.agentDir },
    modelRuntime: f.gateway, trust: f.trust, settingsModel: f.settings.settingsModel, settingsChanges: f.settings.settingsChanges,
    sessions: f.registry, home: homeOwnerOf(f.registry), receipts: new CommandReceiptStore(f.tronHome), broadcast: () => {},
  } as unknown as GatewayServiceDependencies);
  const model = f.faux.getModel();
  await setHomeMemoryModels(f.registry, [{ provider: model.provider, id: model.id }]);
  const home = await f.registry.acquire(f.home.sessionId);
  let learned = 0;
  const learn = async (texts: readonly string[]) => {
    const notes: Array<{ id: string; revisionId: string; text: string }> = [];
    for (const text of texts) {
      const { saved } = await profile.apply({ action: "learn", kind: "preference", text }, { kind: "maintainer" }, `lesson-note-${++learned}`);
      notes.push({ id: saved.id, revisionId: saved.revisionId!, text });
    }
    return notes;
  };
  const statuses = async (notes: ReadonlyArray<{ id: string }>) => (await profile.read()).items
    .filter(item => notes.some(note => note.id === item.id)).map(item => item.status);
  const applied = async (lesson: string) => (await f.settings.settingsChanges.history({ key: "context.lesson" }, { kind: "ui", id: "maintainer" })).entries
    .find(row => row.qualifiers?.lesson === lesson && row.status === "applied");
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
  const undo = (changeId: string, commandId: string) => maintainerChange(service, phone, "settings.undo", { commandId, changeId });
  return { f, learn, statuses, applied, propose, undo };
}

it("moves a lesson from Profile notes into the global rules through the exact card, refuses stale notes, and Undo restores both or neither", async () => {
  const { f, learn, statuses, applied, propose, undo } = await setup();
  const rules = join(f.agentDir, "AGENTS.md");
  const original = "# Global rules\n\n- Keep work scoped.\n";
  await writeFile(rules, original);
  const notes = await learn(["Run the owning test first.", "Owning test before the suite.", "Start with the owning test."]);
  const move = { destination: { kind: "global-rule", file: "AGENTS.md", anchor: "- Keep work scoped." },
    text: "- Run the changed module's owning test before any suite.", retire: { notes } };

  const first = await propose("owning-test-first", move);
  expect(first.outcome).toBeUndefined();
  const card = JSON.stringify(first.interaction);
  expect(card).toContain("Lesson move");
  expect(card).toContain("Applying changes the instructions every chat and worker reads.");
  for (const note of notes) expect(card).toContain(note.text);
  const moved = `# Global rules\n\n- Keep work scoped.\n- Run the changed module's owning test before any suite.\n`;
  expect(await readFile(rules, "utf8")).toBe(moved);
  expect(await statuses(notes)).toEqual(["retired", "retired", "retired"]);
  const entry = (await applied("owning-test-first"))!;

  expect((await propose("stale-notes", move)).outcome).toMatchObject({ message: expect.stringMatching(/no longer the active revision you read/u) });
  expect(await readFile(rules, "utf8")).toBe(moved);
  expect(await applied("stale-notes")).toBeUndefined();

  const restore = HomeProfileItems.prototype.restore;
  let calls = 0;
  vi.spyOn(HomeProfileItems.prototype, "restore").mockImplementation(async function (this: HomeProfileItems, ...args) {
    calls += 1;
    if (calls === 1) {
      await restore.call(this, [args[0][0]!], ...args.slice(1) as [never, never]);
      throw new Error("Profile restore interrupted");
    }
    return restore.apply(this, args);
  });
  await expect(undo(entry.changeId, "undo-lesson-interrupted")).rejects.toThrow(/Profile restore interrupted/u);
  expect(await readFile(rules, "utf8")).toBe(moved);
  expect(await statuses(notes)).toEqual(["retired", "retired", "retired"]);
  vi.restoreAllMocks();

  await undo(entry.changeId, "undo-lesson");
  expect(await readFile(rules, "utf8")).toBe(original);
  expect(await statuses(notes)).toEqual(["active", "active", "active"]);
}, 90_000);

it("moves a lesson into a global skill description with YAML-hostile text, exactly, and Undo restores the bytes", async () => {
  const { f, learn, applied, propose, undo } = await setup();
  const skill = join(f.agentDir, "skills", "lesson-skill", "SKILL.md");
  await mkdir(dirname(skill), { recursive: true });
  const skillBefore = "---\nname: lesson-skill\ndescription: \"Old: description\"\n---\nBody\n";
  await writeFile(skill, skillBefore);
  const skillMove = { destination: { kind: "global-skill-description", skill: "lesson-skill" }, replaces: "Old: description",
    text: "Before a suite: run the owning test $' first.", retire: { notes: await learn(["Skill lesson note."]) } };
  expect((await propose("skill-description", skillMove)).outcome).toBeUndefined();
  expect(parseFrontmatter<{ description: string }>(await readFile(skill, "utf8")).frontmatter.description).toBe(skillMove.text);
  await undo((await applied("skill-description"))!.changeId, "undo-skill-lesson");
  expect(await readFile(skill, "utf8")).toBe(skillBefore);
}, 90_000);
