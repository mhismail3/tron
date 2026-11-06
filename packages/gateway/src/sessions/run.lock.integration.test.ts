import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { type LockGateway, type LockGatewayOptions } from "../../test-support/gateway-lock-harness.js";
import { normalizeTraceValue, type TraceValue } from "../../test-support/scenario-lock.js";
import { expectScenario } from "../../test-support/lock-projections.js";
import { awaitsWithin } from "../../test-support/wait-for.js";
import { compactionScenario, EXTENSION_UI_OPTIONS, extensionUiScenario, openLockSession, promptStreamScenario, type LockSession } from "../../test-support/lock-scenarios.js";

/**
 * Kernel run locks (packages/gateway/docs/scenario-locks.md#locks) for the `gateway/run` module:
 * prompt/stream, steer, abort, compaction and extension UI, each through the
 * real Gateway over a loopback WebSocket (`gateway-lock-harness.ts`) with the
 * faux provider as the only scripted party.
 *
 * Each lock asserts its normalized trace exactly (`expectScenario`,
 * `test-support/lock-projections.ts`): every request, its parameters and its
 * response (snapshots included), the transcript the client reads, the canonical
 * JSONL and each provider request, with per-run identities, times and token counts
 * normalized. Event schemas are pinned by `client-event-schemas`, and each provider
 * request's tools, prompt sections and hash and each system entry must equal a
 * `session-shapes` shape.
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
  expectScenario(trace as unknown as Record<string, unknown>, EXPECTED[lock]);
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
    }, pending as unknown as TraceValue);
  });
});



/** Each lock's expected trace (`test-support/lock-projections.ts` `expectScenario`): its normalized exchanges, transcript, canonical JSONL, provider conversations and observed state, with model-visible parts named by session shape. */
const EXPECTED: Record<string, unknown> = {
  "run-prompt-stream": {
    "lock": "run-prompt-stream",
    "exchanges": [
      {
        "client": "phone",
        "method": "session.create",
        "params": {
          "commandId": "lock-command-0001",
          "cwd": "<tmp>/workspace"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "sessionId": "<id>"
          }
        }
      },
      {
        "client": "phone",
        "method": "session.open",
        "params": {
          "sessionId": "<id>"
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
                    "id": "<id>",
                    "provider": "tron-lock-run-prompt-stream"
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
                  "id": "<id>",
                  "provider": "tron-lock-run-prompt-stream"
                },
                "override": 128000,
                "source": "session",
                "warning": "This new session and its context override are not yet saved to disk; they persist after the first user or assistant message."
              },
              "cwd": "<tmp>/workspace",
              "diagnostics": [],
              "eventSequence": "<n>",
              "extensionActivityAsOf": "<timestamp>",
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
                "hostEpoch": "<id>",
                "pendingInteractions": [],
                "revision": "<n>",
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
              "leafEntryId": "<id>",
              "liveActivityRevision": 0,
              "model": {
                "id": "<id>",
                "provider": "tron-lock-run-prompt-stream"
              },
              "phase": "idle",
              "processOverview": {
                "activeCount": 0,
                "asOf": "<timestamp>",
                "problemCount": 0,
                "recentCount": 0,
                "revision": "<n>",
                "version": 1,
                "visibility": "hidden"
              },
              "queueRevision": 0,
              "queuedItems": [],
              "revision": "<n>",
              "runtimeGeneration": "<id>",
              "sessionId": "<id>",
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
                  "id": "<id>",
                  "kind": "modelChange",
                  "modelRef": {
                    "id": "<id>",
                    "provider": "tron-lock-run-prompt-stream"
                  },
                  "parentId": "<id>",
                  "semantic": {
                    "contextEffect": "none",
                    "delivery": "stored",
                    "direction": "ambientStatus",
                    "kind": "status",
                    "origin": {
                      "confidence": "boundary",
                      "kind": "gateway"
                    },
                    "sequence": "<n>",
                    "version": 1,
                    "visibility": "visible"
                  },
                  "timestamp": "<timestamp>"
                },
                {
                  "id": "<id>",
                  "kind": "thinkingChange",
                  "level": "off",
                  "parentId": "<id>",
                  "semantic": {
                    "contextEffect": "none",
                    "delivery": "stored",
                    "direction": "ambientStatus",
                    "kind": "status",
                    "origin": {
                      "confidence": "boundary",
                      "kind": "gateway"
                    },
                    "sequence": "<n>",
                    "version": 1,
                    "visibility": "visible"
                  },
                  "timestamp": "<timestamp>"
                }
              ],
              "transcriptStart": 0,
              "transcriptTotal": 2
            },
            "subscriptionToken": "<id>",
            "syncToken": "<id>"
          }
        }
      },
      {
        "client": "phone",
        "method": "session.sync",
        "params": {
          "sessionId": "<id>",
          "syncToken": "<id>"
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
        "client": "phone",
        "method": "session.prompt",
        "params": {
          "commandId": "lock-command-0002",
          "sessionId": "<id>",
          "text": "read the notes"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "operationId": "<id>"
          }
        }
      },
      {
        "client": "phone",
        "method": "session.transcript",
        "params": {
          "sessionId": "<id>"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "end": 6,
            "items": [
              {
                "id": "<id>",
                "kind": "modelChange",
                "modelRef": {
                  "id": "<id>",
                  "provider": "tron-lock-run-prompt-stream"
                },
                "parentId": "<id>",
                "semantic": {
                  "contextEffect": "none",
                  "delivery": "stored",
                  "direction": "ambientStatus",
                  "kind": "status",
                  "origin": {
                    "confidence": "boundary",
                    "kind": "gateway"
                  },
                  "sequence": "<n>",
                  "version": 1,
                  "visibility": "visible"
                },
                "timestamp": "<timestamp>"
              },
              {
                "id": "<id>",
                "kind": "thinkingChange",
                "level": "off",
                "parentId": "<id>",
                "semantic": {
                  "contextEffect": "none",
                  "delivery": "stored",
                  "direction": "ambientStatus",
                  "kind": "status",
                  "origin": {
                    "confidence": "boundary",
                    "kind": "gateway"
                  },
                  "sequence": "<n>",
                  "version": 1,
                  "visibility": "visible"
                },
                "timestamp": "<timestamp>"
              },
              {
                "content": [
                  {
                    "id": "<id>",
                    "ordinal": 0,
                    "text": "read the notes",
                    "type": "text"
                  }
                ],
                "id": "<id>",
                "kind": "message",
                "parentId": "<id>",
                "presentationId": "<id>",
                "role": "user",
                "semantic": {
                  "contextEffect": "modelInput",
                  "delivery": "stored",
                  "direction": "inboundContext",
                  "invocationId": "<id>",
                  "kind": "resourcePrompt",
                  "lifecycle": "completed",
                  "operationId": "<id>",
                  "origin": {
                    "confidence": "boundary",
                    "kind": "user"
                  },
                  "sequence": "<n>",
                  "version": 1,
                  "visibility": "visible"
                },
                "timestamp": "<timestamp>"
              },
              {
                "content": [
                  {
                    "id": "<id>",
                    "ordinal": 0,
                    "text": "Reading the lock notes.",
                    "thinkingRunOrdinal": 0,
                    "type": "thinking"
                  },
                  {
                    "id": "<id>",
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
                    "groupId": "<id>",
                    "groupIndex": 0,
                    "id": "<id>",
                    "name": "read",
                    "ordinal": 2,
                    "toolCallId": "<id>",
                    "toolSegmentId": "<id>",
                    "type": "toolCall"
                  }
                ],
                "id": "<id>",
                "kind": "message",
                "modelId": "faux-1",
                "parentId": "<id>",
                "presentationId": "<id>",
                "provider": "tron-lock-run-prompt-stream",
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
                  "sequence": "<n>",
                  "version": 1,
                  "visibility": "visible"
                },
                "stopReason": "toolUse",
                "thinkingLevel": "off",
                "timestamp": "<timestamp>",
                "usage": {
                  "cacheRead": "<value>",
                  "cacheWrite": "<value>",
                  "cost": {
                    "cacheRead": "<value>",
                    "cacheWrite": "<value>",
                    "input": "<value>",
                    "output": "<value>",
                    "total": "<value>"
                  },
                  "input": "<value>",
                  "output": "<value>",
                  "totalTokens": "<value>"
                }
              },
              {
                "completedAt": "<timestamp>",
                "content": [
                  {
                    "id": "<id>",
                    "ordinal": 0,
                    "text": "lock notes\n",
                    "type": "text"
                  }
                ],
                "durationMs": "<duration>",
                "groupCount": 1,
                "groupFinalized": true,
                "groupId": "<id>",
                "groupIndex": 0,
                "id": "<id>",
                "isError": false,
                "kind": "message",
                "lastProgressAt": "<timestamp>",
                "parentId": "<id>",
                "presentationId": "<id>",
                "progressSequence": "<n>",
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
                  "sequence": "<n>",
                  "version": 1,
                  "visibility": "visible"
                },
                "startedAt": "<timestamp>",
                "timestamp": "<timestamp>",
                "toolCallId": "<id>",
                "toolName": "read",
                "toolSegmentId": "<id>"
              },
              {
                "content": [
                  {
                    "id": "<id>",
                    "ordinal": 0,
                    "text": "The notes say: lock notes.",
                    "type": "text"
                  }
                ],
                "id": "<id>",
                "kind": "message",
                "modelId": "faux-1",
                "parentId": "<id>",
                "presentationId": "<id>",
                "provider": "tron-lock-run-prompt-stream",
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
                  "sequence": "<n>",
                  "version": 1,
                  "visibility": "visible"
                },
                "stopReason": "stop",
                "thinkingLevel": "off",
                "timestamp": "<timestamp>",
                "usage": {
                  "cacheRead": "<value>",
                  "cacheWrite": "<value>",
                  "cost": {
                    "cacheRead": "<value>",
                    "cacheWrite": "<value>",
                    "input": "<value>",
                    "output": "<value>",
                    "total": "<value>"
                  },
                  "input": "<value>",
                  "output": "<value>",
                  "totalTokens": "<value>"
                }
              }
            ],
            "leafEntryId": "<id>",
            "runtimeGeneration": "<id>",
            "start": 0,
            "total": 6
          }
        }
      }
    ],
    "providerRequests": [
      {
        "sessionShape": "chat",
        "messages": [
          {
            "role": "user",
            "text": "read the notes"
          }
        ]
      },
      {
        "sessionShape": "chat",
        "messages": [
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
      }
    ],
    "canonicalJsonl": [
      {
        "cwd": "<tmp>/workspace",
        "id": "<id>",
        "timestamp": "<timestamp>",
        "type": "session",
        "version": 3
      },
      {
        "id": "<id>",
        "modelId": "faux-1",
        "parentId": "<id>",
        "provider": "tron-lock-run-prompt-stream",
        "timestamp": "<timestamp>",
        "type": "model_change"
      },
      {
        "id": "<id>",
        "parentId": "<id>",
        "thinkingLevel": "off",
        "timestamp": "<timestamp>",
        "type": "thinking_level_change"
      },
      {
        "customType": "tron.context-window.v1",
        "data": {
          "contextWindow": 128000,
          "modelId": "faux-1",
          "provider": "tron-lock-run-prompt-stream",
          "version": 1
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "customType": "tron.settings.v1",
        "data": {
          "fixed": {
            "context.images.autoResize": {
              "at": "<timestamp>",
              "from": "global",
              "ref": "<id>",
              "value": true
            },
            "model.contextWindow": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "model": "tron-lock-run-prompt-stream/faux-1"
              },
              "ref": "<id>",
              "value": 128000
            },
            "model.ref[role=chat]": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "role": "chat"
              },
              "ref": "<id>",
              "value": {
                "id": "<id>",
                "provider": "tron-lock-run-prompt-stream"
              }
            },
            "model.thinking[role=chat]": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "model": "tron-lock-run-prompt-stream/faux-1",
                "role": "chat"
              },
              "ref": "<id>",
              "value": "off"
            },
            "tools.active": {
              "at": "<timestamp>",
              "from": "global",
              "ref": "<id>",
              "value": [
                "read",
                "bash",
                "edit",
                "write",
                "jev",
                "web_search",
                "settings",
                "projects",
                "ask_user",
                "display",
                "swift_app",
                "computer"
              ]
            }
          },
          "receiptId": "<id>",
          "requestPins": {},
          "settings": {}
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "customType": "tron.settings.v1",
        "data": {
          "fixed": {
            "context.images.autoResize": {
              "at": "<timestamp>",
              "from": "global",
              "ref": "<id>",
              "value": true
            },
            "model.contextWindow": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "model": "tron-lock-run-prompt-stream/faux-1"
              },
              "ref": "<id>",
              "value": 128000
            },
            "model.ref[role=chat]": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "role": "chat"
              },
              "ref": "<id>",
              "value": {
                "id": "<id>",
                "provider": "tron-lock-run-prompt-stream"
              }
            },
            "model.thinking[role=chat]": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "model": "tron-lock-run-prompt-stream/faux-1",
                "role": "chat"
              },
              "ref": "<id>",
              "value": "off"
            },
            "tools.active": {
              "at": "<timestamp>",
              "from": "global",
              "ref": "<id>",
              "value": [
                "read",
                "bash",
                "edit",
                "write",
                "jev",
                "web_search",
                "settings",
                "projects",
                "ask_user",
                "display",
                "swift_app",
                "computer"
              ]
            }
          },
          "receiptId": "<id>",
          "requestPins": {
            "context.images.block": {
              "at": "<timestamp>",
              "from": "global",
              "ref": "<id>",
              "value": false
            }
          },
          "settings": {}
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "customType": "tron.chat-invocation.v1",
        "data": {
          "createdAt": "<timestamp>",
          "invocationId": "<id>",
          "lifecycle": "staged",
          "operationId": "<id>",
          "origin": {
            "confidence": "boundary",
            "kind": "user"
          },
          "receiptId": "<id>",
          "receiptKind": "start",
          "sequence": "<n>",
          "sessionId": "<id>",
          "source": "plain",
          "version": 1,
          "writer": "gateway"
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "customType": "tron.chat-invocation.v1",
        "data": {
          "createdAt": "<timestamp>",
          "invocationId": "<id>",
          "lifecycle": "accepted",
          "operationId": "<id>",
          "receiptId": "<id>",
          "receiptKind": "transition",
          "sequence": "<n>",
          "sessionId": "<id>",
          "source": "plain",
          "version": 1,
          "writer": "gateway"
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "id": "<id>",
        "message": {
          "content": "",
          "role": "system",
          "timestamp": "<timestamp>",
          "sections": {
            "cwd": "<cwd>\n<tmp>/workspace\n</cwd>",
            "sessionShape": "chat#0"
          }
        },
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "message"
      },
      {
        "id": "<id>",
        "message": {
          "content": [
            {
              "text": "read the notes",
              "type": "text"
            }
          ],
          "role": "user",
          "timestamp": "<timestamp>"
        },
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "message"
      },
      {
        "customType": "tron.chat-invocation.v1",
        "data": {
          "canonicalEntryId": "<id>",
          "createdAt": "<timestamp>",
          "invocationId": "<id>",
          "operationId": "<id>",
          "receiptId": "<id>",
          "receiptKind": "binding",
          "sequence": "<n>",
          "sessionId": "<id>",
          "source": "plain",
          "version": 1,
          "writer": "gateway"
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "id": "<id>",
        "message": {
          "api": "<api>",
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
              "id": "<id>",
              "name": "read",
              "type": "toolCall"
            }
          ],
          "durationMs": "<duration>",
          "model": "faux-1",
          "provider": "tron-lock-run-prompt-stream",
          "role": "assistant",
          "stopReason": "toolUse",
          "thinkingLevel": "off",
          "timestamp": "<timestamp>",
          "usage": {
            "cacheRead": "<value>",
            "cacheWrite": "<value>",
            "cost": {
              "cacheRead": "<value>",
              "cacheWrite": "<value>",
              "input": "<value>",
              "output": "<value>",
              "total": "<value>"
            },
            "input": "<value>",
            "output": "<value>",
            "totalTokens": "<value>"
          }
        },
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "message"
      },
      {
        "id": "<id>",
        "message": {
          "content": [
            {
              "text": "lock notes\n",
              "type": "text"
            }
          ],
          "durationMs": "<duration>",
          "isError": false,
          "role": "toolResult",
          "timestamp": "<timestamp>",
          "toolCallId": "<id>",
          "toolName": "read"
        },
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "message"
      },
      {
        "id": "<id>",
        "message": {
          "api": "<api>",
          "content": [
            {
              "text": "The notes say: lock notes.",
              "type": "text"
            }
          ],
          "durationMs": "<duration>",
          "model": "faux-1",
          "provider": "tron-lock-run-prompt-stream",
          "role": "assistant",
          "stopReason": "stop",
          "thinkingLevel": "off",
          "timestamp": "<timestamp>",
          "usage": {
            "cacheRead": "<value>",
            "cacheWrite": "<value>",
            "cost": {
              "cacheRead": "<value>",
              "cacheWrite": "<value>",
              "input": "<value>",
              "output": "<value>",
              "total": "<value>"
            },
            "input": "<value>",
            "output": "<value>",
            "totalTokens": "<value>"
          }
        },
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "message"
      },
      {
        "customType": "tron.chat-invocation.v1",
        "data": {
          "createdAt": "<timestamp>",
          "invocationId": "<id>",
          "lifecycle": "completed",
          "operationId": "<id>",
          "origin": {
            "confidence": "boundary",
            "kind": "user"
          },
          "receiptId": "<id>",
          "receiptKind": "terminal",
          "sequence": "<n>",
          "sessionId": "<id>",
          "source": "plain",
          "version": 1,
          "writer": "gateway"
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      }
    ],
    "transcript": {
      "error": null,
      "ok": true,
      "result": {
        "end": 6,
        "items": [
          {
            "id": "<id>",
            "kind": "modelChange",
            "modelRef": {
              "id": "<id>",
              "provider": "tron-lock-run-prompt-stream"
            },
            "parentId": "<id>",
            "semantic": {
              "contextEffect": "none",
              "delivery": "stored",
              "direction": "ambientStatus",
              "kind": "status",
              "origin": {
                "confidence": "boundary",
                "kind": "gateway"
              },
              "sequence": "<n>",
              "version": 1,
              "visibility": "visible"
            },
            "timestamp": "<timestamp>"
          },
          {
            "id": "<id>",
            "kind": "thinkingChange",
            "level": "off",
            "parentId": "<id>",
            "semantic": {
              "contextEffect": "none",
              "delivery": "stored",
              "direction": "ambientStatus",
              "kind": "status",
              "origin": {
                "confidence": "boundary",
                "kind": "gateway"
              },
              "sequence": "<n>",
              "version": 1,
              "visibility": "visible"
            },
            "timestamp": "<timestamp>"
          },
          {
            "content": [
              {
                "id": "<id>",
                "ordinal": 0,
                "text": "read the notes",
                "type": "text"
              }
            ],
            "id": "<id>",
            "kind": "message",
            "parentId": "<id>",
            "presentationId": "<id>",
            "role": "user",
            "semantic": {
              "contextEffect": "modelInput",
              "delivery": "stored",
              "direction": "inboundContext",
              "invocationId": "<id>",
              "kind": "resourcePrompt",
              "lifecycle": "completed",
              "operationId": "<id>",
              "origin": {
                "confidence": "boundary",
                "kind": "user"
              },
              "sequence": "<n>",
              "version": 1,
              "visibility": "visible"
            },
            "timestamp": "<timestamp>"
          },
          {
            "content": [
              {
                "id": "<id>",
                "ordinal": 0,
                "text": "Reading the lock notes.",
                "thinkingRunOrdinal": 0,
                "type": "thinking"
              },
              {
                "id": "<id>",
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
                "groupId": "<id>",
                "groupIndex": 0,
                "id": "<id>",
                "name": "read",
                "ordinal": 2,
                "toolCallId": "<id>",
                "toolSegmentId": "<id>",
                "type": "toolCall"
              }
            ],
            "id": "<id>",
            "kind": "message",
            "modelId": "faux-1",
            "parentId": "<id>",
            "presentationId": "<id>",
            "provider": "tron-lock-run-prompt-stream",
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
              "sequence": "<n>",
              "version": 1,
              "visibility": "visible"
            },
            "stopReason": "toolUse",
            "thinkingLevel": "off",
            "timestamp": "<timestamp>",
            "usage": {
              "cacheRead": "<value>",
              "cacheWrite": "<value>",
              "cost": {
                "cacheRead": "<value>",
                "cacheWrite": "<value>",
                "input": "<value>",
                "output": "<value>",
                "total": "<value>"
              },
              "input": "<value>",
              "output": "<value>",
              "totalTokens": "<value>"
            }
          },
          {
            "completedAt": "<timestamp>",
            "content": [
              {
                "id": "<id>",
                "ordinal": 0,
                "text": "lock notes\n",
                "type": "text"
              }
            ],
            "durationMs": "<duration>",
            "groupCount": 1,
            "groupFinalized": true,
            "groupId": "<id>",
            "groupIndex": 0,
            "id": "<id>",
            "isError": false,
            "kind": "message",
            "lastProgressAt": "<timestamp>",
            "parentId": "<id>",
            "presentationId": "<id>",
            "progressSequence": "<n>",
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
              "sequence": "<n>",
              "version": 1,
              "visibility": "visible"
            },
            "startedAt": "<timestamp>",
            "timestamp": "<timestamp>",
            "toolCallId": "<id>",
            "toolName": "read",
            "toolSegmentId": "<id>"
          },
          {
            "content": [
              {
                "id": "<id>",
                "ordinal": 0,
                "text": "The notes say: lock notes.",
                "type": "text"
              }
            ],
            "id": "<id>",
            "kind": "message",
            "modelId": "faux-1",
            "parentId": "<id>",
            "presentationId": "<id>",
            "provider": "tron-lock-run-prompt-stream",
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
              "sequence": "<n>",
              "version": 1,
              "visibility": "visible"
            },
            "stopReason": "stop",
            "thinkingLevel": "off",
            "timestamp": "<timestamp>",
            "usage": {
              "cacheRead": "<value>",
              "cacheWrite": "<value>",
              "cost": {
                "cacheRead": "<value>",
                "cacheWrite": "<value>",
                "input": "<value>",
                "output": "<value>",
                "total": "<value>"
              },
              "input": "<value>",
              "output": "<value>",
              "totalTokens": "<value>"
            }
          }
        ],
        "leafEntryId": "<id>",
        "runtimeGeneration": "<id>",
        "start": 0,
        "total": 6
      }
    }
  },
  "run-steer": {
    "lock": "run-steer",
    "exchanges": [
      {
        "client": "phone",
        "method": "session.create",
        "params": {
          "commandId": "lock-command-0001",
          "cwd": "<tmp>/workspace"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "sessionId": "<id>"
          }
        }
      },
      {
        "client": "phone",
        "method": "session.open",
        "params": {
          "sessionId": "<id>"
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
                    "id": "<id>",
                    "provider": "tron-lock-run-steer"
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
                  "id": "<id>",
                  "provider": "tron-lock-run-steer"
                },
                "override": 128000,
                "source": "session",
                "warning": "This new session and its context override are not yet saved to disk; they persist after the first user or assistant message."
              },
              "cwd": "<tmp>/workspace",
              "diagnostics": [],
              "eventSequence": "<n>",
              "extensionActivityAsOf": "<timestamp>",
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
                "hostEpoch": "<id>",
                "pendingInteractions": [],
                "revision": "<n>",
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
              "leafEntryId": "<id>",
              "liveActivityRevision": 0,
              "model": {
                "id": "<id>",
                "provider": "tron-lock-run-steer"
              },
              "phase": "idle",
              "processOverview": {
                "activeCount": 0,
                "asOf": "<timestamp>",
                "problemCount": 0,
                "recentCount": 0,
                "revision": "<n>",
                "version": 1,
                "visibility": "hidden"
              },
              "queueRevision": 0,
              "queuedItems": [],
              "revision": "<n>",
              "runtimeGeneration": "<id>",
              "sessionId": "<id>",
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
                  "id": "<id>",
                  "kind": "modelChange",
                  "modelRef": {
                    "id": "<id>",
                    "provider": "tron-lock-run-steer"
                  },
                  "parentId": "<id>",
                  "semantic": {
                    "contextEffect": "none",
                    "delivery": "stored",
                    "direction": "ambientStatus",
                    "kind": "status",
                    "origin": {
                      "confidence": "boundary",
                      "kind": "gateway"
                    },
                    "sequence": "<n>",
                    "version": 1,
                    "visibility": "visible"
                  },
                  "timestamp": "<timestamp>"
                },
                {
                  "id": "<id>",
                  "kind": "thinkingChange",
                  "level": "off",
                  "parentId": "<id>",
                  "semantic": {
                    "contextEffect": "none",
                    "delivery": "stored",
                    "direction": "ambientStatus",
                    "kind": "status",
                    "origin": {
                      "confidence": "boundary",
                      "kind": "gateway"
                    },
                    "sequence": "<n>",
                    "version": 1,
                    "visibility": "visible"
                  },
                  "timestamp": "<timestamp>"
                }
              ],
              "transcriptStart": 0,
              "transcriptTotal": 2
            },
            "subscriptionToken": "<id>",
            "syncToken": "<id>"
          }
        }
      },
      {
        "client": "phone",
        "method": "session.sync",
        "params": {
          "sessionId": "<id>",
          "syncToken": "<id>"
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
        "client": "phone",
        "method": "session.prompt",
        "params": {
          "commandId": "lock-command-0002",
          "sessionId": "<id>",
          "text": "hold a turn open"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "operationId": "<id>"
          }
        }
      },
      {
        "client": "phone",
        "method": "session.prompt",
        "params": {
          "behavior": "steer",
          "commandId": "lock-command-0003",
          "sessionId": "<id>",
          "text": "steer the run"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "operationId": "<id>"
          }
        }
      },
      {
        "client": "phone",
        "method": "session.prompt",
        "params": {
          "behavior": "followUp",
          "commandId": "lock-command-0004",
          "sessionId": "<id>",
          "text": "then follow up"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "operationId": "<id>"
          }
        }
      },
      {
        "client": "phone",
        "method": "session.transcript",
        "params": {
          "sessionId": "<id>"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "end": 9,
            "items": [
              {
                "id": "<id>",
                "kind": "modelChange",
                "modelRef": {
                  "id": "<id>",
                  "provider": "tron-lock-run-steer"
                },
                "parentId": "<id>",
                "semantic": {
                  "contextEffect": "none",
                  "delivery": "stored",
                  "direction": "ambientStatus",
                  "kind": "status",
                  "origin": {
                    "confidence": "boundary",
                    "kind": "gateway"
                  },
                  "sequence": "<n>",
                  "version": 1,
                  "visibility": "visible"
                },
                "timestamp": "<timestamp>"
              },
              {
                "id": "<id>",
                "kind": "thinkingChange",
                "level": "off",
                "parentId": "<id>",
                "semantic": {
                  "contextEffect": "none",
                  "delivery": "stored",
                  "direction": "ambientStatus",
                  "kind": "status",
                  "origin": {
                    "confidence": "boundary",
                    "kind": "gateway"
                  },
                  "sequence": "<n>",
                  "version": 1,
                  "visibility": "visible"
                },
                "timestamp": "<timestamp>"
              },
              {
                "content": [
                  {
                    "id": "<id>",
                    "ordinal": 0,
                    "text": "hold a turn open",
                    "type": "text"
                  }
                ],
                "id": "<id>",
                "kind": "message",
                "parentId": "<id>",
                "presentationId": "<id>",
                "role": "user",
                "semantic": {
                  "contextEffect": "modelInput",
                  "delivery": "stored",
                  "direction": "inboundContext",
                  "invocationId": "<id>",
                  "kind": "resourcePrompt",
                  "lifecycle": "completed",
                  "operationId": "<id>",
                  "origin": {
                    "confidence": "boundary",
                    "kind": "user"
                  },
                  "sequence": "<n>",
                  "version": 1,
                  "visibility": "visible"
                },
                "timestamp": "<timestamp>"
              },
              {
                "content": [
                  {
                    "arguments": {
                      "path": "notes.txt"
                    },
                    "groupCount": 1,
                    "groupFinalized": true,
                    "groupId": "<id>",
                    "groupIndex": 0,
                    "id": "<id>",
                    "name": "read",
                    "ordinal": 0,
                    "toolCallId": "<id>",
                    "toolSegmentId": "<id>",
                    "type": "toolCall"
                  }
                ],
                "id": "<id>",
                "kind": "message",
                "modelId": "faux-1",
                "parentId": "<id>",
                "presentationId": "<id>",
                "provider": "tron-lock-run-steer",
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
                  "sequence": "<n>",
                  "version": 1,
                  "visibility": "visible"
                },
                "stopReason": "toolUse",
                "thinkingLevel": "off",
                "timestamp": "<timestamp>",
                "usage": {
                  "cacheRead": "<value>",
                  "cacheWrite": "<value>",
                  "cost": {
                    "cacheRead": "<value>",
                    "cacheWrite": "<value>",
                    "input": "<value>",
                    "output": "<value>",
                    "total": "<value>"
                  },
                  "input": "<value>",
                  "output": "<value>",
                  "totalTokens": "<value>"
                }
              },
              {
                "completedAt": "<timestamp>",
                "content": [
                  {
                    "id": "<id>",
                    "ordinal": 0,
                    "text": "lock notes\n",
                    "type": "text"
                  }
                ],
                "durationMs": "<duration>",
                "groupCount": 1,
                "groupFinalized": true,
                "groupId": "<id>",
                "groupIndex": 0,
                "id": "<id>",
                "isError": false,
                "kind": "message",
                "lastProgressAt": "<timestamp>",
                "parentId": "<id>",
                "presentationId": "<id>",
                "progressSequence": "<n>",
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
                  "sequence": "<n>",
                  "version": 1,
                  "visibility": "visible"
                },
                "startedAt": "<timestamp>",
                "timestamp": "<timestamp>",
                "toolCallId": "<id>",
                "toolName": "read",
                "toolSegmentId": "<id>"
              },
              {
                "content": [
                  {
                    "id": "<id>",
                    "ordinal": 0,
                    "text": "steer the run",
                    "type": "text"
                  }
                ],
                "id": "<id>",
                "kind": "message",
                "parentId": "<id>",
                "presentationId": "<id>",
                "role": "user",
                "semantic": {
                  "contextEffect": "modelInput",
                  "delivery": "stored",
                  "direction": "inboundContext",
                  "invocationId": "<id>",
                  "kind": "resourcePrompt",
                  "lifecycle": "completed",
                  "operationId": "<id>",
                  "origin": {
                    "confidence": "boundary",
                    "kind": "user"
                  },
                  "sequence": "<n>",
                  "version": 1,
                  "visibility": "visible"
                },
                "timestamp": "<timestamp>"
              },
              {
                "content": [
                  {
                    "id": "<id>",
                    "ordinal": 0,
                    "text": "Steered work acknowledged.",
                    "type": "text"
                  }
                ],
                "id": "<id>",
                "kind": "message",
                "modelId": "faux-1",
                "parentId": "<id>",
                "presentationId": "<id>",
                "provider": "tron-lock-run-steer",
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
                  "sequence": "<n>",
                  "version": 1,
                  "visibility": "visible"
                },
                "stopReason": "stop",
                "thinkingLevel": "off",
                "timestamp": "<timestamp>",
                "usage": {
                  "cacheRead": "<value>",
                  "cacheWrite": "<value>",
                  "cost": {
                    "cacheRead": "<value>",
                    "cacheWrite": "<value>",
                    "input": "<value>",
                    "output": "<value>",
                    "total": "<value>"
                  },
                  "input": "<value>",
                  "output": "<value>",
                  "totalTokens": "<value>"
                }
              },
              {
                "content": [
                  {
                    "id": "<id>",
                    "ordinal": 0,
                    "text": "then follow up",
                    "type": "text"
                  }
                ],
                "id": "<id>",
                "kind": "message",
                "parentId": "<id>",
                "presentationId": "<id>",
                "role": "user",
                "semantic": {
                  "contextEffect": "modelInput",
                  "delivery": "stored",
                  "direction": "inboundContext",
                  "invocationId": "<id>",
                  "kind": "resourcePrompt",
                  "lifecycle": "completed",
                  "operationId": "<id>",
                  "origin": {
                    "confidence": "boundary",
                    "kind": "user"
                  },
                  "sequence": "<n>",
                  "version": 1,
                  "visibility": "visible"
                },
                "timestamp": "<timestamp>"
              },
              {
                "content": [
                  {
                    "id": "<id>",
                    "ordinal": 0,
                    "text": "Follow-up work acknowledged.",
                    "type": "text"
                  }
                ],
                "id": "<id>",
                "kind": "message",
                "modelId": "faux-1",
                "parentId": "<id>",
                "presentationId": "<id>",
                "provider": "tron-lock-run-steer",
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
                  "sequence": "<n>",
                  "version": 1,
                  "visibility": "visible"
                },
                "stopReason": "stop",
                "thinkingLevel": "off",
                "timestamp": "<timestamp>",
                "usage": {
                  "cacheRead": "<value>",
                  "cacheWrite": "<value>",
                  "cost": {
                    "cacheRead": "<value>",
                    "cacheWrite": "<value>",
                    "input": "<value>",
                    "output": "<value>",
                    "total": "<value>"
                  },
                  "input": "<value>",
                  "output": "<value>",
                  "totalTokens": "<value>"
                }
              }
            ],
            "leafEntryId": "<id>",
            "runtimeGeneration": "<id>",
            "start": 0,
            "total": 9
          }
        }
      }
    ],
    "providerRequests": [
      {
        "sessionShape": "chat",
        "messages": [
          {
            "role": "user",
            "text": "hold a turn open"
          }
        ]
      },
      {
        "sessionShape": "chat",
        "messages": [
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
        ]
      },
      {
        "sessionShape": "chat",
        "messages": [
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
      }
    ],
    "canonicalJsonl": [
      {
        "cwd": "<tmp>/workspace",
        "id": "<id>",
        "timestamp": "<timestamp>",
        "type": "session",
        "version": 3
      },
      {
        "id": "<id>",
        "modelId": "faux-1",
        "parentId": "<id>",
        "provider": "tron-lock-run-steer",
        "timestamp": "<timestamp>",
        "type": "model_change"
      },
      {
        "id": "<id>",
        "parentId": "<id>",
        "thinkingLevel": "off",
        "timestamp": "<timestamp>",
        "type": "thinking_level_change"
      },
      {
        "customType": "tron.context-window.v1",
        "data": {
          "contextWindow": 128000,
          "modelId": "faux-1",
          "provider": "tron-lock-run-steer",
          "version": 1
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "customType": "tron.settings.v1",
        "data": {
          "fixed": {
            "context.images.autoResize": {
              "at": "<timestamp>",
              "from": "global",
              "ref": "<id>",
              "value": true
            },
            "model.contextWindow": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "model": "tron-lock-run-steer/faux-1"
              },
              "ref": "<id>",
              "value": 128000
            },
            "model.ref[role=chat]": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "role": "chat"
              },
              "ref": "<id>",
              "value": {
                "id": "<id>",
                "provider": "tron-lock-run-steer"
              }
            },
            "model.thinking[role=chat]": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "model": "tron-lock-run-steer/faux-1",
                "role": "chat"
              },
              "ref": "<id>",
              "value": "off"
            },
            "tools.active": {
              "at": "<timestamp>",
              "from": "global",
              "ref": "<id>",
              "value": [
                "read",
                "bash",
                "edit",
                "write",
                "jev",
                "web_search",
                "settings",
                "projects",
                "ask_user",
                "display",
                "swift_app",
                "computer"
              ]
            }
          },
          "receiptId": "<id>",
          "requestPins": {},
          "settings": {}
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "customType": "tron.settings.v1",
        "data": {
          "fixed": {
            "context.images.autoResize": {
              "at": "<timestamp>",
              "from": "global",
              "ref": "<id>",
              "value": true
            },
            "model.contextWindow": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "model": "tron-lock-run-steer/faux-1"
              },
              "ref": "<id>",
              "value": 128000
            },
            "model.ref[role=chat]": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "role": "chat"
              },
              "ref": "<id>",
              "value": {
                "id": "<id>",
                "provider": "tron-lock-run-steer"
              }
            },
            "model.thinking[role=chat]": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "model": "tron-lock-run-steer/faux-1",
                "role": "chat"
              },
              "ref": "<id>",
              "value": "off"
            },
            "tools.active": {
              "at": "<timestamp>",
              "from": "global",
              "ref": "<id>",
              "value": [
                "read",
                "bash",
                "edit",
                "write",
                "jev",
                "web_search",
                "settings",
                "projects",
                "ask_user",
                "display",
                "swift_app",
                "computer"
              ]
            }
          },
          "receiptId": "<id>",
          "requestPins": {
            "context.images.block": {
              "at": "<timestamp>",
              "from": "global",
              "ref": "<id>",
              "value": false
            }
          },
          "settings": {}
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "customType": "tron.chat-invocation.v1",
        "data": {
          "createdAt": "<timestamp>",
          "invocationId": "<id>",
          "lifecycle": "staged",
          "operationId": "<id>",
          "origin": {
            "confidence": "boundary",
            "kind": "user"
          },
          "receiptId": "<id>",
          "receiptKind": "start",
          "sequence": "<n>",
          "sessionId": "<id>",
          "source": "plain",
          "version": 1,
          "writer": "gateway"
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "customType": "tron.chat-invocation.v1",
        "data": {
          "createdAt": "<timestamp>",
          "invocationId": "<id>",
          "lifecycle": "accepted",
          "operationId": "<id>",
          "receiptId": "<id>",
          "receiptKind": "transition",
          "sequence": "<n>",
          "sessionId": "<id>",
          "source": "plain",
          "version": 1,
          "writer": "gateway"
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "id": "<id>",
        "message": {
          "content": "",
          "role": "system",
          "timestamp": "<timestamp>",
          "sections": {
            "cwd": "<cwd>\n<tmp>/workspace\n</cwd>",
            "sessionShape": "chat#0"
          }
        },
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "message"
      },
      {
        "id": "<id>",
        "message": {
          "content": [
            {
              "text": "hold a turn open",
              "type": "text"
            }
          ],
          "role": "user",
          "timestamp": "<timestamp>"
        },
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "message"
      },
      {
        "customType": "tron.chat-invocation.v1",
        "data": {
          "canonicalEntryId": "<id>",
          "createdAt": "<timestamp>",
          "invocationId": "<id>",
          "operationId": "<id>",
          "receiptId": "<id>",
          "receiptKind": "binding",
          "sequence": "<n>",
          "sessionId": "<id>",
          "source": "plain",
          "version": 1,
          "writer": "gateway"
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "customType": "tron.chat-invocation.v1",
        "data": {
          "createdAt": "<timestamp>",
          "invocationId": "<id>",
          "lifecycle": "staged",
          "operationId": "<id>",
          "origin": {
            "confidence": "boundary",
            "kind": "user"
          },
          "receiptId": "<id>",
          "receiptKind": "start",
          "sequence": "<n>",
          "sessionId": "<id>",
          "source": "plain",
          "version": 1,
          "writer": "gateway"
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "customType": "tron.chat-invocation.v1",
        "data": {
          "createdAt": "<timestamp>",
          "invocationId": "<id>",
          "lifecycle": "accepted",
          "operationId": "<id>",
          "receiptId": "<id>",
          "receiptKind": "transition",
          "sequence": "<n>",
          "sessionId": "<id>",
          "source": "plain",
          "version": 1,
          "writer": "gateway"
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "customType": "tron.chat-invocation.v1",
        "data": {
          "createdAt": "<timestamp>",
          "invocationId": "<id>",
          "lifecycle": "staged",
          "operationId": "<id>",
          "origin": {
            "confidence": "boundary",
            "kind": "user"
          },
          "receiptId": "<id>",
          "receiptKind": "start",
          "sequence": "<n>",
          "sessionId": "<id>",
          "source": "plain",
          "version": 1,
          "writer": "gateway"
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "customType": "tron.chat-invocation.v1",
        "data": {
          "createdAt": "<timestamp>",
          "invocationId": "<id>",
          "lifecycle": "accepted",
          "operationId": "<id>",
          "receiptId": "<id>",
          "receiptKind": "transition",
          "sequence": "<n>",
          "sessionId": "<id>",
          "source": "plain",
          "version": 1,
          "writer": "gateway"
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "id": "<id>",
        "message": {
          "api": "<api>",
          "content": [
            {
              "arguments": {
                "path": "notes.txt"
              },
              "id": "<id>",
              "name": "read",
              "type": "toolCall"
            }
          ],
          "durationMs": "<duration>",
          "model": "faux-1",
          "provider": "tron-lock-run-steer",
          "role": "assistant",
          "stopReason": "toolUse",
          "thinkingLevel": "off",
          "timestamp": "<timestamp>",
          "usage": {
            "cacheRead": "<value>",
            "cacheWrite": "<value>",
            "cost": {
              "cacheRead": "<value>",
              "cacheWrite": "<value>",
              "input": "<value>",
              "output": "<value>",
              "total": "<value>"
            },
            "input": "<value>",
            "output": "<value>",
            "totalTokens": "<value>"
          }
        },
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "message"
      },
      {
        "id": "<id>",
        "message": {
          "content": [
            {
              "text": "lock notes\n",
              "type": "text"
            }
          ],
          "durationMs": "<duration>",
          "isError": false,
          "role": "toolResult",
          "timestamp": "<timestamp>",
          "toolCallId": "<id>",
          "toolName": "read"
        },
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "message"
      },
      {
        "id": "<id>",
        "message": {
          "content": [
            {
              "text": "steer the run",
              "type": "text"
            }
          ],
          "role": "user",
          "timestamp": "<timestamp>"
        },
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "message"
      },
      {
        "customType": "tron.chat-invocation.v1",
        "data": {
          "canonicalEntryId": "<id>",
          "createdAt": "<timestamp>",
          "invocationId": "<id>",
          "operationId": "<id>",
          "receiptId": "<id>",
          "receiptKind": "binding",
          "sequence": "<n>",
          "sessionId": "<id>",
          "source": "plain",
          "version": 1,
          "writer": "gateway"
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "customType": "tron.chat-invocation.v1",
        "data": {
          "createdAt": "<timestamp>",
          "invocationId": "<id>",
          "lifecycle": "completed",
          "operationId": "<id>",
          "origin": {
            "confidence": "boundary",
            "kind": "user"
          },
          "receiptId": "<id>",
          "receiptKind": "terminal",
          "sequence": "<n>",
          "sessionId": "<id>",
          "source": "plain",
          "version": 1,
          "writer": "gateway"
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "id": "<id>",
        "message": {
          "api": "<api>",
          "content": [
            {
              "text": "Steered work acknowledged.",
              "type": "text"
            }
          ],
          "durationMs": "<duration>",
          "model": "faux-1",
          "provider": "tron-lock-run-steer",
          "role": "assistant",
          "stopReason": "stop",
          "thinkingLevel": "off",
          "timestamp": "<timestamp>",
          "usage": {
            "cacheRead": "<value>",
            "cacheWrite": "<value>",
            "cost": {
              "cacheRead": "<value>",
              "cacheWrite": "<value>",
              "input": "<value>",
              "output": "<value>",
              "total": "<value>"
            },
            "input": "<value>",
            "output": "<value>",
            "totalTokens": "<value>"
          }
        },
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "message"
      },
      {
        "customType": "tron.chat-invocation.v1",
        "data": {
          "createdAt": "<timestamp>",
          "invocationId": "<id>",
          "lifecycle": "completed",
          "operationId": "<id>",
          "origin": {
            "confidence": "boundary",
            "kind": "user"
          },
          "receiptId": "<id>",
          "receiptKind": "terminal",
          "sequence": "<n>",
          "sessionId": "<id>",
          "source": "plain",
          "version": 1,
          "writer": "gateway"
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "id": "<id>",
        "message": {
          "content": [
            {
              "text": "then follow up",
              "type": "text"
            }
          ],
          "role": "user",
          "timestamp": "<timestamp>"
        },
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "message"
      },
      {
        "customType": "tron.chat-invocation.v1",
        "data": {
          "canonicalEntryId": "<id>",
          "createdAt": "<timestamp>",
          "invocationId": "<id>",
          "operationId": "<id>",
          "receiptId": "<id>",
          "receiptKind": "binding",
          "sequence": "<n>",
          "sessionId": "<id>",
          "source": "plain",
          "version": 1,
          "writer": "gateway"
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "id": "<id>",
        "message": {
          "api": "<api>",
          "content": [
            {
              "text": "Follow-up work acknowledged.",
              "type": "text"
            }
          ],
          "durationMs": "<duration>",
          "model": "faux-1",
          "provider": "tron-lock-run-steer",
          "role": "assistant",
          "stopReason": "stop",
          "thinkingLevel": "off",
          "timestamp": "<timestamp>",
          "usage": {
            "cacheRead": "<value>",
            "cacheWrite": "<value>",
            "cost": {
              "cacheRead": "<value>",
              "cacheWrite": "<value>",
              "input": "<value>",
              "output": "<value>",
              "total": "<value>"
            },
            "input": "<value>",
            "output": "<value>",
            "totalTokens": "<value>"
          }
        },
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "message"
      },
      {
        "customType": "tron.chat-invocation.v1",
        "data": {
          "createdAt": "<timestamp>",
          "invocationId": "<id>",
          "lifecycle": "completed",
          "operationId": "<id>",
          "origin": {
            "confidence": "boundary",
            "kind": "user"
          },
          "receiptId": "<id>",
          "receiptKind": "terminal",
          "sequence": "<n>",
          "sessionId": "<id>",
          "source": "plain",
          "version": 1,
          "writer": "gateway"
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      }
    ],
    "transcript": {
      "error": null,
      "ok": true,
      "result": {
        "end": 9,
        "items": [
          {
            "id": "<id>",
            "kind": "modelChange",
            "modelRef": {
              "id": "<id>",
              "provider": "tron-lock-run-steer"
            },
            "parentId": "<id>",
            "semantic": {
              "contextEffect": "none",
              "delivery": "stored",
              "direction": "ambientStatus",
              "kind": "status",
              "origin": {
                "confidence": "boundary",
                "kind": "gateway"
              },
              "sequence": "<n>",
              "version": 1,
              "visibility": "visible"
            },
            "timestamp": "<timestamp>"
          },
          {
            "id": "<id>",
            "kind": "thinkingChange",
            "level": "off",
            "parentId": "<id>",
            "semantic": {
              "contextEffect": "none",
              "delivery": "stored",
              "direction": "ambientStatus",
              "kind": "status",
              "origin": {
                "confidence": "boundary",
                "kind": "gateway"
              },
              "sequence": "<n>",
              "version": 1,
              "visibility": "visible"
            },
            "timestamp": "<timestamp>"
          },
          {
            "content": [
              {
                "id": "<id>",
                "ordinal": 0,
                "text": "hold a turn open",
                "type": "text"
              }
            ],
            "id": "<id>",
            "kind": "message",
            "parentId": "<id>",
            "presentationId": "<id>",
            "role": "user",
            "semantic": {
              "contextEffect": "modelInput",
              "delivery": "stored",
              "direction": "inboundContext",
              "invocationId": "<id>",
              "kind": "resourcePrompt",
              "lifecycle": "completed",
              "operationId": "<id>",
              "origin": {
                "confidence": "boundary",
                "kind": "user"
              },
              "sequence": "<n>",
              "version": 1,
              "visibility": "visible"
            },
            "timestamp": "<timestamp>"
          },
          {
            "content": [
              {
                "arguments": {
                  "path": "notes.txt"
                },
                "groupCount": 1,
                "groupFinalized": true,
                "groupId": "<id>",
                "groupIndex": 0,
                "id": "<id>",
                "name": "read",
                "ordinal": 0,
                "toolCallId": "<id>",
                "toolSegmentId": "<id>",
                "type": "toolCall"
              }
            ],
            "id": "<id>",
            "kind": "message",
            "modelId": "faux-1",
            "parentId": "<id>",
            "presentationId": "<id>",
            "provider": "tron-lock-run-steer",
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
              "sequence": "<n>",
              "version": 1,
              "visibility": "visible"
            },
            "stopReason": "toolUse",
            "thinkingLevel": "off",
            "timestamp": "<timestamp>",
            "usage": {
              "cacheRead": "<value>",
              "cacheWrite": "<value>",
              "cost": {
                "cacheRead": "<value>",
                "cacheWrite": "<value>",
                "input": "<value>",
                "output": "<value>",
                "total": "<value>"
              },
              "input": "<value>",
              "output": "<value>",
              "totalTokens": "<value>"
            }
          },
          {
            "completedAt": "<timestamp>",
            "content": [
              {
                "id": "<id>",
                "ordinal": 0,
                "text": "lock notes\n",
                "type": "text"
              }
            ],
            "durationMs": "<duration>",
            "groupCount": 1,
            "groupFinalized": true,
            "groupId": "<id>",
            "groupIndex": 0,
            "id": "<id>",
            "isError": false,
            "kind": "message",
            "lastProgressAt": "<timestamp>",
            "parentId": "<id>",
            "presentationId": "<id>",
            "progressSequence": "<n>",
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
              "sequence": "<n>",
              "version": 1,
              "visibility": "visible"
            },
            "startedAt": "<timestamp>",
            "timestamp": "<timestamp>",
            "toolCallId": "<id>",
            "toolName": "read",
            "toolSegmentId": "<id>"
          },
          {
            "content": [
              {
                "id": "<id>",
                "ordinal": 0,
                "text": "steer the run",
                "type": "text"
              }
            ],
            "id": "<id>",
            "kind": "message",
            "parentId": "<id>",
            "presentationId": "<id>",
            "role": "user",
            "semantic": {
              "contextEffect": "modelInput",
              "delivery": "stored",
              "direction": "inboundContext",
              "invocationId": "<id>",
              "kind": "resourcePrompt",
              "lifecycle": "completed",
              "operationId": "<id>",
              "origin": {
                "confidence": "boundary",
                "kind": "user"
              },
              "sequence": "<n>",
              "version": 1,
              "visibility": "visible"
            },
            "timestamp": "<timestamp>"
          },
          {
            "content": [
              {
                "id": "<id>",
                "ordinal": 0,
                "text": "Steered work acknowledged.",
                "type": "text"
              }
            ],
            "id": "<id>",
            "kind": "message",
            "modelId": "faux-1",
            "parentId": "<id>",
            "presentationId": "<id>",
            "provider": "tron-lock-run-steer",
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
              "sequence": "<n>",
              "version": 1,
              "visibility": "visible"
            },
            "stopReason": "stop",
            "thinkingLevel": "off",
            "timestamp": "<timestamp>",
            "usage": {
              "cacheRead": "<value>",
              "cacheWrite": "<value>",
              "cost": {
                "cacheRead": "<value>",
                "cacheWrite": "<value>",
                "input": "<value>",
                "output": "<value>",
                "total": "<value>"
              },
              "input": "<value>",
              "output": "<value>",
              "totalTokens": "<value>"
            }
          },
          {
            "content": [
              {
                "id": "<id>",
                "ordinal": 0,
                "text": "then follow up",
                "type": "text"
              }
            ],
            "id": "<id>",
            "kind": "message",
            "parentId": "<id>",
            "presentationId": "<id>",
            "role": "user",
            "semantic": {
              "contextEffect": "modelInput",
              "delivery": "stored",
              "direction": "inboundContext",
              "invocationId": "<id>",
              "kind": "resourcePrompt",
              "lifecycle": "completed",
              "operationId": "<id>",
              "origin": {
                "confidence": "boundary",
                "kind": "user"
              },
              "sequence": "<n>",
              "version": 1,
              "visibility": "visible"
            },
            "timestamp": "<timestamp>"
          },
          {
            "content": [
              {
                "id": "<id>",
                "ordinal": 0,
                "text": "Follow-up work acknowledged.",
                "type": "text"
              }
            ],
            "id": "<id>",
            "kind": "message",
            "modelId": "faux-1",
            "parentId": "<id>",
            "presentationId": "<id>",
            "provider": "tron-lock-run-steer",
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
              "sequence": "<n>",
              "version": 1,
              "visibility": "visible"
            },
            "stopReason": "stop",
            "thinkingLevel": "off",
            "timestamp": "<timestamp>",
            "usage": {
              "cacheRead": "<value>",
              "cacheWrite": "<value>",
              "cost": {
                "cacheRead": "<value>",
                "cacheWrite": "<value>",
                "input": "<value>",
                "output": "<value>",
                "total": "<value>"
              },
              "input": "<value>",
              "output": "<value>",
              "totalTokens": "<value>"
            }
          }
        ],
        "leafEntryId": "<id>",
        "runtimeGeneration": "<id>",
        "start": 0,
        "total": 9
      }
    }
  },
  "run-abort": {
    "lock": "run-abort",
    "exchanges": [
      {
        "client": "phone",
        "method": "session.create",
        "params": {
          "commandId": "lock-command-0001",
          "cwd": "<tmp>/workspace"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "sessionId": "<id>"
          }
        }
      },
      {
        "client": "phone",
        "method": "session.open",
        "params": {
          "sessionId": "<id>"
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
                    "id": "<id>",
                    "provider": "tron-lock-run-abort"
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
                  "id": "<id>",
                  "provider": "tron-lock-run-abort"
                },
                "override": 128000,
                "source": "session",
                "warning": "This new session and its context override are not yet saved to disk; they persist after the first user or assistant message."
              },
              "cwd": "<tmp>/workspace",
              "diagnostics": [],
              "eventSequence": "<n>",
              "extensionActivityAsOf": "<timestamp>",
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
                "hostEpoch": "<id>",
                "pendingInteractions": [],
                "revision": "<n>",
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
              "leafEntryId": "<id>",
              "liveActivityRevision": 0,
              "model": {
                "id": "<id>",
                "provider": "tron-lock-run-abort"
              },
              "phase": "idle",
              "processOverview": {
                "activeCount": 0,
                "asOf": "<timestamp>",
                "problemCount": 0,
                "recentCount": 0,
                "revision": "<n>",
                "version": 1,
                "visibility": "hidden"
              },
              "queueRevision": 0,
              "queuedItems": [],
              "revision": "<n>",
              "runtimeGeneration": "<id>",
              "sessionId": "<id>",
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
                  "id": "<id>",
                  "kind": "modelChange",
                  "modelRef": {
                    "id": "<id>",
                    "provider": "tron-lock-run-abort"
                  },
                  "parentId": "<id>",
                  "semantic": {
                    "contextEffect": "none",
                    "delivery": "stored",
                    "direction": "ambientStatus",
                    "kind": "status",
                    "origin": {
                      "confidence": "boundary",
                      "kind": "gateway"
                    },
                    "sequence": "<n>",
                    "version": 1,
                    "visibility": "visible"
                  },
                  "timestamp": "<timestamp>"
                },
                {
                  "id": "<id>",
                  "kind": "thinkingChange",
                  "level": "off",
                  "parentId": "<id>",
                  "semantic": {
                    "contextEffect": "none",
                    "delivery": "stored",
                    "direction": "ambientStatus",
                    "kind": "status",
                    "origin": {
                      "confidence": "boundary",
                      "kind": "gateway"
                    },
                    "sequence": "<n>",
                    "version": 1,
                    "visibility": "visible"
                  },
                  "timestamp": "<timestamp>"
                }
              ],
              "transcriptStart": 0,
              "transcriptTotal": 2
            },
            "subscriptionToken": "<id>",
            "syncToken": "<id>"
          }
        }
      },
      {
        "client": "phone",
        "method": "session.sync",
        "params": {
          "sessionId": "<id>",
          "syncToken": "<id>"
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
        "client": "phone",
        "method": "session.prompt",
        "params": {
          "commandId": "lock-command-0002",
          "sessionId": "<id>",
          "text": "start a turn to abort"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "operationId": "<id>"
          }
        }
      },
      {
        "client": "phone",
        "method": "session.abort",
        "params": {
          "commandId": "lock-command-0003",
          "operationId": "<id>",
          "sessionId": "<id>"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "aborted": true
          }
        }
      },
      {
        "client": "phone",
        "method": "session.transcript",
        "params": {
          "sessionId": "<id>"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "end": 4,
            "items": [
              {
                "id": "<id>",
                "kind": "modelChange",
                "modelRef": {
                  "id": "<id>",
                  "provider": "tron-lock-run-abort"
                },
                "parentId": "<id>",
                "semantic": {
                  "contextEffect": "none",
                  "delivery": "stored",
                  "direction": "ambientStatus",
                  "kind": "status",
                  "origin": {
                    "confidence": "boundary",
                    "kind": "gateway"
                  },
                  "sequence": "<n>",
                  "version": 1,
                  "visibility": "visible"
                },
                "timestamp": "<timestamp>"
              },
              {
                "id": "<id>",
                "kind": "thinkingChange",
                "level": "off",
                "parentId": "<id>",
                "semantic": {
                  "contextEffect": "none",
                  "delivery": "stored",
                  "direction": "ambientStatus",
                  "kind": "status",
                  "origin": {
                    "confidence": "boundary",
                    "kind": "gateway"
                  },
                  "sequence": "<n>",
                  "version": 1,
                  "visibility": "visible"
                },
                "timestamp": "<timestamp>"
              },
              {
                "content": [
                  {
                    "id": "<id>",
                    "ordinal": 0,
                    "text": "start a turn to abort",
                    "type": "text"
                  }
                ],
                "id": "<id>",
                "kind": "message",
                "parentId": "<id>",
                "presentationId": "<id>",
                "role": "user",
                "semantic": {
                  "contextEffect": "modelInput",
                  "delivery": "stored",
                  "direction": "inboundContext",
                  "invocationId": "<id>",
                  "kind": "resourcePrompt",
                  "lifecycle": "interrupted",
                  "operationId": "<id>",
                  "origin": {
                    "confidence": "boundary",
                    "kind": "user"
                  },
                  "sequence": "<n>",
                  "version": 1,
                  "visibility": "visible"
                },
                "timestamp": "<timestamp>"
              },
              {
                "content": [],
                "errorInfo": {
                  "category": "aborted",
                  "message": "Request cancelled",
                  "providerMessage": "Request was aborted"
                },
                "errorMessage": "Request was aborted",
                "id": "<id>",
                "kind": "message",
                "modelId": "faux-1",
                "parentId": "<id>",
                "presentationId": "<id>",
                "provider": "tron-lock-run-abort",
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
                  "sequence": "<n>",
                  "version": 1,
                  "visibility": "visible"
                },
                "stopReason": "aborted",
                "thinkingLevel": "off",
                "timestamp": "<timestamp>",
                "usage": {
                  "cacheRead": "<value>",
                  "cacheWrite": "<value>",
                  "cost": {
                    "cacheRead": "<value>",
                    "cacheWrite": "<value>",
                    "input": "<value>",
                    "output": "<value>",
                    "total": "<value>"
                  },
                  "input": "<value>",
                  "output": "<value>",
                  "totalTokens": "<value>"
                }
              }
            ],
            "leafEntryId": "<id>",
            "runtimeGeneration": "<id>",
            "start": 0,
            "total": 4
          }
        }
      }
    ],
    "providerRequests": [
      {
        "sessionShape": "chat",
        "messages": [
          {
            "role": "user",
            "text": "start a turn to abort"
          }
        ]
      }
    ],
    "canonicalJsonl": [
      {
        "cwd": "<tmp>/workspace",
        "id": "<id>",
        "timestamp": "<timestamp>",
        "type": "session",
        "version": 3
      },
      {
        "id": "<id>",
        "modelId": "faux-1",
        "parentId": "<id>",
        "provider": "tron-lock-run-abort",
        "timestamp": "<timestamp>",
        "type": "model_change"
      },
      {
        "id": "<id>",
        "parentId": "<id>",
        "thinkingLevel": "off",
        "timestamp": "<timestamp>",
        "type": "thinking_level_change"
      },
      {
        "customType": "tron.context-window.v1",
        "data": {
          "contextWindow": 128000,
          "modelId": "faux-1",
          "provider": "tron-lock-run-abort",
          "version": 1
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "customType": "tron.settings.v1",
        "data": {
          "fixed": {
            "context.images.autoResize": {
              "at": "<timestamp>",
              "from": "global",
              "ref": "<id>",
              "value": true
            },
            "model.contextWindow": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "model": "tron-lock-run-abort/faux-1"
              },
              "ref": "<id>",
              "value": 128000
            },
            "model.ref[role=chat]": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "role": "chat"
              },
              "ref": "<id>",
              "value": {
                "id": "<id>",
                "provider": "tron-lock-run-abort"
              }
            },
            "model.thinking[role=chat]": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "model": "tron-lock-run-abort/faux-1",
                "role": "chat"
              },
              "ref": "<id>",
              "value": "off"
            },
            "tools.active": {
              "at": "<timestamp>",
              "from": "global",
              "ref": "<id>",
              "value": [
                "read",
                "bash",
                "edit",
                "write",
                "jev",
                "web_search",
                "settings",
                "projects",
                "ask_user",
                "display",
                "swift_app",
                "computer"
              ]
            }
          },
          "receiptId": "<id>",
          "requestPins": {},
          "settings": {}
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "customType": "tron.settings.v1",
        "data": {
          "fixed": {
            "context.images.autoResize": {
              "at": "<timestamp>",
              "from": "global",
              "ref": "<id>",
              "value": true
            },
            "model.contextWindow": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "model": "tron-lock-run-abort/faux-1"
              },
              "ref": "<id>",
              "value": 128000
            },
            "model.ref[role=chat]": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "role": "chat"
              },
              "ref": "<id>",
              "value": {
                "id": "<id>",
                "provider": "tron-lock-run-abort"
              }
            },
            "model.thinking[role=chat]": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "model": "tron-lock-run-abort/faux-1",
                "role": "chat"
              },
              "ref": "<id>",
              "value": "off"
            },
            "tools.active": {
              "at": "<timestamp>",
              "from": "global",
              "ref": "<id>",
              "value": [
                "read",
                "bash",
                "edit",
                "write",
                "jev",
                "web_search",
                "settings",
                "projects",
                "ask_user",
                "display",
                "swift_app",
                "computer"
              ]
            }
          },
          "receiptId": "<id>",
          "requestPins": {
            "context.images.block": {
              "at": "<timestamp>",
              "from": "global",
              "ref": "<id>",
              "value": false
            }
          },
          "settings": {}
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "customType": "tron.chat-invocation.v1",
        "data": {
          "createdAt": "<timestamp>",
          "invocationId": "<id>",
          "lifecycle": "staged",
          "operationId": "<id>",
          "origin": {
            "confidence": "boundary",
            "kind": "user"
          },
          "receiptId": "<id>",
          "receiptKind": "start",
          "sequence": "<n>",
          "sessionId": "<id>",
          "source": "plain",
          "version": 1,
          "writer": "gateway"
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "customType": "tron.chat-invocation.v1",
        "data": {
          "createdAt": "<timestamp>",
          "invocationId": "<id>",
          "lifecycle": "accepted",
          "operationId": "<id>",
          "receiptId": "<id>",
          "receiptKind": "transition",
          "sequence": "<n>",
          "sessionId": "<id>",
          "source": "plain",
          "version": 1,
          "writer": "gateway"
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "id": "<id>",
        "message": {
          "content": "",
          "role": "system",
          "timestamp": "<timestamp>",
          "sections": {
            "cwd": "<cwd>\n<tmp>/workspace\n</cwd>",
            "sessionShape": "chat#0"
          }
        },
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "message"
      },
      {
        "id": "<id>",
        "message": {
          "content": [
            {
              "text": "start a turn to abort",
              "type": "text"
            }
          ],
          "role": "user",
          "timestamp": "<timestamp>"
        },
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "message"
      },
      {
        "customType": "tron.chat-invocation.v1",
        "data": {
          "canonicalEntryId": "<id>",
          "createdAt": "<timestamp>",
          "invocationId": "<id>",
          "operationId": "<id>",
          "receiptId": "<id>",
          "receiptKind": "binding",
          "sequence": "<n>",
          "sessionId": "<id>",
          "source": "plain",
          "version": 1,
          "writer": "gateway"
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "id": "<id>",
        "message": {
          "api": "<api>",
          "content": [],
          "durationMs": "<duration>",
          "errorMessage": "Request was aborted",
          "model": "faux-1",
          "provider": "tron-lock-run-abort",
          "role": "assistant",
          "stopReason": "aborted",
          "thinkingLevel": "off",
          "timestamp": "<timestamp>",
          "usage": {
            "cacheRead": "<value>",
            "cacheWrite": "<value>",
            "cost": {
              "cacheRead": "<value>",
              "cacheWrite": "<value>",
              "input": "<value>",
              "output": "<value>",
              "total": "<value>"
            },
            "input": "<value>",
            "output": "<value>",
            "totalTokens": "<value>"
          }
        },
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "message"
      },
      {
        "customType": "tron.chat-invocation.v1",
        "data": {
          "createdAt": "<timestamp>",
          "errorCode": "user-abort",
          "invocationId": "<id>",
          "lifecycle": "interrupted",
          "operationId": "<id>",
          "origin": {
            "confidence": "boundary",
            "kind": "user"
          },
          "receiptId": "<id>",
          "receiptKind": "terminal",
          "sequence": "<n>",
          "sessionId": "<id>",
          "source": "plain",
          "version": 1,
          "writer": "gateway"
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      }
    ],
    "transcript": {
      "error": null,
      "ok": true,
      "result": {
        "end": 4,
        "items": [
          {
            "id": "<id>",
            "kind": "modelChange",
            "modelRef": {
              "id": "<id>",
              "provider": "tron-lock-run-abort"
            },
            "parentId": "<id>",
            "semantic": {
              "contextEffect": "none",
              "delivery": "stored",
              "direction": "ambientStatus",
              "kind": "status",
              "origin": {
                "confidence": "boundary",
                "kind": "gateway"
              },
              "sequence": "<n>",
              "version": 1,
              "visibility": "visible"
            },
            "timestamp": "<timestamp>"
          },
          {
            "id": "<id>",
            "kind": "thinkingChange",
            "level": "off",
            "parentId": "<id>",
            "semantic": {
              "contextEffect": "none",
              "delivery": "stored",
              "direction": "ambientStatus",
              "kind": "status",
              "origin": {
                "confidence": "boundary",
                "kind": "gateway"
              },
              "sequence": "<n>",
              "version": 1,
              "visibility": "visible"
            },
            "timestamp": "<timestamp>"
          },
          {
            "content": [
              {
                "id": "<id>",
                "ordinal": 0,
                "text": "start a turn to abort",
                "type": "text"
              }
            ],
            "id": "<id>",
            "kind": "message",
            "parentId": "<id>",
            "presentationId": "<id>",
            "role": "user",
            "semantic": {
              "contextEffect": "modelInput",
              "delivery": "stored",
              "direction": "inboundContext",
              "invocationId": "<id>",
              "kind": "resourcePrompt",
              "lifecycle": "interrupted",
              "operationId": "<id>",
              "origin": {
                "confidence": "boundary",
                "kind": "user"
              },
              "sequence": "<n>",
              "version": 1,
              "visibility": "visible"
            },
            "timestamp": "<timestamp>"
          },
          {
            "content": [],
            "errorInfo": {
              "category": "aborted",
              "message": "Request cancelled",
              "providerMessage": "Request was aborted"
            },
            "errorMessage": "Request was aborted",
            "id": "<id>",
            "kind": "message",
            "modelId": "faux-1",
            "parentId": "<id>",
            "presentationId": "<id>",
            "provider": "tron-lock-run-abort",
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
              "sequence": "<n>",
              "version": 1,
              "visibility": "visible"
            },
            "stopReason": "aborted",
            "thinkingLevel": "off",
            "timestamp": "<timestamp>",
            "usage": {
              "cacheRead": "<value>",
              "cacheWrite": "<value>",
              "cost": {
                "cacheRead": "<value>",
                "cacheWrite": "<value>",
                "input": "<value>",
                "output": "<value>",
                "total": "<value>"
              },
              "input": "<value>",
              "output": "<value>",
              "totalTokens": "<value>"
            }
          }
        ],
        "leafEntryId": "<id>",
        "runtimeGeneration": "<id>",
        "start": 0,
        "total": 4
      }
    }
  },
  "run-compaction": {
    "lock": "run-compaction",
    "exchanges": [
      {
        "client": "phone",
        "method": "session.create",
        "params": {
          "commandId": "lock-command-0001",
          "cwd": "<tmp>/workspace"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "sessionId": "<id>"
          }
        }
      },
      {
        "client": "phone",
        "method": "session.open",
        "params": {
          "sessionId": "<id>"
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
                    "id": "<id>",
                    "provider": "tron-lock-run-compaction"
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
                  "id": "<id>",
                  "provider": "tron-lock-run-compaction"
                },
                "override": 128000,
                "source": "session",
                "warning": "This new session and its context override are not yet saved to disk; they persist after the first user or assistant message."
              },
              "cwd": "<tmp>/workspace",
              "diagnostics": [],
              "eventSequence": "<n>",
              "extensionActivityAsOf": "<timestamp>",
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
                "hostEpoch": "<id>",
                "pendingInteractions": [],
                "revision": "<n>",
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
              "leafEntryId": "<id>",
              "liveActivityRevision": 0,
              "model": {
                "id": "<id>",
                "provider": "tron-lock-run-compaction"
              },
              "phase": "idle",
              "processOverview": {
                "activeCount": 0,
                "asOf": "<timestamp>",
                "problemCount": 0,
                "recentCount": 0,
                "revision": "<n>",
                "version": 1,
                "visibility": "hidden"
              },
              "queueRevision": 0,
              "queuedItems": [],
              "revision": "<n>",
              "runtimeGeneration": "<id>",
              "sessionId": "<id>",
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
                  "id": "<id>",
                  "kind": "modelChange",
                  "modelRef": {
                    "id": "<id>",
                    "provider": "tron-lock-run-compaction"
                  },
                  "parentId": "<id>",
                  "semantic": {
                    "contextEffect": "none",
                    "delivery": "stored",
                    "direction": "ambientStatus",
                    "kind": "status",
                    "origin": {
                      "confidence": "boundary",
                      "kind": "gateway"
                    },
                    "sequence": "<n>",
                    "version": 1,
                    "visibility": "visible"
                  },
                  "timestamp": "<timestamp>"
                },
                {
                  "id": "<id>",
                  "kind": "thinkingChange",
                  "level": "off",
                  "parentId": "<id>",
                  "semantic": {
                    "contextEffect": "none",
                    "delivery": "stored",
                    "direction": "ambientStatus",
                    "kind": "status",
                    "origin": {
                      "confidence": "boundary",
                      "kind": "gateway"
                    },
                    "sequence": "<n>",
                    "version": 1,
                    "visibility": "visible"
                  },
                  "timestamp": "<timestamp>"
                }
              ],
              "transcriptStart": 0,
              "transcriptTotal": 2
            },
            "subscriptionToken": "<id>",
            "syncToken": "<id>"
          }
        }
      },
      {
        "client": "phone",
        "method": "session.sync",
        "params": {
          "sessionId": "<id>",
          "syncToken": "<id>"
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
        "client": "phone",
        "method": "session.prompt",
        "params": {
          "commandId": "lock-command-0002",
          "sessionId": "<id>",
          "text": "first question"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "operationId": "<id>"
          }
        }
      },
      {
        "client": "phone",
        "method": "session.prompt",
        "params": {
          "commandId": "lock-command-0003",
          "sessionId": "<id>",
          "text": "second question"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "operationId": "<id>"
          }
        }
      },
      {
        "client": "phone",
        "method": "session.compact",
        "params": {
          "commandId": "lock-command-0004",
          "sessionId": "<id>"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "compacted": true,
            "queued": false
          }
        }
      },
      {
        "client": "phone",
        "method": "session.transcript",
        "params": {
          "sessionId": "<id>"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "end": 7,
            "items": [
              {
                "id": "<id>",
                "kind": "modelChange",
                "modelRef": {
                  "id": "<id>",
                  "provider": "tron-lock-run-compaction"
                },
                "parentId": "<id>",
                "semantic": {
                  "contextEffect": "none",
                  "delivery": "stored",
                  "direction": "ambientStatus",
                  "kind": "status",
                  "origin": {
                    "confidence": "boundary",
                    "kind": "gateway"
                  },
                  "sequence": "<n>",
                  "version": 1,
                  "visibility": "visible"
                },
                "timestamp": "<timestamp>"
              },
              {
                "id": "<id>",
                "kind": "thinkingChange",
                "level": "off",
                "parentId": "<id>",
                "semantic": {
                  "contextEffect": "none",
                  "delivery": "stored",
                  "direction": "ambientStatus",
                  "kind": "status",
                  "origin": {
                    "confidence": "boundary",
                    "kind": "gateway"
                  },
                  "sequence": "<n>",
                  "version": 1,
                  "visibility": "visible"
                },
                "timestamp": "<timestamp>"
              },
              {
                "content": [
                  {
                    "id": "<id>",
                    "ordinal": 0,
                    "text": "first question",
                    "type": "text"
                  }
                ],
                "id": "<id>",
                "kind": "message",
                "parentId": "<id>",
                "presentationId": "<id>",
                "role": "user",
                "semantic": {
                  "contextEffect": "modelInput",
                  "delivery": "stored",
                  "direction": "inboundContext",
                  "invocationId": "<id>",
                  "kind": "resourcePrompt",
                  "lifecycle": "completed",
                  "operationId": "<id>",
                  "origin": {
                    "confidence": "boundary",
                    "kind": "user"
                  },
                  "sequence": "<n>",
                  "version": 1,
                  "visibility": "visible"
                },
                "timestamp": "<timestamp>"
              },
              {
                "content": [
                  {
                    "id": "<id>",
                    "ordinal": 0,
                    "text": "First answer. lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context ",
                    "type": "text"
                  }
                ],
                "id": "<id>",
                "kind": "message",
                "modelId": "faux-1",
                "parentId": "<id>",
                "presentationId": "<id>",
                "provider": "tron-lock-run-compaction",
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
                  "sequence": "<n>",
                  "version": 1,
                  "visibility": "visible"
                },
                "stopReason": "stop",
                "thinkingLevel": "off",
                "timestamp": "<timestamp>",
                "usage": {
                  "cacheRead": "<value>",
                  "cacheWrite": "<value>",
                  "cost": {
                    "cacheRead": "<value>",
                    "cacheWrite": "<value>",
                    "input": "<value>",
                    "output": "<value>",
                    "total": "<value>"
                  },
                  "input": "<value>",
                  "output": "<value>",
                  "totalTokens": "<value>"
                }
              },
              {
                "content": [
                  {
                    "id": "<id>",
                    "ordinal": 0,
                    "text": "second question",
                    "type": "text"
                  }
                ],
                "id": "<id>",
                "kind": "message",
                "parentId": "<id>",
                "presentationId": "<id>",
                "role": "user",
                "semantic": {
                  "contextEffect": "modelInput",
                  "delivery": "stored",
                  "direction": "inboundContext",
                  "invocationId": "<id>",
                  "kind": "resourcePrompt",
                  "lifecycle": "completed",
                  "operationId": "<id>",
                  "origin": {
                    "confidence": "boundary",
                    "kind": "user"
                  },
                  "sequence": "<n>",
                  "version": 1,
                  "visibility": "visible"
                },
                "timestamp": "<timestamp>"
              },
              {
                "content": [
                  {
                    "id": "<id>",
                    "ordinal": 0,
                    "text": "Second answer. lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context ",
                    "type": "text"
                  }
                ],
                "id": "<id>",
                "kind": "message",
                "modelId": "faux-1",
                "parentId": "<id>",
                "presentationId": "<id>",
                "provider": "tron-lock-run-compaction",
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
                  "sequence": "<n>",
                  "version": 1,
                  "visibility": "visible"
                },
                "stopReason": "stop",
                "thinkingLevel": "off",
                "timestamp": "<timestamp>",
                "usage": {
                  "cacheRead": "<value>",
                  "cacheWrite": "<value>",
                  "cost": {
                    "cacheRead": "<value>",
                    "cacheWrite": "<value>",
                    "input": "<value>",
                    "output": "<value>",
                    "total": "<value>"
                  },
                  "input": "<value>",
                  "output": "<value>",
                  "totalTokens": "<value>"
                }
              },
              {
                "details": {
                  "modifiedFiles": [],
                  "readFiles": []
                },
                "fromHook": false,
                "id": "<id>",
                "kind": "compaction",
                "parentId": "<id>",
                "presentationId": "<id>",
                "semantic": {
                  "contextEffect": "none",
                  "delivery": "stored",
                  "direction": "ambientStatus",
                  "kind": "status",
                  "origin": {
                    "confidence": "boundary",
                    "kind": "gateway"
                  },
                  "sequence": "<n>",
                  "version": 1,
                  "visibility": "visible"
                },
                "summary": "Summary: two answered turns about the lock context.\n\n---\n\n**Turn Context (split turn):**\n\nTurn prefix: the second question.",
                "timestamp": "<timestamp>",
                "tokensBefore": "<value>",
                "usage": {
                  "cacheRead": "<value>",
                  "cacheWrite": "<value>",
                  "cost": {
                    "cacheRead": "<value>",
                    "cacheWrite": "<value>",
                    "input": "<value>",
                    "output": "<value>",
                    "total": "<value>"
                  },
                  "input": "<value>",
                  "output": "<value>",
                  "totalTokens": "<value>"
                }
              }
            ],
            "leafEntryId": "<id>",
            "runtimeGeneration": "<id>",
            "start": 0,
            "total": 7
          }
        }
      }
    ],
    "providerRequests": [
      {
        "sessionShape": "chat",
        "messages": [
          {
            "role": "user",
            "text": "first question"
          }
        ]
      },
      {
        "sessionShape": "chat",
        "messages": [
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
        ]
      },
      {
        "sessionShape": "compactionSummary",
        "messages": [
          {
            "role": "user",
            "text": "<conversation>\n[User]: first question\n\n[Assistant]: First answer. lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context \n</conversation>\n\nThe messages above are a conversation to summarize. Create a structured context checkpoint summary that another LLM will use to continue the work.\n\nUse this EXACT format:\n\n## Goal\n[What is the user trying to accomplish? Can be multiple items if the session covers different tasks.]\n\n## Constraints & Preferences\n- [Any constraints, preferences, or requirements mentioned by user]\n- [Or \"(none)\" if none were mentioned]\n\n## Progress\n### Done\n- [x] [Completed tasks/changes]\n\n### In Progress\n- [ ] [Current work]\n\n### Blocked\n- [Issues preventing progress, if any]\n\n## Key Decisions\n- **[Decision]**: [Brief rationale]\n\n## Next Steps\n1. [Ordered list of what should happen next]\n\n## Critical Context\n- [Any data, examples, or references needed to continue]\n- [Or \"(none)\" if not applicable]\n\nKeep each section concise. Preserve exact file paths, function names, and error messages."
          }
        ]
      },
      {
        "sessionShape": "compactionSummary",
        "messages": [
          {
            "role": "user",
            "text": "# Conversation\n[User]: second question\n\n# Instructions\nThe messages above are earlier context from an ongoing conversation. Later messages are stored separately and do not need to be reconstructed.\n\nCreate a concise checkpoint of the user's request and the progress shown above. This checkpoint will be placed before the later messages so the conversation can continue with the necessary context.\n\n## Original Request\n[What did the user ask for?]\n\n## Progress So Far\n- [Key decisions and work completed in these messages]\n\n## Context Needed to Continue\n- [Information from these messages needed to understand the later work]\n\nOnly summarize information explicitly present above. Do not infer or recreate later messages."
          }
        ]
      }
    ],
    "canonicalJsonl": [
      {
        "cwd": "<tmp>/workspace",
        "id": "<id>",
        "timestamp": "<timestamp>",
        "type": "session",
        "version": 3
      },
      {
        "id": "<id>",
        "modelId": "faux-1",
        "parentId": "<id>",
        "provider": "tron-lock-run-compaction",
        "timestamp": "<timestamp>",
        "type": "model_change"
      },
      {
        "id": "<id>",
        "parentId": "<id>",
        "thinkingLevel": "off",
        "timestamp": "<timestamp>",
        "type": "thinking_level_change"
      },
      {
        "customType": "tron.context-window.v1",
        "data": {
          "contextWindow": 128000,
          "modelId": "faux-1",
          "provider": "tron-lock-run-compaction",
          "version": 1
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "customType": "tron.settings.v1",
        "data": {
          "fixed": {
            "context.images.autoResize": {
              "at": "<timestamp>",
              "from": "global",
              "ref": "<id>",
              "value": true
            },
            "model.contextWindow": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "model": "tron-lock-run-compaction/faux-1"
              },
              "ref": "<id>",
              "value": 128000
            },
            "model.ref[role=chat]": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "role": "chat"
              },
              "ref": "<id>",
              "value": {
                "id": "<id>",
                "provider": "tron-lock-run-compaction"
              }
            },
            "model.thinking[role=chat]": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "model": "tron-lock-run-compaction/faux-1",
                "role": "chat"
              },
              "ref": "<id>",
              "value": "off"
            },
            "tools.active": {
              "at": "<timestamp>",
              "from": "global",
              "ref": "<id>",
              "value": [
                "read",
                "bash",
                "edit",
                "write",
                "jev",
                "web_search",
                "settings",
                "projects",
                "ask_user",
                "display",
                "swift_app",
                "computer"
              ]
            }
          },
          "receiptId": "<id>",
          "requestPins": {},
          "settings": {}
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "customType": "tron.settings.v1",
        "data": {
          "fixed": {
            "context.images.autoResize": {
              "at": "<timestamp>",
              "from": "global",
              "ref": "<id>",
              "value": true
            },
            "model.contextWindow": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "model": "tron-lock-run-compaction/faux-1"
              },
              "ref": "<id>",
              "value": 128000
            },
            "model.ref[role=chat]": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "role": "chat"
              },
              "ref": "<id>",
              "value": {
                "id": "<id>",
                "provider": "tron-lock-run-compaction"
              }
            },
            "model.thinking[role=chat]": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "model": "tron-lock-run-compaction/faux-1",
                "role": "chat"
              },
              "ref": "<id>",
              "value": "off"
            },
            "tools.active": {
              "at": "<timestamp>",
              "from": "global",
              "ref": "<id>",
              "value": [
                "read",
                "bash",
                "edit",
                "write",
                "jev",
                "web_search",
                "settings",
                "projects",
                "ask_user",
                "display",
                "swift_app",
                "computer"
              ]
            }
          },
          "receiptId": "<id>",
          "requestPins": {
            "context.images.block": {
              "at": "<timestamp>",
              "from": "global",
              "ref": "<id>",
              "value": false
            }
          },
          "settings": {}
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "customType": "tron.chat-invocation.v1",
        "data": {
          "createdAt": "<timestamp>",
          "invocationId": "<id>",
          "lifecycle": "staged",
          "operationId": "<id>",
          "origin": {
            "confidence": "boundary",
            "kind": "user"
          },
          "receiptId": "<id>",
          "receiptKind": "start",
          "sequence": "<n>",
          "sessionId": "<id>",
          "source": "plain",
          "version": 1,
          "writer": "gateway"
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "customType": "tron.chat-invocation.v1",
        "data": {
          "createdAt": "<timestamp>",
          "invocationId": "<id>",
          "lifecycle": "accepted",
          "operationId": "<id>",
          "receiptId": "<id>",
          "receiptKind": "transition",
          "sequence": "<n>",
          "sessionId": "<id>",
          "source": "plain",
          "version": 1,
          "writer": "gateway"
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "id": "<id>",
        "message": {
          "content": "",
          "role": "system",
          "timestamp": "<timestamp>",
          "sections": {
            "cwd": "<cwd>\n<tmp>/workspace\n</cwd>",
            "sessionShape": "chat#0"
          }
        },
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "message"
      },
      {
        "id": "<id>",
        "message": {
          "content": [
            {
              "text": "first question",
              "type": "text"
            }
          ],
          "role": "user",
          "timestamp": "<timestamp>"
        },
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "message"
      },
      {
        "customType": "tron.chat-invocation.v1",
        "data": {
          "canonicalEntryId": "<id>",
          "createdAt": "<timestamp>",
          "invocationId": "<id>",
          "operationId": "<id>",
          "receiptId": "<id>",
          "receiptKind": "binding",
          "sequence": "<n>",
          "sessionId": "<id>",
          "source": "plain",
          "version": 1,
          "writer": "gateway"
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "id": "<id>",
        "message": {
          "api": "<api>",
          "content": [
            {
              "text": "First answer. lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context ",
              "type": "text"
            }
          ],
          "durationMs": "<duration>",
          "model": "faux-1",
          "provider": "tron-lock-run-compaction",
          "role": "assistant",
          "stopReason": "stop",
          "thinkingLevel": "off",
          "timestamp": "<timestamp>",
          "usage": {
            "cacheRead": "<value>",
            "cacheWrite": "<value>",
            "cost": {
              "cacheRead": "<value>",
              "cacheWrite": "<value>",
              "input": "<value>",
              "output": "<value>",
              "total": "<value>"
            },
            "input": "<value>",
            "output": "<value>",
            "totalTokens": "<value>"
          }
        },
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "message"
      },
      {
        "customType": "tron.chat-invocation.v1",
        "data": {
          "createdAt": "<timestamp>",
          "invocationId": "<id>",
          "lifecycle": "completed",
          "operationId": "<id>",
          "origin": {
            "confidence": "boundary",
            "kind": "user"
          },
          "receiptId": "<id>",
          "receiptKind": "terminal",
          "sequence": "<n>",
          "sessionId": "<id>",
          "source": "plain",
          "version": 1,
          "writer": "gateway"
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "customType": "tron.chat-invocation.v1",
        "data": {
          "createdAt": "<timestamp>",
          "invocationId": "<id>",
          "lifecycle": "staged",
          "operationId": "<id>",
          "origin": {
            "confidence": "boundary",
            "kind": "user"
          },
          "receiptId": "<id>",
          "receiptKind": "start",
          "sequence": "<n>",
          "sessionId": "<id>",
          "source": "plain",
          "version": 1,
          "writer": "gateway"
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "customType": "tron.chat-invocation.v1",
        "data": {
          "createdAt": "<timestamp>",
          "invocationId": "<id>",
          "lifecycle": "accepted",
          "operationId": "<id>",
          "receiptId": "<id>",
          "receiptKind": "transition",
          "sequence": "<n>",
          "sessionId": "<id>",
          "source": "plain",
          "version": 1,
          "writer": "gateway"
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "id": "<id>",
        "message": {
          "content": [
            {
              "text": "second question",
              "type": "text"
            }
          ],
          "role": "user",
          "timestamp": "<timestamp>"
        },
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "message"
      },
      {
        "customType": "tron.chat-invocation.v1",
        "data": {
          "canonicalEntryId": "<id>",
          "createdAt": "<timestamp>",
          "invocationId": "<id>",
          "operationId": "<id>",
          "receiptId": "<id>",
          "receiptKind": "binding",
          "sequence": "<n>",
          "sessionId": "<id>",
          "source": "plain",
          "version": 1,
          "writer": "gateway"
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "id": "<id>",
        "message": {
          "api": "<api>",
          "content": [
            {
              "text": "Second answer. lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context ",
              "type": "text"
            }
          ],
          "durationMs": "<duration>",
          "model": "faux-1",
          "provider": "tron-lock-run-compaction",
          "role": "assistant",
          "stopReason": "stop",
          "thinkingLevel": "off",
          "timestamp": "<timestamp>",
          "usage": {
            "cacheRead": "<value>",
            "cacheWrite": "<value>",
            "cost": {
              "cacheRead": "<value>",
              "cacheWrite": "<value>",
              "input": "<value>",
              "output": "<value>",
              "total": "<value>"
            },
            "input": "<value>",
            "output": "<value>",
            "totalTokens": "<value>"
          }
        },
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "message"
      },
      {
        "customType": "tron.chat-invocation.v1",
        "data": {
          "createdAt": "<timestamp>",
          "invocationId": "<id>",
          "lifecycle": "completed",
          "operationId": "<id>",
          "origin": {
            "confidence": "boundary",
            "kind": "user"
          },
          "receiptId": "<id>",
          "receiptKind": "terminal",
          "sequence": "<n>",
          "sessionId": "<id>",
          "source": "plain",
          "version": 1,
          "writer": "gateway"
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "details": {
          "modifiedFiles": [],
          "readFiles": []
        },
        "firstKeptEntryId": "<id>",
        "fromHook": false,
        "id": "<id>",
        "parentId": "<id>",
        "summary": "Summary: two answered turns about the lock context.\n\n---\n\n**Turn Context (split turn):**\n\nTurn prefix: the second question.",
        "systemMessage": {
          "contentChars": 0,
          "sectionNames": [
            "cwd",
            "docs",
            "preamble",
            "rules",
            "tools"
          ],
          "toolsAdded": [
            "read",
            "bash",
            "edit",
            "write",
            "jev",
            "web_search",
            "settings",
            "projects",
            "ask_user",
            "display",
            "swift_app",
            "computer"
          ]
        },
        "timestamp": "<timestamp>",
        "tokensBefore": "<value>",
        "type": "compaction",
        "usage": {
          "cacheRead": "<value>",
          "cacheWrite": "<value>",
          "cost": {
            "cacheRead": "<value>",
            "cacheWrite": "<value>",
            "input": "<value>",
            "output": "<value>",
            "total": "<value>"
          },
          "input": "<value>",
          "output": "<value>",
          "totalTokens": "<value>"
        }
      }
    ],
    "transcript": {
      "error": null,
      "ok": true,
      "result": {
        "end": 7,
        "items": [
          {
            "id": "<id>",
            "kind": "modelChange",
            "modelRef": {
              "id": "<id>",
              "provider": "tron-lock-run-compaction"
            },
            "parentId": "<id>",
            "semantic": {
              "contextEffect": "none",
              "delivery": "stored",
              "direction": "ambientStatus",
              "kind": "status",
              "origin": {
                "confidence": "boundary",
                "kind": "gateway"
              },
              "sequence": "<n>",
              "version": 1,
              "visibility": "visible"
            },
            "timestamp": "<timestamp>"
          },
          {
            "id": "<id>",
            "kind": "thinkingChange",
            "level": "off",
            "parentId": "<id>",
            "semantic": {
              "contextEffect": "none",
              "delivery": "stored",
              "direction": "ambientStatus",
              "kind": "status",
              "origin": {
                "confidence": "boundary",
                "kind": "gateway"
              },
              "sequence": "<n>",
              "version": 1,
              "visibility": "visible"
            },
            "timestamp": "<timestamp>"
          },
          {
            "content": [
              {
                "id": "<id>",
                "ordinal": 0,
                "text": "first question",
                "type": "text"
              }
            ],
            "id": "<id>",
            "kind": "message",
            "parentId": "<id>",
            "presentationId": "<id>",
            "role": "user",
            "semantic": {
              "contextEffect": "modelInput",
              "delivery": "stored",
              "direction": "inboundContext",
              "invocationId": "<id>",
              "kind": "resourcePrompt",
              "lifecycle": "completed",
              "operationId": "<id>",
              "origin": {
                "confidence": "boundary",
                "kind": "user"
              },
              "sequence": "<n>",
              "version": 1,
              "visibility": "visible"
            },
            "timestamp": "<timestamp>"
          },
          {
            "content": [
              {
                "id": "<id>",
                "ordinal": 0,
                "text": "First answer. lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context ",
                "type": "text"
              }
            ],
            "id": "<id>",
            "kind": "message",
            "modelId": "faux-1",
            "parentId": "<id>",
            "presentationId": "<id>",
            "provider": "tron-lock-run-compaction",
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
              "sequence": "<n>",
              "version": 1,
              "visibility": "visible"
            },
            "stopReason": "stop",
            "thinkingLevel": "off",
            "timestamp": "<timestamp>",
            "usage": {
              "cacheRead": "<value>",
              "cacheWrite": "<value>",
              "cost": {
                "cacheRead": "<value>",
                "cacheWrite": "<value>",
                "input": "<value>",
                "output": "<value>",
                "total": "<value>"
              },
              "input": "<value>",
              "output": "<value>",
              "totalTokens": "<value>"
            }
          },
          {
            "content": [
              {
                "id": "<id>",
                "ordinal": 0,
                "text": "second question",
                "type": "text"
              }
            ],
            "id": "<id>",
            "kind": "message",
            "parentId": "<id>",
            "presentationId": "<id>",
            "role": "user",
            "semantic": {
              "contextEffect": "modelInput",
              "delivery": "stored",
              "direction": "inboundContext",
              "invocationId": "<id>",
              "kind": "resourcePrompt",
              "lifecycle": "completed",
              "operationId": "<id>",
              "origin": {
                "confidence": "boundary",
                "kind": "user"
              },
              "sequence": "<n>",
              "version": 1,
              "visibility": "visible"
            },
            "timestamp": "<timestamp>"
          },
          {
            "content": [
              {
                "id": "<id>",
                "ordinal": 0,
                "text": "Second answer. lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context lock context ",
                "type": "text"
              }
            ],
            "id": "<id>",
            "kind": "message",
            "modelId": "faux-1",
            "parentId": "<id>",
            "presentationId": "<id>",
            "provider": "tron-lock-run-compaction",
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
              "sequence": "<n>",
              "version": 1,
              "visibility": "visible"
            },
            "stopReason": "stop",
            "thinkingLevel": "off",
            "timestamp": "<timestamp>",
            "usage": {
              "cacheRead": "<value>",
              "cacheWrite": "<value>",
              "cost": {
                "cacheRead": "<value>",
                "cacheWrite": "<value>",
                "input": "<value>",
                "output": "<value>",
                "total": "<value>"
              },
              "input": "<value>",
              "output": "<value>",
              "totalTokens": "<value>"
            }
          },
          {
            "details": {
              "modifiedFiles": [],
              "readFiles": []
            },
            "fromHook": false,
            "id": "<id>",
            "kind": "compaction",
            "parentId": "<id>",
            "presentationId": "<id>",
            "semantic": {
              "contextEffect": "none",
              "delivery": "stored",
              "direction": "ambientStatus",
              "kind": "status",
              "origin": {
                "confidence": "boundary",
                "kind": "gateway"
              },
              "sequence": "<n>",
              "version": 1,
              "visibility": "visible"
            },
            "summary": "Summary: two answered turns about the lock context.\n\n---\n\n**Turn Context (split turn):**\n\nTurn prefix: the second question.",
            "timestamp": "<timestamp>",
            "tokensBefore": "<value>",
            "usage": {
              "cacheRead": "<value>",
              "cacheWrite": "<value>",
              "cost": {
                "cacheRead": "<value>",
                "cacheWrite": "<value>",
                "input": "<value>",
                "output": "<value>",
                "total": "<value>"
              },
              "input": "<value>",
              "output": "<value>",
              "totalTokens": "<value>"
            }
          }
        ],
        "leafEntryId": "<id>",
        "runtimeGeneration": "<id>",
        "start": 0,
        "total": 7
      }
    }
  },
  "run-extension-ui": {
    "lock": "run-extension-ui",
    "exchanges": [
      {
        "client": "phone",
        "method": "session.create",
        "params": {
          "commandId": "lock-command-0001",
          "cwd": "<tmp>/workspace"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "sessionId": "<id>"
          }
        }
      },
      {
        "client": "phone",
        "method": "session.open",
        "params": {
          "sessionId": "<id>"
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
                    "id": "<id>",
                    "provider": "tron-lock-run-extension-ui"
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
                  "id": "<id>",
                  "provider": "tron-lock-run-extension-ui"
                },
                "override": 128000,
                "source": "session",
                "warning": "This new session and its context override are not yet saved to disk; they persist after the first user or assistant message."
              },
              "cwd": "<tmp>/workspace",
              "diagnostics": [],
              "eventSequence": "<n>",
              "extensionActivityAsOf": "<timestamp>",
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
                "hostEpoch": "<id>",
                "pendingInteractions": [],
                "revision": "<n>",
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
              "leafEntryId": "<id>",
              "liveActivityRevision": 0,
              "model": {
                "id": "<id>",
                "provider": "tron-lock-run-extension-ui"
              },
              "phase": "idle",
              "processOverview": {
                "activeCount": 0,
                "asOf": "<timestamp>",
                "problemCount": 0,
                "recentCount": 0,
                "revision": "<n>",
                "version": 1,
                "visibility": "hidden"
              },
              "queueRevision": 0,
              "queuedItems": [],
              "revision": "<n>",
              "runtimeGeneration": "<id>",
              "sessionId": "<id>",
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
                  "id": "<id>",
                  "kind": "modelChange",
                  "modelRef": {
                    "id": "<id>",
                    "provider": "tron-lock-run-extension-ui"
                  },
                  "parentId": "<id>",
                  "semantic": {
                    "contextEffect": "none",
                    "delivery": "stored",
                    "direction": "ambientStatus",
                    "kind": "status",
                    "origin": {
                      "confidence": "boundary",
                      "kind": "gateway"
                    },
                    "sequence": "<n>",
                    "version": 1,
                    "visibility": "visible"
                  },
                  "timestamp": "<timestamp>"
                },
                {
                  "id": "<id>",
                  "kind": "thinkingChange",
                  "level": "off",
                  "parentId": "<id>",
                  "semantic": {
                    "contextEffect": "none",
                    "delivery": "stored",
                    "direction": "ambientStatus",
                    "kind": "status",
                    "origin": {
                      "confidence": "boundary",
                      "kind": "gateway"
                    },
                    "sequence": "<n>",
                    "version": 1,
                    "visibility": "visible"
                  },
                  "timestamp": "<timestamp>"
                }
              ],
              "transcriptStart": 0,
              "transcriptTotal": 2
            },
            "subscriptionToken": "<id>",
            "syncToken": "<id>"
          }
        }
      },
      {
        "client": "phone",
        "method": "session.sync",
        "params": {
          "sessionId": "<id>",
          "syncToken": "<id>"
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
        "client": "phone",
        "method": "session.prompt",
        "params": {
          "commandId": "lock-command-0002",
          "sessionId": "<id>",
          "text": "ask me which path"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "operationId": "<id>"
          }
        }
      },
      {
        "client": "phone",
        "method": "extension.respond",
        "params": {
          "commandId": "lock-command-0003",
          "hostEpoch": "<id>",
          "interactionId": "<id>",
          "presentationRevision": 1,
          "sessionId": "<id>",
          "value": "Keep"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "answered": true
          }
        }
      },
      {
        "client": "phone",
        "method": "session.transcript",
        "params": {
          "sessionId": "<id>"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "end": 6,
            "items": [
              {
                "id": "<id>",
                "kind": "modelChange",
                "modelRef": {
                  "id": "<id>",
                  "provider": "tron-lock-run-extension-ui"
                },
                "parentId": "<id>",
                "semantic": {
                  "contextEffect": "none",
                  "delivery": "stored",
                  "direction": "ambientStatus",
                  "kind": "status",
                  "origin": {
                    "confidence": "boundary",
                    "kind": "gateway"
                  },
                  "sequence": "<n>",
                  "version": 1,
                  "visibility": "visible"
                },
                "timestamp": "<timestamp>"
              },
              {
                "id": "<id>",
                "kind": "thinkingChange",
                "level": "off",
                "parentId": "<id>",
                "semantic": {
                  "contextEffect": "none",
                  "delivery": "stored",
                  "direction": "ambientStatus",
                  "kind": "status",
                  "origin": {
                    "confidence": "boundary",
                    "kind": "gateway"
                  },
                  "sequence": "<n>",
                  "version": 1,
                  "visibility": "visible"
                },
                "timestamp": "<timestamp>"
              },
              {
                "content": [
                  {
                    "id": "<id>",
                    "ordinal": 0,
                    "text": "ask me which path",
                    "type": "text"
                  }
                ],
                "id": "<id>",
                "kind": "message",
                "parentId": "<id>",
                "presentationId": "<id>",
                "role": "user",
                "semantic": {
                  "contextEffect": "modelInput",
                  "delivery": "stored",
                  "direction": "inboundContext",
                  "invocationId": "<id>",
                  "kind": "resourcePrompt",
                  "lifecycle": "completed",
                  "operationId": "<id>",
                  "origin": {
                    "confidence": "boundary",
                    "kind": "user"
                  },
                  "sequence": "<n>",
                  "version": 1,
                  "visibility": "visible"
                },
                "timestamp": "<timestamp>"
              },
              {
                "content": [
                  {
                    "arguments": {},
                    "groupCount": 1,
                    "groupFinalized": true,
                    "groupId": "<id>",
                    "groupIndex": 0,
                    "id": "<id>",
                    "label": "Lock select",
                    "name": "lock_select",
                    "ordinal": 0,
                    "toolCallId": "<id>",
                    "toolSegmentId": "<id>",
                    "type": "toolCall"
                  }
                ],
                "id": "<id>",
                "kind": "message",
                "modelId": "faux-1",
                "parentId": "<id>",
                "presentationId": "<id>",
                "provider": "tron-lock-run-extension-ui",
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
                  "sequence": "<n>",
                  "version": 1,
                  "visibility": "visible"
                },
                "stopReason": "toolUse",
                "thinkingLevel": "off",
                "timestamp": "<timestamp>",
                "usage": {
                  "cacheRead": "<value>",
                  "cacheWrite": "<value>",
                  "cost": {
                    "cacheRead": "<value>",
                    "cacheWrite": "<value>",
                    "input": "<value>",
                    "output": "<value>",
                    "total": "<value>"
                  },
                  "input": "<value>",
                  "output": "<value>",
                  "totalTokens": "<value>"
                }
              },
              {
                "completedAt": "<timestamp>",
                "content": [
                  {
                    "id": "<id>",
                    "ordinal": 0,
                    "text": "chosen: Keep",
                    "type": "text"
                  }
                ],
                "details": {
                  "answer": "Keep"
                },
                "durationMs": "<duration>",
                "extensionOrigin": {
                  "owner": {
                    "id": "<id>",
                    "kind": "extension",
                    "source": "auto",
                    "title": "Lock Select"
                  },
                  "source": "auto"
                },
                "groupCount": 1,
                "groupFinalized": true,
                "groupId": "<id>",
                "groupIndex": 0,
                "id": "<id>",
                "isError": false,
                "kind": "message",
                "lastProgressAt": "<timestamp>",
                "parentId": "<id>",
                "presentationId": "<id>",
                "progressSequence": "<n>",
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
                  "sequence": "<n>",
                  "version": 1,
                  "visibility": "visible"
                },
                "startedAt": "<timestamp>",
                "timestamp": "<timestamp>",
                "toolCallId": "<id>",
                "toolLabel": "Lock select",
                "toolName": "lock_select",
                "toolSegmentId": "<id>"
              },
              {
                "content": [
                  {
                    "id": "<id>",
                    "ordinal": 0,
                    "text": "Keeping the lock path.",
                    "type": "text"
                  }
                ],
                "id": "<id>",
                "kind": "message",
                "modelId": "faux-1",
                "parentId": "<id>",
                "presentationId": "<id>",
                "provider": "tron-lock-run-extension-ui",
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
                  "sequence": "<n>",
                  "version": 1,
                  "visibility": "visible"
                },
                "stopReason": "stop",
                "thinkingLevel": "off",
                "timestamp": "<timestamp>",
                "usage": {
                  "cacheRead": "<value>",
                  "cacheWrite": "<value>",
                  "cost": {
                    "cacheRead": "<value>",
                    "cacheWrite": "<value>",
                    "input": "<value>",
                    "output": "<value>",
                    "total": "<value>"
                  },
                  "input": "<value>",
                  "output": "<value>",
                  "totalTokens": "<value>"
                }
              }
            ],
            "leafEntryId": "<id>",
            "runtimeGeneration": "<id>",
            "start": 0,
            "total": 6
          }
        }
      }
    ],
    "providerRequests": [
      {
        "sessionShape": "chatWithExtensionSelect",
        "messages": [
          {
            "role": "user",
            "text": "ask me which path"
          }
        ]
      },
      {
        "sessionShape": "chatWithExtensionSelect",
        "messages": [
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
      }
    ],
    "canonicalJsonl": [
      {
        "cwd": "<tmp>/workspace",
        "id": "<id>",
        "timestamp": "<timestamp>",
        "type": "session",
        "version": 3
      },
      {
        "id": "<id>",
        "modelId": "faux-1",
        "parentId": "<id>",
        "provider": "tron-lock-run-extension-ui",
        "timestamp": "<timestamp>",
        "type": "model_change"
      },
      {
        "id": "<id>",
        "parentId": "<id>",
        "thinkingLevel": "off",
        "timestamp": "<timestamp>",
        "type": "thinking_level_change"
      },
      {
        "customType": "tron.context-window.v1",
        "data": {
          "contextWindow": 128000,
          "modelId": "faux-1",
          "provider": "tron-lock-run-extension-ui",
          "version": 1
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "customType": "tron.settings.v1",
        "data": {
          "fixed": {
            "context.images.autoResize": {
              "at": "<timestamp>",
              "from": "global",
              "ref": "<id>",
              "value": true
            },
            "model.contextWindow": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "model": "tron-lock-run-extension-ui/faux-1"
              },
              "ref": "<id>",
              "value": 128000
            },
            "model.ref[role=chat]": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "role": "chat"
              },
              "ref": "<id>",
              "value": {
                "id": "<id>",
                "provider": "tron-lock-run-extension-ui"
              }
            },
            "model.thinking[role=chat]": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "model": "tron-lock-run-extension-ui/faux-1",
                "role": "chat"
              },
              "ref": "<id>",
              "value": "off"
            },
            "tools.active": {
              "at": "<timestamp>",
              "from": "global",
              "ref": "<id>",
              "value": [
                "read",
                "bash",
                "edit",
                "write",
                "lock_select",
                "jev",
                "web_search",
                "settings",
                "projects",
                "ask_user",
                "display",
                "swift_app",
                "computer"
              ]
            }
          },
          "receiptId": "<id>",
          "requestPins": {},
          "settings": {}
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "customType": "tron.settings.v1",
        "data": {
          "fixed": {
            "context.images.autoResize": {
              "at": "<timestamp>",
              "from": "global",
              "ref": "<id>",
              "value": true
            },
            "model.contextWindow": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "model": "tron-lock-run-extension-ui/faux-1"
              },
              "ref": "<id>",
              "value": 128000
            },
            "model.ref[role=chat]": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "role": "chat"
              },
              "ref": "<id>",
              "value": {
                "id": "<id>",
                "provider": "tron-lock-run-extension-ui"
              }
            },
            "model.thinking[role=chat]": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "model": "tron-lock-run-extension-ui/faux-1",
                "role": "chat"
              },
              "ref": "<id>",
              "value": "off"
            },
            "tools.active": {
              "at": "<timestamp>",
              "from": "global",
              "ref": "<id>",
              "value": [
                "read",
                "bash",
                "edit",
                "write",
                "lock_select",
                "jev",
                "web_search",
                "settings",
                "projects",
                "ask_user",
                "display",
                "swift_app",
                "computer"
              ]
            }
          },
          "receiptId": "<id>",
          "requestPins": {
            "context.images.block": {
              "at": "<timestamp>",
              "from": "global",
              "ref": "<id>",
              "value": false
            }
          },
          "settings": {}
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "customType": "tron.chat-invocation.v1",
        "data": {
          "createdAt": "<timestamp>",
          "invocationId": "<id>",
          "lifecycle": "staged",
          "operationId": "<id>",
          "origin": {
            "confidence": "boundary",
            "kind": "user"
          },
          "receiptId": "<id>",
          "receiptKind": "start",
          "sequence": "<n>",
          "sessionId": "<id>",
          "source": "plain",
          "version": 1,
          "writer": "gateway"
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "customType": "tron.chat-invocation.v1",
        "data": {
          "createdAt": "<timestamp>",
          "invocationId": "<id>",
          "lifecycle": "accepted",
          "operationId": "<id>",
          "receiptId": "<id>",
          "receiptKind": "transition",
          "sequence": "<n>",
          "sessionId": "<id>",
          "source": "plain",
          "version": 1,
          "writer": "gateway"
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "id": "<id>",
        "message": {
          "content": "",
          "role": "system",
          "timestamp": "<timestamp>",
          "sections": {
            "cwd": "<cwd>\n<tmp>/workspace\n</cwd>",
            "sessionShape": "chatWithExtensionSelect#0"
          }
        },
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "message"
      },
      {
        "id": "<id>",
        "message": {
          "content": [
            {
              "text": "ask me which path",
              "type": "text"
            }
          ],
          "role": "user",
          "timestamp": "<timestamp>"
        },
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "message"
      },
      {
        "customType": "tron.chat-invocation.v1",
        "data": {
          "canonicalEntryId": "<id>",
          "createdAt": "<timestamp>",
          "invocationId": "<id>",
          "operationId": "<id>",
          "receiptId": "<id>",
          "receiptKind": "binding",
          "sequence": "<n>",
          "sessionId": "<id>",
          "source": "plain",
          "version": 1,
          "writer": "gateway"
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      },
      {
        "id": "<id>",
        "message": {
          "api": "<api>",
          "content": [
            {
              "arguments": {},
              "id": "<id>",
              "name": "lock_select",
              "type": "toolCall"
            }
          ],
          "durationMs": "<duration>",
          "model": "faux-1",
          "provider": "tron-lock-run-extension-ui",
          "role": "assistant",
          "stopReason": "toolUse",
          "thinkingLevel": "off",
          "timestamp": "<timestamp>",
          "usage": {
            "cacheRead": "<value>",
            "cacheWrite": "<value>",
            "cost": {
              "cacheRead": "<value>",
              "cacheWrite": "<value>",
              "input": "<value>",
              "output": "<value>",
              "total": "<value>"
            },
            "input": "<value>",
            "output": "<value>",
            "totalTokens": "<value>"
          }
        },
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "message"
      },
      {
        "id": "<id>",
        "message": {
          "content": [
            {
              "text": "chosen: Keep",
              "type": "text"
            }
          ],
          "details": {
            "answer": "Keep"
          },
          "durationMs": "<duration>",
          "isError": false,
          "role": "toolResult",
          "timestamp": "<timestamp>",
          "toolCallId": "<id>",
          "toolName": "lock_select"
        },
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "message"
      },
      {
        "id": "<id>",
        "message": {
          "api": "<api>",
          "content": [
            {
              "text": "Keeping the lock path.",
              "type": "text"
            }
          ],
          "durationMs": "<duration>",
          "model": "faux-1",
          "provider": "tron-lock-run-extension-ui",
          "role": "assistant",
          "stopReason": "stop",
          "thinkingLevel": "off",
          "timestamp": "<timestamp>",
          "usage": {
            "cacheRead": "<value>",
            "cacheWrite": "<value>",
            "cost": {
              "cacheRead": "<value>",
              "cacheWrite": "<value>",
              "input": "<value>",
              "output": "<value>",
              "total": "<value>"
            },
            "input": "<value>",
            "output": "<value>",
            "totalTokens": "<value>"
          }
        },
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "message"
      },
      {
        "customType": "tron.chat-invocation.v1",
        "data": {
          "createdAt": "<timestamp>",
          "invocationId": "<id>",
          "lifecycle": "completed",
          "operationId": "<id>",
          "origin": {
            "confidence": "boundary",
            "kind": "user"
          },
          "receiptId": "<id>",
          "receiptKind": "terminal",
          "sequence": "<n>",
          "sessionId": "<id>",
          "source": "plain",
          "version": 1,
          "writer": "gateway"
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      }
    ],
    "transcript": {
      "error": null,
      "ok": true,
      "result": {
        "end": 6,
        "items": [
          {
            "id": "<id>",
            "kind": "modelChange",
            "modelRef": {
              "id": "<id>",
              "provider": "tron-lock-run-extension-ui"
            },
            "parentId": "<id>",
            "semantic": {
              "contextEffect": "none",
              "delivery": "stored",
              "direction": "ambientStatus",
              "kind": "status",
              "origin": {
                "confidence": "boundary",
                "kind": "gateway"
              },
              "sequence": "<n>",
              "version": 1,
              "visibility": "visible"
            },
            "timestamp": "<timestamp>"
          },
          {
            "id": "<id>",
            "kind": "thinkingChange",
            "level": "off",
            "parentId": "<id>",
            "semantic": {
              "contextEffect": "none",
              "delivery": "stored",
              "direction": "ambientStatus",
              "kind": "status",
              "origin": {
                "confidence": "boundary",
                "kind": "gateway"
              },
              "sequence": "<n>",
              "version": 1,
              "visibility": "visible"
            },
            "timestamp": "<timestamp>"
          },
          {
            "content": [
              {
                "id": "<id>",
                "ordinal": 0,
                "text": "ask me which path",
                "type": "text"
              }
            ],
            "id": "<id>",
            "kind": "message",
            "parentId": "<id>",
            "presentationId": "<id>",
            "role": "user",
            "semantic": {
              "contextEffect": "modelInput",
              "delivery": "stored",
              "direction": "inboundContext",
              "invocationId": "<id>",
              "kind": "resourcePrompt",
              "lifecycle": "completed",
              "operationId": "<id>",
              "origin": {
                "confidence": "boundary",
                "kind": "user"
              },
              "sequence": "<n>",
              "version": 1,
              "visibility": "visible"
            },
            "timestamp": "<timestamp>"
          },
          {
            "content": [
              {
                "arguments": {},
                "groupCount": 1,
                "groupFinalized": true,
                "groupId": "<id>",
                "groupIndex": 0,
                "id": "<id>",
                "label": "Lock select",
                "name": "lock_select",
                "ordinal": 0,
                "toolCallId": "<id>",
                "toolSegmentId": "<id>",
                "type": "toolCall"
              }
            ],
            "id": "<id>",
            "kind": "message",
            "modelId": "faux-1",
            "parentId": "<id>",
            "presentationId": "<id>",
            "provider": "tron-lock-run-extension-ui",
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
              "sequence": "<n>",
              "version": 1,
              "visibility": "visible"
            },
            "stopReason": "toolUse",
            "thinkingLevel": "off",
            "timestamp": "<timestamp>",
            "usage": {
              "cacheRead": "<value>",
              "cacheWrite": "<value>",
              "cost": {
                "cacheRead": "<value>",
                "cacheWrite": "<value>",
                "input": "<value>",
                "output": "<value>",
                "total": "<value>"
              },
              "input": "<value>",
              "output": "<value>",
              "totalTokens": "<value>"
            }
          },
          {
            "completedAt": "<timestamp>",
            "content": [
              {
                "id": "<id>",
                "ordinal": 0,
                "text": "chosen: Keep",
                "type": "text"
              }
            ],
            "details": {
              "answer": "Keep"
            },
            "durationMs": "<duration>",
            "extensionOrigin": {
              "owner": {
                "id": "<id>",
                "kind": "extension",
                "source": "auto",
                "title": "Lock Select"
              },
              "source": "auto"
            },
            "groupCount": 1,
            "groupFinalized": true,
            "groupId": "<id>",
            "groupIndex": 0,
            "id": "<id>",
            "isError": false,
            "kind": "message",
            "lastProgressAt": "<timestamp>",
            "parentId": "<id>",
            "presentationId": "<id>",
            "progressSequence": "<n>",
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
              "sequence": "<n>",
              "version": 1,
              "visibility": "visible"
            },
            "startedAt": "<timestamp>",
            "timestamp": "<timestamp>",
            "toolCallId": "<id>",
            "toolLabel": "Lock select",
            "toolName": "lock_select",
            "toolSegmentId": "<id>"
          },
          {
            "content": [
              {
                "id": "<id>",
                "ordinal": 0,
                "text": "Keeping the lock path.",
                "type": "text"
              }
            ],
            "id": "<id>",
            "kind": "message",
            "modelId": "faux-1",
            "parentId": "<id>",
            "presentationId": "<id>",
            "provider": "tron-lock-run-extension-ui",
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
              "sequence": "<n>",
              "version": 1,
              "visibility": "visible"
            },
            "stopReason": "stop",
            "thinkingLevel": "off",
            "timestamp": "<timestamp>",
            "usage": {
              "cacheRead": "<value>",
              "cacheWrite": "<value>",
              "cost": {
                "cacheRead": "<value>",
                "cacheWrite": "<value>",
                "input": "<value>",
                "output": "<value>",
                "total": "<value>"
              },
              "input": "<value>",
              "output": "<value>",
              "totalTokens": "<value>"
            }
          }
        ],
        "leafEntryId": "<id>",
        "runtimeGeneration": "<id>",
        "start": 0,
        "total": 6
      }
    },
    "observed": {
      "hostEpoch": "<id>",
      "id": "<id>",
      "invocationId": "<id>",
      "method": "select",
      "operationId": "<id>",
      "options": [
        "Keep",
        "Change"
      ],
      "owner": {
        "id": "<id>",
        "kind": "extension",
        "source": "auto",
        "title": "Lock Select"
      },
      "presentationRevision": 1,
      "title": "Choose a lock path"
    }
  },
};
