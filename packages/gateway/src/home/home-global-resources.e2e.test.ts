import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { setHomeMemoryModels } from "../../test-support/settings-dependencies.js";
import { disposeFixtures, fixture } from "../../test-support/home-task-fixture.js";
import { waitFor } from "../../test-support/wait-for.js";
import { UploadStore } from "../machine/upload-store.js";
import { CommandReceiptStore } from "../transport/command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../transport/gateway-service.js";

const homes: string[] = [];
afterEach(async () => {
  vi.restoreAllMocks();
  await disposeFixtures();
  await Promise.all(homes.splice(0).map(home => rm(home, { recursive: true, force: true })));
});

type Command = { name: string; source: string; description?: string; resourceScope?: string };

/** User-level (global) prompt and skill commands, as the composer receives them. */
function globalResources(commands: readonly Command[]): string[] {
  return commands.filter(command => (command.source === "prompt" || command.source === "skill") && command.resourceScope === "user")
    .map(command => `${command.name}|${command.description ?? ""}`).sort();
}

function lastUserText(messages: readonly { role: string; content?: unknown }[]): string {
  const content = messages.filter(message => message.role === "user").at(-1)?.content;
  return typeof content === "string" ? content
    : (content as Array<{ type: string; text?: string }>).filter(part => part.type === "text").map(part => part.text).join("");
}

/** A live Home and the Gateway service its composer talks to. Nothing reloads
 * Home explicitly: every resource change below happens on disk while Home is
 * live, and Home must follow it without a new session or a Gateway restart. */
async function liveHome() {
  // `~/.agents/skills` is a global skill input too: keep the host's own out of these lists.
  const userHome = await mkdtemp(join(tmpdir(), "tron-home-resources-"));
  homes.push(userHome);
  vi.stubEnv("HOME", userHome);
  await mkdir(join(userHome, ".agents", "skills"), { recursive: true });
  const f = await fixture();
  const model = f.faux.getModel();
  await setHomeMemoryModels(f.registry, [{ provider: model.provider, id: model.id }]);
  const home = await f.registry.acquire(f.home.sessionId);
  await watchersDeliver(f, userHome);
  const service = new GatewayService({ config: { tronHome: f.tronHome }, sessions: f.registry, home: f.registry.homeOwner(),
    uploads: new UploadStore(join(f.root, "composer-uploads"), 1024),
    receipts: new CommandReceiptStore(join(f.root, "composer-receipts")) } as unknown as GatewayServiceDependencies);
  const client = { id: "resources-client", identity: "device:resources-test", isLocal: true, isSubscribed: () => true, isRevoked: () => false } as unknown as ClientContext;
  const commands = async (sessionId: string) =>
    (await service.invoke(client, "session.commands", { sessionId }) as { commands: Command[] }).commands;
  const prompts: string[] = [];
  let sequence = 0;
  /** One Home turn that inserts `resource`; resolves to the user text the model received. */
  const turn = async (resource: { source: "prompt" | "skill"; name: string }, text: string) => {
    const before = prompts.length;
    f.faux.setResponses([(context) => { prompts.push(lastUserText(context.messages)); return fauxAssistantMessage("ok"); }]);
    sequence += 1;
    await service.invoke(client, "home.prompt", { commandId: `resources-turn-${String(sequence).padStart(4, "0")}`, text,
      resourceInvocations: [{ ...resource, arguments: "" }] });
    await waitFor(() => prompts.length === before + 1, `turn ${sequence} request`);
    await waitFor(() => home.snapshot().configurationBlocker === null && home.snapshot().operation === undefined, `turn ${sequence} settled`);
    return prompts.at(-1)!;
  };
  return { f, home, commands, turn, service, client, userHome };
}

/**
 * Resolves once Home's resource watchers deliver events. `fs.watch` has no readiness
 * signal, and on macOS a write made before its FSEvents stream starts is never reported;
 * under parallel load the cases' first write landed in that window (#1664). Each probe
 * rewrites an input with its own bytes (no resource changes) until Home reloads, seen as
 * a `session.resourcesChanged` broadcast. Nothing here reloads Home itself, so a dead
 * watcher still fails with this label.
 */
async function watchersDeliver(f: { agentDir: string; events: Array<{ topic: string }> }, userHome: string): Promise<void> {
  const reloads = () => f.events.filter(event => event.topic === "session.resourcesChanged").length;
  for (const [input, label] of [[join(f.agentDir, "settings.json"), "agent directory"], [join(userHome, ".agents", "skills", "probe.txt"), "~/.agents/skills"]] as const) {
    const bytes = await readFile(input).catch(() => Buffer.from("probe\n"));
    const before = reloads();
    await waitFor(async () => {
      await writeFile(input, bytes);
      await new Promise(resolve => setTimeout(resolve, 400)); // past the watcher's 150 ms settle
      return reloads() > before;
    }, `Home's ${label} watcher delivers an event`, { intervalMs: 0 });
  }
}

async function writeSkill(agentDir: string, name: string, description: string, body: string): Promise<void> {
  await mkdir(join(agentDir, "skills", name), { recursive: true });
  await writeFile(join(agentDir, "skills", name, "SKILL.md"), `---\nname: ${name}\ndescription: ${description}\n---\n${body}\n`);
}

async function writePrompt(agentDir: string, name: string, description: string, body: string): Promise<void> {
  await mkdir(join(agentDir, "prompts"), { recursive: true });
  await writeFile(join(agentDir, "prompts", `${name}.md`), `---\ndescription: ${description}\n---\n${body}\n`);
}

describe("Home's global skills and prompt templates follow the agent directory live", () => {
  it("lists and uses a global prompt and skill added while Home is live, on its next turn", async () => {
    const { f, home, commands, turn, userHome } = await liveHome();
    expect(globalResources(await commands(home.id))).toEqual([]);

    await writePrompt(f.agentDir, "deeper", "Go deeper", "DEEPER PROMPT BODY");
    await writeSkill(f.agentDir, "late-skill", "Late skill", "LATE SKILL BODY");
    await writeSkill(join(userHome, ".agents"), "agents-skill", "Agents skill", "AGENTS SKILL BODY");

    let listed: string[] = [];
    await waitFor(async () => (listed = globalResources(await commands(home.id))).length === 3, "Home lists the added resources");
    expect(listed).toEqual(["deeper|Go deeper", "skill:agents-skill|Agents skill", "skill:late-skill|Late skill"]);
    expect(f.events.some(event => event.topic === "session.resourcesChanged")).toBe(true);
    expect(await turn({ source: "prompt", name: "deeper" }, "now")).toBe("DEEPER PROMPT BODY\n\nnow");
    expect(await turn({ source: "skill", name: "late-skill" }, "apply")).toContain("LATE SKILL BODY");
  }, 60_000);

  it("lists a skill's frontmatter title for display without changing its name or adding a loader diagnostic", async () => {
    const { f, home, commands, service, client } = await liveHome();
    await mkdir(join(f.agentDir, "skills", "last30days"), { recursive: true });
    await writeFile(join(f.agentDir, "skills", "last30days", "SKILL.md"),
      "---\nname: last30days\ntitle: Last 30 Days\ndescription: Recent research\n---\nBODY\n");
    await writeSkill(f.agentDir, "jev", "Typed decisions", "BODY");
    let skills: Array<Command & { title?: string }> = [];
    await waitFor(async () => (skills = (await commands(home.id)).filter(command => command.source === "skill" && command.resourceScope === "user")).length === 2, "Home lists both skills");
    expect(skills.map(skill => [skill.name, skill.title])).toEqual([["skill:jev", undefined], ["skill:last30days", "Last 30 Days"]]);
    const resources = await service.invoke(client, "session.resources", { sessionId: home.id }) as { skills: { diagnostics: unknown[] } };
    expect(resources.skills.diagnostics).toEqual([]);
  }, 60_000);

  it("follows edits and deletions, and lists the same global resources as an ordinary chat", async () => {
    const { f, home, commands, turn } = await liveHome();
    await writePrompt(f.agentDir, "deeper", "Go deeper", "FIRST BODY");
    await writeSkill(f.agentDir, "kept-skill", "Kept skill", "KEPT BODY");
    await writeSkill(f.agentDir, "doomed-skill", "Doomed skill", "DOOMED BODY");
    await waitFor(async () => globalResources(await commands(home.id)).length === 3, "Home lists the first set");

    await writePrompt(f.agentDir, "deeper", "Go much deeper", "SECOND BODY");
    await rm(join(f.agentDir, "skills", "doomed-skill"), { recursive: true });
    const expected = ["deeper|Go much deeper", "skill:kept-skill|Kept skill"];
    await waitFor(async () => JSON.stringify(globalResources(await commands(home.id))) === JSON.stringify(expected), "Home follows the edit and deletion");
    expect(await turn({ source: "prompt", name: "deeper" }, "again")).toBe("SECOND BODY\n\nagain");

    // A skills root deleted and recreated is still followed.
    await rm(join(f.agentDir, "skills"), { recursive: true });
    await waitFor(async () => !globalResources(await commands(home.id)).includes("skill:kept-skill|Kept skill"), "Home drops the deleted root");
    await writeSkill(f.agentDir, "kept-skill", "Kept skill", "KEPT BODY");
    await waitFor(async () => JSON.stringify(globalResources(await commands(home.id))) === JSON.stringify(expected), "Home follows the recreated root");

    // An ordinary chat in a trusted project lists exactly the same global set.
    const chat = await f.registry.create(f.cwd);
    expect(globalResources(await commands(chat.id))).toEqual(expected);
  }, 60_000);

  it("does not reload Home for agent-directory writes made before its watchers started (#1694)", async () => {
    const userHome = await mkdtemp(join(tmpdir(), "tron-home-resources-"));
    homes.push(userHome);
    vi.stubEnv("HOME", userHome);
    const f = await fixture();
    // A conversation file exists only after its first message, which a cold registry needs to find Home.
    const greeted = await f.registry.acquire(f.home.sessionId);
    f.faux.setResponses([fauxAssistantMessage("Hello.")]);
    await greeted.prompt("Hello");
    await waitFor(() => !greeted.isBusy && greeted.snapshot().operation === undefined, "greeting settled");
    // An outside write lands just before the Gateway starts and arms Home's watchers;
    // macOS FSEvents may still report it once the new stream starts.
    const settings = await readFile(join(f.agentDir, "settings.json"));
    await f.registry.dispose();
    await writeFile(join(f.agentDir, "settings.json"), settings);
    const restarted = await f.restartToReadiness();
    const before = f.events.length;
    await restarted.acquire(f.home.sessionId);
    // Past FSEvents delivery latency and the watcher's 150 ms settle.
    await new Promise(resolve => setTimeout(resolve, 1_500));
    expect(f.events.slice(before).filter(event => event.topic === "session.resourcesChanged")).toEqual([]);
    // The watcher is live: a real write after it started still reloads Home.
    await writePrompt(f.agentDir, "after-start", "Written after start", "BODY");
    await waitFor(() => f.events.slice(before).some(event => event.topic === "session.resourcesChanged"), "Home reloads for a write after its watchers started");
  }, 60_000);

  it("applies a change made during a Home run once that run settles", async () => {
    const { f, home, commands, service, client } = await liveHome();
    let release!: () => void;
    const gate = new Promise<void>(resolve => { release = resolve; });
    let started = false;
    f.faux.setResponses([async () => { started = true; await gate; return fauxAssistantMessage("done"); }]);
    await service.invoke(client, "home.prompt", { commandId: "resources-busy-0001", text: "long work" });
    await waitFor(() => started, "Home run started");
    await writePrompt(f.agentDir, "during-run", "Written mid-run", "MID RUN BODY");
    // Let the change notification land while Home still runs, so it must wait for idle.
    await new Promise(resolve => setTimeout(resolve, 1_000));
    expect(home.snapshot().operation).toBeDefined();
    release();
    await waitFor(async () => globalResources(await commands(home.id)).includes("during-run|Written mid-run"), "Home lists the mid-run prompt");
  }, 60_000);
});
