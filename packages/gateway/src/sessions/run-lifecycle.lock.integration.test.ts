import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockClient, type LockGateway } from "../../test-support/gateway-lock-harness.js";
import { normalizeTraceValue, type TraceValue } from "../../test-support/scenario-lock.js";
import { expectScenario } from "../../test-support/lock-projections.js";
import { awaitsWithin, waitFor } from "../../test-support/wait-for.js";

/**
 * Lifecycle RPC lock (packages/gateway/docs/scenario-locks.md; K-0 §7, guarding E5's abort
 * and E7's drain) for the `gateway/run` module: the restart and stop RPCs a
 * phone sends, through the real Gateway (`gateway-lock-harness.ts`, option
 * `lifecycleRequests`: the real terminal owner, and `gateway-main`'s process
 * exit requests recorded instead of acted on; the lock runs the drain
 * `gateway-main` would run, `waitUntilIdle`).
 *
 * `run-lifecycle-rpcs`:
 * - an unsupervised Gateway refuses restart and stop; a supervised one refuses
 *   malformed parameters;
 * - `session.reloadResources` (the session restart) reloads an idle session and
 *   is refused during its run;
 * - `gateway.restart` during a live run schedules a drain naming that session,
 *   cancels waiting auth and asks for the restart after its receipt; a second
 *   restart, a stop and new work are refused while it drains; `restartNow`
 *   during the drain asks for an immediate restart; the drain completes after
 *   the run;
 * - on a second, idle Gateway `gateway.stop` drains nothing and asks for the stop.
 */

const gateways: LockGateway[] = [];
const previousSupervised = process.env.TRON_GATEWAY_SUPERVISED;
afterEach(async () => {
  if (previousSupervised === undefined) delete process.env.TRON_GATEWAY_SUPERVISED;
  else process.env.TRON_GATEWAY_SUPERVISED = previousSupervised;
  await Promise.all(gateways.splice(0).map((gateway) => gateway.dispose()));
});

/** A gate a scripted provider step holds until the test opens it. */
function gate(): { opened: Promise<void>; open(): void; reached: Promise<void>; reach(): void } {
  let open = (): void => {};
  let reach = (): void => {};
  const opened = new Promise<void>((resolve) => { open = resolve; });
  const reached = new Promise<void>((resolve) => { reach = resolve; });
  return { opened, open: () => open(), reached, reach: () => reach() };
}

async function createAndOpen(gateway: LockGateway, client: LockClient): Promise<string> {
  const created = await client.request("session.create", { commandId: gateway.commandId(), cwd: gateway.cwd });
  expect(created.ok, JSON.stringify(created)).toBe(true);
  const sessionId = created.result.sessionId as string;
  const opened = await client.request("session.open", { sessionId });
  expect((await client.request("session.sync", { sessionId, syncToken: opened.result.syncToken })).ok).toBe(true);
  return sessionId;
}

/** `restarting` and `stopping` count the RPC's own work as a blocker, so they
 * are never true (#1559); they are blinded rather than pinned. */
function blinded(key: string, value: unknown): unknown {
  return key === "restarting" || key === "stopping" ? "<blinded:#1559>" : value;
}

/** Replace a session id by its role, so a normalized record still says which session. */
function labelled(value: unknown, sessionId: string, role: string, gateway: LockGateway): TraceValue {
  const text = JSON.stringify(value ?? null).split(sessionId).join(`<session:${role}>`);
  return normalizeTraceValue(JSON.parse(text, blinded), { ...gateway.normalization, stableIds: [`<session:${role}>`] });
}

describe("gateway/run lifecycle RPC lock", () => {
  it("run-lifecycle-rpcs: restart and stop refusals, the session restart, a restart drain over a live run, and an idle stop", async () => {
    const gateway = await startLockGateway("run-lifecycle-rpcs", { lifecycleRequests: true });
    gateways.push(gateway);
    const phone = await gateway.connect("phone");
    const held = gate();
    gateway.script([
      () => fauxAssistantMessage("Answer before the reload."),
      async () => { held.reach(); await held.opened; return fauxAssistantMessage("Run settled during the drain."); },
    ]);
    const command = (method: string, params: Record<string, unknown> = {}) =>
      phone.request(method, { commandId: gateway.commandId(), ...params });

    // 1. Refusals: no supervisor, then malformed parameters.
    delete process.env.TRON_GATEWAY_SUPERVISED;
    const unsupervisedRestart = await command("gateway.restart");
    const unsupervisedStop = await command("gateway.stop");
    process.env.TRON_GATEWAY_SUPERVISED = "1";
    const malformedRestartNow = await command("gateway.restart", { restartNow: "yes" });
    const extraRestart = await command("gateway.restart", { reason: "lock" });
    const extraStop = await command("gateway.stop", { reason: "lock" });

    // 2. The session restart: reload while idle, refused while its run is live.
    const sessionId = await createAndOpen(gateway, phone);
    expect((await command("session.prompt", { sessionId, text: "answer before the reload" })).ok).toBe(true);
    await gateway.settled(sessionId);
    const reloadIdle = await command("session.reloadResources", { sessionId });
    const running = await command("session.prompt", { sessionId, text: "hold this run through the restart" });
    expect(running.ok, JSON.stringify(running)).toBe(true);
    await awaitsWithin(held.reached, "the held provider request");
    const reloadRunning = await command("session.reloadResources", { sessionId });

    // 3. A restart drains the live run; while it drains, everything else is refused.
    const restart = await command("gateway.restart");
    expect(restart.ok, JSON.stringify(restart)).toBe(true);
    await waitFor(() => gateway.lifecycleRequests.some((request) => request.kind === "restart"), "the scheduled restart request");
    const drained = gateway.registry.waitUntilIdle();
    await waitFor(() => gateway.registry.administrativeDrainSnapshot().phase === "waiting", "the drain to wait on the live run");
    const secondRestart = await command("gateway.restart");
    const stopDuringDrain = await command("gateway.stop");
    const promptDuringDrain = await command("session.prompt", { sessionId, text: "new work during the restart drain" });
    const restartNow = await command("gateway.restart", { restartNow: true });
    const requestsBeforeSettle = [...gateway.lifecycleRequests];
    held.open();
    const completed = await awaitsWithin(drained, "the restart drain to complete");
    const statusComplete = await phone.request("gateway.drain.status", {});

    // 4. An idle Gateway's stop drains nothing and asks for the stop.
    const idle = await startLockGateway("run-lifecycle-stop", { lifecycleRequests: true });
    gateways.push(idle);
    const mac = await idle.connect("mac");
    const stop = await mac.request("gateway.stop", { commandId: idle.commandId() });
    await waitFor(() => idle.lifecycleRequests.some((request) => request.kind === "stop"), "the stop request");
    const stopCompleted = await awaitsWithin(idle.registry.waitUntilIdle(), "the stop drain to complete");
    const stopStatus = await mac.request("gateway.drain.status", {});

    const recorded = gateway.record();
    const label = (response: { result?: unknown; error?: unknown }) => labelled(response.result ?? response.error ?? null, sessionId, "live", gateway);
    const trace = {
      lock: "run-lifecycle-rpcs",
      exchanges: recorded.exchanges.map((entry) => labelled(entry, sessionId, "live", gateway)),
      providerRequests: recorded.providerRequests as unknown as TraceValue[],
      canonicalJsonl: await gateway.canonical(sessionId),
      observed: {
        refused: {
          unsupervisedRestart: label(unsupervisedRestart), unsupervisedStop: label(unsupervisedStop),
          malformedRestartNow: label(malformedRestartNow), extraRestart: label(extraRestart), extraStop: label(extraStop),
        },
        reload: { idle: label(reloadIdle), running: label(reloadRunning) },
        restart: {
          accepted: label(restart), secondRestart: label(secondRestart), stopDuringDrain: label(stopDuringDrain),
          promptDuringDrain: label(promptDuringDrain), restartNow: label(restartNow),
          requestsBeforeSettle: requestsBeforeSettle as unknown as TraceValue, completed, complete: label(statusComplete),
          requests: [...gateway.lifecycleRequests] as unknown as TraceValue,
        },
        stop: {
          completed: stopCompleted,
          requests: [...idle.lifecycleRequests] as unknown as TraceValue,
          exchanges: idle.record().exchanges.map((entry) => normalizeTraceValue(JSON.parse(JSON.stringify(entry), blinded), idle.normalization)),
        },
      },
    };
    expectScenario(trace as unknown as Record<string, unknown>, EXPECTED["run-lifecycle-rpcs"]);
    expect(unsupervisedRestart.error).toMatchObject({ code: "unsupported" });
    expect(unsupervisedStop.error).toMatchObject({ code: "unsupported" });
    for (const refusal of [malformedRestartNow, extraRestart, extraStop]) expect(refusal.error).toMatchObject({ code: "invalid_request" });
    expect(reloadIdle.result).toEqual({ reloaded: true });
    expect(reloadRunning.ok).toBe(false);
    expect(restart.result).toMatchObject({ scheduled: true, activeSessionIds: [sessionId] });
    expect(JSON.stringify(trace.observed.restart.accepted)).toContain("foreground-agent-operation");
    expect(secondRestart.error).toMatchObject({ code: "busy" });
    expect(stopDuringDrain.error).toMatchObject({ code: "busy" });
    expect(promptDuringDrain.ok).toBe(false);
    expect(restartNow.result).toMatchObject({ scheduled: true, restartNow: true });
    expect(requestsBeforeSettle).toEqual([
      { kind: "auth.cancelWaitingForRestart" }, { kind: "restart", restartNow: false }, { kind: "restart", restartNow: true },
    ]);
    expect(completed).toBe(true);
    expect(statusComplete.result).toMatchObject({ phase: "complete", blockerCount: 0 });
    expect(JSON.stringify(trace.canonicalJsonl)).toContain("Run settled during the drain.");
    expect(stop.result).toMatchObject({ scheduled: true, activeSessionIds: [] });
    expect(idle.lifecycleRequests).toEqual([{ kind: "stop" }]);
    expect(stopStatus.result).toMatchObject({ phase: "complete", blockerCount: 0 });
  }, 60_000);
});

/** Each lock's expected trace (`test-support/lock-projections.ts` `expectScenario`): the scenario's normalized trace without event schemas, with model-visible parts named by session shape. */
const EXPECTED: Record<string, unknown> = {
  "run-lifecycle-rpcs": {
    "lock": "run-lifecycle-rpcs",
    "exchanges": [
      {
        "client": "phone",
        "method": "gateway.restart",
        "params": {
          "commandId": "lock-command-0001"
        },
        "response": {
          "error": {
            "code": "unsupported",
            "message": "Gateway restart requires an external supervisor",
            "retryable": false
          },
          "ok": false,
          "result": null
        }
      },
      {
        "client": "phone",
        "method": "gateway.stop",
        "params": {
          "commandId": "lock-command-0002"
        },
        "response": {
          "error": {
            "code": "unsupported",
            "message": "Gateway stop requires an external supervisor",
            "retryable": false
          },
          "ok": false,
          "result": null
        }
      },
      {
        "client": "phone",
        "method": "gateway.restart",
        "params": {
          "commandId": "lock-command-0003",
          "restartNow": "yes"
        },
        "response": {
          "error": {
            "code": "invalid_request",
            "message": "Gateway restart restartNow must be boolean",
            "retryable": false
          },
          "ok": false,
          "result": null
        }
      },
      {
        "client": "phone",
        "method": "gateway.restart",
        "params": {
          "commandId": "lock-command-0004",
          "reason": "lock"
        },
        "response": {
          "error": {
            "code": "invalid_request",
            "message": "Gateway restart accepts only commandId and optional restartNow",
            "retryable": false
          },
          "ok": false,
          "result": null
        }
      },
      {
        "client": "phone",
        "method": "gateway.stop",
        "params": {
          "commandId": "lock-command-0005",
          "reason": "lock"
        },
        "response": {
          "error": {
            "code": "invalid_request",
            "message": "Gateway stop accepts only commandId",
            "retryable": false
          },
          "ok": false,
          "result": null
        }
      },
      {
        "client": "phone",
        "method": "session.create",
        "params": {
          "commandId": "lock-command-0006",
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
                    "provider": "tron-lock-run-lifecycle-rpcs"
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
                  "provider": "tron-lock-run-lifecycle-rpcs"
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
                "provider": "tron-lock-run-lifecycle-rpcs"
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
                    "provider": "tron-lock-run-lifecycle-rpcs"
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
          "commandId": "lock-command-0007",
          "sessionId": "<id>",
          "text": "answer before the reload"
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
        "method": "session.reloadResources",
        "params": {
          "commandId": "lock-command-0008",
          "sessionId": "<id>"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "reloaded": true
          }
        }
      },
      {
        "client": "phone",
        "method": "session.prompt",
        "params": {
          "commandId": "lock-command-0009",
          "sessionId": "<id>",
          "text": "hold this run through the restart"
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
        "method": "session.reloadResources",
        "params": {
          "commandId": "lock-command-0010",
          "sessionId": "<id>"
        },
        "response": {
          "error": {
            "code": "busy",
            "message": "Session must be idle for this operation",
            "retryable": false
          },
          "ok": false,
          "result": null
        }
      },
      {
        "client": "phone",
        "method": "gateway.restart",
        "params": {
          "commandId": "lock-command-0011"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "activeSessionIds": [
              "<id>"
            ],
            "drain": {
              "blockerCount": 2,
              "blockerCounts": {
                "foreground-agent-operation": 1,
                "rpc-mutation": 1
              },
              "blockers": [
                {
                  "admittedAt": "<timestamp>",
                  "ageMs": "<duration>",
                  "category": "foreground-agent-operation",
                  "id": "<id>",
                  "progressAt": "<timestamp>",
                  "sessionId": "<id>",
                  "state": "active"
                },
                {
                  "admittedAt": "<timestamp>",
                  "ageMs": "<duration>",
                  "category": "rpc-mutation",
                  "id": "<id>",
                  "method": "gateway.restart",
                  "progressAt": "<timestamp>",
                  "state": "active"
                }
              ],
              "drainId": "<id>",
              "omittedCount": 0,
              "phase": "preparing",
              "revision": "<n>",
              "suspectProjectionCount": 0
            },
            "drainId": "<id>",
            "drainRevision": 4,
            "restarting": "<blinded:#1559>",
            "scheduled": true
          }
        }
      },
      {
        "client": "phone",
        "method": "gateway.restart",
        "params": {
          "commandId": "lock-command-0012"
        },
        "response": {
          "error": {
            "code": "busy",
            "message": "Gateway is already draining accepted work; inspect gateway.drain.status or command.status",
            "retryable": true
          },
          "ok": false,
          "result": null
        }
      },
      {
        "client": "phone",
        "method": "gateway.stop",
        "params": {
          "commandId": "lock-command-0013"
        },
        "response": {
          "error": {
            "code": "busy",
            "message": "Gateway is already draining accepted work; inspect gateway.drain.status or command.status",
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
          "commandId": "lock-command-0014",
          "sessionId": "<id>",
          "text": "new work during the restart drain"
        },
        "response": {
          "error": {
            "code": "busy",
            "message": "The Gateway is draining accepted work",
            "retryable": true
          },
          "ok": false,
          "result": null
        }
      },
      {
        "client": "phone",
        "method": "gateway.restart",
        "params": {
          "commandId": "lock-command-0015",
          "restartNow": true
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "drain": {
              "blockerCount": 2,
              "blockerCounts": {
                "foreground-agent-operation": 1,
                "rpc-mutation": 1
              },
              "blockers": [
                {
                  "admittedAt": "<timestamp>",
                  "ageMs": "<duration>",
                  "category": "foreground-agent-operation",
                  "id": "<id>",
                  "progressAt": "<timestamp>",
                  "sessionId": "<id>",
                  "state": "active"
                },
                {
                  "admittedAt": "<timestamp>",
                  "ageMs": "<duration>",
                  "category": "rpc-mutation",
                  "id": "<id>",
                  "method": "gateway.restart",
                  "progressAt": "<timestamp>",
                  "state": "active"
                }
              ],
              "drainId": "<id>",
              "omittedCount": 0,
              "phase": "waiting",
              "revision": "<n>",
              "suspectProjectionCount": 0
            },
            "restartNow": true,
            "restarting": "<blinded:#1559>",
            "scheduled": true
          }
        }
      },
      {
        "client": "phone",
        "method": "gateway.drain.status",
        "params": {},
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "blockerCount": 0,
            "blockerCounts": {},
            "blockers": [],
            "drainId": "<id>",
            "omittedCount": 0,
            "phase": "complete",
            "revision": "<n>",
            "suspectProjectionCount": 0
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
            "text": "answer before the reload"
          }
        ]
      },
      {
        "sessionShape": "chat",
        "messages": [
          {
            "role": "user",
            "text": "answer before the reload"
          },
          {
            "role": "assistant",
            "text": "Answer before the reload."
          },
          {
            "role": "user",
            "text": "hold this run through the restart"
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
        "provider": "tron-lock-run-lifecycle-rpcs",
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
          "provider": "tron-lock-run-lifecycle-rpcs",
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
                "model": "tron-lock-run-lifecycle-rpcs/faux-1"
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
                "provider": "tron-lock-run-lifecycle-rpcs"
              }
            },
            "model.thinking[role=chat]": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "model": "tron-lock-run-lifecycle-rpcs/faux-1",
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
                "model": "tron-lock-run-lifecycle-rpcs/faux-1"
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
                "provider": "tron-lock-run-lifecycle-rpcs"
              }
            },
            "model.thinking[role=chat]": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "model": "tron-lock-run-lifecycle-rpcs/faux-1",
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
              "text": "answer before the reload",
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
              "text": "Answer before the reload.",
              "type": "text"
            }
          ],
          "durationMs": "<duration>",
          "model": "faux-1",
          "provider": "tron-lock-run-lifecycle-rpcs",
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
              "text": "hold this run through the restart",
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
              "text": "Run settled during the drain.",
              "type": "text"
            }
          ],
          "durationMs": "<duration>",
          "model": "faux-1",
          "provider": "tron-lock-run-lifecycle-rpcs",
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
    "observed": {
      "refused": {
        "unsupervisedRestart": {
          "code": "unsupported",
          "message": "Gateway restart requires an external supervisor",
          "retryable": false
        },
        "unsupervisedStop": {
          "code": "unsupported",
          "message": "Gateway stop requires an external supervisor",
          "retryable": false
        },
        "malformedRestartNow": {
          "code": "invalid_request",
          "message": "Gateway restart restartNow must be boolean",
          "retryable": false
        },
        "extraRestart": {
          "code": "invalid_request",
          "message": "Gateway restart accepts only commandId and optional restartNow",
          "retryable": false
        },
        "extraStop": {
          "code": "invalid_request",
          "message": "Gateway stop accepts only commandId",
          "retryable": false
        }
      },
      "reload": {
        "idle": {
          "reloaded": true
        },
        "running": {
          "code": "busy",
          "message": "Session must be idle for this operation",
          "retryable": false
        }
      },
      "restart": {
        "accepted": {
          "activeSessionIds": [
            "<session:live>"
          ],
          "drain": {
            "blockerCount": 2,
            "blockerCounts": {
              "foreground-agent-operation": 1,
              "rpc-mutation": 1
            },
            "blockers": [
              {
                "admittedAt": "<timestamp>",
                "ageMs": "<duration>",
                "category": "foreground-agent-operation",
                "id": "<id>",
                "progressAt": "<timestamp>",
                "sessionId": "<session:live>",
                "state": "active"
              },
              {
                "admittedAt": "<timestamp>",
                "ageMs": "<duration>",
                "category": "rpc-mutation",
                "id": "<id>",
                "method": "gateway.restart",
                "progressAt": "<timestamp>",
                "state": "active"
              }
            ],
            "drainId": "<id>",
            "omittedCount": 0,
            "phase": "preparing",
            "revision": "<n>",
            "suspectProjectionCount": 0
          },
          "drainId": "<id>",
          "drainRevision": 4,
          "restarting": "<blinded:#1559>",
          "scheduled": true
        },
        "secondRestart": {
          "code": "busy",
          "message": "Gateway is already draining accepted work; inspect gateway.drain.status or command.status",
          "retryable": true
        },
        "stopDuringDrain": {
          "code": "busy",
          "message": "Gateway is already draining accepted work; inspect gateway.drain.status or command.status",
          "retryable": true
        },
        "promptDuringDrain": {
          "code": "busy",
          "message": "The Gateway is draining accepted work",
          "retryable": true
        },
        "restartNow": {
          "drain": {
            "blockerCount": 2,
            "blockerCounts": {
              "foreground-agent-operation": 1,
              "rpc-mutation": 1
            },
            "blockers": [
              {
                "admittedAt": "<timestamp>",
                "ageMs": "<duration>",
                "category": "foreground-agent-operation",
                "id": "<id>",
                "progressAt": "<timestamp>",
                "sessionId": "<session:live>",
                "state": "active"
              },
              {
                "admittedAt": "<timestamp>",
                "ageMs": "<duration>",
                "category": "rpc-mutation",
                "id": "<id>",
                "method": "gateway.restart",
                "progressAt": "<timestamp>",
                "state": "active"
              }
            ],
            "drainId": "<id>",
            "omittedCount": 0,
            "phase": "waiting",
            "revision": "<n>",
            "suspectProjectionCount": 0
          },
          "restartNow": true,
          "restarting": "<blinded:#1559>",
          "scheduled": true
        },
        "requestsBeforeSettle": [
          {
            "kind": "auth.cancelWaitingForRestart"
          },
          {
            "kind": "restart",
            "restartNow": false
          },
          {
            "kind": "restart",
            "restartNow": true
          }
        ],
        "completed": true,
        "complete": {
          "blockerCount": 0,
          "blockerCounts": {},
          "blockers": [],
          "drainId": "<id>",
          "omittedCount": 0,
          "phase": "complete",
          "revision": "<n>",
          "suspectProjectionCount": 0
        },
        "requests": [
          {
            "kind": "auth.cancelWaitingForRestart"
          },
          {
            "kind": "restart",
            "restartNow": false
          },
          {
            "kind": "restart",
            "restartNow": true
          }
        ]
      },
      "stop": {
        "completed": true,
        "requests": [
          {
            "kind": "stop"
          }
        ],
        "exchanges": [
          {
            "client": "mac",
            "method": "gateway.stop",
            "params": {
              "commandId": "lock-command-0001"
            },
            "response": {
              "error": null,
              "ok": true,
              "result": {
                "activeSessionIds": [],
                "drain": {
                  "blockerCount": 1,
                  "blockerCounts": {
                    "rpc-mutation": 1
                  },
                  "blockers": [
                    {
                      "admittedAt": "<timestamp>",
                      "ageMs": "<duration>",
                      "category": "rpc-mutation",
                      "id": "<id>",
                      "method": "gateway.stop",
                      "progressAt": "<timestamp>",
                      "state": "active"
                    }
                  ],
                  "drainId": "<id>",
                  "omittedCount": 0,
                  "phase": "preparing",
                  "revision": "<n>",
                  "suspectProjectionCount": 0
                },
                "drainId": "<id>",
                "drainRevision": 3,
                "scheduled": true,
                "stopping": "<blinded:#1559>"
              }
            }
          },
          {
            "client": "mac",
            "method": "gateway.drain.status",
            "params": {},
            "response": {
              "error": null,
              "ok": true,
              "result": {
                "blockerCount": 0,
                "blockerCounts": {},
                "blockers": [],
                "drainId": "<id>",
                "omittedCount": 0,
                "phase": "complete",
                "revision": "<n>",
                "suspectProjectionCount": 0
              }
            }
          }
        ]
      }
    }
  },
};
