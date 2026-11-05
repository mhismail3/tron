import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { type LockGateway, type LockGatewayOptions } from "../../test-support/gateway-lock-harness.js";
import { normalizeTraceValue, type TraceValue } from "../../test-support/scenario-lock.js";
import { expectSessionLock, projected, projectedSnapshot, type SessionLockExpectation } from "../../test-support/lock-projections.js";
import { awaitsWithin } from "../../test-support/wait-for.js";
import { compactionScenario, EXTENSION_UI_OPTIONS, extensionUiScenario, openLockSession, promptStreamScenario, type LockSession } from "../../test-support/lock-scenarios.js";

/**
 * Kernel run locks (restructure plan §6.4, V3) for the `gateway/run` module:
 * prompt/stream, steer, abort, compaction and extension UI, each through the
 * real Gateway over a loopback WebSocket (`gateway-lock-harness.ts`) with the
 * faux provider as the only scripted party.
 *
 * Each lock asserts, inline and exactly: every request the client made, its
 * parameters and its response (snapshots included), the transcript the client reads, the canonical
 * messages and entry order, the invocation receipts and the conversation each
 * provider request carried, all without per-run identities, times and token
 * counts (`test-support/lock-projections.ts`). Event schemas, model-visible session
 * shapes and Tron's persisted entry values are pinned once by `client-event-schemas`,
 * `session-shapes` and `session-entries`: every event topic and payload path, prompt
 * shape and Tron entry these scenarios produce is in those locks (their coverage was
 * checked against these scenarios' former goldens), though not every scenario here is
 * one those locks run.
 */

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

type Session = LockSession;

async function openSession(name: string, options?: LockGatewayOptions): Promise<Session> {
  const session = await openLockSession(name, options);
  gateways.push(session.gateway);
  return session;
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
  expectSessionLock(lock, {
    exchanges: recorded.exchanges, canonical: trace.canonicalJsonl, providers: recorded.providerRequests.map((request) => request.messages),
    items: (transcript.result as { items: unknown[] }).items,
    window: Object.fromEntries(Object.entries(transcript.result as Record<string, unknown>).filter(([key]) => key !== "items")),
  }, EXPECTED[lock]!);
  validate(trace);
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
    await promptStreamScenario(session);
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
    await finish(session, "run-abort", (trace) => {
      const assistant = trace.canonicalJsonl.find((entry) => (entry as { message?: { role?: string } }).message?.role === "assistant");
      expect((assistant as { message: { stopReason?: string } }).message.stopReason).toBe("aborted");
      expect(trace.providerRequests).toHaveLength(1);
    });
  });

  it("compaction: a manual compaction summarizes earlier turns and keeps the recent tail", async () => {
    const session = await openSession("run-compaction");
    await compactionScenario(session);
    await finish(session, "run-compaction", (trace) => {
      const entry = trace.canonicalJsonl.find((candidate) => (candidate as { type?: unknown }).type === "compaction") as { firstKeptEntryId: string };
      expect(projected(entry), "the compaction entry").toEqual({
        id: "<present>", parentId: "<present>", timestamp: "<present>", usage: "<present>",
        details: { modifiedFiles: [], readFiles: [] }, firstKeptEntryId: "<id>", fromHook: false,
        summary: "Summary: two answered turns about the lock context.\n\n---\n\n**Turn Context (split turn):**\n\nTurn prefix: the second question.",
        systemMessage: { contentChars: 0, sectionNames: ["cwd", "docs", "preamble", "rules", "tools"],
          toolsAdded: ["read", "bash", "edit", "write", "jev", "web_search", "settings", "projects", "ask_user", "display", "swift_app", "computer"] },
        tokensBefore: "<value>", type: "compaction",
      });
      expect(canonicalTypes(trace)).toContain("compaction");
      const compaction = trace.canonicalJsonl.find((entry) => (entry as { type?: unknown }).type === "compaction") as { summary?: string };
      expect(compaction.summary).toContain("two answered turns");
      expect(trace.providerRequests).toHaveLength(4);
      expect(JSON.stringify(trace.providerRequests)).not.toContain("Unscripted lock response");
    });
  });

  it("extension UI: an extension tool's select waits for the client's answer and resumes the turn with it", async () => {
    const session = await openSession("run-extension-ui", EXTENSION_UI_OPTIONS);
    const { pending } = await extensionUiScenario(session);
    await finish(session, "run-extension-ui", (trace) => {
      const result = trace.canonicalJsonl.find((entry) => (entry as { message?: { role?: string } }).message?.role === "toolResult");
      expect(JSON.stringify(result)).toContain("chosen: Keep");
      expect(projectedSnapshot(trace.observed), "the pending select the client was shown").toEqual(EXPECTED["run-extension-ui"]!.extra.observed);
    }, pending as unknown as TraceValue);
  });
});


/** What each run lock expects (`test-support/lock-projections.ts`), generated from its former golden. */
const EXPECTED: Record<string, SessionLockExpectation & { extra: Record<string, unknown> }> = {
  "run-prompt-stream": {
    "exchanges": [
      {
        "method": "session.create",
        "params": {
          "commandId": "lock-command-0001",
          "cwd": "<tmp>/workspace"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "sessionId": "<present>"
          }
        }
      },
      {
        "method": "session.open",
        "params": {
          "sessionId": "<present>"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "completionRevision": 0,
            "session": {
              "acceptsQueuedPrompts": false,
              "automaticCompactionEnabled": false,
              "availableThinkingLevels": [
                "off"
              ],
              "compactionPolicy": {
                "currentBudgets": {
                  "enabled": false,
                  "keepRecentTokens": 120,
                  "reserveTokens": 2048
                },
                "extensionMayOverride": false,
                "next": {
                  "effectiveThinkingLevel": "off",
                  "enabled": false,
                  "instructions": "",
                  "keepRecentTokens": 120,
                  "model": {
                    "id": "<present>",
                    "provider": "<LOCK>"
                  },
                  "requestedThinkingLevel": "off",
                  "reserveTokens": 2048,
                  "source": {
                    "enabled": "global",
                    "instructions": "global",
                    "keepRecentTokens": "global",
                    "reserveTokens": "global",
                    "thinkingLevel": "global"
                  },
                  "thinkingLevel": "inherit"
                }
              },
              "compactionQueued": false,
              "configurationBlocker": null,
              "contextUsage": {
                "contextWindow": "<value>",
                "percent": "<value>",
                "tokens": "<value>"
              },
              "contextWindowPolicy": {
                "default": 128000,
                "effective": 128000,
                "maximum": 128000,
                "minimum": 3192,
                "model": {
                  "id": "<present>",
                  "provider": "<LOCK>"
                },
                "override": 128000,
                "source": "session",
                "warning": "This new session and its context override are not yet saved to disk; they persist after the first user or assistant message."
              },
              "cwd": "<tmp>/workspace",
              "diagnostics": [],
              "eventSequence": "<present>",
              "extensionActivityAsOf": "<present>",
              "extensionPresentation": {
                "capabilities": [
                  "semantic.dialogs",
                  "tron.form.v1",
                  "semantic.notifications",
                  "semantic.status",
                  "semantic.working",
                  "semantic.hidden-thinking-label",
                  "semantic.string-widgets",
                  "semantic.title",
                  "semantic.revisioned-editor",
                  "semantic.tools-expanded",
                  "surfaces.full-frame"
                ],
                "diagnostics": [
                  {
                    "code": "remote-components.enabled",
                    "message": "Retained string widgets and bounded read-only component frames are presented through the general extension-content sheet; blocking custom and overlay UI remain deferred."
                  },
                  {
                    "code": "remote-components.overlay-deferred",
                    "message": "Overlay and interactive component UI remain deferred until native rendering and input leases are available."
                  },
                  {
                    "code": "theme.baseline-only",
                    "message": "Per-session process-global Pi theme synchronization is unavailable through the pinned public API."
                  }
                ],
                "hostEpoch": "<present>",
                "pendingInteractions": [],
                "revision": "<present>",
                "semanticState": {
                  "editorRevision": 0,
                  "editorText": "",
                  "statusOwners": {},
                  "statuses": {},
                  "toolsExpanded": false,
                  "widgets": [],
                  "working": {
                    "indicator": {
                      "frames": [],
                      "kind": "default"
                    },
                    "visible": true
                  }
                },
                "surfaces": [],
                "version": 3
              },
              "leafEntryId": "<present>",
              "liveActivityRevision": 0,
              "model": {
                "id": "<present>",
                "provider": "<LOCK>"
              },
              "phase": "idle",
              "processOverview": {
                "activeCount": 0,
                "asOf": "<present>",
                "problemCount": 0,
                "recentCount": 0,
                "revision": "<present>",
                "version": 1,
                "visibility": "hidden"
              },
              "queueRevision": 0,
              "queuedItems": [],
              "revision": "<present>",
              "runtimeGeneration": "<present>",
              "sessionId": "<present>",
              "stats": {
                "assistantMessages": "<value>",
                "cost": "<value>",
                "tokens": {
                  "cacheRead": "<value>",
                  "cacheWrite": "<value>",
                  "input": "<value>",
                  "output": "<value>",
                  "total": "<value>"
                },
                "toolCalls": "<value>",
                "toolResults": "<value>",
                "totalMessages": "<value>",
                "userMessages": "<value>"
              },
              "thinkingLevel": "off",
              "toolExecutions": [],
              "transcript": [
                {
                  "id": "<present>",
                  "kind": "modelChange",
                  "modelRef": {
                    "id": "<present>",
                    "provider": "<LOCK>"
                  },
                  "parentId": "<present>",
                  "semantic": {
                    "contextEffect": "none",
                    "delivery": "stored",
                    "direction": "ambientStatus",
                    "kind": "status",
                    "origin": {
                      "confidence": "boundary",
                      "kind": "gateway"
                    },
                    "sequence": "<present>",
                    "version": 1,
                    "visibility": "visible"
                  },
                  "timestamp": "<present>"
                },
                {
                  "id": "<present>",
                  "kind": "thinkingChange",
                  "level": "off",
                  "parentId": "<present>",
                  "semantic": {
                    "contextEffect": "none",
                    "delivery": "stored",
                    "direction": "ambientStatus",
                    "kind": "status",
                    "origin": {
                      "confidence": "boundary",
                      "kind": "gateway"
                    },
                    "sequence": "<present>",
                    "version": 1,
                    "visibility": "visible"
                  },
                  "timestamp": "<present>"
                }
              ],
              "transcriptStart": 0,
              "transcriptTotal": 2
            },
            "subscriptionToken": "<present>",
            "syncToken": "<present>"
          }
        }
      },
      {
        "method": "session.sync",
        "params": {
          "sessionId": "<present>",
          "syncToken": "<present>"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "synchronized": true
          }
        }
      },
      {
        "method": "session.prompt",
        "params": {
          "commandId": "lock-command-0002",
          "sessionId": "<present>",
          "text": "read the notes"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "operationId": "<present>"
          }
        }
      }
    ],
    "items": [
      {
        "id": "<present>",
        "kind": "modelChange",
        "modelRef": {
          "id": "<present>",
          "provider": "<LOCK>"
        },
        "parentId": "<present>",
        "semantic": {
          "contextEffect": "none",
          "delivery": "stored",
          "direction": "ambientStatus",
          "kind": "status",
          "origin": {
            "confidence": "boundary",
            "kind": "gateway"
          },
          "sequence": "<present>",
          "version": 1,
          "visibility": "visible"
        },
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "kind": "thinkingChange",
        "level": "off",
        "parentId": "<present>",
        "semantic": {
          "contextEffect": "none",
          "delivery": "stored",
          "direction": "ambientStatus",
          "kind": "status",
          "origin": {
            "confidence": "boundary",
            "kind": "gateway"
          },
          "sequence": "<present>",
          "version": 1,
          "visibility": "visible"
        },
        "timestamp": "<present>"
      },
      {
        "content": [
          {
            "id": "<present>",
            "ordinal": 0,
            "text": "read the notes",
            "type": "text"
          }
        ],
        "id": "<present>",
        "kind": "message",
        "parentId": "<present>",
        "presentationId": "<present>",
        "role": "user",
        "semantic": {
          "contextEffect": "modelInput",
          "delivery": "stored",
          "direction": "inboundContext",
          "invocationId": "<present>",
          "kind": "resourcePrompt",
          "lifecycle": "completed",
          "operationId": "<present>",
          "origin": {
            "confidence": "boundary",
            "kind": "user"
          },
          "sequence": "<present>",
          "version": 1,
          "visibility": "visible"
        },
        "timestamp": "<present>"
      },
      {
        "content": [
          {
            "id": "<present>",
            "ordinal": 0,
            "text": "Reading the lock notes.",
            "thinkingRunOrdinal": 0,
            "type": "thinking"
          },
          {
            "id": "<present>",
            "ordinal": 1,
            "text": "Reading notes.",
            "type": "text"
          },
          {
            "arguments": {
              "path": "notes.txt"
            },
            "groupCount": 1,
            "groupFinalized": true,
            "groupId": "<present>",
            "groupIndex": 0,
            "id": "<present>",
            "name": "read",
            "ordinal": 2,
            "toolCallId": "<present>",
            "toolSegmentId": "<present>",
            "type": "toolCall"
          }
        ],
        "id": "<present>",
        "kind": "message",
        "modelId": "faux-1",
        "parentId": "<present>",
        "presentationId": "<present>",
        "provider": "<LOCK>",
        "role": "assistant",
        "semantic": {
          "contextEffect": "modelInput",
          "delivery": "stored",
          "direction": "agentOutput",
          "kind": "prompt",
          "origin": {
            "confidence": "boundary",
            "kind": "assistant"
          },
          "sequence": "<present>",
          "version": 1,
          "visibility": "visible"
        },
        "stopReason": "toolUse",
        "thinkingLevel": "off",
        "timestamp": "<present>",
        "usage": "<present>"
      },
      {
        "completedAt": "<present>",
        "content": [
          {
            "id": "<present>",
            "ordinal": 0,
            "text": "lock notes\n",
            "type": "text"
          }
        ],
        "durationMs": "<present>",
        "groupCount": 1,
        "groupFinalized": true,
        "groupId": "<present>",
        "groupIndex": 0,
        "id": "<present>",
        "isError": false,
        "kind": "message",
        "lastProgressAt": "<present>",
        "parentId": "<present>",
        "presentationId": "<present>",
        "progressSequence": "<present>",
        "role": "toolResult",
        "semantic": {
          "contextEffect": "toolResult",
          "delivery": "toolResult",
          "direction": "agentInvocation",
          "kind": "tool",
          "origin": {
            "confidence": "boundary",
            "kind": "assistant"
          },
          "sequence": "<present>",
          "version": 1,
          "visibility": "visible"
        },
        "startedAt": "<present>",
        "timestamp": "<present>",
        "toolCallId": "<present>",
        "toolName": "read",
        "toolSegmentId": "<present>"
      },
      {
        "content": [
          {
            "id": "<present>",
            "ordinal": 0,
            "text": "The notes say: lock notes.",
            "type": "text"
          }
        ],
        "id": "<present>",
        "kind": "message",
        "modelId": "faux-1",
        "parentId": "<present>",
        "presentationId": "<present>",
        "provider": "<LOCK>",
        "role": "assistant",
        "semantic": {
          "contextEffect": "modelInput",
          "delivery": "stored",
          "direction": "agentOutput",
          "kind": "prompt",
          "origin": {
            "confidence": "boundary",
            "kind": "assistant"
          },
          "sequence": "<present>",
          "version": 1,
          "visibility": "visible"
        },
        "stopReason": "stop",
        "thinkingLevel": "off",
        "timestamp": "<present>",
        "usage": "<present>"
      }
    ],
    "window": {
      "end": 6,
      "leafEntryId": "<present>",
      "runtimeGeneration": "<present>",
      "start": 0,
      "total": 6
    },
    "messages": [
      {
        "content": [
          {
            "text": "read the notes",
            "type": "text"
          }
        ],
        "role": "user",
        "timestamp": "<present>"
      },
      {
        "api": "<present>",
        "content": [
          {
            "thinking": "Reading the lock notes.",
            "type": "thinking"
          },
          {
            "text": "Reading notes.",
            "type": "text"
          },
          {
            "arguments": {
              "path": "notes.txt"
            },
            "id": "<present>",
            "name": "read",
            "type": "toolCall"
          }
        ],
        "durationMs": "<present>",
        "model": "faux-1",
        "provider": "<LOCK>",
        "role": "assistant",
        "stopReason": "toolUse",
        "thinkingLevel": "off",
        "timestamp": "<present>",
        "usage": "<present>"
      },
      {
        "content": [
          {
            "text": "lock notes\n",
            "type": "text"
          }
        ],
        "durationMs": "<present>",
        "isError": false,
        "role": "toolResult",
        "timestamp": "<present>",
        "toolCallId": "<present>",
        "toolName": "read"
      },
      {
        "api": "<present>",
        "content": [
          {
            "text": "The notes say: lock notes.",
            "type": "text"
          }
        ],
        "durationMs": "<present>",
        "model": "faux-1",
        "provider": "<LOCK>",
        "role": "assistant",
        "stopReason": "stop",
        "thinkingLevel": "off",
        "timestamp": "<present>",
        "usage": "<present>"
      }
    ],
    "types": [
      "session",
      "model_change",
      "thinking_level_change",
      "custom:tron.context-window.v1",
      "custom:tron.settings.v1",
      "custom:tron.settings.v1",
      "custom:tron.chat-invocation.v1",
      "custom:tron.chat-invocation.v1",
      "message:system",
      "message:user",
      "custom:tron.chat-invocation.v1",
      "message:assistant",
      "message:toolResult",
      "message:assistant",
      "custom:tron.chat-invocation.v1"
    ],
    "receipts": [
      {
        "receiptKind": "start",
        "lifecycle": "staged",
        "source": "plain"
      },
      {
        "receiptKind": "transition",
        "lifecycle": "accepted",
        "source": "plain"
      },
      {
        "receiptKind": "binding",
        "source": "plain"
      },
      {
        "receiptKind": "terminal",
        "lifecycle": "completed",
        "source": "plain"
      }
    ],
    "envelopes": [
      {
        "id": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      }
    ],
    "sessionEntries": [
      {
        "cwd": "<tmp>/workspace",
        "id": "<present>",
        "timestamp": "<present>",
        "type": "session",
        "version": 3
      },
      {
        "id": "<present>",
        "modelId": "faux-1",
        "parentId": "<present>",
        "provider": "<LOCK>",
        "timestamp": "<present>",
        "type": "model_change"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "thinkingLevel": "off",
        "timestamp": "<present>",
        "type": "thinking_level_change"
      }
    ],
    "providers": [
      [
        {
          "role": "user",
          "text": "read the notes"
        }
      ],
      [
        {
          "role": "user",
          "text": "read the notes"
        },
        {
          "role": "assistant",
          "text": "Reading notes.",
          "toolCalls": [
            "read"
          ]
        },
        {
          "role": "toolResult",
          "text": "lock notes\n",
          "toolName": "read"
        }
      ]
    ],
    "extra": {}
  },
  "run-steer": {
    "exchanges": [
      {
        "method": "session.create",
        "params": {
          "commandId": "lock-command-0001",
          "cwd": "<tmp>/workspace"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "sessionId": "<present>"
          }
        }
      },
      {
        "method": "session.open",
        "params": {
          "sessionId": "<present>"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "completionRevision": 0,
            "session": {
              "acceptsQueuedPrompts": false,
              "automaticCompactionEnabled": false,
              "availableThinkingLevels": [
                "off"
              ],
              "compactionPolicy": {
                "currentBudgets": {
                  "enabled": false,
                  "keepRecentTokens": 120,
                  "reserveTokens": 2048
                },
                "extensionMayOverride": false,
                "next": {
                  "effectiveThinkingLevel": "off",
                  "enabled": false,
                  "instructions": "",
                  "keepRecentTokens": 120,
                  "model": {
                    "id": "<present>",
                    "provider": "<LOCK>"
                  },
                  "requestedThinkingLevel": "off",
                  "reserveTokens": 2048,
                  "source": {
                    "enabled": "global",
                    "instructions": "global",
                    "keepRecentTokens": "global",
                    "reserveTokens": "global",
                    "thinkingLevel": "global"
                  },
                  "thinkingLevel": "inherit"
                }
              },
              "compactionQueued": false,
              "configurationBlocker": null,
              "contextUsage": {
                "contextWindow": "<value>",
                "percent": "<value>",
                "tokens": "<value>"
              },
              "contextWindowPolicy": {
                "default": 128000,
                "effective": 128000,
                "maximum": 128000,
                "minimum": 3192,
                "model": {
                  "id": "<present>",
                  "provider": "<LOCK>"
                },
                "override": 128000,
                "source": "session",
                "warning": "This new session and its context override are not yet saved to disk; they persist after the first user or assistant message."
              },
              "cwd": "<tmp>/workspace",
              "diagnostics": [],
              "eventSequence": "<present>",
              "extensionActivityAsOf": "<present>",
              "extensionPresentation": {
                "capabilities": [
                  "semantic.dialogs",
                  "tron.form.v1",
                  "semantic.notifications",
                  "semantic.status",
                  "semantic.working",
                  "semantic.hidden-thinking-label",
                  "semantic.string-widgets",
                  "semantic.title",
                  "semantic.revisioned-editor",
                  "semantic.tools-expanded",
                  "surfaces.full-frame"
                ],
                "diagnostics": [
                  {
                    "code": "remote-components.enabled",
                    "message": "Retained string widgets and bounded read-only component frames are presented through the general extension-content sheet; blocking custom and overlay UI remain deferred."
                  },
                  {
                    "code": "remote-components.overlay-deferred",
                    "message": "Overlay and interactive component UI remain deferred until native rendering and input leases are available."
                  },
                  {
                    "code": "theme.baseline-only",
                    "message": "Per-session process-global Pi theme synchronization is unavailable through the pinned public API."
                  }
                ],
                "hostEpoch": "<present>",
                "pendingInteractions": [],
                "revision": "<present>",
                "semanticState": {
                  "editorRevision": 0,
                  "editorText": "",
                  "statusOwners": {},
                  "statuses": {},
                  "toolsExpanded": false,
                  "widgets": [],
                  "working": {
                    "indicator": {
                      "frames": [],
                      "kind": "default"
                    },
                    "visible": true
                  }
                },
                "surfaces": [],
                "version": 3
              },
              "leafEntryId": "<present>",
              "liveActivityRevision": 0,
              "model": {
                "id": "<present>",
                "provider": "<LOCK>"
              },
              "phase": "idle",
              "processOverview": {
                "activeCount": 0,
                "asOf": "<present>",
                "problemCount": 0,
                "recentCount": 0,
                "revision": "<present>",
                "version": 1,
                "visibility": "hidden"
              },
              "queueRevision": 0,
              "queuedItems": [],
              "revision": "<present>",
              "runtimeGeneration": "<present>",
              "sessionId": "<present>",
              "stats": {
                "assistantMessages": "<value>",
                "cost": "<value>",
                "tokens": {
                  "cacheRead": "<value>",
                  "cacheWrite": "<value>",
                  "input": "<value>",
                  "output": "<value>",
                  "total": "<value>"
                },
                "toolCalls": "<value>",
                "toolResults": "<value>",
                "totalMessages": "<value>",
                "userMessages": "<value>"
              },
              "thinkingLevel": "off",
              "toolExecutions": [],
              "transcript": [
                {
                  "id": "<present>",
                  "kind": "modelChange",
                  "modelRef": {
                    "id": "<present>",
                    "provider": "<LOCK>"
                  },
                  "parentId": "<present>",
                  "semantic": {
                    "contextEffect": "none",
                    "delivery": "stored",
                    "direction": "ambientStatus",
                    "kind": "status",
                    "origin": {
                      "confidence": "boundary",
                      "kind": "gateway"
                    },
                    "sequence": "<present>",
                    "version": 1,
                    "visibility": "visible"
                  },
                  "timestamp": "<present>"
                },
                {
                  "id": "<present>",
                  "kind": "thinkingChange",
                  "level": "off",
                  "parentId": "<present>",
                  "semantic": {
                    "contextEffect": "none",
                    "delivery": "stored",
                    "direction": "ambientStatus",
                    "kind": "status",
                    "origin": {
                      "confidence": "boundary",
                      "kind": "gateway"
                    },
                    "sequence": "<present>",
                    "version": 1,
                    "visibility": "visible"
                  },
                  "timestamp": "<present>"
                }
              ],
              "transcriptStart": 0,
              "transcriptTotal": 2
            },
            "subscriptionToken": "<present>",
            "syncToken": "<present>"
          }
        }
      },
      {
        "method": "session.sync",
        "params": {
          "sessionId": "<present>",
          "syncToken": "<present>"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "synchronized": true
          }
        }
      },
      {
        "method": "session.prompt",
        "params": {
          "commandId": "lock-command-0002",
          "sessionId": "<present>",
          "text": "hold a turn open"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "operationId": "<present>"
          }
        }
      },
      {
        "method": "session.prompt",
        "params": {
          "behavior": "steer",
          "commandId": "lock-command-0003",
          "sessionId": "<present>",
          "text": "steer the run"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "operationId": "<present>"
          }
        }
      },
      {
        "method": "session.prompt",
        "params": {
          "behavior": "followUp",
          "commandId": "lock-command-0004",
          "sessionId": "<present>",
          "text": "then follow up"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "operationId": "<present>"
          }
        }
      }
    ],
    "items": [
      {
        "id": "<present>",
        "kind": "modelChange",
        "modelRef": {
          "id": "<present>",
          "provider": "<LOCK>"
        },
        "parentId": "<present>",
        "semantic": {
          "contextEffect": "none",
          "delivery": "stored",
          "direction": "ambientStatus",
          "kind": "status",
          "origin": {
            "confidence": "boundary",
            "kind": "gateway"
          },
          "sequence": "<present>",
          "version": 1,
          "visibility": "visible"
        },
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "kind": "thinkingChange",
        "level": "off",
        "parentId": "<present>",
        "semantic": {
          "contextEffect": "none",
          "delivery": "stored",
          "direction": "ambientStatus",
          "kind": "status",
          "origin": {
            "confidence": "boundary",
            "kind": "gateway"
          },
          "sequence": "<present>",
          "version": 1,
          "visibility": "visible"
        },
        "timestamp": "<present>"
      },
      {
        "content": [
          {
            "id": "<present>",
            "ordinal": 0,
            "text": "hold a turn open",
            "type": "text"
          }
        ],
        "id": "<present>",
        "kind": "message",
        "parentId": "<present>",
        "presentationId": "<present>",
        "role": "user",
        "semantic": {
          "contextEffect": "modelInput",
          "delivery": "stored",
          "direction": "inboundContext",
          "invocationId": "<present>",
          "kind": "resourcePrompt",
          "lifecycle": "completed",
          "operationId": "<present>",
          "origin": {
            "confidence": "boundary",
            "kind": "user"
          },
          "sequence": "<present>",
          "version": 1,
          "visibility": "visible"
        },
        "timestamp": "<present>"
      },
      {
        "content": [
          {
            "arguments": {
              "path": "notes.txt"
            },
            "groupCount": 1,
            "groupFinalized": true,
            "groupId": "<present>",
            "groupIndex": 0,
            "id": "<present>",
            "name": "read",
            "ordinal": 0,
            "toolCallId": "<present>",
            "toolSegmentId": "<present>",
            "type": "toolCall"
          }
        ],
        "id": "<present>",
        "kind": "message",
        "modelId": "faux-1",
        "parentId": "<present>",
        "presentationId": "<present>",
        "provider": "<LOCK>",
        "role": "assistant",
        "semantic": {
          "contextEffect": "modelInput",
          "delivery": "stored",
          "direction": "agentOutput",
          "kind": "prompt",
          "origin": {
            "confidence": "boundary",
            "kind": "assistant"
          },
          "sequence": "<present>",
          "version": 1,
          "visibility": "visible"
        },
        "stopReason": "toolUse",
        "thinkingLevel": "off",
        "timestamp": "<present>",
        "usage": "<present>"
      },
      {
        "completedAt": "<present>",
        "content": [
          {
            "id": "<present>",
            "ordinal": 0,
            "text": "lock notes\n",
            "type": "text"
          }
        ],
        "durationMs": "<present>",
        "groupCount": 1,
        "groupFinalized": true,
        "groupId": "<present>",
        "groupIndex": 0,
        "id": "<present>",
        "isError": false,
        "kind": "message",
        "lastProgressAt": "<present>",
        "parentId": "<present>",
        "presentationId": "<present>",
        "progressSequence": "<present>",
        "role": "toolResult",
        "semantic": {
          "contextEffect": "toolResult",
          "delivery": "toolResult",
          "direction": "agentInvocation",
          "kind": "tool",
          "origin": {
            "confidence": "boundary",
            "kind": "assistant"
          },
          "sequence": "<present>",
          "version": 1,
          "visibility": "visible"
        },
        "startedAt": "<present>",
        "timestamp": "<present>",
        "toolCallId": "<present>",
        "toolName": "read",
        "toolSegmentId": "<present>"
      },
      {
        "content": [
          {
            "id": "<present>",
            "ordinal": 0,
            "text": "steer the run",
            "type": "text"
          }
        ],
        "id": "<present>",
        "kind": "message",
        "parentId": "<present>",
        "presentationId": "<present>",
        "role": "user",
        "semantic": {
          "contextEffect": "modelInput",
          "delivery": "stored",
          "direction": "inboundContext",
          "invocationId": "<present>",
          "kind": "resourcePrompt",
          "lifecycle": "completed",
          "operationId": "<present>",
          "origin": {
            "confidence": "boundary",
            "kind": "user"
          },
          "sequence": "<present>",
          "version": 1,
          "visibility": "visible"
        },
        "timestamp": "<present>"
      },
      {
        "content": [
          {
            "id": "<present>",
            "ordinal": 0,
            "text": "Steered work acknowledged.",
            "type": "text"
          }
        ],
        "id": "<present>",
        "kind": "message",
        "modelId": "faux-1",
        "parentId": "<present>",
        "presentationId": "<present>",
        "provider": "<LOCK>",
        "role": "assistant",
        "semantic": {
          "contextEffect": "modelInput",
          "delivery": "stored",
          "direction": "agentOutput",
          "kind": "prompt",
          "origin": {
            "confidence": "boundary",
            "kind": "assistant"
          },
          "sequence": "<present>",
          "version": 1,
          "visibility": "visible"
        },
        "stopReason": "stop",
        "thinkingLevel": "off",
        "timestamp": "<present>",
        "usage": "<present>"
      },
      {
        "content": [
          {
            "id": "<present>",
            "ordinal": 0,
            "text": "then follow up",
            "type": "text"
          }
        ],
        "id": "<present>",
        "kind": "message",
        "parentId": "<present>",
        "presentationId": "<present>",
        "role": "user",
        "semantic": {
          "contextEffect": "modelInput",
          "delivery": "stored",
          "direction": "inboundContext",
          "invocationId": "<present>",
          "kind": "resourcePrompt",
          "lifecycle": "completed",
          "operationId": "<present>",
          "origin": {
            "confidence": "boundary",
            "kind": "user"
          },
          "sequence": "<present>",
          "version": 1,
          "visibility": "visible"
        },
        "timestamp": "<present>"
      },
      {
        "content": [
          {
            "id": "<present>",
            "ordinal": 0,
            "text": "Follow-up work acknowledged.",
            "type": "text"
          }
        ],
        "id": "<present>",
        "kind": "message",
        "modelId": "faux-1",
        "parentId": "<present>",
        "presentationId": "<present>",
        "provider": "<LOCK>",
        "role": "assistant",
        "semantic": {
          "contextEffect": "modelInput",
          "delivery": "stored",
          "direction": "agentOutput",
          "kind": "prompt",
          "origin": {
            "confidence": "boundary",
            "kind": "assistant"
          },
          "sequence": "<present>",
          "version": 1,
          "visibility": "visible"
        },
        "stopReason": "stop",
        "thinkingLevel": "off",
        "timestamp": "<present>",
        "usage": "<present>"
      }
    ],
    "window": {
      "end": 9,
      "leafEntryId": "<present>",
      "runtimeGeneration": "<present>",
      "start": 0,
      "total": 9
    },
    "messages": [
      {
        "content": [
          {
            "text": "hold a turn open",
            "type": "text"
          }
        ],
        "role": "user",
        "timestamp": "<present>"
      },
      {
        "api": "<present>",
        "content": [
          {
            "arguments": {
              "path": "notes.txt"
            },
            "id": "<present>",
            "name": "read",
            "type": "toolCall"
          }
        ],
        "durationMs": "<present>",
        "model": "faux-1",
        "provider": "<LOCK>",
        "role": "assistant",
        "stopReason": "toolUse",
        "thinkingLevel": "off",
        "timestamp": "<present>",
        "usage": "<present>"
      },
      {
        "content": [
          {
            "text": "lock notes\n",
            "type": "text"
          }
        ],
        "durationMs": "<present>",
        "isError": false,
        "role": "toolResult",
        "timestamp": "<present>",
        "toolCallId": "<present>",
        "toolName": "read"
      },
      {
        "content": [
          {
            "text": "steer the run",
            "type": "text"
          }
        ],
        "role": "user",
        "timestamp": "<present>"
      },
      {
        "api": "<present>",
        "content": [
          {
            "text": "Steered work acknowledged.",
            "type": "text"
          }
        ],
        "durationMs": "<present>",
        "model": "faux-1",
        "provider": "<LOCK>",
        "role": "assistant",
        "stopReason": "stop",
        "thinkingLevel": "off",
        "timestamp": "<present>",
        "usage": "<present>"
      },
      {
        "content": [
          {
            "text": "then follow up",
            "type": "text"
          }
        ],
        "role": "user",
        "timestamp": "<present>"
      },
      {
        "api": "<present>",
        "content": [
          {
            "text": "Follow-up work acknowledged.",
            "type": "text"
          }
        ],
        "durationMs": "<present>",
        "model": "faux-1",
        "provider": "<LOCK>",
        "role": "assistant",
        "stopReason": "stop",
        "thinkingLevel": "off",
        "timestamp": "<present>",
        "usage": "<present>"
      }
    ],
    "types": [
      "session",
      "model_change",
      "thinking_level_change",
      "custom:tron.context-window.v1",
      "custom:tron.settings.v1",
      "custom:tron.settings.v1",
      "custom:tron.chat-invocation.v1",
      "custom:tron.chat-invocation.v1",
      "message:system",
      "message:user",
      "custom:tron.chat-invocation.v1",
      "custom:tron.chat-invocation.v1",
      "custom:tron.chat-invocation.v1",
      "custom:tron.chat-invocation.v1",
      "custom:tron.chat-invocation.v1",
      "message:assistant",
      "message:toolResult",
      "message:user",
      "custom:tron.chat-invocation.v1",
      "custom:tron.chat-invocation.v1",
      "message:assistant",
      "custom:tron.chat-invocation.v1",
      "message:user",
      "custom:tron.chat-invocation.v1",
      "message:assistant",
      "custom:tron.chat-invocation.v1"
    ],
    "receipts": [
      {
        "receiptKind": "start",
        "lifecycle": "staged",
        "source": "plain"
      },
      {
        "receiptKind": "transition",
        "lifecycle": "accepted",
        "source": "plain"
      },
      {
        "receiptKind": "binding",
        "source": "plain"
      },
      {
        "receiptKind": "start",
        "lifecycle": "staged",
        "source": "plain"
      },
      {
        "receiptKind": "transition",
        "lifecycle": "accepted",
        "source": "plain"
      },
      {
        "receiptKind": "start",
        "lifecycle": "staged",
        "source": "plain"
      },
      {
        "receiptKind": "transition",
        "lifecycle": "accepted",
        "source": "plain"
      },
      {
        "receiptKind": "binding",
        "source": "plain"
      },
      {
        "receiptKind": "terminal",
        "lifecycle": "completed",
        "source": "plain"
      },
      {
        "receiptKind": "terminal",
        "lifecycle": "completed",
        "source": "plain"
      },
      {
        "receiptKind": "binding",
        "source": "plain"
      },
      {
        "receiptKind": "terminal",
        "lifecycle": "completed",
        "source": "plain"
      }
    ],
    "envelopes": [
      {
        "id": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      }
    ],
    "sessionEntries": [
      {
        "cwd": "<tmp>/workspace",
        "id": "<present>",
        "timestamp": "<present>",
        "type": "session",
        "version": 3
      },
      {
        "id": "<present>",
        "modelId": "faux-1",
        "parentId": "<present>",
        "provider": "<LOCK>",
        "timestamp": "<present>",
        "type": "model_change"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "thinkingLevel": "off",
        "timestamp": "<present>",
        "type": "thinking_level_change"
      }
    ],
    "providers": [
      [
        {
          "role": "user",
          "text": "hold a turn open"
        }
      ],
      [
        {
          "role": "user",
          "text": "hold a turn open"
        },
        {
          "role": "assistant",
          "text": "",
          "toolCalls": [
            "read"
          ]
        },
        {
          "role": "toolResult",
          "text": "lock notes\n",
          "toolName": "read"
        },
        {
          "role": "user",
          "text": "steer the run"
        }
      ],
      [
        {
          "role": "user",
          "text": "hold a turn open"
        },
        {
          "role": "assistant",
          "text": "",
          "toolCalls": [
            "read"
          ]
        },
        {
          "role": "toolResult",
          "text": "lock notes\n",
          "toolName": "read"
        },
        {
          "role": "user",
          "text": "steer the run"
        },
        {
          "role": "assistant",
          "text": "Steered work acknowledged."
        },
        {
          "role": "user",
          "text": "then follow up"
        }
      ]
    ],
    "extra": {}
  },
  "run-abort": {
    "exchanges": [
      {
        "method": "session.create",
        "params": {
          "commandId": "lock-command-0001",
          "cwd": "<tmp>/workspace"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "sessionId": "<present>"
          }
        }
      },
      {
        "method": "session.open",
        "params": {
          "sessionId": "<present>"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "completionRevision": 0,
            "session": {
              "acceptsQueuedPrompts": false,
              "automaticCompactionEnabled": false,
              "availableThinkingLevels": [
                "off"
              ],
              "compactionPolicy": {
                "currentBudgets": {
                  "enabled": false,
                  "keepRecentTokens": 120,
                  "reserveTokens": 2048
                },
                "extensionMayOverride": false,
                "next": {
                  "effectiveThinkingLevel": "off",
                  "enabled": false,
                  "instructions": "",
                  "keepRecentTokens": 120,
                  "model": {
                    "id": "<present>",
                    "provider": "<LOCK>"
                  },
                  "requestedThinkingLevel": "off",
                  "reserveTokens": 2048,
                  "source": {
                    "enabled": "global",
                    "instructions": "global",
                    "keepRecentTokens": "global",
                    "reserveTokens": "global",
                    "thinkingLevel": "global"
                  },
                  "thinkingLevel": "inherit"
                }
              },
              "compactionQueued": false,
              "configurationBlocker": null,
              "contextUsage": {
                "contextWindow": "<value>",
                "percent": "<value>",
                "tokens": "<value>"
              },
              "contextWindowPolicy": {
                "default": 128000,
                "effective": 128000,
                "maximum": 128000,
                "minimum": 3192,
                "model": {
                  "id": "<present>",
                  "provider": "<LOCK>"
                },
                "override": 128000,
                "source": "session",
                "warning": "This new session and its context override are not yet saved to disk; they persist after the first user or assistant message."
              },
              "cwd": "<tmp>/workspace",
              "diagnostics": [],
              "eventSequence": "<present>",
              "extensionActivityAsOf": "<present>",
              "extensionPresentation": {
                "capabilities": [
                  "semantic.dialogs",
                  "tron.form.v1",
                  "semantic.notifications",
                  "semantic.status",
                  "semantic.working",
                  "semantic.hidden-thinking-label",
                  "semantic.string-widgets",
                  "semantic.title",
                  "semantic.revisioned-editor",
                  "semantic.tools-expanded",
                  "surfaces.full-frame"
                ],
                "diagnostics": [
                  {
                    "code": "remote-components.enabled",
                    "message": "Retained string widgets and bounded read-only component frames are presented through the general extension-content sheet; blocking custom and overlay UI remain deferred."
                  },
                  {
                    "code": "remote-components.overlay-deferred",
                    "message": "Overlay and interactive component UI remain deferred until native rendering and input leases are available."
                  },
                  {
                    "code": "theme.baseline-only",
                    "message": "Per-session process-global Pi theme synchronization is unavailable through the pinned public API."
                  }
                ],
                "hostEpoch": "<present>",
                "pendingInteractions": [],
                "revision": "<present>",
                "semanticState": {
                  "editorRevision": 0,
                  "editorText": "",
                  "statusOwners": {},
                  "statuses": {},
                  "toolsExpanded": false,
                  "widgets": [],
                  "working": {
                    "indicator": {
                      "frames": [],
                      "kind": "default"
                    },
                    "visible": true
                  }
                },
                "surfaces": [],
                "version": 3
              },
              "leafEntryId": "<present>",
              "liveActivityRevision": 0,
              "model": {
                "id": "<present>",
                "provider": "<LOCK>"
              },
              "phase": "idle",
              "processOverview": {
                "activeCount": 0,
                "asOf": "<present>",
                "problemCount": 0,
                "recentCount": 0,
                "revision": "<present>",
                "version": 1,
                "visibility": "hidden"
              },
              "queueRevision": 0,
              "queuedItems": [],
              "revision": "<present>",
              "runtimeGeneration": "<present>",
              "sessionId": "<present>",
              "stats": {
                "assistantMessages": "<value>",
                "cost": "<value>",
                "tokens": {
                  "cacheRead": "<value>",
                  "cacheWrite": "<value>",
                  "input": "<value>",
                  "output": "<value>",
                  "total": "<value>"
                },
                "toolCalls": "<value>",
                "toolResults": "<value>",
                "totalMessages": "<value>",
                "userMessages": "<value>"
              },
              "thinkingLevel": "off",
              "toolExecutions": [],
              "transcript": [
                {
                  "id": "<present>",
                  "kind": "modelChange",
                  "modelRef": {
                    "id": "<present>",
                    "provider": "<LOCK>"
                  },
                  "parentId": "<present>",
                  "semantic": {
                    "contextEffect": "none",
                    "delivery": "stored",
                    "direction": "ambientStatus",
                    "kind": "status",
                    "origin": {
                      "confidence": "boundary",
                      "kind": "gateway"
                    },
                    "sequence": "<present>",
                    "version": 1,
                    "visibility": "visible"
                  },
                  "timestamp": "<present>"
                },
                {
                  "id": "<present>",
                  "kind": "thinkingChange",
                  "level": "off",
                  "parentId": "<present>",
                  "semantic": {
                    "contextEffect": "none",
                    "delivery": "stored",
                    "direction": "ambientStatus",
                    "kind": "status",
                    "origin": {
                      "confidence": "boundary",
                      "kind": "gateway"
                    },
                    "sequence": "<present>",
                    "version": 1,
                    "visibility": "visible"
                  },
                  "timestamp": "<present>"
                }
              ],
              "transcriptStart": 0,
              "transcriptTotal": 2
            },
            "subscriptionToken": "<present>",
            "syncToken": "<present>"
          }
        }
      },
      {
        "method": "session.sync",
        "params": {
          "sessionId": "<present>",
          "syncToken": "<present>"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "synchronized": true
          }
        }
      },
      {
        "method": "session.prompt",
        "params": {
          "commandId": "lock-command-0002",
          "sessionId": "<present>",
          "text": "start a turn to abort"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "operationId": "<present>"
          }
        }
      },
      {
        "method": "session.abort",
        "params": {
          "commandId": "lock-command-0003",
          "operationId": "<present>",
          "sessionId": "<present>"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "aborted": true
          }
        }
      }
    ],
    "items": [
      {
        "id": "<present>",
        "kind": "modelChange",
        "modelRef": {
          "id": "<present>",
          "provider": "<LOCK>"
        },
        "parentId": "<present>",
        "semantic": {
          "contextEffect": "none",
          "delivery": "stored",
          "direction": "ambientStatus",
          "kind": "status",
          "origin": {
            "confidence": "boundary",
            "kind": "gateway"
          },
          "sequence": "<present>",
          "version": 1,
          "visibility": "visible"
        },
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "kind": "thinkingChange",
        "level": "off",
        "parentId": "<present>",
        "semantic": {
          "contextEffect": "none",
          "delivery": "stored",
          "direction": "ambientStatus",
          "kind": "status",
          "origin": {
            "confidence": "boundary",
            "kind": "gateway"
          },
          "sequence": "<present>",
          "version": 1,
          "visibility": "visible"
        },
        "timestamp": "<present>"
      },
      {
        "content": [
          {
            "id": "<present>",
            "ordinal": 0,
            "text": "start a turn to abort",
            "type": "text"
          }
        ],
        "id": "<present>",
        "kind": "message",
        "parentId": "<present>",
        "presentationId": "<present>",
        "role": "user",
        "semantic": {
          "contextEffect": "modelInput",
          "delivery": "stored",
          "direction": "inboundContext",
          "invocationId": "<present>",
          "kind": "resourcePrompt",
          "lifecycle": "interrupted",
          "operationId": "<present>",
          "origin": {
            "confidence": "boundary",
            "kind": "user"
          },
          "sequence": "<present>",
          "version": 1,
          "visibility": "visible"
        },
        "timestamp": "<present>"
      },
      {
        "content": [],
        "errorInfo": {
          "category": "aborted",
          "message": "Request cancelled",
          "providerMessage": "Request was aborted"
        },
        "errorMessage": "Request was aborted",
        "id": "<present>",
        "kind": "message",
        "modelId": "faux-1",
        "parentId": "<present>",
        "presentationId": "<present>",
        "provider": "<LOCK>",
        "role": "assistant",
        "semantic": {
          "contextEffect": "modelInput",
          "delivery": "stored",
          "direction": "agentOutput",
          "kind": "prompt",
          "origin": {
            "confidence": "boundary",
            "kind": "assistant"
          },
          "sequence": "<present>",
          "version": 1,
          "visibility": "visible"
        },
        "stopReason": "aborted",
        "thinkingLevel": "off",
        "timestamp": "<present>",
        "usage": "<present>"
      }
    ],
    "window": {
      "end": 4,
      "leafEntryId": "<present>",
      "runtimeGeneration": "<present>",
      "start": 0,
      "total": 4
    },
    "messages": [
      {
        "content": [
          {
            "text": "start a turn to abort",
            "type": "text"
          }
        ],
        "role": "user",
        "timestamp": "<present>"
      },
      {
        "api": "<present>",
        "content": [],
        "durationMs": "<present>",
        "errorMessage": "Request was aborted",
        "model": "faux-1",
        "provider": "<LOCK>",
        "role": "assistant",
        "stopReason": "aborted",
        "thinkingLevel": "off",
        "timestamp": "<present>",
        "usage": "<present>"
      }
    ],
    "types": [
      "session",
      "model_change",
      "thinking_level_change",
      "custom:tron.context-window.v1",
      "custom:tron.settings.v1",
      "custom:tron.settings.v1",
      "custom:tron.chat-invocation.v1",
      "custom:tron.chat-invocation.v1",
      "message:system",
      "message:user",
      "custom:tron.chat-invocation.v1",
      "message:assistant",
      "custom:tron.chat-invocation.v1"
    ],
    "receipts": [
      {
        "receiptKind": "start",
        "lifecycle": "staged",
        "source": "plain"
      },
      {
        "receiptKind": "transition",
        "lifecycle": "accepted",
        "source": "plain"
      },
      {
        "receiptKind": "binding",
        "source": "plain"
      },
      {
        "receiptKind": "terminal",
        "lifecycle": "interrupted",
        "errorCode": "user-abort",
        "source": "plain"
      }
    ],
    "envelopes": [
      {
        "id": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      }
    ],
    "sessionEntries": [
      {
        "cwd": "<tmp>/workspace",
        "id": "<present>",
        "timestamp": "<present>",
        "type": "session",
        "version": 3
      },
      {
        "id": "<present>",
        "modelId": "faux-1",
        "parentId": "<present>",
        "provider": "<LOCK>",
        "timestamp": "<present>",
        "type": "model_change"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "thinkingLevel": "off",
        "timestamp": "<present>",
        "type": "thinking_level_change"
      }
    ],
    "providers": [
      [
        {
          "role": "user",
          "text": "start a turn to abort"
        }
      ]
    ],
    "extra": {}
  },
  "run-compaction": {
    "exchanges": [
      {
        "method": "session.create",
        "params": {
          "commandId": "lock-command-0001",
          "cwd": "<tmp>/workspace"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "sessionId": "<present>"
          }
        }
      },
      {
        "method": "session.open",
        "params": {
          "sessionId": "<present>"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "completionRevision": 0,
            "session": {
              "acceptsQueuedPrompts": false,
              "automaticCompactionEnabled": false,
              "availableThinkingLevels": [
                "off"
              ],
              "compactionPolicy": {
                "currentBudgets": {
                  "enabled": false,
                  "keepRecentTokens": 120,
                  "reserveTokens": 2048
                },
                "extensionMayOverride": false,
                "next": {
                  "effectiveThinkingLevel": "off",
                  "enabled": false,
                  "instructions": "",
                  "keepRecentTokens": 120,
                  "model": {
                    "id": "<present>",
                    "provider": "<LOCK>"
                  },
                  "requestedThinkingLevel": "off",
                  "reserveTokens": 2048,
                  "source": {
                    "enabled": "global",
                    "instructions": "global",
                    "keepRecentTokens": "global",
                    "reserveTokens": "global",
                    "thinkingLevel": "global"
                  },
                  "thinkingLevel": "inherit"
                }
              },
              "compactionQueued": false,
              "configurationBlocker": null,
              "contextUsage": {
                "contextWindow": "<value>",
                "percent": "<value>",
                "tokens": "<value>"
              },
              "contextWindowPolicy": {
                "default": 128000,
                "effective": 128000,
                "maximum": 128000,
                "minimum": 3192,
                "model": {
                  "id": "<present>",
                  "provider": "<LOCK>"
                },
                "override": 128000,
                "source": "session",
                "warning": "This new session and its context override are not yet saved to disk; they persist after the first user or assistant message."
              },
              "cwd": "<tmp>/workspace",
              "diagnostics": [],
              "eventSequence": "<present>",
              "extensionActivityAsOf": "<present>",
              "extensionPresentation": {
                "capabilities": [
                  "semantic.dialogs",
                  "tron.form.v1",
                  "semantic.notifications",
                  "semantic.status",
                  "semantic.working",
                  "semantic.hidden-thinking-label",
                  "semantic.string-widgets",
                  "semantic.title",
                  "semantic.revisioned-editor",
                  "semantic.tools-expanded",
                  "surfaces.full-frame"
                ],
                "diagnostics": [
                  {
                    "code": "remote-components.enabled",
                    "message": "Retained string widgets and bounded read-only component frames are presented through the general extension-content sheet; blocking custom and overlay UI remain deferred."
                  },
                  {
                    "code": "remote-components.overlay-deferred",
                    "message": "Overlay and interactive component UI remain deferred until native rendering and input leases are available."
                  },
                  {
                    "code": "theme.baseline-only",
                    "message": "Per-session process-global Pi theme synchronization is unavailable through the pinned public API."
                  }
                ],
                "hostEpoch": "<present>",
                "pendingInteractions": [],
                "revision": "<present>",
                "semanticState": {
                  "editorRevision": 0,
                  "editorText": "",
                  "statusOwners": {},
                  "statuses": {},
                  "toolsExpanded": false,
                  "widgets": [],
                  "working": {
                    "indicator": {
                      "frames": [],
                      "kind": "default"
                    },
                    "visible": true
                  }
                },
                "surfaces": [],
                "version": 3
              },
              "leafEntryId": "<present>",
              "liveActivityRevision": 0,
              "model": {
                "id": "<present>",
                "provider": "<LOCK>"
              },
              "phase": "idle",
              "processOverview": {
                "activeCount": 0,
                "asOf": "<present>",
                "problemCount": 0,
                "recentCount": 0,
                "revision": "<present>",
                "version": 1,
                "visibility": "hidden"
              },
              "queueRevision": 0,
              "queuedItems": [],
              "revision": "<present>",
              "runtimeGeneration": "<present>",
              "sessionId": "<present>",
              "stats": {
                "assistantMessages": "<value>",
                "cost": "<value>",
                "tokens": {
                  "cacheRead": "<value>",
                  "cacheWrite": "<value>",
                  "input": "<value>",
                  "output": "<value>",
                  "total": "<value>"
                },
                "toolCalls": "<value>",
                "toolResults": "<value>",
                "totalMessages": "<value>",
                "userMessages": "<value>"
              },
              "thinkingLevel": "off",
              "toolExecutions": [],
              "transcript": [
                {
                  "id": "<present>",
                  "kind": "modelChange",
                  "modelRef": {
                    "id": "<present>",
                    "provider": "<LOCK>"
                  },
                  "parentId": "<present>",
                  "semantic": {
                    "contextEffect": "none",
                    "delivery": "stored",
                    "direction": "ambientStatus",
                    "kind": "status",
                    "origin": {
                      "confidence": "boundary",
                      "kind": "gateway"
                    },
                    "sequence": "<present>",
                    "version": 1,
                    "visibility": "visible"
                  },
                  "timestamp": "<present>"
                },
                {
                  "id": "<present>",
                  "kind": "thinkingChange",
                  "level": "off",
                  "parentId": "<present>",
                  "semantic": {
                    "contextEffect": "none",
                    "delivery": "stored",
                    "direction": "ambientStatus",
                    "kind": "status",
                    "origin": {
                      "confidence": "boundary",
                      "kind": "gateway"
                    },
                    "sequence": "<present>",
                    "version": 1,
                    "visibility": "visible"
                  },
                  "timestamp": "<present>"
                }
              ],
              "transcriptStart": 0,
              "transcriptTotal": 2
            },
            "subscriptionToken": "<present>",
            "syncToken": "<present>"
          }
        }
      },
      {
        "method": "session.sync",
        "params": {
          "sessionId": "<present>",
          "syncToken": "<present>"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "synchronized": true
          }
        }
      },
      {
        "method": "session.prompt",
        "params": {
          "commandId": "lock-command-0002",
          "sessionId": "<present>",
          "text": "first question"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "operationId": "<present>"
          }
        }
      },
      {
        "method": "session.prompt",
        "params": {
          "commandId": "lock-command-0003",
          "sessionId": "<present>",
          "text": "second question"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "operationId": "<present>"
          }
        }
      },
      {
        "method": "session.compact",
        "params": {
          "commandId": "lock-command-0004",
          "sessionId": "<present>"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "compacted": true,
            "queued": false
          }
        }
      }
    ],
    "items": [
      {
        "id": "<present>",
        "kind": "modelChange",
        "modelRef": {
          "id": "<present>",
          "provider": "<LOCK>"
        },
        "parentId": "<present>",
        "semantic": {
          "contextEffect": "none",
          "delivery": "stored",
          "direction": "ambientStatus",
          "kind": "status",
          "origin": {
            "confidence": "boundary",
            "kind": "gateway"
          },
          "sequence": "<present>",
          "version": 1,
          "visibility": "visible"
        },
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "kind": "thinkingChange",
        "level": "off",
        "parentId": "<present>",
        "semantic": {
          "contextEffect": "none",
          "delivery": "stored",
          "direction": "ambientStatus",
          "kind": "status",
          "origin": {
            "confidence": "boundary",
            "kind": "gateway"
          },
          "sequence": "<present>",
          "version": 1,
          "visibility": "visible"
        },
        "timestamp": "<present>"
      },
      {
        "content": [
          {
            "id": "<present>",
            "ordinal": 0,
            "text": "first question",
            "type": "text"
          }
        ],
        "id": "<present>",
        "kind": "message",
        "parentId": "<present>",
        "presentationId": "<present>",
        "role": "user",
        "semantic": {
          "contextEffect": "modelInput",
          "delivery": "stored",
          "direction": "inboundContext",
          "invocationId": "<present>",
          "kind": "resourcePrompt",
          "lifecycle": "completed",
          "operationId": "<present>",
          "origin": {
            "confidence": "boundary",
            "kind": "user"
          },
          "sequence": "<present>",
          "version": 1,
          "visibility": "visible"
        },
        "timestamp": "<present>"
      },
      {
        "content": [
          {
            "id": "<present>",
            "ordinal": 0,
            "text": "First answer. lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context ",
            "type": "text"
          }
        ],
        "id": "<present>",
        "kind": "message",
        "modelId": "faux-1",
        "parentId": "<present>",
        "presentationId": "<present>",
        "provider": "<LOCK>",
        "role": "assistant",
        "semantic": {
          "contextEffect": "modelInput",
          "delivery": "stored",
          "direction": "agentOutput",
          "kind": "prompt",
          "origin": {
            "confidence": "boundary",
            "kind": "assistant"
          },
          "sequence": "<present>",
          "version": 1,
          "visibility": "visible"
        },
        "stopReason": "stop",
        "thinkingLevel": "off",
        "timestamp": "<present>",
        "usage": "<present>"
      },
      {
        "content": [
          {
            "id": "<present>",
            "ordinal": 0,
            "text": "second question",
            "type": "text"
          }
        ],
        "id": "<present>",
        "kind": "message",
        "parentId": "<present>",
        "presentationId": "<present>",
        "role": "user",
        "semantic": {
          "contextEffect": "modelInput",
          "delivery": "stored",
          "direction": "inboundContext",
          "invocationId": "<present>",
          "kind": "resourcePrompt",
          "lifecycle": "completed",
          "operationId": "<present>",
          "origin": {
            "confidence": "boundary",
            "kind": "user"
          },
          "sequence": "<present>",
          "version": 1,
          "visibility": "visible"
        },
        "timestamp": "<present>"
      },
      {
        "content": [
          {
            "id": "<present>",
            "ordinal": 0,
            "text": "Second answer. lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context ",
            "type": "text"
          }
        ],
        "id": "<present>",
        "kind": "message",
        "modelId": "faux-1",
        "parentId": "<present>",
        "presentationId": "<present>",
        "provider": "<LOCK>",
        "role": "assistant",
        "semantic": {
          "contextEffect": "modelInput",
          "delivery": "stored",
          "direction": "agentOutput",
          "kind": "prompt",
          "origin": {
            "confidence": "boundary",
            "kind": "assistant"
          },
          "sequence": "<present>",
          "version": 1,
          "visibility": "visible"
        },
        "stopReason": "stop",
        "thinkingLevel": "off",
        "timestamp": "<present>",
        "usage": "<present>"
      },
      {
        "details": {
          "modifiedFiles": [],
          "readFiles": []
        },
        "fromHook": false,
        "id": "<present>",
        "kind": "compaction",
        "parentId": "<present>",
        "presentationId": "<present>",
        "semantic": {
          "contextEffect": "none",
          "delivery": "stored",
          "direction": "ambientStatus",
          "kind": "status",
          "origin": {
            "confidence": "boundary",
            "kind": "gateway"
          },
          "sequence": "<present>",
          "version": 1,
          "visibility": "visible"
        },
        "summary": "Summary: two answered turns about the lock context.\n\n---\n\n**Turn Context (split turn):**\n\nTurn prefix: the second question.",
        "timestamp": "<present>",
        "tokensBefore": "<value>",
        "usage": "<present>"
      }
    ],
    "window": {
      "end": 7,
      "leafEntryId": "<present>",
      "runtimeGeneration": "<present>",
      "start": 0,
      "total": 7
    },
    "messages": [
      {
        "content": [
          {
            "text": "first question",
            "type": "text"
          }
        ],
        "role": "user",
        "timestamp": "<present>"
      },
      {
        "api": "<present>",
        "content": [
          {
            "text": "First answer. lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context ",
            "type": "text"
          }
        ],
        "durationMs": "<present>",
        "model": "faux-1",
        "provider": "<LOCK>",
        "role": "assistant",
        "stopReason": "stop",
        "thinkingLevel": "off",
        "timestamp": "<present>",
        "usage": "<present>"
      },
      {
        "content": [
          {
            "text": "second question",
            "type": "text"
          }
        ],
        "role": "user",
        "timestamp": "<present>"
      },
      {
        "api": "<present>",
        "content": [
          {
            "text": "Second answer. lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context ",
            "type": "text"
          }
        ],
        "durationMs": "<present>",
        "model": "faux-1",
        "provider": "<LOCK>",
        "role": "assistant",
        "stopReason": "stop",
        "thinkingLevel": "off",
        "timestamp": "<present>",
        "usage": "<present>"
      }
    ],
    "types": [
      "session",
      "model_change",
      "thinking_level_change",
      "custom:tron.context-window.v1",
      "custom:tron.settings.v1",
      "custom:tron.settings.v1",
      "custom:tron.chat-invocation.v1",
      "custom:tron.chat-invocation.v1",
      "message:system",
      "message:user",
      "custom:tron.chat-invocation.v1",
      "message:assistant",
      "custom:tron.chat-invocation.v1",
      "custom:tron.chat-invocation.v1",
      "custom:tron.chat-invocation.v1",
      "message:user",
      "custom:tron.chat-invocation.v1",
      "message:assistant",
      "custom:tron.chat-invocation.v1",
      "compaction"
    ],
    "receipts": [
      {
        "receiptKind": "start",
        "lifecycle": "staged",
        "source": "plain"
      },
      {
        "receiptKind": "transition",
        "lifecycle": "accepted",
        "source": "plain"
      },
      {
        "receiptKind": "binding",
        "source": "plain"
      },
      {
        "receiptKind": "terminal",
        "lifecycle": "completed",
        "source": "plain"
      },
      {
        "receiptKind": "start",
        "lifecycle": "staged",
        "source": "plain"
      },
      {
        "receiptKind": "transition",
        "lifecycle": "accepted",
        "source": "plain"
      },
      {
        "receiptKind": "binding",
        "source": "plain"
      },
      {
        "receiptKind": "terminal",
        "lifecycle": "completed",
        "source": "plain"
      }
    ],
    "envelopes": [
      {
        "id": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      }
    ],
    "sessionEntries": [
      {
        "cwd": "<tmp>/workspace",
        "id": "<present>",
        "timestamp": "<present>",
        "type": "session",
        "version": 3
      },
      {
        "id": "<present>",
        "modelId": "faux-1",
        "parentId": "<present>",
        "provider": "<LOCK>",
        "timestamp": "<present>",
        "type": "model_change"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "thinkingLevel": "off",
        "timestamp": "<present>",
        "type": "thinking_level_change"
      }
    ],
    "providers": [
      [
        {
          "role": "user",
          "text": "first question"
        }
      ],
      [
        {
          "role": "user",
          "text": "first question"
        },
        {
          "role": "assistant",
          "text": "First answer. lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context "
        },
        {
          "role": "user",
          "text": "second question"
        }
      ],
      [
        {
          "role": "user",
          "text": "<conversation>\n[User]: first question\n\n[Assistant]: First answer. lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context \n</conversation>\n\nThe messages above are a conversation to summarize. Create a structured context checkpoint summary that another LLM will use to continue the work.\n\nUse this EXACT format:\n\n## Goal\n[What is the user trying to accomplish? Can be multiple items if the session covers different tasks.]\n\n## Constraints & Preferences\n- [Any constraints, preferences, or requirements mentioned by user]\n- [Or \"(none)\" if none were mentioned]\n\n## Progress\n### Done\n- [x] [Completed tasks/changes]\n\n### In Progress\n- [ ] [Current work]\n\n### Blocked\n- [Issues preventing progress, if any]\n\n## Key Decisions\n- **[Decision]**: [Brief rationale]\n\n## Next Steps\n1. [Ordered list of what should happen next]\n\n## Critical Context\n- [Any data, examples, or references needed to continue]\n- [Or \"(none)\" if not applicable]\n\nKeep each section concise. Preserve exact file paths, function names, and error messages."
        }
      ],
      [
        {
          "role": "user",
          "text": "# Conversation\n[User]: second question\n\n# Instructions\nThe messages above are earlier context from an ongoing conversation. Later messages are stored separately and do not need to be reconstructed.\n\nCreate a concise checkpoint of the user's request and the progress shown above. This checkpoint will be placed before the later messages so the conversation can continue with the necessary context.\n\n## Original Request\n[What did the user ask for?]\n\n## Progress So Far\n- [Key decisions and work completed in these messages]\n\n## Context Needed to Continue\n- [Information from these messages needed to understand the later work]\n\nOnly summarize information explicitly present above. Do not infer or recreate later messages."
        }
      ]
    ],
    "extra": {}
  },
  "run-extension-ui": {
    "exchanges": [
      {
        "method": "session.create",
        "params": {
          "commandId": "lock-command-0001",
          "cwd": "<tmp>/workspace"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "sessionId": "<present>"
          }
        }
      },
      {
        "method": "session.open",
        "params": {
          "sessionId": "<present>"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "completionRevision": 0,
            "session": {
              "acceptsQueuedPrompts": false,
              "automaticCompactionEnabled": false,
              "availableThinkingLevels": [
                "off"
              ],
              "compactionPolicy": {
                "currentBudgets": {
                  "enabled": false,
                  "keepRecentTokens": 120,
                  "reserveTokens": 2048
                },
                "extensionMayOverride": false,
                "next": {
                  "effectiveThinkingLevel": "off",
                  "enabled": false,
                  "instructions": "",
                  "keepRecentTokens": 120,
                  "model": {
                    "id": "<present>",
                    "provider": "<LOCK>"
                  },
                  "requestedThinkingLevel": "off",
                  "reserveTokens": 2048,
                  "source": {
                    "enabled": "global",
                    "instructions": "global",
                    "keepRecentTokens": "global",
                    "reserveTokens": "global",
                    "thinkingLevel": "global"
                  },
                  "thinkingLevel": "inherit"
                }
              },
              "compactionQueued": false,
              "configurationBlocker": null,
              "contextUsage": {
                "contextWindow": "<value>",
                "percent": "<value>",
                "tokens": "<value>"
              },
              "contextWindowPolicy": {
                "default": 128000,
                "effective": 128000,
                "maximum": 128000,
                "minimum": 3192,
                "model": {
                  "id": "<present>",
                  "provider": "<LOCK>"
                },
                "override": 128000,
                "source": "session",
                "warning": "This new session and its context override are not yet saved to disk; they persist after the first user or assistant message."
              },
              "cwd": "<tmp>/workspace",
              "diagnostics": [],
              "eventSequence": "<present>",
              "extensionActivityAsOf": "<present>",
              "extensionPresentation": {
                "capabilities": [
                  "semantic.dialogs",
                  "tron.form.v1",
                  "semantic.notifications",
                  "semantic.status",
                  "semantic.working",
                  "semantic.hidden-thinking-label",
                  "semantic.string-widgets",
                  "semantic.title",
                  "semantic.revisioned-editor",
                  "semantic.tools-expanded",
                  "surfaces.full-frame"
                ],
                "diagnostics": [
                  {
                    "code": "remote-components.enabled",
                    "message": "Retained string widgets and bounded read-only component frames are presented through the general extension-content sheet; blocking custom and overlay UI remain deferred."
                  },
                  {
                    "code": "remote-components.overlay-deferred",
                    "message": "Overlay and interactive component UI remain deferred until native rendering and input leases are available."
                  },
                  {
                    "code": "theme.baseline-only",
                    "message": "Per-session process-global Pi theme synchronization is unavailable through the pinned public API."
                  }
                ],
                "hostEpoch": "<present>",
                "pendingInteractions": [],
                "revision": "<present>",
                "semanticState": {
                  "editorRevision": 0,
                  "editorText": "",
                  "statusOwners": {},
                  "statuses": {},
                  "toolsExpanded": false,
                  "widgets": [],
                  "working": {
                    "indicator": {
                      "frames": [],
                      "kind": "default"
                    },
                    "visible": true
                  }
                },
                "surfaces": [],
                "version": 3
              },
              "leafEntryId": "<present>",
              "liveActivityRevision": 0,
              "model": {
                "id": "<present>",
                "provider": "<LOCK>"
              },
              "phase": "idle",
              "processOverview": {
                "activeCount": 0,
                "asOf": "<present>",
                "problemCount": 0,
                "recentCount": 0,
                "revision": "<present>",
                "version": 1,
                "visibility": "hidden"
              },
              "queueRevision": 0,
              "queuedItems": [],
              "revision": "<present>",
              "runtimeGeneration": "<present>",
              "sessionId": "<present>",
              "stats": {
                "assistantMessages": "<value>",
                "cost": "<value>",
                "tokens": {
                  "cacheRead": "<value>",
                  "cacheWrite": "<value>",
                  "input": "<value>",
                  "output": "<value>",
                  "total": "<value>"
                },
                "toolCalls": "<value>",
                "toolResults": "<value>",
                "totalMessages": "<value>",
                "userMessages": "<value>"
              },
              "thinkingLevel": "off",
              "toolExecutions": [],
              "transcript": [
                {
                  "id": "<present>",
                  "kind": "modelChange",
                  "modelRef": {
                    "id": "<present>",
                    "provider": "<LOCK>"
                  },
                  "parentId": "<present>",
                  "semantic": {
                    "contextEffect": "none",
                    "delivery": "stored",
                    "direction": "ambientStatus",
                    "kind": "status",
                    "origin": {
                      "confidence": "boundary",
                      "kind": "gateway"
                    },
                    "sequence": "<present>",
                    "version": 1,
                    "visibility": "visible"
                  },
                  "timestamp": "<present>"
                },
                {
                  "id": "<present>",
                  "kind": "thinkingChange",
                  "level": "off",
                  "parentId": "<present>",
                  "semantic": {
                    "contextEffect": "none",
                    "delivery": "stored",
                    "direction": "ambientStatus",
                    "kind": "status",
                    "origin": {
                      "confidence": "boundary",
                      "kind": "gateway"
                    },
                    "sequence": "<present>",
                    "version": 1,
                    "visibility": "visible"
                  },
                  "timestamp": "<present>"
                }
              ],
              "transcriptStart": 0,
              "transcriptTotal": 2
            },
            "subscriptionToken": "<present>",
            "syncToken": "<present>"
          }
        }
      },
      {
        "method": "session.sync",
        "params": {
          "sessionId": "<present>",
          "syncToken": "<present>"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "synchronized": true
          }
        }
      },
      {
        "method": "session.prompt",
        "params": {
          "commandId": "lock-command-0002",
          "sessionId": "<present>",
          "text": "ask me which path"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "operationId": "<present>"
          }
        }
      },
      {
        "method": "extension.respond",
        "params": {
          "commandId": "lock-command-0003",
          "hostEpoch": "<present>",
          "interactionId": "<id>",
          "presentationRevision": 1,
          "sessionId": "<present>",
          "value": "Keep"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "answered": true
          }
        }
      }
    ],
    "items": [
      {
        "id": "<present>",
        "kind": "modelChange",
        "modelRef": {
          "id": "<present>",
          "provider": "<LOCK>"
        },
        "parentId": "<present>",
        "semantic": {
          "contextEffect": "none",
          "delivery": "stored",
          "direction": "ambientStatus",
          "kind": "status",
          "origin": {
            "confidence": "boundary",
            "kind": "gateway"
          },
          "sequence": "<present>",
          "version": 1,
          "visibility": "visible"
        },
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "kind": "thinkingChange",
        "level": "off",
        "parentId": "<present>",
        "semantic": {
          "contextEffect": "none",
          "delivery": "stored",
          "direction": "ambientStatus",
          "kind": "status",
          "origin": {
            "confidence": "boundary",
            "kind": "gateway"
          },
          "sequence": "<present>",
          "version": 1,
          "visibility": "visible"
        },
        "timestamp": "<present>"
      },
      {
        "content": [
          {
            "id": "<present>",
            "ordinal": 0,
            "text": "ask me which path",
            "type": "text"
          }
        ],
        "id": "<present>",
        "kind": "message",
        "parentId": "<present>",
        "presentationId": "<present>",
        "role": "user",
        "semantic": {
          "contextEffect": "modelInput",
          "delivery": "stored",
          "direction": "inboundContext",
          "invocationId": "<present>",
          "kind": "resourcePrompt",
          "lifecycle": "completed",
          "operationId": "<present>",
          "origin": {
            "confidence": "boundary",
            "kind": "user"
          },
          "sequence": "<present>",
          "version": 1,
          "visibility": "visible"
        },
        "timestamp": "<present>"
      },
      {
        "content": [
          {
            "arguments": {},
            "groupCount": 1,
            "groupFinalized": true,
            "groupId": "<present>",
            "groupIndex": 0,
            "id": "<present>",
            "label": "Lock select",
            "name": "lock_select",
            "ordinal": 0,
            "toolCallId": "<present>",
            "toolSegmentId": "<present>",
            "type": "toolCall"
          }
        ],
        "id": "<present>",
        "kind": "message",
        "modelId": "faux-1",
        "parentId": "<present>",
        "presentationId": "<present>",
        "provider": "<LOCK>",
        "role": "assistant",
        "semantic": {
          "contextEffect": "modelInput",
          "delivery": "stored",
          "direction": "agentOutput",
          "kind": "prompt",
          "origin": {
            "confidence": "boundary",
            "kind": "assistant"
          },
          "sequence": "<present>",
          "version": 1,
          "visibility": "visible"
        },
        "stopReason": "toolUse",
        "thinkingLevel": "off",
        "timestamp": "<present>",
        "usage": "<present>"
      },
      {
        "completedAt": "<present>",
        "content": [
          {
            "id": "<present>",
            "ordinal": 0,
            "text": "chosen: Keep",
            "type": "text"
          }
        ],
        "details": {
          "answer": "Keep"
        },
        "durationMs": "<present>",
        "extensionOrigin": {
          "owner": {
            "id": "<present>",
            "kind": "extension",
            "source": "auto",
            "title": "Lock Select"
          },
          "source": "auto"
        },
        "groupCount": 1,
        "groupFinalized": true,
        "groupId": "<present>",
        "groupIndex": 0,
        "id": "<present>",
        "isError": false,
        "kind": "message",
        "lastProgressAt": "<present>",
        "parentId": "<present>",
        "presentationId": "<present>",
        "progressSequence": "<present>",
        "role": "toolResult",
        "semantic": {
          "contextEffect": "toolResult",
          "delivery": "toolResult",
          "direction": "agentInvocation",
          "kind": "tool",
          "origin": {
            "confidence": "boundary",
            "kind": "assistant"
          },
          "sequence": "<present>",
          "version": 1,
          "visibility": "visible"
        },
        "startedAt": "<present>",
        "timestamp": "<present>",
        "toolCallId": "<present>",
        "toolLabel": "Lock select",
        "toolName": "lock_select",
        "toolSegmentId": "<present>"
      },
      {
        "content": [
          {
            "id": "<present>",
            "ordinal": 0,
            "text": "Keeping the lock path.",
            "type": "text"
          }
        ],
        "id": "<present>",
        "kind": "message",
        "modelId": "faux-1",
        "parentId": "<present>",
        "presentationId": "<present>",
        "provider": "<LOCK>",
        "role": "assistant",
        "semantic": {
          "contextEffect": "modelInput",
          "delivery": "stored",
          "direction": "agentOutput",
          "kind": "prompt",
          "origin": {
            "confidence": "boundary",
            "kind": "assistant"
          },
          "sequence": "<present>",
          "version": 1,
          "visibility": "visible"
        },
        "stopReason": "stop",
        "thinkingLevel": "off",
        "timestamp": "<present>",
        "usage": "<present>"
      }
    ],
    "window": {
      "end": 6,
      "leafEntryId": "<present>",
      "runtimeGeneration": "<present>",
      "start": 0,
      "total": 6
    },
    "messages": [
      {
        "content": [
          {
            "text": "ask me which path",
            "type": "text"
          }
        ],
        "role": "user",
        "timestamp": "<present>"
      },
      {
        "api": "<present>",
        "content": [
          {
            "arguments": {},
            "id": "<present>",
            "name": "lock_select",
            "type": "toolCall"
          }
        ],
        "durationMs": "<present>",
        "model": "faux-1",
        "provider": "<LOCK>",
        "role": "assistant",
        "stopReason": "toolUse",
        "thinkingLevel": "off",
        "timestamp": "<present>",
        "usage": "<present>"
      },
      {
        "content": [
          {
            "text": "chosen: Keep",
            "type": "text"
          }
        ],
        "details": {
          "answer": "Keep"
        },
        "durationMs": "<present>",
        "isError": false,
        "role": "toolResult",
        "timestamp": "<present>",
        "toolCallId": "<present>",
        "toolName": "lock_select"
      },
      {
        "api": "<present>",
        "content": [
          {
            "text": "Keeping the lock path.",
            "type": "text"
          }
        ],
        "durationMs": "<present>",
        "model": "faux-1",
        "provider": "<LOCK>",
        "role": "assistant",
        "stopReason": "stop",
        "thinkingLevel": "off",
        "timestamp": "<present>",
        "usage": "<present>"
      }
    ],
    "types": [
      "session",
      "model_change",
      "thinking_level_change",
      "custom:tron.context-window.v1",
      "custom:tron.settings.v1",
      "custom:tron.settings.v1",
      "custom:tron.chat-invocation.v1",
      "custom:tron.chat-invocation.v1",
      "message:system",
      "message:user",
      "custom:tron.chat-invocation.v1",
      "message:assistant",
      "message:toolResult",
      "message:assistant",
      "custom:tron.chat-invocation.v1"
    ],
    "receipts": [
      {
        "receiptKind": "start",
        "lifecycle": "staged",
        "source": "plain"
      },
      {
        "receiptKind": "transition",
        "lifecycle": "accepted",
        "source": "plain"
      },
      {
        "receiptKind": "binding",
        "source": "plain"
      },
      {
        "receiptKind": "terminal",
        "lifecycle": "completed",
        "source": "plain"
      }
    ],
    "envelopes": [
      {
        "id": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "timestamp": "<present>"
      }
    ],
    "sessionEntries": [
      {
        "cwd": "<tmp>/workspace",
        "id": "<present>",
        "timestamp": "<present>",
        "type": "session",
        "version": 3
      },
      {
        "id": "<present>",
        "modelId": "faux-1",
        "parentId": "<present>",
        "provider": "<LOCK>",
        "timestamp": "<present>",
        "type": "model_change"
      },
      {
        "id": "<present>",
        "parentId": "<present>",
        "thinkingLevel": "off",
        "timestamp": "<present>",
        "type": "thinking_level_change"
      }
    ],
    "providers": [
      [
        {
          "role": "user",
          "text": "ask me which path"
        }
      ],
      [
        {
          "role": "user",
          "text": "ask me which path"
        },
        {
          "role": "assistant",
          "text": "",
          "toolCalls": [
            "lock_select"
          ]
        },
        {
          "role": "toolResult",
          "text": "chosen: Keep",
          "toolName": "lock_select"
        }
      ]
    ],
    "extra": {
      "observed": {
        "hostEpoch": "<present>",
        "id": "<present>",
        "invocationId": "<present>",
        "method": "select",
        "operationId": "<present>",
        "options": [
          "Keep",
          "Change"
        ],
        "owner": {
          "id": "<present>",
          "kind": "extension",
          "source": "auto",
          "title": "Lock Select"
        },
        "presentationRevision": 1,
        "title": "Choose a lock path"
      }
    }
  },
};
