import { afterEach, describe, expect, it } from "vitest";
import { startGatewayProcess, type GatewayProcess, type ProcessClient } from "../../test-support/gateway-process.js";
import { awaitsWithin, waitFor } from "../../test-support/wait-for.js";

/**
 * Core prompt journeys at the real Gateway-process boundary (#2142): a source
 * Gateway process, the production loopback WebSocket and local credential, and
 * a scripted HTTP provider as the only scripted party.
 */

const gateways: GatewayProcess[] = [];
afterEach(async () => { await Promise.all(gateways.splice(0).map((gateway) => gateway.dispose())); });

type Snapshot = { phase: string; operation?: unknown; transcript: Array<Record<string, any>> };

async function openAndSync(client: ProcessClient, sessionId: string): Promise<Snapshot> {
  const opened = await client.request("session.open", { sessionId });
  expect(opened.ok, JSON.stringify(opened)).toBe(true);
  const synced = await client.request("session.sync", { sessionId, syncToken: opened.result.syncToken });
  expect(synced.ok, JSON.stringify(synced)).toBe(true);
  return opened.result.session as Snapshot;
}

/** A fresh connection's authoritative snapshot, as a reconnecting phone reads it. */
async function freshSnapshot(gateway: GatewayProcess, sessionId: string): Promise<Snapshot> {
  const client = await gateway.connect();
  try { return await openAndSync(client, sessionId); } finally { await client.close(); }
}

function messages(snapshot: Snapshot, role: string): string[] {
  return snapshot.transcript.filter((item) => item.kind === "message" && item.role === role)
    .map((item) => (item.content as Array<{ type: string; text?: string }>).filter((part) => part.type === "text")
      .map((part) => part.text).join(""));
}

async function createSession(gateway: GatewayProcess, client: ProcessClient, commandId: string): Promise<string> {
  const created = await client.request("session.create", { commandId, cwd: gateway.cwd });
  expect(created.ok, JSON.stringify(created)).toBe(true);
  const sessionId = created.result.sessionId as string;
  await openAndSync(client, sessionId);
  return sessionId;
}

async function settled(gateway: GatewayProcess, sessionId: string): Promise<Snapshot> {
  return await waitFor(async () => {
    const snapshot = await freshSnapshot(gateway, sessionId);
    return snapshot.phase === "idle" && !snapshot.operation ? snapshot : undefined;
  }, "the session settled idle");
}

describe("prompt journeys across the real Gateway process", () => {
  it("settles one streamed reply exactly once across reconnects, a lost-response retry and a process restart (#2230)", async () => {
    const gateway = await startGatewayProcess();
    gateways.push(gateway);
    const prompt = "Reply once to this exact prompt.";
    const head = "PARTIAL-ALPHA ";
    const tail = "OMEGA-COMPLETE.";
    let reach = (): void => {};
    let release = (): void => {};
    const reached = new Promise<void>((resolve) => { reach = resolve; });
    const released = new Promise<void>((resolve) => { release = resolve; });
    gateway.provider.script([() => ({ chunks: [head, async () => { reach(); await released; }, tail] })]);

    const phone = await gateway.connect();
    const sessionId = await createSession(gateway, phone, "prompt-once-create");
    const admitted = await phone.request("session.prompt", { commandId: "prompt-once-command", sessionId, text: prompt });
    expect(admitted.ok, JSON.stringify(admitted)).toBe(true);
    await awaitsWithin(reached, "the provider streamed its first chunk");
    // The phone observes the reply partially: the head is streamed, the tail is not yet written.
    await waitFor(async () => phone.events.some((event) => event.sessionId === sessionId
      && JSON.stringify(event.payload).includes(head)) || undefined, "the phone saw the partial reply");
    expect(phone.events.some((event) => JSON.stringify(event.payload).includes(tail))).toBe(false);
    release();

    const expectExactlyOnce = (snapshot: Snapshot) => {
      expect(snapshot.phase).toBe("idle");
      expect(snapshot.operation ?? null).toBeNull();
      expect(messages(snapshot, "user")).toEqual([prompt]);
      expect(messages(snapshot, "assistant")).toEqual([head + tail]);
    };
    expectExactlyOnce(await settled(gateway, sessionId));
    expectExactlyOnce(await freshSnapshot(gateway, sessionId));

    // A phone that lost the admission response retries the same command: the
    // Gateway answers its receipt and never admits a second prompt.
    const retried = await phone.request("session.prompt", { commandId: "prompt-once-command", sessionId, text: prompt });
    expect(retried.ok, JSON.stringify(retried)).toBe(true);
    expect(retried.result.operationId).toBe(admitted.result.operationId);
    expectExactlyOnce(await freshSnapshot(gateway, sessionId));
    await phone.close();

    // The canonical record, read back by a new Gateway process, holds the same single turn.
    await gateway.restart();
    expectExactlyOnce(await freshSnapshot(gateway, sessionId));
    expect(gateway.provider.requests).toHaveLength(1);
    expect(gateway.provider.requests[0]!.messages.filter((message) => message.role === "user")).toHaveLength(1);
  });
});
