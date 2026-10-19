import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockClient, type LockGateway } from "../../test-support/gateway-lock-harness.js";
import { compareWithGolden, lockPaths, lockUpdateRequested, type TraceValue } from "../../test-support/scenario-lock.js";
import { awaitsWithin } from "../../test-support/wait-for.js";

/**
 * Kernel reconnect-snapshot lock (restructure plan §6.4, V3) for the
 * `gateway/transport` module, through the real Gateway over loopback WebSockets.
 *
 * The invariant (AGENTS.md architecture): an accepted prompt survives a client
 * disconnect, and a reconnecting client gets an authoritative snapshot — while
 * the run is still live, and again after it settled — without the interrupted
 * prompt being replayed. The lock records both reconnect snapshots' values, the
 * request/response exchanges, provider requests and canonical JSONL, and compares them with `locks/transport-reconnect-snapshot.golden.json`.
 */

const MODULE = "gateway/transport";
const gateways: LockGateway[] = [];
afterEach(async () => { await Promise.all(gateways.splice(0).map((gateway) => gateway.dispose())); });

async function openAndSync(client: LockClient, sessionId: string): Promise<{ ok: boolean; result?: any }> {
  const opened = await client.request("session.open", { sessionId });
  expect(opened.ok, JSON.stringify(opened)).toBe(true);
  expect((await client.request("session.sync", { sessionId, syncToken: opened.result.syncToken })).ok).toBe(true);
  return opened;
}

describe("gateway/transport kernel locks", () => {
  it("reconnect snapshot: a client that drops mid-run reopens to the live run, then to its settled result", async () => {
    const gateway = await startLockGateway("transport-reconnect-snapshot");
    gateways.push(gateway);
    let reach = (): void => {};
    let release = (): void => {};
    const reached = new Promise<void>((resolve) => { reach = resolve; });
    const released = new Promise<void>((resolve) => { release = resolve; });
    gateway.script([
      async () => { reach(); await released; return fauxAssistantMessage("Answered after the reconnect."); },
    ]);

    const first = await gateway.connect("phone");
    const created = await first.request("session.create", { commandId: gateway.commandId(), cwd: gateway.cwd });
    expect(created.ok, JSON.stringify(created)).toBe(true);
    const sessionId = created.result.sessionId as string;
    await openAndSync(first, sessionId);
    const admitted = await first.request("session.prompt", { commandId: gateway.commandId(), sessionId, text: "survive my disconnect" });
    expect(admitted.ok, JSON.stringify(admitted)).toBe(true);
    await awaitsWithin(reached, "the held provider request");
    await first.close();

    const live = await openAndSync(await gateway.connect("reconnect-live"), sessionId);
    release();
    await gateway.settled(sessionId);
    const settled = await openAndSync(await gateway.connect("reconnect-settled"), sessionId);

    const recorded = gateway.record();
    const trace = {
      lock: "transport-reconnect-snapshot",
      // Event shapes are not part of this lock: which coalesced snapshot a socket
      // that drops mid-run receives before it closes is host timing. The subject is
      // the two reconnect snapshots, recorded in full in the exchanges.
      exchanges: recorded.exchanges,
      providerRequests: recorded.providerRequests as unknown as TraceValue[],
      canonicalJsonl: await gateway.canonical(sessionId),
    };
    await compareWithGolden({
      module: MODULE, ...lockPaths(import.meta.url, trace.lock), trace, update: lockUpdateRequested(MODULE),
      validate: () => {
        // The live snapshot names the admitted operation; the settled one has none and
        // carries the answer. The prompt reached the model exactly once.
        expect(live.result.session.operation?.id).toBe(admitted.result.operationId);
        expect(settled.result.session.operation ?? null).toBeNull();
        expect(JSON.stringify(settled.result.session.transcript)).toContain("Answered after the reconnect.");
        expect(trace.providerRequests).toHaveLength(1);
        const prompts = trace.canonicalJsonl.filter((entry) => (entry as { message?: { role?: string } }).message?.role === "user");
        expect(prompts).toHaveLength(1);
      },
    });
  });
});
