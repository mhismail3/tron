import { afterEach, describe, expect, it } from "vitest";
import { BACKGROUND_MODEL, SCRIPTED_MODEL, SCRIPTED_PROVIDER, startGatewayProcess, type GatewayProcess, type ProcessClient } from "../../../test-support/gateway-process.js";
import { waitFor } from "../../../test-support/wait-for.js";

const gateways: GatewayProcess[] = [];
afterEach(async () => { await Promise.all(gateways.splice(0).map((gateway) => gateway.dispose())); });

const AUTOMATION_TEXT = "Review the morning queue.";

async function ok(client: ProcessClient, method: string, params: Record<string, unknown>): Promise<any> {
  const response = await client.request(method, params);
  expect(response.ok, `${method}: ${JSON.stringify(response)}`).toBe(true);
  return response.result;
}

async function homeTranscript(client: ProcessClient, sessionId: string): Promise<{ phase: string; transcript: Array<Record<string, any>> }> {
  const opened = await ok(client, "session.open", { sessionId });
  await ok(client, "session.sync", { sessionId, syncToken: opened.syncToken });
  return opened.session;
}

async function startupRecovered(gateway: GatewayProcess, count: number): Promise<void> {
  await waitFor(async () => (await gateway.log()).filter((record) => record.event === "gateway.startup-step"
    && record.step === "home-task-recovery").length === count || undefined, `Gateway start ${count} finished its startup recovery`);
}

const automationMessages = (transcript: Array<Record<string, any>>) => transcript.filter((item) => item.kind === "customMessage"
  && item.customType === "tron.home-trigger.v1" && JSON.stringify(item.content).includes(AUTOMATION_TEXT));
const automationRequests = (gateway: GatewayProcess) => gateway.provider.requests.filter((request) => request.messages
  .some((message) => message.role === "user" && JSON.stringify(message.content).includes(AUTOMATION_TEXT)));

describe("a Home automation wake across real Gateway-process restarts", () => {
  it("delivers a paused run once after a restart and never again after the next (#2234)", async () => {
    const gateway = await startGatewayProcess();
    gateways.push(gateway);
    let phone = await gateway.connect();
    const designated = await ok(phone, "home.designate", { commandId: "home-wake-designate", model: { provider: SCRIPTED_PROVIDER, id: SCRIPTED_MODEL } });
    const sessionId = designated.sessionId as string;
    await ok(phone, "settings.change", { commandId: "home-wake-background-queue", target: { kind: "home" }, changes: [
      { key: "model.queue[role=background]", layer: "session", op: "set", value: [`${SCRIPTED_PROVIDER}/${BACKGROUND_MODEL}`] },
    ] });
    gateway.provider.answerModel(BACKGROUND_MODEL, () => ({ chunks: ["Memory line."] }));
    gateway.provider.script([() => ({ chunks: ["Home is ready."] })]);
    await ok(phone, "home.prompt", { commandId: "home-wake-bootstrap", text: "Initialize this Home conversation." });
    await waitFor(async () => {
      const home = await homeTranscript(phone, sessionId);
      return home.phase === "idle" && JSON.stringify(home.transcript).includes("Home is ready.") || undefined;
    }, "the Home bootstrap settled");

    const status = await ok(phone, "home.status", {});
    await ok(phone, "home.pauseMemory", { commandId: "home-wake-pause" });
    const created = await ok(phone, "automation.create", { commandId: "home-wake-create", definition: {
      name: "Morning review", activation: "draft", target: { kind: "home", homeId: status.homeId, routeGeneration: status.routeGeneration },
      trigger: { kind: "once", at: "2099-01-01T09:00:00.000Z" }, misfirePolicy: "latest", overlapPolicy: "skip",
      action: { kind: "sessionPrompt", text: AUTOMATION_TEXT },
    } });
    const automationId = created.id as string;
    const fired = await ok(phone, "automation.runNow", { commandId: "home-wake-run-now", automationId, expectedRevision: created.revision });
    const runId = fired.runId as string;
    expect((await ok(phone, "automation.run.get", { automationId, runId })).state).toBe("queued");
    expect(automationMessages((await homeTranscript(phone, sessionId)).transcript)).toHaveLength(0);
    expect(automationRequests(gateway)).toHaveLength(0);

    await gateway.restart();
    await startupRecovered(gateway, 2);
    phone = await gateway.connect();
    expect((await ok(phone, "automation.run.get", { automationId, runId })).state).toBe("queued");
    expect(automationRequests(gateway)).toHaveLength(0);
    gateway.provider.script([() => ({ chunks: ["Woke once for the morning review."] })]);
    await ok(phone, "home.resumeMemory", { commandId: "home-wake-resume" });
    const delivered = await waitFor(async () => {
      const run = await ok(phone, "automation.run.get", { automationId, runId });
      const home = await homeTranscript(phone, sessionId);
      return run.state === "succeeded" && home.phase === "idle"
        && JSON.stringify(home.transcript).includes("Woke once for the morning review.") ? { run, home } : undefined;
    }, "the resumed Home wake settled");
    expect(delivered.run).toMatchObject({ state: "succeeded", executionSessionId: sessionId, homeDelivery: "wake" });
    expect(automationMessages(delivered.home.transcript)).toHaveLength(1);
    const replies = delivered.home.transcript.filter((item) => item.kind === "message" && item.role === "assistant");
    expect(replies.map((item) => item.content.map((part: { text?: string }) => part.text ?? "").join(""))).toEqual(["Home is ready.", "Woke once for the morning review."]);
    expect(automationRequests(gateway)).toHaveLength(1);
    await phone.close();

    await gateway.restart();
    await startupRecovered(gateway, 3);
    phone = await gateway.connect();
    expect(await ok(phone, "automation.run.get", { automationId, runId })).toEqual(delivered.run);
    const after = await homeTranscript(phone, sessionId);
    expect(after.phase).toBe("idle");
    expect(after.transcript.map((item) => item.id)).toEqual(delivered.home.transcript.map((item) => item.id));
    const runs = await ok(phone, "automation.run.list", { automationId });
    expect((runs.runs as Array<{ runId: string; state: string }>).map((run) => [run.runId, run.state])).toEqual([[runId, "succeeded"]]);
    expect(automationRequests(gateway)).toHaveLength(1);
    expect(gateway.provider.errors).toEqual([]);
    await phone.close();
  });
});
