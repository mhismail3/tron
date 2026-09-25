import { describe, expect, it } from "vitest";
import { InMemoryConnectorCredentialStore } from "../../test-support/connector-credentials.js";
import { JevDecisionClient } from "./jev-client.js";
import { createJevExtension } from "./jev-extension.js";

const answer = JSON.stringify({ model: "jev-1.13.0", answers: { decision: { type: "choice", choice: "unknown", probabilities: { unknown: 1, useful: 0 }, confidence: 1 } }, usage: { input_tokens: 3, output_tokens: 2 } });
describe("first-party Jev tool", () => {
  it("rejects an absent or insufficient charge bound before any external effect", async () => {
    const effects: string[] = []; let tool: any;
    createJevExtension(new JevDecisionClient({ read: async () => { effects.push("key"); return "synthetic"; } }, async () => { effects.push("http"); return { status: 200, body: answer }; }))({ registerTool(value: unknown) { tool = value; } } as any);
    const request = { state: "synthetic", questions: { decision: { type: "choice", instructions: "Choose", criteria: { unknown: null, useful: null } } } };
    for (const maxChargeCents of [undefined, 0, 0.01, NaN, 101]) {
      await expect(tool.execute("tool", { ...request, maxChargeCents }, new AbortController().signal)).rejects.toThrow(/maxChargeCents/);
    }
    expect(effects).toEqual([]);
  });
  it("registers an explicit general typed evaluation without Knowledge state", async () => {
    let tool: any; createJevExtension(new JevDecisionClient(new InMemoryConnectorCredentialStore(new Map([["connector:jev:personal", "synthetic"]])), async () => ({ status: 200, body: answer })))({ registerTool(value: unknown) { tool = value; } } as any);
    expect(tool.name).toBe("jev");
    const result = await tool.execute("tool", { state: { value: 1 }, questions: { decision: { type: "choice", instructions: "Choose", criteria: { unknown: null, useful: null } } }, maxChargeCents: 1 }, new AbortController().signal, undefined, {});
    expect(result.details.actualModel).toBe("jev-1.13.0"); expect(result.details.usage).toEqual({ input_tokens: 3, output_tokens: 2 });
  });
});
