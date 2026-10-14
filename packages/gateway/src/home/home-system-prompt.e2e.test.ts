import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { UploadStore } from "../machine/upload-store.js";
import { CommandReceiptStore } from "../transport/command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../transport/gateway-service.js";
import { disposeFixtures, fixture } from "../../test-support/home-task-fixture.js";
import { waitFor } from "../../test-support/wait-for.js";

afterEach(async () => {
  vi.restoreAllMocks();
  await disposeFixtures();
});

/** The system messages one provider request carries, as their text. */
function systemTexts(messages: readonly { role: string; content?: unknown }[]): string[] {
  return messages.filter(message => message.role === "system").map(message => String(message.content));
}

/** The text of the last user message one provider request carries. */
function lastUserText(messages: readonly { role: string; content?: unknown }[]): string {
  const content = messages.filter(message => message.role === "user").at(-1)?.content;
  return typeof content === "string" ? content
    : (content as Array<{ type: string; text?: string }>).filter(part => part.type === "text").map(part => part.text).join("");
}

describe("Home system prompt at the request seam", () => {
  it("frames every request of a user activation with one identical Home system prompt", async () => {
    const f = await fixture();
    const model = f.faux.getModel();
    await f.registry.homeOwner().configureMemory({ model: { provider: model.provider, id: model.id } });
    const home = await f.registry.acquire(f.home.sessionId);
    const systems: string[][] = [];
    // One activation with a tool loop: two provider requests that must carry identical system bytes.
    f.faux.setResponses([
      (context) => { systems.push(systemTexts(context.messages)); return fauxAssistantMessage([fauxToolCall("memory_search", { query: "earlier" })], { stopReason: "toolUse" }); },
      (context) => { systems.push(systemTexts(context.messages)); return fauxAssistantMessage("first reply"); },
    ]);
    await home.prompt("first input");
    await waitFor(() => home.snapshot().configurationBlocker === null && home.snapshot().operation === undefined, "activation settled");
    expect(systems).toHaveLength(2);
    for (const system of systems) {
      expect(system).toHaveLength(1);
      expect(system[0]).toContain("## Tron Home");
      expect(system[0]).toContain("## Learned profile");
    }
    expect(systems[1]).toEqual(systems[0]);
  }, 30_000);

  it("offers user-level skills and prompts to Home's composer and sends only the inserted one, in the user message", async () => {
    const f = await fixture();
    const model = f.faux.getModel();
    await f.registry.homeOwner().configureMemory({ model: { provider: model.provider, id: model.id } });
    const home = await f.registry.acquire(f.home.sessionId);
    // User-level resources in the agent directory, and project resources in Home's own
    // directory, trusted so only Home's guard keeps them out.
    await mkdir(join(f.agentDir, "skills", "global-skill"), { recursive: true });
    await writeFile(join(f.agentDir, "skills", "global-skill", "SKILL.md"),
      "---\nname: global-skill\ndescription: Global skill description marker.\n---\nGLOBAL SKILL BODY\n");
    await mkdir(join(f.agentDir, "prompts"), { recursive: true });
    await writeFile(join(f.agentDir, "prompts", "global-prompt.md"), "---\ndescription: Global prompt\n---\nGLOBAL PROMPT BODY $@\n");
    await mkdir(join(home.cwd, ".pi", "skills", "project-skill"), { recursive: true });
    await writeFile(join(home.cwd, ".pi", "skills", "project-skill", "SKILL.md"), "---\nname: project-skill\ndescription: Project skill.\n---\nPROJECT\n");
    await mkdir(join(home.cwd, ".pi", "prompts"), { recursive: true });
    await writeFile(join(home.cwd, ".pi", "prompts", "project-prompt.md"), "PROJECT PROMPT\n");
    await f.trust.set(home.cwd, true);
    // A trust transition reload is the strongest admission path for project resources.
    await home.reload(true);

    const service = new GatewayService({ config: { tronHome: f.tronHome }, sessions: f.registry, home: f.registry.homeOwner(),
      uploads: new UploadStore(join(f.root, "composer-uploads"), 1024),
      receipts: new CommandReceiptStore(join(f.root, "composer-receipts")) } as unknown as GatewayServiceDependencies);
    const client = { id: "composer-client", identity: "device:composer-test", isLocal: true, isSubscribed: () => true, isRevoked: () => false } as unknown as ClientContext;

    // The composer pickers' catalog.
    const { commands } = await service.invoke(client, "session.commands", { sessionId: home.id }) as { commands: Array<{ name: string; source: string; resourceScope?: string }> };
    expect(commands).toEqual(expect.arrayContaining([
      expect.objectContaining({ name: "skill:global-skill", source: "skill", resourceScope: "user" }),
      expect.objectContaining({ name: "global-prompt", source: "prompt", resourceScope: "user" }),
    ]));
    expect(commands.map(command => command.name)).not.toEqual(expect.arrayContaining(["skill:project-skill"]));
    expect(commands.map(command => command.name)).not.toContain("project-prompt");

    const requests: Array<{ system: string[]; user: string }> = [];
    const capture = (reply: string) => (context: { messages: Array<{ role: string; content?: unknown }> }) => {
      requests.push({ system: systemTexts(context.messages), user: lastUserText(context.messages) });
      return fauxAssistantMessage(reply);
    };
    const settle = (label: string) => waitFor(() => home.snapshot().configurationBlocker === null && home.snapshot().operation === undefined, label);
    f.faux.setResponses([capture("plain"), capture("skill"), capture("prompt")]);
    await service.invoke(client, "home.prompt", { commandId: "composer-plain-0001", text: "plain message" });
    await waitFor(() => requests.length === 1, "plain request");
    await settle("plain settled");
    await service.invoke(client, "home.prompt", { commandId: "composer-skill-0001", text: "apply it",
      resourceInvocation: { source: "skill", name: "global-skill", arguments: "apply it" } });
    await waitFor(() => requests.length === 2, "skill request");
    await settle("skill settled");
    await service.invoke(client, "home.prompt", { commandId: "composer-prompt-0001", text: "argument",
      resourceInvocation: { source: "prompt", name: "global-prompt", arguments: "argument" } });
    await waitFor(() => requests.length === 3, "prompt request");
    await settle("prompt settled");

    // The inserted resource is expanded into that user message, as in an ordinary chat.
    expect(requests[0]!.user).toBe("plain message");
    expect(requests[1]!.user).toContain('<skill name="global-skill"');
    expect(requests[1]!.user).toContain("GLOBAL SKILL BODY");
    expect(requests[1]!.user.endsWith("apply it")).toBe(true);
    expect(requests[2]!.user).toBe("GLOBAL PROMPT BODY argument");
    // Home's system prompt is unchanged: no skill or prompt is listed or loaded into it.
    for (const request of requests) {
      expect(request.system).toHaveLength(1);
      expect(request.system[0]).not.toContain("global-skill");
      expect(request.system[0]).not.toContain("Global skill description marker");
      expect(request.system[0]).not.toContain("GLOBAL PROMPT BODY");
      expect(request.system[0]).not.toContain("<skills>");
    }
    expect(requests[1]!.system).toEqual(requests[0]!.system);
    expect(requests[2]!.system).toEqual(requests[0]!.system);
  }, 30_000);
});
