import { afterEach, describe, expect, it } from "vitest";
import { type LockGateway } from "../../test-support/gateway-lock-harness.js";
import { normalizeTraceValue, type TraceValue } from "../../test-support/scenario-lock.js";
import { expectScenario } from "../../test-support/lock-projections.js";
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
    expectScenario(trace as unknown as Record<string, unknown>, EXPECTED["run-queue-control"]);
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


/** Each lock's expected trace (`test-support/lock-projections.ts` `expectScenario`): its normalized exchanges, transcript, canonical JSONL, provider conversations and observed state, with model-visible parts named by session shape. */
const EXPECTED: Record<string, unknown> = {
  "run-queue-control": {
    "lock": "run-queue-control",
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
                    "provider": "tron-lock-run-queue-control"
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
                  "provider": "tron-lock-run-queue-control"
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
                "provider": "tron-lock-run-queue-control"
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
                    "provider": "tron-lock-run-queue-control"
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
          "text": "hold the first run open"
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
          "text": "first follow-up"
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
          "commandId": "lock-command-0003",
          "sessionId": "<id>",
          "text": "second follow-up"
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
          "commandId": "lock-command-0005",
          "sessionId": "<id>",
          "text": "third follow-up"
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
          "commandId": "lock-command-0003",
          "sessionId": "<id>",
          "text": "second follow-up"
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
        "method": "session.queue.replace",
        "params": {
          "commandId": "lock-command-0006",
          "expectedRevision": 2,
          "items": [
            {
              "behavior": "followUp",
              "id": "<id>",
              "text": "third follow-up"
            },
            {
              "behavior": "followUp",
              "id": "<id>",
              "text": "first follow-up"
            }
          ],
          "sessionId": "<id>"
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
        "client": "phone",
        "method": "session.queue.replace",
        "params": {
          "commandId": "lock-command-0007",
          "expectedRevision": 3,
          "items": [
            {
              "behavior": "followUp",
              "id": "<id>",
              "text": "third follow-up"
            },
            {
              "behavior": "followUp",
              "id": "<id>",
              "text": "first follow-up"
            }
          ],
          "sessionId": "<id>"
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
        "client": "phone",
        "method": "session.queue.replace",
        "params": {
          "commandId": "lock-command-0008",
          "expectedRevision": 3,
          "items": [
            {
              "behavior": "followUp",
              "id": "<id>",
              "text": "third follow-up"
            },
            {
              "behavior": "followUp",
              "id": "<id>",
              "text": "first follow-up"
            }
          ],
          "sessionId": "<id>"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "items": [
              {
                "attachmentCount": 0,
                "behavior": "followUp",
                "id": "<id>",
                "text": "third follow-up"
              },
              {
                "attachmentCount": 0,
                "behavior": "followUp",
                "id": "<id>",
                "text": "first follow-up"
              }
            ],
            "queueRevision": 4
          }
        }
      },
      {
        "client": "phone",
        "method": "session.abort",
        "params": {
          "commandId": "lock-command-0009",
          "operationId": "<id>",
          "sessionId": "<id>"
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
        "client": "phone",
        "method": "session.prompt",
        "params": {
          "commandId": "lock-command-0010",
          "sessionId": "<id>",
          "text": "hold the second run open"
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
          "commandId": "lock-command-0011",
          "sessionId": "<id>",
          "text": "cleared follow-up one"
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
          "commandId": "lock-command-0012",
          "sessionId": "<id>",
          "text": "cleared follow-up two"
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
        "method": "session.clearQueue",
        "params": {
          "commandId": "lock-command-0013",
          "sessionId": "<id>"
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
        "client": "phone",
        "method": "session.prompt",
        "params": {
          "commandId": "lock-command-0014",
          "sessionId": "<id>",
          "text": "hold a run to stop"
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
          "commandId": "lock-command-0015",
          "sessionId": "<id>",
          "text": "steer queued at stop"
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
          "commandId": "lock-command-0016",
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
            "end": 14,
            "items": [
              {
                "id": "<id>",
                "kind": "modelChange",
                "modelRef": {
                  "id": "<id>",
                  "provider": "tron-lock-run-queue-control"
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
                    "text": "hold the first run open",
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
                    "text": "Held run settled.",
                    "type": "text"
                  }
                ],
                "id": "<id>",
                "kind": "message",
                "modelId": "faux-1",
                "parentId": "<id>",
                "presentationId": "<id>",
                "provider": "tron-lock-run-queue-control",
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
                    "text": "third follow-up",
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
                    "text": "Third follow-up answered.",
                    "type": "text"
                  }
                ],
                "id": "<id>",
                "kind": "message",
                "modelId": "faux-1",
                "parentId": "<id>",
                "presentationId": "<id>",
                "provider": "tron-lock-run-queue-control",
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
                    "text": "first follow-up",
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
                    "text": "First follow-up answered.",
                    "type": "text"
                  }
                ],
                "id": "<id>",
                "kind": "message",
                "modelId": "faux-1",
                "parentId": "<id>",
                "presentationId": "<id>",
                "provider": "tron-lock-run-queue-control",
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
                    "text": "hold the second run open",
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
                    "text": "Second held run settled.",
                    "type": "text"
                  }
                ],
                "id": "<id>",
                "kind": "message",
                "modelId": "faux-1",
                "parentId": "<id>",
                "presentationId": "<id>",
                "provider": "tron-lock-run-queue-control",
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
                    "text": "hold a run to stop",
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
                "provider": "tron-lock-run-queue-control",
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
              },
              {
                "content": [
                  {
                    "id": "<id>",
                    "ordinal": 0,
                    "text": "steer queued at stop",
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
                    "text": "Stopped steer answered.",
                    "type": "text"
                  }
                ],
                "id": "<id>",
                "kind": "message",
                "modelId": "faux-1",
                "parentId": "<id>",
                "presentationId": "<id>",
                "provider": "tron-lock-run-queue-control",
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
            "total": 14
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
            "text": "hold the first run open"
          }
        ]
      },
      {
        "sessionShape": "chat",
        "messages": [
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
        ]
      },
      {
        "sessionShape": "chat",
        "messages": [
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
        ]
      },
      {
        "sessionShape": "chat",
        "messages": [
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
        ]
      },
      {
        "sessionShape": "chat",
        "messages": [
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
        ]
      },
      {
        "sessionShape": "chat",
        "messages": [
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
        "provider": "tron-lock-run-queue-control",
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
          "provider": "tron-lock-run-queue-control",
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
                "model": "tron-lock-run-queue-control/faux-1"
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
                "provider": "tron-lock-run-queue-control"
              }
            },
            "model.thinking[role=chat]": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "model": "tron-lock-run-queue-control/faux-1",
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
                "model": "tron-lock-run-queue-control/faux-1"
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
                "provider": "tron-lock-run-queue-control"
              }
            },
            "model.thinking[role=chat]": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "model": "tron-lock-run-queue-control/faux-1",
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
              "text": "hold the first run open",
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
          "errorCode": "queue-replaced",
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
      },
      {
        "id": "<id>",
        "message": {
          "api": "<api>",
          "content": [
            {
              "text": "Held run settled.",
              "type": "text"
            }
          ],
          "durationMs": "<duration>",
          "model": "faux-1",
          "provider": "tron-lock-run-queue-control",
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
              "text": "third follow-up",
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
              "text": "Third follow-up answered.",
              "type": "text"
            }
          ],
          "durationMs": "<duration>",
          "model": "faux-1",
          "provider": "tron-lock-run-queue-control",
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
              "text": "first follow-up",
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
              "text": "First follow-up answered.",
              "type": "text"
            }
          ],
          "durationMs": "<duration>",
          "model": "faux-1",
          "provider": "tron-lock-run-queue-control",
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
              "text": "hold the second run open",
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
        "customType": "tron.chat-invocation.v1",
        "data": {
          "createdAt": "<timestamp>",
          "errorCode": "queue-cleared",
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
      },
      {
        "customType": "tron.chat-invocation.v1",
        "data": {
          "createdAt": "<timestamp>",
          "errorCode": "queue-cleared",
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
      },
      {
        "id": "<id>",
        "message": {
          "api": "<api>",
          "content": [
            {
              "text": "Second held run settled.",
              "type": "text"
            }
          ],
          "durationMs": "<duration>",
          "model": "faux-1",
          "provider": "tron-lock-run-queue-control",
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
              "text": "hold a run to stop",
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
        "id": "<id>",
        "message": {
          "api": "<api>",
          "content": [],
          "durationMs": "<duration>",
          "errorMessage": "Request was aborted",
          "model": "faux-1",
          "provider": "tron-lock-run-queue-control",
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
      },
      {
        "id": "<id>",
        "message": {
          "content": [
            {
              "text": "steer queued at stop",
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
              "text": "Stopped steer answered.",
              "type": "text"
            }
          ],
          "durationMs": "<duration>",
          "model": "faux-1",
          "provider": "tron-lock-run-queue-control",
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
      "end": 14,
      "items": [
        {
          "id": "<id>",
          "kind": "modelChange",
          "modelRef": {
            "id": "<id>",
            "provider": "tron-lock-run-queue-control"
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
              "text": "hold the first run open",
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
              "text": "Held run settled.",
              "type": "text"
            }
          ],
          "id": "<id>",
          "kind": "message",
          "modelId": "faux-1",
          "parentId": "<id>",
          "presentationId": "<id>",
          "provider": "tron-lock-run-queue-control",
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
              "text": "third follow-up",
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
              "text": "Third follow-up answered.",
              "type": "text"
            }
          ],
          "id": "<id>",
          "kind": "message",
          "modelId": "faux-1",
          "parentId": "<id>",
          "presentationId": "<id>",
          "provider": "tron-lock-run-queue-control",
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
              "text": "first follow-up",
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
              "text": "First follow-up answered.",
              "type": "text"
            }
          ],
          "id": "<id>",
          "kind": "message",
          "modelId": "faux-1",
          "parentId": "<id>",
          "presentationId": "<id>",
          "provider": "tron-lock-run-queue-control",
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
              "text": "hold the second run open",
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
              "text": "Second held run settled.",
              "type": "text"
            }
          ],
          "id": "<id>",
          "kind": "message",
          "modelId": "faux-1",
          "parentId": "<id>",
          "presentationId": "<id>",
          "provider": "tron-lock-run-queue-control",
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
              "text": "hold a run to stop",
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
          "provider": "tron-lock-run-queue-control",
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
        },
        {
          "content": [
            {
              "id": "<id>",
              "ordinal": 0,
              "text": "steer queued at stop",
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
              "text": "Stopped steer answered.",
              "type": "text"
            }
          ],
          "id": "<id>",
          "kind": "message",
          "modelId": "faux-1",
          "parentId": "<id>",
          "presentationId": "<id>",
          "provider": "tron-lock-run-queue-control",
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
      "total": 14
    },
    "observed": {
      "queuedThree": {
        "queueRevision": 3,
        "queuedItems": [
          {
            "behavior": "followUp",
            "id": "<id>",
            "text": "first follow-up"
          },
          {
            "behavior": "followUp",
            "id": "<id>",
            "text": "second follow-up"
          },
          {
            "behavior": "followUp",
            "id": "<id>",
            "text": "third follow-up"
          }
        ]
      },
      "afterEdit": {
        "queueRevision": 4,
        "queuedItems": [
          {
            "behavior": "followUp",
            "id": "<id>",
            "text": "third follow-up"
          },
          {
            "behavior": "followUp",
            "id": "<id>",
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
            "id": "<id>",
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
  },
};
