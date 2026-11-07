import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { readFile } from "node:fs/promises";
import { afterEach, describe, expect, it } from "vitest";
import { type LockGateway, type LockGatewayOptions } from "../../test-support/gateway-lock-harness.js";
import { normalizeTraceValue } from "../../test-support/scenario-lock.js";
import { expectRequestShapes, expectSystemShapes } from "../../test-support/lock-projections.js";
import { awaitsWithin } from "../../test-support/wait-for.js";
import { compactionScenario, EXTENSION_UI_OPTIONS, extensionUiScenario, gate, openLockSession, promptStreamScenario, type LockSession } from "../../test-support/lock-scenarios.js";

/**
 * Kernel run locks (packages/gateway/docs/scenario-locks.md#locks) for the `gateway/run` module:
 * prompt/stream, steer, abort, compaction and extension UI, each through the
 * real Gateway over a loopback WebSocket (`gateway-lock-harness.ts`) with the
 * faux provider as the only scripted party.
 *
 * Each lock asserts its effects by name: the invocation receipts the run
 * persists (kind, lifecycle and identity), the canonical entry types, the
 * transcript rows the client reads (semantic visibility, context effect,
 * lifecycle, tool and content text), the responses each request returned, each
 * provider request's messages, and the `session-shapes` shape of each provider
 * request and system entry (the model-visible prompt and tools).
 */

const gateways: LockGateway[] = [];
afterEach(async () => { await Promise.all(gateways.splice(0).map((gateway) => gateway.dispose())); });

interface RunLockTrace {
  readonly sessionId: string;
  readonly exchanges: ReadonlyArray<{ readonly method?: string; readonly response?: { readonly result?: any } }>;
  readonly events: readonly unknown[];
  readonly providerRequests: ReadonlyArray<{ readonly messages: readonly unknown[] }>;
  readonly canonicalJsonl: readonly unknown[];
  readonly transcript: { readonly end: number; readonly total: number; readonly items: ReadonlyArray<Record<string, unknown>> };
}

type Session = LockSession;

async function openSession(name: string, options?: LockGatewayOptions): Promise<Session> {
  const session = await openLockSession(name, options);
  gateways.push(session.gateway);
  return session;
}

/** Settle the run and read what it left: normalized exchanges and provider requests, the raw canonical JSONL and the client's transcript. */
async function finish(session: Session, shape: string): Promise<RunLockTrace> {
  await session.gateway.settled(session.sessionId);
  const transcript = await session.client.request("session.transcript", { sessionId: session.sessionId });
  expect(transcript.ok, JSON.stringify(transcript)).toBe(true);
  const recorded = session.gateway.record();
  // The raw file, so receipt identities can be compared; `canonical()` normalizes every id to `<id>`.
  const slot = await session.gateway.registry.acquire(session.sessionId);
  const canonicalJsonl = (await readFile(slot.sessionFile!, "utf8")).trimEnd().split("\n").map((line) => JSON.parse(line) as unknown);
  expectSystemShapes(normalizeTraceValue(canonicalJsonl, session.gateway.normalization) as unknown[], [`${shape}#0`]);
  return { sessionId: session.sessionId, exchanges: recorded.exchanges as RunLockTrace["exchanges"], events: recorded.events,
    providerRequests: recorded.providerRequests, canonicalJsonl, transcript: transcript.result };
}

/** The results of every recorded response to `method`, in request order. */
function results(trace: RunLockTrace, method: string): unknown[] {
  return trace.exchanges.filter((exchange) => exchange.method === method).map((exchange) => exchange.response?.result);
}

/** The roles of the canonical message entries, in file order. */
function canonicalRoles(trace: RunLockTrace): string[] {
  return trace.canonicalJsonl.flatMap((entry) => {
    const message = (entry as { message?: { role?: string } }).message;
    return message?.role && message.role !== "system" ? [message.role] : [];
  });
}

/** Every canonical entry's type, custom entries as `custom:<customType>`, in file order. */
function canonicalTypes(trace: RunLockTrace): string[] {
  return trace.canonicalJsonl.map((entry) => {
    const { type, customType } = entry as { type?: string; customType?: string };
    return type === "custom" ? `custom:${customType}` : String(type);
  });
}

const SESSION_PREAMBLE = ["session", "model_change", "thinking_level_change", "custom:tron.context-window.v1", "custom:tron.settings.v1", "custom:tron.settings.v1"];
const RECEIPT = "custom:tron.chat-invocation.v1";

interface Receipt {
  readonly receiptKind: string; readonly lifecycle?: string; readonly invocationId: string; readonly operationId: string; readonly sessionId: string;
  readonly source: string; readonly writer: string; readonly version: number; readonly origin?: { kind: string }; readonly canonicalEntryId?: string; readonly errorCode?: string;
}

function receiptData(trace: RunLockTrace): Receipt[] {
  return trace.canonicalJsonl.flatMap((entry) => {
    const record = entry as { customType?: string; data?: Receipt };
    return record.customType === "tron.chat-invocation.v1" && record.data ? [record.data] : [];
  });
}

/**
 * Each persisted chat-invocation receipt as `kind:lifecycle`, in file order,
 * after checking its identity: every invocation writes start, transition,
 * binding and terminal under one operation, from the Gateway for a plain user
 * prompt in this session. The i-th invocation (by its start) binds the
 * canonical message holding `prompts[i]`, and the client's transcript row for
 * that prompt carries the same invocation and operation.
 */
function receipts(trace: RunLockTrace, prompts: readonly string[]): string[] {
  const data = receiptData(trace);
  const invocations = new Map<string, Receipt[]>();
  for (const receipt of data) invocations.set(receipt.invocationId, [...invocations.get(receipt.invocationId) ?? [], receipt]);
  const entries = new Map(trace.canonicalJsonl.map((entry) => [(entry as { id?: string }).id, entry as { message?: { role?: string } }]));
  for (const [, receipts] of invocations) {
    expect(receipts.map((receipt) => receipt.receiptKind)).toEqual(["start", "transition", "binding", "terminal"]);
    expect(new Set(receipts.map((receipt) => receipt.operationId)).size).toBe(1);
    for (const receipt of receipts) {
      expect(receipt).toMatchObject({ sessionId: trace.sessionId, source: "plain", writer: "gateway", version: 1 });
      if (receipt.receiptKind === "start" || receipt.receiptKind === "terminal") expect(receipt.origin).toEqual({ confidence: "boundary", kind: "user" });
    }
    expect(entries.get(receipts[2]!.canonicalEntryId)?.message?.role).toBe("user");
  }
  expect(new Set(data.map((receipt) => receipt.operationId)).size).toBe(invocations.size);
  expect([...invocations.keys()]).toHaveLength(prompts.length);
  [...invocations.values()].forEach((receipts, index) => {
    const bound = entries.get(receipts[2]!.canonicalEntryId) as { message?: { content?: Array<{ text?: string }> } } | undefined;
    expect(bound?.message?.content?.map((part) => part.text).join("")).toBe(prompts[index]);
    const row = trace.transcript.items.find((item) => item.role === "user"
      && (item.content as Array<{ text?: string }>).map((part) => part.text).join("") === prompts[index]) as { semantic?: { invocationId?: string; operationId?: string } } | undefined;
    expect(row?.semantic).toMatchObject({ invocationId: receipts[0]!.invocationId, operationId: receipts[0]!.operationId });
  });
  return data.map((receipt) => `${receipt.receiptKind}:${receipt.lifecycle ?? ""}`);
}

/** Each provider request's messages as `role:text`, with tool calls `[name]` and tool results `(name)`. */
function requestMessages(trace: RunLockTrace): string[][] {
  return trace.providerRequests.map((request) => request.messages.map((message) => {
    const { role, text, toolCalls, toolName } = message as { role: string; text?: string; toolCalls?: string[]; toolName?: string };
    return `${role}:${text ?? ""}${toolCalls ? `[${toolCalls.join(",")}]` : ""}${toolName ? `(${toolName})` : ""}`;
  }));
}

/**
 * The transcript rows the client reads, each as `head | [tags] | content...`:
 * the head is a message's role (and stop reason) or the row's kind; the tags are
 * its semantic visibility, context effect and lifecycle, tool name and outcome,
 * thinking level and model provider; content is each part's text (`thinking:`
 * prefixed), a tool call as `call:<name>`, then an error message or summary.
 * Texts over 80 characters keep their head and length.
 */
function transcriptRows(trace: RunLockTrace): string[] {
  const clip = (text: string): string => text.length > 80 ? `${text.slice(0, 80)}…(${text.length})` : text;
  return trace.transcript.items.map((item) => {
    const { kind, role, stopReason, semantic, toolName, isError, level, modelRef, content, errorMessage, summary } = item as {
      kind: string; role?: string; stopReason?: string; toolName?: string; isError?: boolean; level?: string; errorMessage?: string; summary?: string;
      semantic?: { visibility?: string; contextEffect?: string; lifecycle?: string }; modelRef?: { provider?: string };
      content?: Array<{ type: string; text?: string; name?: string }>;
    };
    const head = kind === "message" ? `${role}${stopReason ? `:${stopReason}` : ""}` : kind;
    const tags = [semantic?.visibility, semantic?.contextEffect, semantic?.lifecycle, toolName, isError === undefined ? undefined : isError ? "error" : "ok",
      level, modelRef?.provider].filter(Boolean).join(" ");
    const parts = (content ?? []).map((part) => part.type === "toolCall" ? `call:${part.name}` : part.type === "thinking" ? `thinking:${part.text}` : clip(part.text ?? part.type));
    return [head, `[${tags}]`, ...parts, ...[errorMessage, summary].filter((text): text is string => text !== undefined).map(clip)].join(" | ");
  });
}

const ONE_TURN = ["start:staged", "transition:accepted", "binding:", "terminal:completed"];

describe("gateway/run kernel locks", () => {
  it("prompt/stream: one prompt streams thinking, text and a tool round trip", async () => {
    const session = await openSession("run-prompt-stream");
    await promptStreamScenario(session);
    const trace = await finish(session, "chat");
    // The idle snapshot a client opens before the first prompt.
    const [opened] = results(trace, "session.open") as Array<{ completionRevision: number; session: Record<string, unknown> }>;
    expect(opened!.completionRevision).toBe(0);
    expect(opened!.session).toMatchObject({
      phase: "idle", cwd: "<tmp>/workspace", configurationBlocker: null, acceptsQueuedPrompts: false, automaticCompactionEnabled: false,
      compactionQueued: false, availableThinkingLevels: ["off"], thinkingLevel: "off", diagnostics: [], queueRevision: 0, queuedItems: [],
      toolExecutions: [], liveActivityRevision: 0, transcriptStart: 0, transcriptTotal: 2,
      compactionPolicy: {
        currentBudgets: { enabled: false, keepRecentTokens: 120, reserveTokens: 2048 }, extensionMayOverride: false,
        next: { effectiveThinkingLevel: "off", enabled: false, instructions: "", keepRecentTokens: 120, requestedThinkingLevel: "off", reserveTokens: 2048,
          thinkingLevel: "inherit", source: { enabled: "global", instructions: "global", keepRecentTokens: "global", reserveTokens: "global", thinkingLevel: "global" } },
      },
      contextWindowPolicy: { default: 128_000, effective: 128_000, maximum: 128_000, minimum: 3192, override: 128_000, source: "session",
        warning: "This new session and its context override are not yet saved to disk; they persist after the first user or assistant message." },
    });
    expect(results(trace, "session.sync")).toEqual([{ synchronized: true }]);
    expect(results(trace, "session.prompt")).toEqual([{ operationId: expect.any(String) }]);
    expect(canonicalRoles(trace)).toEqual(["user", "assistant", "toolResult", "assistant"]);
    expect(canonicalTypes(trace)).toEqual([...SESSION_PREAMBLE, RECEIPT, RECEIPT, "message", "message", RECEIPT, "message", "message", "message", RECEIPT]);
    expect(receipts(trace, ["read the notes"])).toEqual(ONE_TURN);
    expect(transcriptRows(trace)).toEqual([
      "modelChange | [visible none tron-lock-run-prompt-stream]",
      "thinkingChange | [visible none off]",
      "user | [visible modelInput completed] | read the notes",
      "assistant:toolUse | [visible modelInput] | thinking:Reading the lock notes. | Reading notes. | call:read",
      "toolResult | [visible toolResult read ok] | lock notes\n",
      "assistant:stop | [visible modelInput] | The notes say: lock notes.",
    ]);
    expect(trace.transcript).toMatchObject({ end: 6, total: 6 });
    expect(requestMessages(trace)).toEqual([
      ["user:read the notes"],
      ["user:read the notes", "assistant:Reading notes.[read]", "toolResult:lock notes\n(read)"],
    ]);
    expectRequestShapes(trace.providerRequests, ["chat", "chat"]);
  });

  it("steer: a steer and a follow-up admitted into a live run reach the model in order", async () => {
    const session = await openSession("run-steer");
    const held = gate();
    session.gateway.script([
      async () => { await session.gateway.observeLiveOperation(session.client, session.sessionId); held.reach(); await held.opened; return fauxAssistantMessage([fauxToolCall("read", { path: "notes.txt" }, { id: "lock-steer-read" })], { stopReason: "toolUse" }); },
      () => fauxAssistantMessage("Steered work acknowledged."),
      () => fauxAssistantMessage("Follow-up work acknowledged."),
    ]);
    const running = session.prompt("hold a turn open");
    await awaitsWithin(held.reached, "the held provider request");
    expect((await session.prompt("steer the run", { behavior: "steer" })).ok).toBe(true);
    expect((await session.prompt("then follow up", { behavior: "followUp" })).ok).toBe(true);
    held.open();
    expect((await running).ok).toBe(true);
    const trace = await finish(session, "chat");
    const texts = trace.canonicalJsonl.flatMap((entry) => {
      const message = (entry as { message?: { role?: string; content?: unknown } }).message;
      return message?.role === "user" ? [JSON.stringify(message.content)] : [];
    });
    expect(texts.map((text) => ["hold a turn open", "steer the run", "then follow up"].findIndex((needle) => text.includes(needle))))
      .toEqual([0, 1, 2]);
    // The steer joins the live run's next model call; the follow-up runs after it, each with its own receipts.
    expect(requestMessages(trace)).toEqual([
      ["user:hold a turn open"],
      ["user:hold a turn open", "assistant:[read]", "toolResult:lock notes\n(read)", "user:steer the run"],
      ["user:hold a turn open", "assistant:[read]", "toolResult:lock notes\n(read)", "user:steer the run", "assistant:Steered work acknowledged.", "user:then follow up"],
    ]);
    expectRequestShapes(trace.providerRequests, ["chat", "chat", "chat"]);
    expect(receipts(trace, ["hold a turn open", "steer the run", "then follow up"])).toEqual(["start:staged", "transition:accepted", "binding:", "start:staged", "transition:accepted",
      "start:staged", "transition:accepted", "binding:", "terminal:completed", "terminal:completed", "binding:", "terminal:completed"]);
    expect(results(trace, "session.prompt")).toEqual([0, 1, 2].map(() => ({ operationId: expect.any(String) })));
    expect(canonicalTypes(trace)).toEqual([...SESSION_PREAMBLE, RECEIPT, RECEIPT, "message", "message", RECEIPT, RECEIPT, RECEIPT, RECEIPT, RECEIPT,
      "message", "message", "message", RECEIPT, RECEIPT, "message", RECEIPT, "message", RECEIPT, "message", RECEIPT]);
    expect(transcriptRows(trace)).toEqual([
      "modelChange | [visible none tron-lock-run-steer]",
      "thinkingChange | [visible none off]",
      "user | [visible modelInput completed] | hold a turn open",
      "assistant:toolUse | [visible modelInput] | call:read",
      "toolResult | [visible toolResult read ok] | lock notes\n",
      "user | [visible modelInput completed] | steer the run",
      "assistant:stop | [visible modelInput] | Steered work acknowledged.",
      "user | [visible modelInput completed] | then follow up",
      "assistant:stop | [visible modelInput] | Follow-up work acknowledged.",
    ]);
  });

  it("abort: aborting the live operation settles the turn as aborted", async () => {
    const session = await openSession("run-abort");
    const held = gate();
    session.gateway.script([
      async (_context, options) => {
        await session.gateway.observeLiveOperation(session.client, session.sessionId);
        held.reach();
        await new Promise<void>((resolve) => {
          const signal = options?.signal;
          if (!signal || signal.aborted) { resolve(); return; }
          signal.addEventListener("abort", () => resolve(), { once: true });
        });
        return fauxAssistantMessage("Aborted turn response.");
      },
    ]);
    const admitted = await session.prompt("start a turn to abort");
    expect(admitted.ok).toBe(true);
    await awaitsWithin(held.reached, "the abortable provider request");
    const aborted = await session.client.request("session.abort", {
      commandId: session.gateway.commandId(), sessionId: session.sessionId, operationId: admitted.result.operationId,
    });
    expect(aborted.ok, JSON.stringify(aborted)).toBe(true);
    expect(aborted.result).toEqual({ aborted: true });
    const trace = await finish(session, "chat");
    const assistant = trace.canonicalJsonl.find((entry) => (entry as { message?: { role?: string } }).message?.role === "assistant");
    expect((assistant as { message: { stopReason?: string } }).message.stopReason).toBe("aborted");
    // The aborted turn's terminal receipt is interrupted; the model was asked once.
    expect(receipts(trace, ["start a turn to abort"])).toEqual(["start:staged", "transition:accepted", "binding:", "terminal:interrupted"]);
    expect(receiptData(trace)[3]).toMatchObject({ operationId: admitted.result.operationId, errorCode: "user-abort" });
    expect(canonicalTypes(trace)).toEqual([...SESSION_PREAMBLE, RECEIPT, RECEIPT, "message", "message", RECEIPT, "message", RECEIPT]);
    // The interrupted prompt's row says so; the aborted reply carries the provider's reason.
    expect(transcriptRows(trace)).toEqual([
      "modelChange | [visible none tron-lock-run-abort]",
      "thinkingChange | [visible none off]",
      "user | [visible modelInput interrupted] | start a turn to abort",
      "assistant:aborted | [visible modelInput] | Request was aborted",
    ]);
    expect(requestMessages(trace)).toEqual([["user:start a turn to abort"]]);
    expectRequestShapes(trace.providerRequests, ["chat"]);
  });

  it("compaction: a manual compaction summarizes earlier turns and keeps the recent tail", async () => {
    const session = await openSession("run-compaction");
    const { compacted } = await compactionScenario(session);
    expect(compacted.result).toEqual({ compacted: true, queued: false });
    const trace = await finish(session, "chat");
    expect(canonicalTypes(trace)).toEqual([...SESSION_PREAMBLE, RECEIPT, RECEIPT, "message", "message", RECEIPT, "message", RECEIPT, RECEIPT, RECEIPT,
      "message", RECEIPT, "message", RECEIPT, "compaction"]);
    // The summary the next model call sees: the history summary, then the split turn's prefix.
    const compaction = trace.canonicalJsonl.find((entry) => (entry as { type?: unknown }).type === "compaction") as
      { summary?: string; firstKeptEntryId?: string; details?: unknown };
    expect(compaction.summary).toBe("Summary: two answered turns about the lock context.\n\n---\n\n**Turn Context (split turn):**\n\nTurn prefix: the second question.");
    expect(compaction.details).toEqual({ modifiedFiles: [], readFiles: [] });
    expect(trace.canonicalJsonl.map((entry) => (entry as { id?: string }).id)).toContain(compaction.firstKeptEntryId);
    expect(receipts(trace, ["first question", "second question"])).toEqual([...ONE_TURN, ...ONE_TURN]);
    expect(transcriptRows(trace)).toEqual([
      "modelChange | [visible none tron-lock-run-compaction]",
      "thinkingChange | [visible none off]",
      "user | [visible modelInput completed] | first question",
      "assistant:stop | [visible modelInput] | First answer. lock context lock context lock context lock context lock context l…(1054)",
      "user | [visible modelInput completed] | second question",
      "assistant:stop | [visible modelInput] | Second answer. lock context lock context lock context lock context lock context …(1055)",
      "compaction | [visible none] | Summary: two answered turns about the lock context.\n\n---\n\n**Turn Context (split …(123)",
    ]);
    // Two chat turns, then the history summary and the split-turn prefix requests.
    expectRequestShapes(trace.providerRequests, ["chat", "chat", "compactionSummary", "compactionSummary"]);
    const long = "lock context ".repeat(80);
    expect(requestMessages(trace).slice(0, 2)).toEqual([["user:first question"], ["user:first question", `assistant:First answer. ${long}`, "user:second question"]]);
    const [summaryRequest, prefixRequest] = requestMessages(trace).slice(2);
    expect(summaryRequest![0]).toMatch(/^user:<conversation>\n\[User\]: first question\n\n\[Assistant\]: First answer\. lock context/);
    expect(prefixRequest![0]).toMatch(/^user:# Conversation\n\[User\]: second question\n\n# Instructions\n/);
    expect(JSON.stringify(trace.providerRequests)).not.toContain("Unscripted lock response");
  });

  it("extension UI: an extension tool's select waits for the client's answer and resumes the turn with it", async () => {
    const session = await openSession("run-extension-ui", EXTENSION_UI_OPTIONS);
    const { pending } = await extensionUiScenario(session);
    expect(pending).toMatchObject({ invocationId: expect.any(String), operationId: expect.any(String), owner: { id: expect.any(String) } });
    // The client saw one select, owned by the extension, with its title and options.
    expect(pending).toMatchObject({ method: "select", title: "Choose a lock path", options: ["Keep", "Change"], presentationRevision: 1,
      owner: { kind: "extension", source: "auto", title: "Lock Select" } });
    const trace = await finish(session, "chatWithExtensionSelect");
    const result = trace.canonicalJsonl.find((entry) => (entry as { message?: { role?: string } }).message?.role === "toolResult");
    expect(JSON.stringify(result)).toContain("chosen: Keep");
    expect((result as { message: { details?: unknown } }).message.details).toEqual({ answer: "Keep" });
    expect(receipts(trace, ["ask me which path"])).toEqual(ONE_TURN);
    // The pending select belongs to the turn's invocation and operation.
    expect(pending).toMatchObject({ invocationId: receiptData(trace)[0]!.invocationId, operationId: receiptData(trace)[0]!.operationId });
    expect(results(trace, "extension.respond")).toEqual([{ answered: true }]);
    expect(canonicalTypes(trace)).toEqual([...SESSION_PREAMBLE, RECEIPT, RECEIPT, "message", "message", RECEIPT, "message", "message", "message", RECEIPT]);
    expect(transcriptRows(trace)).toEqual([
      "modelChange | [visible none tron-lock-run-extension-ui]",
      "thinkingChange | [visible none off]",
      "user | [visible modelInput completed] | ask me which path",
      "assistant:toolUse | [visible modelInput] | call:lock_select",
      "toolResult | [visible toolResult lock_select ok] | chosen: Keep",
      "assistant:stop | [visible modelInput] | Keeping the lock path.",
    ]);
    expect(requestMessages(trace)).toEqual([
      ["user:ask me which path"],
      ["user:ask me which path", "assistant:[lock_select]", "toolResult:chosen: Keep(lock_select)"],
    ]);
    expectRequestShapes(trace.providerRequests, ["chatWithExtensionSelect", "chatWithExtensionSelect"]);
  });
});
