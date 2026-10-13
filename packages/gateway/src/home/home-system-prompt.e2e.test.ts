import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
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
});
