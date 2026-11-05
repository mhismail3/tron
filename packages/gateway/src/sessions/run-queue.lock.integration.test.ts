import { afterEach, describe, expect, it } from "vitest";
import { type LockGateway } from "../../test-support/gateway-lock-harness.js";
import { normalizeTraceValue, type TraceValue } from "../../test-support/scenario-lock.js";
import { expectSessionLock, projectedSnapshot, type SessionLockExpectation } from "../../test-support/lock-projections.js";
import { openLockSession, queueControlScenario, type QueueState } from "../../test-support/lock-scenarios.js";

/**
 * Queue lock (restructure plan §6.4, V3; K-0 §7, guarding E5 `kernel/run`'s
 * admission, queue and abort) for the `gateway/run` module, through the real
 * Gateway over a loopback WebSocket (`gateway-lock-harness.ts`).
 *
 * `run-queue-control`: while one run is held open, three follow-ups queue in
 * order and a retried `commandId` replays its receipt instead of queueing
 * again. `session.queue.replace` refuses a stale revision and an unknown item,
 * then reorders two follow-ups and drops the third; `session.abort` refuses an
 * operation that is not the live one. The run and the follow-ups then reach the
 * model in the edited order. A second held run's follow-ups are cleared by
 * `session.clearQueue`, and stopping a third run with a queued steer delivers
 * that steer as the next turn. Canonical JSONL records each queued item's
 * terminal receipt (`queue-replaced`, `queue-cleared`).
 */

const gateways: LockGateway[] = [];
afterEach(async () => { await Promise.all(gateways.splice(0).map((gateway) => gateway.dispose())); });

describe("gateway/run queue lock", () => {
  it("run-queue-control: queued follow-ups keep order, a retried command replays, edits and clears are exact, a stopped steer is delivered", async () => {
    const session = await openLockSession("run-queue-control");
    gateways.push(session.gateway);
    const { gateway, sessionId } = session;
    const { queuedThree, staleEdit, unknownEdit, afterEdit, wrongAbort, retriedResponse, followUps, afterClear, beforeStop, finalQueue, transcript } =
      await queueControlScenario(session);

    const recorded = gateway.record();
    const userTexts = (await gateway.canonical(sessionId)).flatMap((entry) => {
      const message = (entry as { message?: { role?: string; content?: unknown } }).message;
      return message?.role === "user" ? [JSON.stringify(message.content)] : [];
    });
    const queueValue = (state: QueueState) => normalizeTraceValue(state as unknown as TraceValue, gateway.normalization);
    const trace = {
      lock: "run-queue-control",
      exchanges: recorded.exchanges,
      events: recorded.events,
      providerRequests: recorded.providerRequests as unknown as TraceValue[],
      canonicalJsonl: await gateway.canonical(sessionId),
      transcript: normalizeTraceValue(transcript.result, gateway.normalization),
      observed: {
        queuedThree: queueValue(queuedThree), afterEdit: queueValue(afterEdit), afterClear: queueValue(afterClear),
        beforeStop: queueValue(beforeStop), final: queueValue(finalQueue),
        retriedReplaysOriginal: JSON.stringify(retriedResponse.result) === JSON.stringify(followUps[1]!.result),
      },
    };
    expectSessionLock("run-queue-control", { exchanges: recorded.exchanges, canonical: trace.canonicalJsonl,
      items: (transcript.result as { items: unknown[] }).items, providers: recorded.providerRequests.map((request) => request.messages),
      window: Object.fromEntries(Object.entries(transcript.result as Record<string, unknown>).filter(([key]) => key !== "items")) }, EXPECTED);
    expect(projectedSnapshot(trace.observed), "each queue state the client saw").toEqual(EXPECTED.observed);
    expect(queuedThree.queuedItems.map((item) => item.text)).toEqual(["first follow-up", "second follow-up", "third follow-up"]);
    expect(staleEdit.error).toMatchObject({ code: "conflict" });
    expect(unknownEdit.error).toMatchObject({ code: "conflict" });
    expect(afterEdit.queuedItems.map((item) => item.text)).toEqual(["third follow-up", "first follow-up"]);
    expect(wrongAbort.error).toMatchObject({ code: "conflict" });
    expect(retriedResponse.ok).toBe(true);
    expect(trace.observed.retriedReplaysOriginal).toBe(true);
    expect(afterClear.queuedItems).toEqual([]);
    expect(beforeStop.queuedItems.map((item) => item.behavior)).toEqual(["steer"]);
    expect(finalQueue.queuedItems).toEqual([]);
    expect(userTexts.map((text) => ["hold the first run open", "third follow-up", "first follow-up", "hold the second run open",
      "hold a run to stop", "steer queued at stop"].findIndex((needle) => text.includes(needle)))).toEqual([0, 1, 2, 3, 4, 5]);
    const canonical = JSON.stringify(trace.canonicalJsonl);
    expect(canonical).toContain("queue-replaced");
    expect(canonical).toContain("queue-cleared");
    expect(recorded.providerRequests).toHaveLength(6);
  }, 60_000);
});

/** What run-queue-control expects (`test-support/lock-projections.ts`), with each queue state the client saw. */
const EXPECTED: SessionLockExpectation & { observed: unknown } = {
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
        "text": "hold the first run open"
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
        "text": "first follow-up"
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
        "commandId": "lock-command-0003",
        "sessionId": "<present>",
        "text": "second follow-up"
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
        "commandId": "lock-command-0005",
        "sessionId": "<present>",
        "text": "third follow-up"
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
        "commandId": "lock-command-0003",
        "sessionId": "<present>",
        "text": "second follow-up"
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
      "method": "session.queue.replace",
      "params": {
        "commandId": "lock-command-0006",
        "expectedRevision": 2,
        "items": [
          {
            "behavior": "followUp",
            "id": "<present>",
            "text": "third follow-up"
          },
          {
            "behavior": "followUp",
            "id": "<present>",
            "text": "first follow-up"
          }
        ],
        "sessionId": "<present>"
      },
      "response": {
        "error": {
          "code": "conflict",
          "message": "The message queue changed. Review the latest queue and try again.",
          "retryable": true
        },
        "ok": false,
        "result": null
      }
    },
    {
      "method": "session.queue.replace",
      "params": {
        "commandId": "lock-command-0007",
        "expectedRevision": 3,
        "items": [
          {
            "behavior": "followUp",
            "id": "<present>",
            "text": "third follow-up"
          },
          {
            "behavior": "followUp",
            "id": "<present>",
            "text": "first follow-up"
          }
        ],
        "sessionId": "<present>"
      },
      "response": {
        "error": {
          "code": "conflict",
          "message": "The message queue changed. Review the latest queue and try again.",
          "retryable": true
        },
        "ok": false,
        "result": null
      }
    },
    {
      "method": "session.queue.replace",
      "params": {
        "commandId": "lock-command-0008",
        "expectedRevision": 3,
        "items": [
          {
            "behavior": "followUp",
            "id": "<present>",
            "text": "third follow-up"
          },
          {
            "behavior": "followUp",
            "id": "<present>",
            "text": "first follow-up"
          }
        ],
        "sessionId": "<present>"
      },
      "response": {
        "error": null,
        "ok": true,
        "result": {
          "items": [
            {
              "attachmentCount": 0,
              "behavior": "followUp",
              "id": "<present>",
              "text": "third follow-up"
            },
            {
              "attachmentCount": 0,
              "behavior": "followUp",
              "id": "<present>",
              "text": "first follow-up"
            }
          ],
          "queueRevision": 4
        }
      }
    },
    {
      "method": "session.abort",
      "params": {
        "commandId": "lock-command-0009",
        "operationId": "<present>",
        "sessionId": "<present>"
      },
      "response": {
        "error": {
          "code": "conflict",
          "message": "The active operation changed before it could be stopped",
          "retryable": true
        },
        "ok": false,
        "result": null
      }
    },
    {
      "method": "session.prompt",
      "params": {
        "commandId": "lock-command-0010",
        "sessionId": "<present>",
        "text": "hold the second run open"
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
        "commandId": "lock-command-0011",
        "sessionId": "<present>",
        "text": "cleared follow-up one"
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
        "commandId": "lock-command-0012",
        "sessionId": "<present>",
        "text": "cleared follow-up two"
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
      "method": "session.clearQueue",
      "params": {
        "commandId": "lock-command-0013",
        "sessionId": "<present>"
      },
      "response": {
        "error": null,
        "ok": true,
        "result": {
          "cleared": true
        }
      }
    },
    {
      "method": "session.prompt",
      "params": {
        "commandId": "lock-command-0014",
        "sessionId": "<present>",
        "text": "hold a run to stop"
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
        "commandId": "lock-command-0015",
        "sessionId": "<present>",
        "text": "steer queued at stop"
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
        "commandId": "lock-command-0016",
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
          "text": "hold the first run open",
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
          "text": "Held run settled.",
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
          "text": "third follow-up",
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
          "text": "Third follow-up answered.",
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
          "text": "first follow-up",
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
          "text": "First follow-up answered.",
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
          "text": "hold the second run open",
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
          "text": "Second held run settled.",
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
          "text": "hold a run to stop",
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
    },
    {
      "content": [
        {
          "id": "<present>",
          "ordinal": 0,
          "text": "steer queued at stop",
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
          "text": "Stopped steer answered.",
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
    "end": 14,
    "leafEntryId": "<present>",
    "runtimeGeneration": "<present>",
    "start": 0,
    "total": 14
  },
  "messages": [
    {
      "content": [
        {
          "text": "hold the first run open",
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
          "text": "Held run settled.",
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
          "text": "third follow-up",
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
          "text": "Third follow-up answered.",
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
          "text": "first follow-up",
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
          "text": "First follow-up answered.",
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
          "text": "hold the second run open",
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
          "text": "Second held run settled.",
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
          "text": "hold a run to stop",
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
    },
    {
      "content": [
        {
          "text": "steer queued at stop",
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
          "text": "Stopped steer answered.",
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
    "custom:tron.chat-invocation.v1",
    "custom:tron.chat-invocation.v1",
    "custom:tron.chat-invocation.v1",
    "message:assistant",
    "custom:tron.chat-invocation.v1",
    "message:user",
    "custom:tron.chat-invocation.v1",
    "message:assistant",
    "custom:tron.chat-invocation.v1",
    "message:user",
    "custom:tron.chat-invocation.v1",
    "message:assistant",
    "custom:tron.chat-invocation.v1",
    "custom:tron.chat-invocation.v1",
    "custom:tron.chat-invocation.v1",
    "message:user",
    "custom:tron.chat-invocation.v1",
    "custom:tron.chat-invocation.v1",
    "custom:tron.chat-invocation.v1",
    "custom:tron.chat-invocation.v1",
    "custom:tron.chat-invocation.v1",
    "custom:tron.chat-invocation.v1",
    "custom:tron.chat-invocation.v1",
    "message:assistant",
    "custom:tron.chat-invocation.v1",
    "custom:tron.chat-invocation.v1",
    "custom:tron.chat-invocation.v1",
    "message:user",
    "custom:tron.chat-invocation.v1",
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
      "receiptKind": "terminal",
      "lifecycle": "interrupted",
      "errorCode": "queue-replaced",
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
      "receiptKind": "terminal",
      "lifecycle": "interrupted",
      "errorCode": "queue-cleared",
      "source": "plain"
    },
    {
      "receiptKind": "terminal",
      "lifecycle": "interrupted",
      "errorCode": "queue-cleared",
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
      "receiptKind": "terminal",
      "lifecycle": "interrupted",
      "errorCode": "user-abort",
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
        "text": "hold the first run open"
      }
    ],
    [
      {
        "role": "user",
        "text": "hold the first run open"
      },
      {
        "role": "assistant",
        "text": "Held run settled."
      },
      {
        "role": "user",
        "text": "third follow-up"
      }
    ],
    [
      {
        "role": "user",
        "text": "hold the first run open"
      },
      {
        "role": "assistant",
        "text": "Held run settled."
      },
      {
        "role": "user",
        "text": "third follow-up"
      },
      {
        "role": "assistant",
        "text": "Third follow-up answered."
      },
      {
        "role": "user",
        "text": "first follow-up"
      }
    ],
    [
      {
        "role": "user",
        "text": "hold the first run open"
      },
      {
        "role": "assistant",
        "text": "Held run settled."
      },
      {
        "role": "user",
        "text": "third follow-up"
      },
      {
        "role": "assistant",
        "text": "Third follow-up answered."
      },
      {
        "role": "user",
        "text": "first follow-up"
      },
      {
        "role": "assistant",
        "text": "First follow-up answered."
      },
      {
        "role": "user",
        "text": "hold the second run open"
      }
    ],
    [
      {
        "role": "user",
        "text": "hold the first run open"
      },
      {
        "role": "assistant",
        "text": "Held run settled."
      },
      {
        "role": "user",
        "text": "third follow-up"
      },
      {
        "role": "assistant",
        "text": "Third follow-up answered."
      },
      {
        "role": "user",
        "text": "first follow-up"
      },
      {
        "role": "assistant",
        "text": "First follow-up answered."
      },
      {
        "role": "user",
        "text": "hold the second run open"
      },
      {
        "role": "assistant",
        "text": "Second held run settled."
      },
      {
        "role": "user",
        "text": "hold a run to stop"
      }
    ],
    [
      {
        "role": "user",
        "text": "hold the first run open"
      },
      {
        "role": "assistant",
        "text": "Held run settled."
      },
      {
        "role": "user",
        "text": "third follow-up"
      },
      {
        "role": "assistant",
        "text": "Third follow-up answered."
      },
      {
        "role": "user",
        "text": "first follow-up"
      },
      {
        "role": "assistant",
        "text": "First follow-up answered."
      },
      {
        "role": "user",
        "text": "hold the second run open"
      },
      {
        "role": "assistant",
        "text": "Second held run settled."
      },
      {
        "role": "user",
        "text": "hold a run to stop"
      },
      {
        "role": "assistant",
        "text": ""
      },
      {
        "role": "user",
        "text": "steer queued at stop"
      }
    ]
  ],
  "observed": {
    "queuedThree": {
      "queueRevision": 3,
      "queuedItems": [
        {
          "behavior": "followUp",
          "id": "<present>",
          "text": "first follow-up"
        },
        {
          "behavior": "followUp",
          "id": "<present>",
          "text": "second follow-up"
        },
        {
          "behavior": "followUp",
          "id": "<present>",
          "text": "third follow-up"
        }
      ]
    },
    "afterEdit": {
      "queueRevision": 4,
      "queuedItems": [
        {
          "behavior": "followUp",
          "id": "<present>",
          "text": "third follow-up"
        },
        {
          "behavior": "followUp",
          "id": "<present>",
          "text": "first follow-up"
        }
      ]
    },
    "afterClear": {
      "queueRevision": 9,
      "queuedItems": []
    },
    "beforeStop": {
      "queueRevision": 10,
      "queuedItems": [
        {
          "behavior": "steer",
          "id": "<present>",
          "text": "steer queued at stop"
        }
      ]
    },
    "final": {
      "queueRevision": 11,
      "queuedItems": []
    },
    "retriedReplaysOriginal": true
  }
};
