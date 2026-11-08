import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockGateway } from "../../../test-support/gateway-lock-harness.js";
import { expectRequestShapes, expectSystemShapes } from "../../../test-support/lock-projections.js";
import { normalizeTraceValue } from "../../../test-support/scenario-lock.js";
import { automationOwnedRunScenario } from "../../../test-support/lock-scenarios.js";

/**
 * Automation owned-run lock (restructure E0c, `packages/gateway/docs/kernel.md` §7)
 * for the `gateway/automations` module.
 *
 * The real Gateway (`gateway-lock-harness.ts`, option `automations`) runs the
 * production automation store, scheduler, executor and service. The phone
 * runs one turn in a chat, then creates two automations over the socket and runs each now: a session prompt
 * into its open chat (the executor leases it through `DelegationOperations`)
 * and a workspace prompt (the registry creates an owned session per run). Each
 * run reads a file through a tool, so the owned operation spans a tool round
 * trip.
 *
 * Effects are asserted by name: each run's admission and durable terminal (the
 * record, its history and the client reads agree), the Automation attribution of
 * each owned prompt's receipts and transcript row, both sessions' entries, each
 * provider request's messages and `session-shapes` shape, every command receipt,
 * and the runtime-marker store the acknowledged runs leave empty. The record and
 * receipt formats are validated by their owners (`automation-contract.ts`,
 * `command-receipts.ts` `isReceipt`); `store-automations` and
 * `store-command-receipts` pin a record envelope and receipt projections.
 */

const gateways: LockGateway[] = [];
afterEach(async () => { await Promise.all(gateways.splice(0).map((gateway) => gateway.dispose())); });

/** A session's raw canonical entries, in file order. */
async function entries(gateway: LockGateway, sessionId: string): Promise<Array<Record<string, any>>> {
  const slot = await gateway.registry.acquire(sessionId);
  return (await readFile(slot.sessionFile!, "utf8")).trimEnd().split("\n").map((line) => JSON.parse(line) as Record<string, any>);
}

describe("gateway/automations owned-run lock", () => {
  it("automation-owned-run: a session prompt and a workspace prompt run now through the owned-session boundary", async () => {
    const gateway = await startLockGateway("automation-owned-run", { automations: true });
    gateways.push(gateway);
    const { sessionId, existing, workspace } = await automationOwnedRunScenario(gateway);
    const automationFile = (automationId: string) => join(gateway.tronHome, "gateway", "automations", `${automationId}.json`);
    const recorded = gateway.record();
    const exchanges = recorded.exchanges as Array<{ method: string; params: Record<string, unknown>; response: { ok: boolean; result: any } }>;
    const results = (method: string) => exchanges.filter((exchange) => exchange.method === method).map((exchange) => exchange.response.result);
    expect(exchanges.map((exchange) => exchange.method)).toEqual(["session.create", "session.open", "session.sync", "session.prompt",
      "automation.create", "automation.runNow", "automation.create", "automation.runNow",
      "automation.get", "automation.run.get", "automation.get", "automation.run.get", "session.transcript"]);
    expect([existing.state, workspace.state]).toEqual(["succeeded", "succeeded"]);
    // The session prompt runs in its chat; the workspace prompt gets its own owned session.
    expect(existing.executionSessionId).toBe(sessionId);
    expect(workspace.executionSessionId).not.toBe(sessionId);

    const runs = [
      { run: existing, text: "run the scheduled notes check", answer: "The scheduled check found: lock notes.", name: "Lock session check", target: { kind: "existingSession", sessionId: "<id>" }, session: sessionId },
      { run: workspace, text: "run the workspace notes check", answer: "The workspace check found: lock notes.", name: "Lock workspace check", target: { kind: "workspace", cwd: "<tmp>/workspace", sessionPolicy: "newPerRun" },
        session: workspace.executionSessionId },
    ];
    const [createdRecords, admitted, records, runReads] = [results("automation.create"), results("automation.runNow"), results("automation.get"), results("automation.run.get")];
    for (const [index, { run, text, answer, name, target, session }] of runs.entries()) {
      const action = { kind: "sessionPrompt", text };
      const trigger = { kind: "once", at: "<timestamp>" };
      expect(createdRecords[index]).toMatchObject({ schemaVersion: 2, name, activation: "draft", action, target, trigger, history: [], stateRevision: 1,
        consecutiveFailureCount: 0, executionDeadlineSeconds: 3600, misfirePolicy: "latest", overlapPolicy: "skip", provenance: { kind: "mobile" } });
      // Run now admits a manual, queued run with its snapshots.
      expect(admitted[index]).toMatchObject({ state: "queued", manual: true, automationRevision: 1, preAdmissionAttemptCount: 0,
        actionSnapshot: action, targetSnapshot: target, triggerSnapshot: trigger });
      // The durable record and both reads agree: one succeeded run, the last run, nothing current.
      const file = await gateway.file(automationFile(run.automationId)) as Record<string, any>;
      expect(records[index]).toEqual(file);
      expect(file).toMatchObject({ schemaVersion: 2, name, activation: "draft", action, target, trigger, misfirePolicy: "latest", overlapPolicy: "skip",
        provenance: { kind: "mobile" }, executionDeadlineSeconds: 3600, stateRevision: 5, consecutiveFailureCount: 0, history: [file.lastRun] });
      expect(file.currentRun).toBeUndefined();
      expect(runReads[index]).toEqual(file.lastRun);
      expect(file.lastRun).toMatchObject({ state: "succeeded", manual: true, occurrenceId: admitted[index].occurrenceId, actionSnapshot: action, targetSnapshot: target,
        triggerSnapshot: trigger, automationRevision: 1, preAdmissionAttemptCount: 0, scheduledFor: expect.any(String),
        claimId: expect.any(String), hostEpoch: expect.any(String), invocationId: expect.any(String), startedAt: expect.any(String), terminalAt: expect.any(String) });
      // Raw identities: the run names its session's final assistant entry as its completion, and its operation and invocation are that prompt's receipts.
      const raw = JSON.parse(await readFile(automationFile(run.automationId), "utf8")) as { id: string; lastRun: Record<string, string> };
      expect(raw.id).toBe(run.automationId);
      expect(raw.lastRun).toMatchObject({ runId: run.runId, executionSessionId: session });
      const jsonl = await entries(gateway, session);
      const assistants = jsonl.filter((entry) => entry.type === "message" && entry.message.role === "assistant");
      expect(raw.lastRun.assistantCompletionId).toBe(assistants.at(-1)!.id);
      expect(run.assistantCompletionId).toBe(raw.lastRun.assistantCompletionId);
      const receipts = jsonl.filter((entry) => entry.customType === "tron.chat-invocation.v1" && entry.data.invocationId === raw.lastRun.invocationId)
        .map((entry) => entry.data);
      expect(receipts.map((receipt) => `${receipt.receiptKind}:${receipt.lifecycle ?? ""}`)).toEqual(["start:staged", "transition:accepted", "binding:", "terminal:completed"]);
      for (const receipt of receipts) expect(receipt).toMatchObject({ operationId: raw.lastRun.operationId, sessionId: session, writer: "gateway", source: "plain" });
      for (const receipt of [receipts[0], receipts[3]]) expect(receipt.origin).toEqual({ confidence: "boundary", kind: "gateway", ownerId: raw.id, title: "Automation" });
      const bound = jsonl.find((entry) => entry.id === receipts[2].canonicalEntryId);
      expect(bound?.message.content.map((part: { text?: string }) => part.text).join("")).toBe(text);
      // The owned turn: the prompt, a read round trip and the answer.
      expect(jsonl.flatMap((entry) => entry.type === "message" && entry.message.role !== "system"
        ? [`${entry.message.role}:${entry.message.content.map((part: { type: string; text?: string; name?: string }) => part.type === "toolCall" ? `[${part.name}]` : part.text).join("")}`]
        : []).slice(-4)).toEqual([`user:${text}`, "assistant:[read]", "toolResult:lock notes\n", `assistant:${answer}`]);
      expectSystemShapes(await gateway.canonical(session), ["chatWithAutomations#0"]);
    }

    // Both sessions' entries: the chat's own turn, then the automation's; the workspace session holds only its run.
    const receipt = "tron.chat-invocation.v1";
    const types = async (session: string) => (await entries(gateway, session)).map((entry) => entry.type === "custom" ? entry.customType : entry.type);
    const preamble = ["session", "model_change", "thinking_level_change", "tron.context-window.v1", "tron.settings.v1", "tron.settings.v1"];
    expect(await types(sessionId)).toEqual([...preamble, receipt, receipt, "message", "message", receipt, "message", receipt, receipt, receipt,
      "message", receipt, "message", "message", "message", receipt]);
    expect(await types(workspace.executionSessionId)).toEqual([...preamble, receipt, receipt, "message", "message", receipt, "message", "message", "message", receipt]);

    // The chat's transcript: the user's turn, then the Automation-attributed prompt and its tool round trip.
    const [transcript] = results("session.transcript") as Array<{ end: number; total: number; items: Array<Record<string, any>> }>;
    expect(transcript).toMatchObject({ end: 8, total: 8 });
    expect(transcript!.items.map((item) => [item.kind === "message" ? `${item.role}${item.stopReason ? `:${item.stopReason}` : ""}` : item.kind,
      item.semantic?.lifecycle ?? "", item.semantic?.origin?.title ?? item.semantic?.origin?.kind ?? "",
      ...(item.content ?? []).map((part: { type: string; text?: string; name?: string }) => part.type === "toolCall" ? `call:${part.name}` : part.text)].join(" | "))).toEqual([
      "modelChange |  | gateway", "thinkingChange |  | gateway",
      "user | completed | user | get ready for scheduled checks", "assistant:stop |  | assistant | Ready for scheduled checks.",
      "user | completed | Automation | run the scheduled notes check", "assistant:toolUse |  | assistant | call:read",
      "toolResult |  | assistant | lock notes\n", "assistant:stop |  | assistant | The scheduled check found: lock notes.",
    ]);

    // Each provider request: the chat keeps its history; the workspace run starts fresh.
    expect(recorded.providerRequests.map((request) => request.messages.map((message) => {
      const { role, text, toolCalls } = message as { role: string; text?: string; toolCalls?: string[] };
      return `${role}:${text ?? ""}${toolCalls ? `[${toolCalls.join(",")}]` : ""}`;
    }))).toEqual([
      ["user:get ready for scheduled checks"],
      ["user:get ready for scheduled checks", "assistant:Ready for scheduled checks.", "user:run the scheduled notes check"],
      ["user:get ready for scheduled checks", "assistant:Ready for scheduled checks.", "user:run the scheduled notes check", "assistant:[read]", "toolResult:lock notes\n"],
      ["user:run the workspace notes check"],
      ["user:run the workspace notes check", "assistant:[read]", "toolResult:lock notes\n"],
    ]);
    expectRequestShapes(recorded.providerRequests, Array(5).fill("chatWithAutomations"));

    // Every mutation has one completed command receipt whose result is the response the phone got.
    const receiptsDir = join(gateway.tronHome, "gateway", "command-receipts");
    const commandReceipts = (await Promise.all((await gateway.tree(receiptsDir)).map(async (name) => JSON.parse(await readFile(join(receiptsDir, name), "utf8")) as Record<string, any>)))
      .sort((left, right) => String(left.commandId).localeCompare(String(right.commandId)));
    expect(commandReceipts.map((entry) => entry.method)).toEqual([
      "session.create", "session.prompt", "automation.create", "automation.runNow", "automation.create", "automation.runNow",
    ]);
    expect(commandReceipts.map((entry) => entry.identityHash)).toEqual(Array(6).fill(expect.stringMatching(/^[A-Za-z0-9_-]{43}$/)));
    expect(new Set(commandReceipts.map((entry) => entry.identityHash)).size).toBe(1);
    const mutations = exchanges.filter((exchange) => typeof exchange.params.commandId === "string");
    for (const [index, entry] of commandReceipts.entries()) {
      expect(entry).toMatchObject({ status: "completed", version: 1, commandId: mutations[index]!.params.commandId });
    }
    expect(commandReceipts.map((entry) => normalizeTraceValue(entry.result, gateway.normalization)))
      .toEqual(mutations.map((exchange) => exchange.response.result));
    // The owned operations' runtime markers are cleared once the scheduler acknowledges each terminal.
    expect(await gateway.tree(join(gateway.tronHome, "gateway", "runtime-markers"))).toEqual([]);
  });
});
