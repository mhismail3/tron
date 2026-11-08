import { afterEach, describe, expect, it } from "vitest";
import { SCRIPTED_MODEL, SCRIPTED_PROVIDER, startGatewayProcess, type GatewayProcess, type ProcessClient } from "../../../test-support/gateway-process.js";
import { waitFor } from "../../../test-support/wait-for.js";

/**
 * A settings change reaches the next operation at the real Gateway-process
 * boundary (#2233): a source Gateway process, the production loopback WebSocket
 * and local credential, and a scripted HTTP provider as the only scripted party.
 * The provider request's model id is what the next prompt actually ran with.
 */

const gateways: GatewayProcess[] = [];
afterEach(async () => { await Promise.all(gateways.splice(0).map((gateway) => gateway.dispose())); });

const ALTERNATE = { provider: SCRIPTED_PROVIDER, id: "scripted-alternate" };
const DEFAULT = { provider: SCRIPTED_PROVIDER, id: SCRIPTED_MODEL };
const KEY = "model.ref[role=chat]";

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

describe("a settings change reaches the next operation of a real Gateway process", () => {
  it("runs the next prompt with a Session change, leaves other chats on Global, and Undo restores it (#2233)", async () => {
    const gateway = await startGatewayProcess();
    gateways.push(gateway);
    const phone = await gateway.connect();
    const create = async (label: string) => {
      const { sessionId } = await ok(phone, "session.create", { commandId: `settings-${label}-create`, cwd: gateway.cwd });
      await open(phone, sessionId);
      return sessionId as string;
    };
    const changed = await create("changed");
    const other = await create("other");
    let turn = 0;
    /** One prompt; returns the model id its provider request carried. */
    const prompt = async (sessionId: string): Promise<string> => {
      const before = gateway.provider.requests.length;
      const reply = `Reply ${++turn}.`;
      gateway.provider.script([() => ({ chunks: [reply] })]);
      await ok(phone, "session.prompt", { commandId: `settings-prompt-${turn}`, sessionId, text: `Prompt ${turn}.` });
      await waitFor(async () => {
        const session = await open(phone, sessionId);
        return session.phase === "idle" && !session.operation && JSON.stringify(session.transcript).includes(reply) || undefined;
      }, `prompt ${turn} settled`);
      expect(gateway.provider.requests).toHaveLength(before + 1);
      return gateway.provider.requests.at(-1)!.model;
    };
    const resolved = async (sessionId: string) => (await ok(phone, "settings.resolve", { target: { kind: "session", sessionId }, keys: [KEY] })).keys[0];
    const fence = async (sessionId: string) => {
      const session = await open(phone, sessionId);
      return { runtimeGeneration: session.runtimeGeneration, model: session.model };
    };

    expect(await prompt(changed)).toBe(SCRIPTED_MODEL);
    const change = await ok(phone, "settings.change", { commandId: "settings-session-change", target: { kind: "session", sessionId: changed },
      fence: await fence(changed), changes: [{ key: KEY, layer: "session", op: "set", value: ALTERNATE, expected: null }] });
    expect(await resolved(changed)).toMatchObject({ value: ALTERNATE, layer: "session" });
    expect(await prompt(changed)).toBe(ALTERNATE.id);
    expect(await prompt(other)).toBe(SCRIPTED_MODEL);
    expect(await resolved(other)).toMatchObject({ value: DEFAULT, layer: "global" });

    // A change that read a stale value is refused and has no effect.
    const historyBefore = (await ok(phone, "settings.history", { key: KEY })).entries;
    const stale = await phone.request("settings.change", { commandId: "settings-stale-change", target: { kind: "session", sessionId: changed },
      fence: await fence(changed), changes: [{ key: KEY, layer: "session", op: "set", value: DEFAULT, expected: { provider: SCRIPTED_PROVIDER, id: "a-value-never-read" } }] });
    expect(stale.ok, JSON.stringify(stale)).toBe(false);
    expect(stale.error, JSON.stringify(stale)).toMatchObject({ code: "conflict", message: expect.stringContaining("changed since it was read"),
      details: { current: ALTERNATE } });
    expect(await resolved(changed)).toMatchObject({ value: ALTERNATE, layer: "session" });
    expect((await ok(phone, "settings.history", { key: KEY })).entries).toEqual(historyBefore);
    expect(await prompt(changed)).toBe(ALTERNATE.id);

    // Undo through the recorded change restores Global for the next prompt.
    expect(change).toMatchObject({ status: "applied", changes: [{ key: KEY, layer: "session", status: "applied", before: null, after: ALTERNATE }] });
    const changeId = change.changes[0].changeId as string;
    expect(await ok(phone, "settings.undo", { commandId: "settings-undo", changeId, fence: await fence(changed) })).toMatchObject({ status: "applied" });
    expect(await resolved(changed)).toMatchObject({ value: DEFAULT, layer: "global" });
    expect(await prompt(changed)).toBe(SCRIPTED_MODEL);
    expect(gateway.provider.errors).toEqual([]);
    await phone.close();
  });
});
