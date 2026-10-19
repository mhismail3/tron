import { fauxAssistantMessage, fauxThinking, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockClient, type LockGateway, type LockGatewayOptions } from "../../test-support/gateway-lock-harness.js";
import { compareWithGolden, lockPaths, lockUpdateRequested, normalizeTraceValue, type TraceValue } from "../../test-support/scenario-lock.js";
import { awaitsWithin, waitFor } from "../../test-support/wait-for.js";

/**
 * Kernel run locks (restructure plan §6.4, V3) for the `gateway/run` module:
 * prompt/stream, steer, abort, compaction and extension UI, each through the
 * real Gateway over a loopback WebSocket (`gateway-lock-harness.ts`) with the
 * faux provider as the only scripted party.
 *
 * Each lock records the client's request/response values, every event topic's
 * payload structure, each provider request (tools, prompt sections, prompt
 * hash, messages), canonical JSONL and the transcript projection, and compares
 * them with `locks/<name>.golden.json`. A refactor never changes a golden; an
 * approved behavior change rewrites it with `TRON_UPDATE_LOCKS=gateway/run`.
 * Each scenario also asserts its own steps happened, so a golden can never
 * record a degraded run as the expected behavior.
 */

const MODULE = "gateway/run";
const gateways: LockGateway[] = [];
afterEach(async () => { await Promise.all(gateways.splice(0).map((gateway) => gateway.dispose())); });

interface RunLockTrace {
  readonly lock: string;
  readonly exchanges: readonly TraceValue[];
  readonly events: readonly TraceValue[];
  readonly providerRequests: readonly TraceValue[];
  readonly canonicalJsonl: readonly TraceValue[];
  readonly transcript: TraceValue;
  readonly observed?: TraceValue;
}

interface Session {
  readonly gateway: LockGateway;
  readonly client: LockClient;
  readonly sessionId: string;
  prompt(text: string, extra?: Record<string, unknown>): Promise<{ ok: boolean; result?: any; error?: any }>;
}

async function openSession(name: string, options?: LockGatewayOptions): Promise<Session> {
  const gateway = await startLockGateway(name, options);
  gateways.push(gateway);
  const client = await gateway.connect("phone");
  const created = await client.request("session.create", { commandId: gateway.commandId(), cwd: gateway.cwd });
  expect(created.ok, JSON.stringify(created)).toBe(true);
  const sessionId = created.result.sessionId as string;
  const opened = await client.request("session.open", { sessionId });
  expect(opened.ok, JSON.stringify(opened)).toBe(true);
  expect((await client.request("session.sync", { sessionId, syncToken: opened.result.syncToken })).ok).toBe(true);
  return {
    gateway, client, sessionId,
    prompt: (text, extra = {}) => client.send("session.prompt", { commandId: gateway.commandId(), sessionId, text, ...extra }),
  };
}

async function finish(session: Session, lock: string, validate: (trace: RunLockTrace) => void, observed?: TraceValue): Promise<void> {
  await session.gateway.settled(session.sessionId);
  const transcript = await session.client.request("session.transcript", { sessionId: session.sessionId });
  expect(transcript.ok, JSON.stringify(transcript)).toBe(true);
  const recorded = session.gateway.record();
  const trace: RunLockTrace = {
    lock,
    exchanges: recorded.exchanges,
    events: recorded.events,
    providerRequests: recorded.providerRequests as unknown as TraceValue[],
    canonicalJsonl: await session.gateway.canonical(session.sessionId),
    transcript: (recorded.exchanges.at(-1) as { response: TraceValue }).response,
    ...(observed === undefined ? {} : { observed: normalizeTraceValue(observed, session.gateway.normalization) }),
  };
  await compareWithGolden({ module: MODULE, ...lockPaths(import.meta.url, lock), trace, update: lockUpdateRequested(MODULE), validate });
}

/** The roles of the canonical message entries, in file order. */
function canonicalRoles(trace: RunLockTrace): string[] {
  return trace.canonicalJsonl.flatMap((entry) => {
    const message = (entry as { message?: { role?: string } }).message;
    return message?.role && message.role !== "system" ? [message.role] : [];
  });
}

function canonicalTypes(trace: RunLockTrace): string[] {
  return trace.canonicalJsonl.map((entry) => String((entry as { type?: unknown }).type));
}

/** A gate a scripted provider step holds until the test opens it. */
function gate(): { opened: Promise<void>; open(): void; reached: Promise<void>; reach(): void } {
  let open = (): void => {};
  let reach = (): void => {};
  const opened = new Promise<void>((resolve) => { open = resolve; });
  const reached = new Promise<void>((resolve) => { reach = resolve; });
  return { opened, open: () => open(), reached, reach: () => reach() };
}

describe("gateway/run kernel locks", () => {
  it("prompt/stream: one prompt streams thinking, text and a tool round trip", async () => {
    const session = await openSession("run-prompt-stream");
    session.gateway.script([
      () => fauxAssistantMessage([
        fauxThinking("Reading the lock notes."),
        { type: "text", text: "Reading notes." },
        fauxToolCall("read", { path: "notes.txt" }, { id: "lock-read" }),
      ], { stopReason: "toolUse" }),
      () => fauxAssistantMessage("The notes say: lock notes."),
    ]);
    const admitted = await session.prompt("read the notes");
    expect(admitted.ok, JSON.stringify(admitted)).toBe(true);
    await finish(session, "run-prompt-stream", (trace) => {
      expect(canonicalRoles(trace)).toEqual(["user", "assistant", "toolResult", "assistant"]);
      expect(trace.providerRequests).toHaveLength(2);
      expect(JSON.stringify(trace.canonicalJsonl)).toContain("lock notes");
      expect((trace.events as Array<{ topic: string }>).map((event) => event.topic)).toContain("session.snapshot");
    });
  });

  it("steer: a steer and a follow-up admitted into a live run reach the model in order", async () => {
    const session = await openSession("run-steer");
    const held = gate();
    session.gateway.script([
      async () => { held.reach(); await held.opened; return fauxAssistantMessage([fauxToolCall("read", { path: "notes.txt" }, { id: "lock-steer-read" })], { stopReason: "toolUse" }); },
      () => fauxAssistantMessage("Steered work acknowledged."),
      () => fauxAssistantMessage("Follow-up work acknowledged."),
    ]);
    const running = session.prompt("hold a turn open");
    await awaitsWithin(held.reached, "the held provider request");
    expect((await session.prompt("steer the run", { behavior: "steer" })).ok).toBe(true);
    expect((await session.prompt("then follow up", { behavior: "followUp" })).ok).toBe(true);
    held.open();
    expect((await running).ok).toBe(true);
    await finish(session, "run-steer", (trace) => {
      const texts = trace.canonicalJsonl.flatMap((entry) => {
        const message = (entry as { message?: { role?: string; content?: unknown } }).message;
        return message?.role === "user" ? [JSON.stringify(message.content)] : [];
      });
      expect(texts.map((text) => ["hold a turn open", "steer the run", "then follow up"].findIndex((needle) => text.includes(needle))))
        .toEqual([0, 1, 2]);
      expect(trace.providerRequests).toHaveLength(3);
    });
  });

  it("abort: aborting the live operation settles the turn as aborted", async () => {
    const session = await openSession("run-abort");
    const held = gate();
    session.gateway.script([
      async (_context, options) => {
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
    await finish(session, "run-abort", (trace) => {
      const assistant = trace.canonicalJsonl.find((entry) => (entry as { message?: { role?: string } }).message?.role === "assistant");
      expect((assistant as { message: { stopReason?: string } }).message.stopReason).toBe("aborted");
      expect(trace.providerRequests).toHaveLength(1);
    });
  });

  it("compaction: a manual compaction summarizes earlier turns and keeps the recent tail", async () => {
    const session = await openSession("run-compaction");
    const long = "lock context ".repeat(80);
    session.gateway.script([
      () => fauxAssistantMessage(`First answer. ${long}`),
      () => fauxAssistantMessage(`Second answer. ${long}`),
      // A manual compaction asks for the summary of the cut history, then for the
      // prefix of the split turn the recent tail keeps.
      () => fauxAssistantMessage("Summary: two answered turns about the lock context."),
      () => fauxAssistantMessage("Turn prefix: the second question."),
    ]);
    expect((await session.prompt("first question")).ok).toBe(true);
    await session.gateway.settled(session.sessionId);
    expect((await session.prompt("second question")).ok).toBe(true);
    await session.gateway.settled(session.sessionId);
    const compacted = await session.client.request("session.compact", { commandId: session.gateway.commandId(), sessionId: session.sessionId });
    expect(compacted.ok, JSON.stringify(compacted)).toBe(true);
    await finish(session, "run-compaction", (trace) => {
      expect(canonicalTypes(trace)).toContain("compaction");
      const compaction = trace.canonicalJsonl.find((entry) => (entry as { type?: unknown }).type === "compaction") as { summary?: string };
      expect(compaction.summary).toContain("two answered turns");
      expect(trace.providerRequests).toHaveLength(4);
      expect(JSON.stringify(trace.providerRequests)).not.toContain("Unscripted lock response");
    });
  });

  it("extension UI: an extension tool's select waits for the client's answer and resumes the turn with it", async () => {
    const session = await openSession("run-extension-ui", { extensions: [{ name: "lock-select.ts", source: `
      export default function (pi) {
        pi.registerTool({
          name: "lock_select", label: "Lock select", description: "Ask the user which lock path to take",
          parameters: { type: "object", properties: {} },
          execute: async (_id, _params, _signal, _update, ctx) => {
            const answer = await ctx.ui.select("Choose a lock path", ["Keep", "Change"]);
            return { content: [{ type: "text", text: "chosen: " + (answer ?? "cancelled") }], details: { answer: answer ?? null } };
          },
        });
      }
    ` }] });
    session.gateway.script([
      () => fauxAssistantMessage([fauxToolCall("lock_select", {}, { id: "lock-select" })], { stopReason: "toolUse" }),
      () => fauxAssistantMessage("Keeping the lock path."),
    ]);
    const running = session.prompt("ask me which path");
    // The client answers what it was shown: the interaction arrives on an event.
    const pending = await waitFor(() => {
      for (const event of session.client.events) {
        const shown = (event.payload as { extensionPresentation?: { pendingInteractions?: Array<{ id: string; hostEpoch: string; presentationRevision: number }> } })
          ?.extensionPresentation?.pendingInteractions?.[0];
        if (shown) return shown;
      }
      return undefined;
    }, "the pending select to reach the client");
    const answered = await session.client.request("extension.respond", {
      commandId: session.gateway.commandId(), sessionId: session.sessionId, interactionId: pending.id,
      hostEpoch: pending.hostEpoch, presentationRevision: pending.presentationRevision, value: "Keep",
    });
    expect(answered.ok, JSON.stringify(answered)).toBe(true);
    expect((await running).ok).toBe(true);
    await finish(session, "run-extension-ui", (trace) => {
      const result = trace.canonicalJsonl.find((entry) => (entry as { message?: { role?: string } }).message?.role === "toolResult");
      expect(JSON.stringify(result)).toContain("chosen: Keep");
      expect(JSON.stringify(trace.observed)).toContain("Choose a lock path");
    }, pending as unknown as TraceValue);
  });
});
