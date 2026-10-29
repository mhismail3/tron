import { mkdir, readFile, writeFile } from "node:fs/promises";
import type { AgentSession, SessionEntry } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { afterEach, expect, it, vi } from "vitest";
import { disposeFixtures, dispatch, fixture, reportCall } from "../../../test-support/home-task-fixture.js";
import { setHomeMemoryModels } from "../../../test-support/settings-dependencies.js";
import { waitFor } from "../../../test-support/wait-for.js";
import { HOME_TASK_RESULT_MESSAGE } from "./home-wake-inbox.js";
import { homeOwnerOf } from "../../../test-support/gateway-registry.js";
import { invocationReceipts } from "../../kernel/run/invocation-receipts.js";

afterEach(async () => { vi.restoreAllMocks(); await disposeFixtures(); });

it("returns an unpersisted wake trigger to pending before terminal settlement, then delivers it once on resume", async () => {
  const f = await fixture();
  await setHomeMemoryModels(f.registry, [{ provider: f.model.provider, id: f.model.id }]);
  const home = await f.registry.acquire(f.home.sessionId);
  f.faux.setResponses([fauxAssistantMessage("Home canonical baseline")]);
  await home.prompt("initialize the canonical Home chapter");
  await waitFor(() => home.snapshot().configurationBlocker === null, "initial Home settled");
  await homeOwnerOf(f.registry).pauseMemory();
  f.faux.setResponses([fauxAssistantMessage([reportCall("release-proof", "Retained result")], { stopReason: "toolUse" })]);
  const run = await dispatch(f, "release-boundary");
  await run.completion;
  await waitFor(async () => (await homeOwnerOf(f.registry).taskResult(run.taskId)).wake?.push === "decided", "paused result push decided");
  const eventId = (await homeOwnerOf(f.registry).taskResult(run.taskId)).wake!.eventId;
  const entries = async () => (await readFile(home.sessionFile!, "utf8")).trimEnd().split("\n")
    .map(line => JSON.parse(line) as SessionEntry);
  const rows = async () => (await entries())
    .filter(entry => entry.type === "custom_message" && entry.customType === HOME_TASK_RESULT_MESSAGE && entry.details?.eventId === eventId);
  const refusalSettled = async () => invocationReceipts(await entries(), f.home.sessionId)
    .some(receipt => receipt.receiptKind === "terminal" && receipt.source === "homeWake" && receipt.errorCode === "preflight-rejected");
  const calls = f.faux.state.callCount;
  // Inject refusal at Pi's send boundary, before it appends the admitted trigger.
  const session = (home as unknown as { runtime: { session: AgentSession } }).runtime.session;
  const send = session.sendCustomMessage.bind(session);
  let refused = false;
  let stateAfterRefusal: string | undefined;
  let callsBeforePersistence: number | undefined;
  let triggerSendAttemptsBeforeResume: number | undefined;
  const fault = vi.spyOn(session, "sendCustomMessage").mockImplementation(async (message, options) => {
    if (!refused && options?.triggerTurn && message.customType === HOME_TASK_RESULT_MESSAGE) {
      // Refuse only the first send, without pausing Home. A premature retry
      // reaches the real canonical/provider boundary and violates the checks below.
      refused = true;
      throw new Error("controlled pre-persistence trigger refusal");
    }
    return send(message, options);
  });
  const triggerSends = () => fault.mock.calls.filter(([message, options]) =>
    options?.triggerTurn && message.customType === HOME_TASK_RESULT_MESSAGE);
  try {
    await homeOwnerOf(f.registry).resumeMemory();
    // Idle alone can precede a queued retry's claim. Wait for the canonical
    // refusal receipt or a second real SDK send, then require exactly one attempt.
    await waitFor(async () => triggerSends().length > 1 || await refusalSettled(), "wake refusal settled or retried");
    triggerSendAttemptsBeforeResume = triggerSends().length;
    expect(triggerSends()).toHaveLength(1);
    expect(await refusalSettled()).toBe(true);
    await waitFor(() => refused && home.snapshot().phase === "idle" && home.snapshot().operation === undefined
      && home.snapshot().configurationBlocker === null, "failed wake retired");
    const wake = (await homeOwnerOf(f.registry).taskResult(run.taskId)).wake;
    stateAfterRefusal = wake?.state;
    callsBeforePersistence = f.faux.state.callCount - calls;
    expect(wake).toMatchObject({ eventId, state: "pending" });
    expect(await rows()).toEqual([]);
    expect(f.faux.state.callCount).toBe(calls);
  } finally { fault.mockRestore(); }

  // Pause only after proving refusal stayed pending without an automatic retry.
  await homeOwnerOf(f.registry).pauseMemory();
  f.faux.setResponses([fauxAssistantMessage("Read the retained result")]);
  await homeOwnerOf(f.registry).resumeMemory();
  await waitFor(async () => (await homeOwnerOf(f.registry).taskResult(run.taskId)).wake?.state === "acknowledged", "released result acknowledged");
  await waitFor(() => home.snapshot().phase === "idle" && home.snapshot().configurationBlocker === null, "resumed wake retired");
  const deliveryRows = await rows();
  expect(deliveryRows).toHaveLength(1);
  expect(f.faux.state.callCount).toBe(calls + 1);
  await f.registry.administrativeWorkRegistry.waitUntilSettled();
  expect(f.registry.administrativeWorkRegistry.size).toBe(0);
  await mkdir("test-results/input-admission", { recursive: true });
  await writeFile("test-results/input-admission/unpersisted-trigger.json", JSON.stringify({
    stateAfterRefusal, triggerSendAttemptsBeforeResume, refusalSettled: await refusalSettled(),
    providerCallsBeforePersistence: callsBeforePersistence, canonicalDeliveries: deliveryRows.length,
    stateAfterResume: (await homeOwnerOf(f.registry).taskResult(run.taskId)).wake?.state,
    providerCallsAfterRelease: f.faux.state.callCount - calls,
    administrativeWork: f.registry.administrativeWorkRegistry.size,
  }, null, 2));
});
