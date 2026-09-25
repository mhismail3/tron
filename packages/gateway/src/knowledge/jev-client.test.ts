import { describe, expect, it } from "vitest";
import { InMemoryConnectorCredentialStore } from "../../test-support/connector-credentials.js";
import { JevDecisionClient, JEV_DEFAULT_MODEL, type JevDecisionRequest } from "./jev-client.js";

const credentials = () => new InMemoryConnectorCredentialStore(new Map([["connector:jev:personal", "synthetic-key"]]));
const request = (state: unknown = { text: "bounded" }): JevDecisionRequest => ({ state, questions: {
  yes: { type: "noul", instructions: "Is this useful?" },
  kind: { type: "choice", instructions: "Choose a kind", criteria: { unknown: null, useful: "Useful" } },
  level: { type: "score", instructions: "Score usefulness", criteria: ["none", "some", "high"] },
} });
const body = (answers: Record<string, unknown>) => JSON.stringify({ model: JEV_DEFAULT_MODEL, answers, usage: { input_tokens: 10, output_tokens: 5 } });
const valid = { yes: { type: "noul", noul: 0.5 }, kind: { type: "choice", choice: "unknown", probabilities: { unknown: 0.8, useful: 0.2 }, confidence: 0.7 }, level: { type: "score", score: 1.2, legend: { "0": "none", "1": "some", "2": "high" }, probabilities: { "0": 0.1, "1": 0.6, "2": 0.3 }, confidence: 0.8 } };
function client(response: string, calls: string[] = []) { return { client: new JevDecisionClient(credentials(), async (_url, init) => { calls.push(init.body); return { status: 200, body: response }; }), calls }; }

describe("JevDecisionClient", () => {
  it("rejects a per-call cost ceiling before credentials, admission or HTTP", async () => {
    const effects: string[] = [];
    const value = new JevDecisionClient({ read: async () => { effects.push("credential"); return "synthetic"; } }, async () => { effects.push("post"); return { status: 200, body: body(valid) }; });
    await expect(value.evaluate(request(), new AbortController().signal, { maxChargeCents: 0.01, beforeDispatch: async () => { effects.push("admit"); } })).rejects.toThrow(/before dispatch/);
    expect(effects).toEqual([]);
  });
  it("returns published fractional-cent pricing rather than rounding every call to a cent", async () => {
    const result = await client(body(valid)).client.evaluate(request(), new AbortController().signal, { maxChargeCents: 1 });
    expect(result.estimatedCostCents).toBeCloseTo(0.000042, 10);
    expect(result.maxEstimatedChargeCents).toBeCloseTo(0.2688, 10);
  });
  it("does not dispatch a stale blocked epoch after disable and re-enable", async () => {
    const calls: string[] = [];
    const fixture = new JevDecisionClient(credentials(), async (_url, init) => { calls.push(init.body); return { status: 200, body: body(valid) }; });
    let epoch = 1;
    let enabled = false;
    let release!: () => void;
    const hold = new Promise<void>(resolve => { release = resolve; });
    const blocked = fixture.evaluate(request(), new AbortController().signal, { beforeDispatch: async () => {
      const captured = epoch;
      await hold;
      if (!enabled || captured !== epoch) throw new Error("admission blocked");
    }});
    await Promise.resolve();
    epoch = 2;
    enabled = true;
    release();
    await expect(blocked).rejects.toThrow("admission blocked");
    await fixture.evaluate(request(), new AbortController().signal, { beforeDispatch: async () => {} });
    expect(calls).toHaveLength(1);
  });

  it("does not dispatch after cancellation during admission", async () => {
    const controller = new AbortController(); const fixture = client(body(valid));
    await expect(fixture.client.evaluate(request(), controller.signal, { beforeDispatch: async () => { controller.abort(); } })).rejects.toThrow(/cancelled/);
    expect(fixture.calls).toEqual([]);
  });
  it("snapshots the admitted rubric and rejects extra answers", async () => {
    const input = request(); const fixture = client(body(valid));
    await fixture.client.evaluate(input, new AbortController().signal, { beforeDispatch: async () => { input.questions.kind = { type: "noul", instructions: "changed" }; } });
    expect(JSON.parse(fixture.calls[0]!).questions.kind.type).toBe("choice");
    await expect(client(body({ ...valid, extra: valid.yes })).client.evaluate(request(), new AbortController().signal)).rejects.toThrow(/invalid/);
  });
  it("bounds state plus a single question and rejects non-JSON inputs before HTTP", async () => {
    const fixture = client(body(valid));
    const input = request("x".repeat(20_000)); input.questions.yes!.instructions = "x".repeat(10_000);
    await expect(fixture.client.evaluate(input, new AbortController().signal)).rejects.toThrow(/bound/);
    await expect(fixture.client.evaluate(request({ value: NaN }), new AbortController().signal)).rejects.toThrow(/invalid/);
    const cyclic: Record<string, unknown> = {}; cyclic.self = cyclic;
    await expect(fixture.client.evaluate(request(cyclic), new AbortController().signal)).rejects.toThrow(/invalid/);
    expect(fixture.calls).toEqual([]);
  });
  it("redacts transport failures and performs no retry", async () => {
    let calls = 0;
    const value = new JevDecisionClient(credentials(), async () => { calls++; throw new Error("secret provider text"); });
    await expect(value.evaluate(request(), new AbortController().signal)).rejects.toThrow(/^Jev provider request failed$/);
    expect(calls).toBe(1);
  });
  it("validates reusable noul, choice, and fractional score answers for distinct callers", async () => {
    const fixture = client(body(valid)); const result = await fixture.client.evaluate(request(), new AbortController().signal);
    expect(result.requestedModel).toBe(JEV_DEFAULT_MODEL); expect(result.actualModel).toBe(JEV_DEFAULT_MODEL); expect(result.answers.kind).toMatchObject({ choice: "unknown" }); expect(result.answers.level).toMatchObject({ score: 1.2 });
    const second = client(body({ decision: { type: "choice", choice: "a", probabilities: { a: 1, b: 0 }, confidence: 1 } }));
    await second.client.evaluate({ state: ["other"], questions: { decision: { type: "choice", instructions: "Choose", criteria: { a: null, b: null } } } }, new AbortController().signal);
    expect(fixture.calls).toHaveLength(1); expect(second.calls).toHaveLength(1);
  });
  it("rejects invalid input before credential or HTTP and rejects mismatched probability shapes", async () => {
    const fixture = client(body(valid));
    await expect(fixture.client.evaluate({ ...request("x".repeat(24_001)) }, new AbortController().signal)).rejects.toThrow(/bound/);
    await expect(fixture.client.evaluate({ ...request(), questions: { x: { type: "choice", instructions: "x", criteria: { a: null } } } }, new AbortController().signal)).rejects.toThrow(/invalid/);
    expect(fixture.calls).toHaveLength(0);
    const mismatch = client(body({ ...valid, kind: { ...valid.kind, choice: "useful" } }));
    await expect(mismatch.client.evaluate(request(), new AbortController().signal)).rejects.toThrow(/invalid/);
  });
  it("runs admission immediately before the only paid POST and sanitizes malformed responses", async () => {
    const order: string[] = []; const fixture = { client: new JevDecisionClient(credentials(), async (_url, init) => { order.push("post"); return { status: 200, body: body(valid) }; }) };
    await fixture.client.evaluate(request(), new AbortController().signal, { beforeDispatch: async () => { order.push("admit"); } }); expect(order).toEqual(["admit", "post"]);
    const malformed = client("provider-secret-body"); await expect(malformed.client.evaluate(request(), new AbortController().signal)).rejects.toThrow(/invalid/);
  });
});
