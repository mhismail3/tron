import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, expect, it, vi } from "vitest";
import { startLockGateway, type LockGateway } from "../../test-support/gateway-lock-harness.js";
import { awaitsWithin, waitFor } from "../../test-support/wait-for.js";
import { GatewayLogger } from "../transport/logger.js";
import { waitForStopDrain } from "../sessions/restart-drain.js";

// #2256: a Home `schedule runNow` result carries `details.runId` and `state: "queued"`.
// Projected as delegated-run shaped activity, it stayed live work for the life of the
// process, so an intentional stop waited on a `detached-extension-run` forever. The
// Gateway, the real `schedule` tool, the Automation owners and the stop drain are all
// production; only the model is scripted.

const gateways: LockGateway[] = [];
afterEach(async () => {
  vi.unstubAllEnvs();
  for (const gateway of gateways.splice(0)) await gateway.dispose();
});

type ToolResult = { isError?: boolean; details: Record<string, any> };

it("a Home schedule runNow leaves no drain blocker, and the intentional stop completes once the run settles", async () => {
  const gateway = await startLockGateway("schedule-run-now-stop-drain", {
    automations: true, lifecycleRequests: true,
    home: { memorySummarizer: () => async () => fauxAssistantMessage("Summary.") },
  });
  gateways.push(gateway);
  const phone = await gateway.connect("phone");
  const model = JSON.parse(await readFile(join(gateway.agentDir, "settings.json"), "utf8"));
  const designated = await phone.request("home.designate", { commandId: gateway.commandId(), model: { provider: model.defaultProvider, id: model.defaultModel } });
  expect(designated.ok, JSON.stringify(designated)).toBe(true);
  const sessionId = designated.result.sessionId as string;
  expect((await phone.request("settings.change", { commandId: gateway.commandId(), target: { kind: "home" }, changes: [{ key: "model.queue[role=background]", layer: "session", op: "set", value: [`${model.defaultProvider}/${model.defaultModel}`] }] })).ok).toBe(true);
  const slot = await gateway.registry.acquire(sessionId);
  const call = async (request: Record<string, unknown>): Promise<ToolResult> => {
    gateway.script([() => fauxAssistantMessage([fauxToolCall("schedule", request)], { stopReason: "toolUse" }), () => fauxAssistantMessage("Observed.")]);
    expect((await phone.request("home.prompt", { commandId: gateway.commandId(), text: "Manage the authorized fixture automation." })).ok).toBe(true);
    await gateway.settled(sessionId);
    return slot.canonicalSessionEntries().findLast(entry => entry.type === "message" && entry.message.role === "toolResult" && entry.message.toolName === "schedule")!.message as unknown as ToolResult;
  };

  const created = await call({ action: "create", name: "Fixture review", target: "home", at: "2099-01-01T00:00:00.000Z", activate: true, prompt: "Review the fixture queue; no approval authority." });
  expect(created.isError, JSON.stringify(created)).not.toBe(true);
  const ranNow = await call({ action: "runNow", automationId: created.details.id, expectedRevision: created.details.revision });
  expect(ranNow.isError, JSON.stringify(ranNow)).not.toBe(true);
  // The incident's exact result shape: the delegated-run convention, owned by the Automation store.
  expect(ranNow.details).toMatchObject({ runId: expect.any(String), state: "queued" });
  const runId = ranNow.details.runId as string;
  await waitFor(async () => (await phone.request("automation.run.get", { automationId: created.details.id, runId })).result?.state === "succeeded", "the automation run settled");
  await gateway.settled(sessionId);

  const blockers = slot.administrativeDrainBlockers();
  const processOverview = slot.snapshot().processOverview;
  expect(blockers.filter(fact => fact.category === "detached-extension-run")).toEqual([]);

  const logPath = join(gateway.root, "logs", "gateway.jsonl");
  await mkdir(join(gateway.root, "logs"), { recursive: true });
  // Served as under launchd; the harness records the exit request and the test runs the drain.
  vi.stubEnv("TRON_GATEWAY_SUPERVISED", "1");
  const stop = await phone.request("gateway.stop", { commandId: gateway.commandId() });
  expect(stop.ok, JSON.stringify(stop)).toBe(true);
  await waitFor(() => gateway.lifecycleRequests.some(request => request.kind === "stop"), "the stop request");
  const final = await awaitsWithin(waitForStopDrain(gateway.registry, new GatewayLogger(logPath), 100), "the intentional stop drain to complete");
  const status = await phone.request("gateway.drain.status", {});
  await mkdir("test-results/2256", { recursive: true });
  await writeFile("test-results/2256/schedule-run-now-stop-drain.json", JSON.stringify({ runNow: ranNow.details, blockers, processOverview, final, status: status.result }, null, 2));
  expect(final).toMatchObject({ phase: "complete", blockerCount: 0 });
  expect(status.result).toMatchObject({ phase: "complete", blockerCount: 0 });
}, 60_000);
