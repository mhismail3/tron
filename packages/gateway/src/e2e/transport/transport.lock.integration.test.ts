import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { realpath } from "node:fs/promises";
import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockClient, type LockGateway } from "../../../test-support/gateway-lock-harness.js";
import { expectRequestShapes, expectSystemShapes } from "../../../test-support/lock-projections.js";
import { awaitsWithin } from "../../../test-support/wait-for.js";

/**
 * Kernel reconnect-snapshot lock (packages/gateway/docs/scenario-locks.md#locks) for the
 * `gateway/transport` module, through the real Gateway over loopback WebSockets.
 *
 * The invariant (AGENTS.md architecture): an accepted prompt survives a client
 * disconnect, and a reconnecting client gets an authoritative snapshot — while
 * the run is still live, and again after it settled — without the interrupted
 * prompt being replayed. Effects are asserted by name: both reconnect snapshots'
 * phase, operation, queue, model, policies, extension presentation and transcript
 * rows, the receipts and messages the file keeps, the one provider request and the
 * `session-shapes` shapes. Receipt identity and the session preamble entries are
 * pinned by `run.lock`'s prompt-stream, which has the same receipt and preamble shape.
 */

const gateways: LockGateway[] = [];
afterEach(async () => { await Promise.all(gateways.splice(0).map((gateway) => gateway.dispose())); });

async function openAndSync(client: LockClient, sessionId: string): Promise<{ ok: boolean; result?: any }> {
  const opened = await client.request("session.open", { sessionId });
  expect(opened.ok, JSON.stringify(opened)).toBe(true);
  expect((await client.request("session.sync", { sessionId, syncToken: opened.result.syncToken })).ok).toBe(true);
  return opened;
}

/** A snapshot's transcript as `head | lifecycle | text` rows. */
function rows(snapshot: { transcript: Array<{ kind: string; role?: string; stopReason?: string; semantic?: { lifecycle?: string }; content?: Array<{ text?: string }> }> }): string[] {
  return snapshot.transcript.map((item) => [item.kind === "message" ? `${item.role}${item.stopReason ? `:${item.stopReason}` : ""}` : item.kind,
    item.semantic?.lifecycle ?? "", ...(item.content ?? []).map((part) => part.text)].join(" | "));
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

    // The same idle session facts in every snapshot: queue, thinking, policies, cwd.
    const steady = { cwd: await realpath(gateway.cwd), queueRevision: 0, queuedItems: [], toolExecutions: [], compactionQueued: false,
      automaticCompactionEnabled: false, availableThinkingLevels: ["off"], thinkingLevel: "off", diagnostics: [], liveActivityRevision: 0,
      compactionPolicy: { currentBudgets: { enabled: false, keepRecentTokens: 120, reserveTokens: 2048 } },
      model: { provider: "tron-lock-transport-reconnect-snapshot" },
      // The first message is saved, so the unsaved-context warning is gone from both reconnects.
      contextWindowPolicy: { default: 128_000, effective: 128_000, maximum: 128_000, minimum: 3192, override: 128_000, source: "session",
        model: { provider: "tron-lock-transport-reconnect-snapshot" } },
      extensionPresentation: { version: 3, pendingInteractions: [], surfaces: [],
        capabilities: ["semantic.dialogs", "tron.form.v1", "semantic.notifications", "semantic.status", "semantic.working", "semantic.hidden-thinking-label",
          "semantic.string-widgets", "semantic.title", "semantic.revisioned-editor", "semantic.tools-expanded", "surfaces.full-frame"],
        diagnostics: [
          { code: "remote-components.enabled", message: "Retained string widgets and bounded read-only component frames are presented through the general extension-content sheet; blocking custom and overlay UI remain deferred." },
          { code: "remote-components.overlay-deferred", message: "Overlay and interactive component UI remain deferred until native rendering and input leases are available." },
          { code: "theme.baseline-only", message: "Per-session process-global Pi theme synchronization is unavailable through the pinned public API." },
        ],
        semanticState: { editorRevision: 0, editorText: "", statusOwners: {}, statuses: {}, toolsExpanded: false, widgets: [],
          working: { indicator: { frames: [], kind: "default" }, visible: true } } } };
    // While the run is live: the admitted operation, a running phase that accepts queued prompts, and the accepted prompt.
    expect(admitted.result.operationId).toEqual(expect.any(String));
    expect(live.result.completionRevision).toBe(0);
    expect(live.result.session).toMatchObject({ ...steady, phase: "running", configurationBlocker: "running", acceptsQueuedPrompts: true, transcriptStart: 0, transcriptTotal: 3,
      operation: { id: admitted.result.operationId, kind: "prompt", lifecycle: "staged", invocationId: expect.any(String) },
      sessionId, activeToolSegmentId: expect.stringMatching(/^tool-segment:"/) });
    expect(live.result.session.contextWindowPolicy).not.toHaveProperty("warning");
    for (const snapshot of [live.result.session, settled.result.session]) {
      expect(snapshot.extensionPresentation.semanticState).toEqual(steady.extensionPresentation.semanticState);
    }
    expect(rows(live.result.session)).toEqual(["modelChange | ", "thinkingChange | ", "user | accepted | survive my disconnect"]);
    // After it settled: no operation, idle, the answer, and the completion counted once.
    expect(settled.result.completionRevision).toBe(1);
    expect(settled.result.session).toMatchObject({ ...steady, sessionId, phase: "idle", configurationBlocker: null, acceptsQueuedPrompts: false, transcriptStart: 0, transcriptTotal: 4 });
    expect(settled.result.session.operation ?? null).toBeNull();
    expect(settled.result.session.activeToolSegmentId).toBeUndefined();
    expect(settled.result.session.contextWindowPolicy).not.toHaveProperty("warning");
    expect(rows(settled.result.session)).toEqual(["modelChange | ", "thinkingChange | ", "user | completed | survive my disconnect",
      "assistant:stop |  | Answered after the reconnect."]);

    // The prompt reached the model exactly once and was never replayed.
    const recorded = gateway.record();
    expect(recorded.providerRequests.map((request) => request.messages.map((message) => `${(message as { role: string }).role}:${(message as { text?: string }).text ?? ""}`)))
      .toEqual([["user:survive my disconnect"]]);
    expectRequestShapes(recorded.providerRequests, ["chat"]);
    expect(recorded.exchanges.map((exchange) => `${(exchange as { client: string }).client} ${(exchange as { method: string }).method}`)).toEqual([
      "phone session.create", "phone session.open", "phone session.sync", "phone session.prompt",
      "reconnect-live session.open", "reconnect-live session.sync", "reconnect-settled session.open", "reconnect-settled session.sync",
    ]);
    const canonicalJsonl = await gateway.canonical(sessionId);
    expectSystemShapes(canonicalJsonl, ["chat#0"]);
    expect(canonicalJsonl.flatMap((entry) => {
      const message = (entry as { message?: { role: string; content?: Array<{ text?: string }> } }).message;
      return message && message.role !== "system" ? [`${message.role}:${message.content?.map((part) => part.text).join("")}`] : [];
    })).toEqual(["user:survive my disconnect", "assistant:Answered after the reconnect."]);
    expect(canonicalJsonl.flatMap((entry) => {
      const record = entry as { customType?: string; data?: { receiptKind?: string; lifecycle?: string } };
      return record.customType === "tron.chat-invocation.v1" ? [`${record.data?.receiptKind}:${record.data?.lifecycle ?? ""}`] : [];
    })).toEqual(["start:staged", "transition:accepted", "binding:", "terminal:completed"]);
  });
});
