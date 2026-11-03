import { existsSync } from "node:fs";
import { writeFile } from "node:fs/promises";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { RunMarkerStore } from "../kernel/run/run-markers.js";
import { startGatewayProcess, type GatewayProcess, type ProcessClient } from "../../test-support/gateway-process.js";
import { awaitsWithin, waitFor } from "../../test-support/wait-for.js";

/**
 * An accepted prompt across a real Gateway-process restart (#2235): a source
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

function userTexts(snapshot: Snapshot): string[] {
  return snapshot.transcript.filter((item) => item.kind === "message" && item.role === "user")
    .map((item) => (item.content as Array<{ type: string; text?: string }>).filter((part) => part.type === "text")
      .map((part) => part.text).join(""));
}

async function listPhase(client: ProcessClient, sessionId: string): Promise<string | undefined> {
  const listed = await client.request("session.list", {});
  expect(listed.ok, JSON.stringify(listed)).toBe(true);
  return (listed.result.sessions as Array<{ id: string; phase: string }>).find((row) => row.id === sessionId)?.phase;
}

/** One record per process start; `count` names the start whose post-listen recovery finished. */
async function recoveries(gateway: GatewayProcess, count: number): Promise<void> {
  await waitFor(async () => (await gateway.log()).filter((record) => record.event === "gateway.startup-step"
    && record.step === "attention-recovery").length === count || undefined, `Gateway start ${count} finished attention recovery`);
}

describe("an accepted prompt across a real Gateway-process restart", () => {
  it("reports the held prompt interrupted, never replays it, and runs the next prompt (#2235)", async () => {
    const gateway = await startGatewayProcess();
    gateways.push(gateway);
    const prompt = "Hold this prompt across the restart.";
    let reach = (): void => {};
    const reached = new Promise<void>((resolve) => { reach = resolve; });
    // The held step never answers: the Gateway process is stopped under it.
    gateway.provider.script([(_request, signal) => {
      reach();
      return new Promise((_resolve, reject) => signal.addEventListener("abort", () => reject(new Error("aborted"))));
    }]);

    const phone = await gateway.connect();
    const created = await phone.request("session.create", { commandId: "restart-held-create", cwd: gateway.cwd });
    expect(created.ok, JSON.stringify(created)).toBe(true);
    const sessionId = created.result.sessionId as string;
    await openAndSync(phone, sessionId);
    const admitted = await phone.request("session.prompt", { commandId: "restart-held-command", sessionId, text: prompt });
    expect(admitted.ok, JSON.stringify(admitted)).toBe(true);
    await awaitsWithin(reached, "the held provider request");
    await phone.close();
    await recoveries(gateway, 1);

    // Startup attention recovery runs after the listener serves. Holding its
    // last marker read places the reconnecting phone inside that window, which
    // a phone reconnecting at once after a restart reaches on a large catalog.
    const before = gateway.pid();
    const hold = join(gateway.root, "attention-recovery");
    await gateway.restart({ environment: { TRON_TEST_HOLD_ATTENTION_RECOVERY: hold } });
    expect(gateway.pid()).not.toBe(before);
    await waitFor(async () => existsSync(`${hold}.held`) || undefined, "attention recovery is held");

    const reconnected = await gateway.connect();
    const expectInterrupted = async (label: string) => {
      const status = await reconnected.request("command.status", { method: "session.prompt", commandId: "restart-held-command" });
      expect(status.ok, JSON.stringify(status)).toBe(true);
      expect(status.result, label).toEqual({ status: "completed", result: { operationId: admitted.result.operationId } });
      const snapshot = await openAndSync(reconnected, sessionId);
      expect(snapshot.phase, label).toBe("interrupted");
      expect(snapshot.operation ?? null, label).toBeNull();
      expect(userTexts(snapshot), label).toEqual([prompt]);
      const lifecycle = snapshot.transcript.find((item) => item.kind === "message" && item.role === "user")?.semantic?.lifecycle;
      expect(lifecycle, label).toBe("outcomeUnknown");
      expect(await listPhase(reconnected, sessionId), label).toBe("interrupted");
      expect(gateway.provider.requests, label).toHaveLength(1);
    };
    await expectInterrupted("during startup attention recovery");
    await writeFile(`${hold}.go`, "");
    await recoveries(gateway, 2);
    await expectInterrupted("after startup attention recovery");

    // The restarted Gateway runs a new prompt normally, and still never replays the held one.
    gateway.provider.script([() => ({ chunks: ["Fresh reply."] })]);
    const next = await reconnected.request("session.prompt", { commandId: "restart-next-command", sessionId, text: "A new prompt." });
    expect(next.ok, JSON.stringify(next)).toBe(true);
    const done = await waitFor(async () => {
      const snapshot = await openAndSync(reconnected, sessionId);
      return snapshot.phase === "idle" && !snapshot.operation
        && JSON.stringify(snapshot.transcript).includes("Fresh reply.") ? snapshot : undefined;
    }, "the new prompt settled");
    expect(userTexts(done)).toEqual([prompt, "A new prompt."]);
    expect(gateway.provider.requests).toHaveLength(2);
    expect(gateway.provider.requests[1]!.messages.filter((message) => message.role === "user")
      .map((message) => JSON.stringify(message.content)))
      .toEqual([JSON.stringify([{ type: "text", text: prompt }]), JSON.stringify([{ type: "text", text: "A new prompt." }])]);
    expect(gateway.provider.errors).toEqual([]);
    await reconnected.close();
  });

  it("reads a prompt whose completion is durably stamped as settled, inside and after the recovery window (#2235)", async () => {
    const gateway = await startGatewayProcess();
    gateways.push(gateway);
    gateway.provider.script([() => ({ chunks: ["Completed reply."] })]);
    const phone = await gateway.connect();
    const created = await phone.request("session.create", { commandId: "stamped-create", cwd: gateway.cwd });
    expect(created.ok, JSON.stringify(created)).toBe(true);
    const sessionId = created.result.sessionId as string;
    await openAndSync(phone, sessionId);
    const admitted = await phone.request("session.prompt", { commandId: "stamped-command", sessionId, text: "Complete this prompt." });
    expect(admitted.ok, JSON.stringify(admitted)).toBe(true);
    const settled = await waitFor(async () => {
      const snapshot = await openAndSync(phone, sessionId);
      return snapshot.phase === "idle" && JSON.stringify(snapshot.transcript).includes("Completed reply.") ? snapshot : undefined;
    }, "the prompt settled");
    const completion = settled.transcript.find((item) => item.kind === "message" && item.role === "assistant")!;
    await phone.close();
    await recoveries(gateway, 1);

    // The durable cut a crash leaves between stamping the completion and
    // clearing its marker, written through the marker owner while no Gateway runs.
    const hold = join(gateway.root, "attention-recovery");
    await gateway.restart({
      environment: { TRON_TEST_HOLD_ATTENTION_RECOVERY: hold },
      whileStopped: async () => {
        const markers = new RunMarkerStore(gateway.tronHome);
        await markers.mark(sessionId, admitted.result.operationId);
        await markers.markAssistantCompletion(sessionId, admitted.result.operationId, completion.id, completion.timestamp);
      },
    });
    await waitFor(async () => existsSync(`${hold}.held`) || undefined, "attention recovery is held");
    const reconnected = await gateway.connect();
    const expectSettled = async (label: string) => {
      const snapshot = await openAndSync(reconnected, sessionId);
      expect(snapshot.phase, label).toBe("idle");
      expect(await listPhase(reconnected, sessionId), label).toBe("idle");
    };
    await expectSettled("during startup attention recovery");
    await writeFile(`${hold}.go`, "");
    await recoveries(gateway, 2);
    await expectSettled("after startup attention recovery");
    expect(await new RunMarkerStore(gateway.tronHome).evidenceFor(sessionId)).toEqual([]);
    expect(gateway.provider.requests).toHaveLength(1);
    expect(gateway.provider.errors).toEqual([]);
    await reconnected.close();
  });
});
