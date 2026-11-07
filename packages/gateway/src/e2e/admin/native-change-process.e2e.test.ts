import { afterEach, describe, expect, it } from "vitest";
import { BACKGROUND_MODEL, SCRIPTED_MODEL, SCRIPTED_PROVIDER, startGatewayProcess, type GatewayProcess, type ProcessClient } from "../../../test-support/gateway-process.js";
import { waitFor } from "../../../test-support/wait-for.js";

/**
 * Exact-tap refusals and a once-only effect for the shared change card at the
 * client socket of a real Gateway process (#2232): a source Gateway process, a
 * device paired through `POST /v1/pair` and the Mac's local credential over the
 * production loopback WebSocket, and a scripted HTTP provider as the only
 * scripted party. Home's model asks for a task-budget raise, which needs the card.
 */

const gateways: GatewayProcess[] = [];
afterEach(async () => { await Promise.all(gateways.splice(0).map((gateway) => gateway.dispose())); });

const KEY = "permissions.budget.task";

async function ok(client: ProcessClient, method: string, params: Record<string, unknown>): Promise<any> {
  const response = await client.request(method, params);
  expect(response.ok, `${method}: ${JSON.stringify(response)}`).toBe(true);
  return response.result;
}

async function open(client: ProcessClient, sessionId: string): Promise<Record<string, any>> {
  const opened = await ok(client, "session.open", { sessionId });
  await ok(client, "session.sync", { sessionId, syncToken: opened.syncToken });
  return opened.session;
}

async function homeWithBudget(): Promise<{ gateway: GatewayProcess; phone: ProcessClient; mac: ProcessClient; homeId: string; budgetChange: (outputTokens: number, label: string) => Promise<Record<string, any>> }> {
  const gateway = await startGatewayProcess();
  gateways.push(gateway);
  const phone = await gateway.connect({ token: (await gateway.pair("Fixture iPhone")).token });
  const mac = await gateway.connect();
  const { sessionId: homeId } = await ok(phone, "home.designate", { commandId: "tap-designate", model: { provider: SCRIPTED_PROVIDER, id: SCRIPTED_MODEL } });
  await ok(phone, "settings.change", { commandId: "tap-background-queue", target: { kind: "home" }, changes: [
    { key: "model.queue[role=background]", layer: "session", op: "set", value: [`${SCRIPTED_PROVIDER}/${BACKGROUND_MODEL}`] },
  ] });
  // Home memory's summaries go to the background model, answered apart from the scripted turns.
  gateway.provider.answerModel(BACKGROUND_MODEL, () => ({ chunks: ["Memory line."] }));
  await open(phone, homeId);
  /** Home's model requests one budget change; resolves with the settled turn or its pending card. */
  const budgetChange = async (outputTokens: number, label: string) => {
    gateway.provider.script([
      () => ({ toolCalls: [{ id: `budget-${label}`, name: "settings", arguments: { action: "change", reason: `Budget ${label}`,
        changes: [{ key: KEY, layer: "session", op: "set", value: { outputTokens } }] } }] }),
      () => ({ chunks: [`Budget ${label} handled.`] }),
    ]);
    await ok(phone, "home.prompt", { commandId: `tap-prompt-${label}`, text: `Set the task budget (${label}).` });
    return await waitFor(async () => {
      const home = await open(phone, homeId);
      const card = home.extensionPresentation?.pendingInteractions?.[0];
      if (card) return { card };
      return home.phase === "idle" && JSON.stringify(home.transcript).includes(`Budget ${label} handled.`) ? { home } : undefined;
    }, `budget ${label} reached its card or settled`);
  };
  // An initial budget applies without a card; a raise needs one.
  const initial = await budgetChange(100, "initial");
  expect(initial.card).toBeUndefined();
  return { gateway, phone, mac, homeId, budgetChange };
}

describe("the shared change card across the client socket of a real Gateway process", () => {
  it("refuses local, wrong-digest, retired and stale answers without effect, then applies one tap once (#2232)", async () => {
    const { gateway, phone, mac, homeId, budgetChange } = await homeWithBudget();
    const budget = async () => (await ok(phone, "settings.resolve", { target: { kind: "home" }, keys: [KEY] })).keys[0].value;
    const history = async () => (await ok(phone, "settings.history", { key: KEY })).entries as Array<Record<string, any>>;
    expect(await budget()).toEqual({ outputTokens: 100 });
    const historyBefore = await history();

    const { card } = await budgetChange(200, "raise");
    expect(card).toMatchObject({ method: "change", review: { requiresTap: true } });
    let sequence = 0;
    const answer = (client: ProcessClient, overrides: Record<string, unknown>, value: unknown) => client.request("extension.respond", {
      commandId: `tap-response-${++sequence}`, sessionId: homeId, interactionId: card.id,
      hostEpoch: card.hostEpoch, presentationRevision: card.presentationRevision, value, ...overrides,
    });
    const exact = { digest: card.review.digest, approved: true };
    // The Mac's local client has the session open too: its refusal is the device rule, not a missing subscription.
    await open(mac, homeId);
    const refusals = [
      // A local (Mac) answer is not a paired-device tap.
      [await answer(mac, {}, exact), "invalid_request"],
      [await answer(phone, {}, { digest: "0".repeat(64), approved: true }), "invalid_request"],
      [await answer(phone, { hostEpoch: "retired" }, exact), "conflict"],
      [await answer(phone, { presentationRevision: card.presentationRevision + 1 }, exact), "conflict"],
    ] as const;
    for (const [response, code] of refusals) {
      expect(response.ok, JSON.stringify(response)).toBe(false);
      expect(response.error.code, JSON.stringify(response)).toBe(code);
      // Local and wrong-digest answers share the exact-review refusal (semantic-ui-broker.ts).
      if (code === "invalid_request") expect(response.error.message).toBe("Native change response does not match its exact review");
    }
    // Each refusal left the card pending and wrote nothing.
    expect((await open(phone, homeId)).extensionPresentation.pendingInteractions.map((item: { id: string }) => item.id)).toEqual([card.id]);
    expect(await budget()).toEqual({ outputTokens: 100 });
    expect(await history()).toEqual(historyBefore);

    // Two exact taps race: one is answered, the other finds no card, the effect lands once.
    const taps = await Promise.all([answer(phone, {}, exact), answer(phone, {}, exact)]);
    expect(taps.filter((tap) => tap.ok).map((tap) => tap.result)).toEqual([{ answered: true }]);
    expect(taps.filter((tap) => !tap.ok).map((tap) => tap.error.code)).toEqual(["not_found"]);
    const settled = await waitFor(async () => {
      const home = await open(phone, homeId);
      return home.phase === "idle" && JSON.stringify(home.transcript).includes("Budget raise handled.") ? home : undefined;
    }, "the approved raise settled");
    expect(await budget()).toEqual({ outputTokens: 200 });
    const raised = (await history()).filter((entry) => !historyBefore.some((before) => before.changeId === entry.changeId));
    expect(raised).toHaveLength(1);
    expect(raised[0]).toMatchObject({ status: "applied", after: { outputTokens: 200 } });
    expect(settled.transcript.find((item: Record<string, any>) => item.role === "toolResult" && item.toolCallId === "budget-raise"))
      .toMatchObject({ isError: false });
    // A fresh exact tap after acceptance finds no card and changes nothing.
    const after = await answer(phone, {}, exact);
    expect(after.ok, JSON.stringify(after)).toBe(false);
    expect(after.error.code).toBe("not_found");
    expect(await budget()).toEqual({ outputTokens: 200 });
    expect((await history()).filter((entry) => !historyBefore.some((before) => before.changeId === entry.changeId))).toHaveLength(1);
    expect(gateway.provider.errors).toEqual([]);
  });

  it("a declined card applies nothing and refuses a late tap (#2232)", async () => {
    const { gateway, phone, homeId, budgetChange } = await homeWithBudget();
    const budget = async () => (await ok(phone, "settings.resolve", { target: { kind: "home" }, keys: [KEY] })).keys[0].value;
    const historyBefore = (await ok(phone, "settings.history", { key: KEY })).entries;
    const { card } = await budgetChange(300, "declined");
    expect(card).toMatchObject({ method: "change", review: { requiresTap: true } });
    const respond = (approved: boolean, commandId: string) => phone.request("extension.respond", { commandId, sessionId: homeId,
      interactionId: card.id, hostEpoch: card.hostEpoch, presentationRevision: card.presentationRevision, value: { digest: card.review.digest, approved } });
    expect(await respond(false, "tap-decline")).toMatchObject({ ok: true, result: { answered: true } });
    const settled = await waitFor(async () => {
      const home = await open(phone, homeId);
      return home.phase === "idle" && JSON.stringify(home.transcript).includes("Budget declined handled.") ? home : undefined;
    }, "the declined turn settled");
    expect(settled.extensionPresentation.pendingInteractions).toEqual([]);
    expect(await budget()).toEqual({ outputTokens: 100 });
    expect((await ok(phone, "settings.history", { key: KEY })).entries).toEqual(historyBefore);
    const late = await respond(true, "tap-late");
    expect(late.ok, JSON.stringify(late)).toBe(false);
    expect(late.error.code).toBe("not_found");
    expect(await budget()).toEqual({ outputTokens: 100 });
    expect(gateway.provider.errors).toEqual([]);
  });
});
