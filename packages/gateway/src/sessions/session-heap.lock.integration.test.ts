import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockGateway } from "../../test-support/gateway-lock-harness.js";
import { normalizeTraceValue, type TraceValue } from "../../test-support/scenario-lock.js";
import { expectScenario } from "../../test-support/lock-projections.js";
import { createAndOpen, DETACHED_RUN, drainBlockersScenario, openExisting, WAITING_COMMAND } from "../../test-support/lock-scenarios.js";

/**
 * Heap and drain locks (restructure plan §6.4, V3; K-0 §7, guarding E5's run
 * ownership and E7's eviction and drain) for the `gateway/run` module, beside
 * `session-lifecycle.lock` (E0d), through the real Gateway (`gateway-lock-harness.ts`).
 *
 * - `run-eviction-choice`: under a three-runtime cap with several eligible
 *   runtimes, each capacity eviction retires the least recently used settled,
 *   closed session; an open session and a never-persisted draft are skipped.
 * - `run-drain-blockers`: blockers that are not a live agent run hold the
 *   administrative drain: an extension command waiting for the user's answer
 *   (still its prompt's preflight work: the handler runs inside admission),
 *   and a detached extension run (an extension tool's declared asynchronous run
 *   with its live status artifact) that outlives the turn which started it. The
 *   drain completes only after the answer and the run's terminal artifact.
 */

const gateways: LockGateway[] = [];
afterEach(async () => { await Promise.all(gateways.splice(0).map((gateway) => gateway.dispose())); });

/** Eviction orders by the registry's millisecond touch clock (`Date.now()`):
 * return only once that clock has moved past every touch made so far, so each
 * later touch is strictly newer. The lock also checks the recorded touch order. */
async function tick(): Promise<void> {
  const last = Date.now();
  while (Date.now() <= last) await new Promise<void>((resolve) => { setImmediate(resolve); });
}

/** Replace each session id by its role, so a normalized record still says which session. */
function labelled(value: unknown, roles: ReadonlyMap<string, string>, gateway: LockGateway): TraceValue {
  let text = JSON.stringify(value ?? null);
  for (const [sessionId, role] of roles) text = text.split(sessionId).join(`<session:${role}>`);
  return normalizeTraceValue(JSON.parse(text), { ...gateway.normalization, stableIds: [...roles.values()].map((role) => `<session:${role}>`) });
}

describe("gateway/run heap and drain locks", () => {
  it("run-eviction-choice: capacity evicts the least recently used eligible runtime, never an open session or an unsaved draft", async () => {
    const gateway = await startLockGateway("run-eviction-choice", { maximumLiveRuntimes: 3 });
    gateways.push(gateway);
    const phone = await gateway.connect("phone");
    gateway.script(["A", "B", "C"].map((role) => () => fauxAssistantMessage(`Session ${role} answered.`)));
    const roles = new Map<string, string>();
    const settledAndClosed = async (role: string): Promise<string> => {
      const session = await createAndOpen(gateway, phone);
      roles.set(session.sessionId, role);
      expect((await phone.request("session.prompt", { commandId: gateway.commandId(), sessionId: session.sessionId, text: `session ${role} turn` })).ok).toBe(true);
      await gateway.settled(session.sessionId);
      expect((await phone.request("session.close", { sessionId: session.sessionId, subscriptionToken: session.subscriptionToken })).ok).toBe(true);
      await tick();
      return session.sessionId;
    };
    const live = () => {
      const current = new Set<string>();
      for (const entry of gateway.runtimeLifecycle) {
        if (entry.event === "runtime.loaded") current.add(entry.sessionId);
        else current.delete(entry.sessionId);
      }
      return [...current].map((id) => roles.get(id) ?? "unknown").sort();
    };

    // A, B and C settle and close. C is reopened and stays open, then A and B are
    // reopened and closed: by touch, C (open) < A < B.
    const a = await settledAndClosed("A");
    const b = await settledAndClosed("B");
    const c = await settledAndClosed("C");
    const openC = await openExisting(phone, c);
    await tick();
    for (const sessionId of [a, b]) {
      const reopened = await openExisting(phone, sessionId);
      expect((await phone.request("session.close", { sessionId, subscriptionToken: reopened.subscriptionToken })).ok).toBe(true);
      await tick();
    }
    const liveFull = live();
    // The touch clock the eviction sorts by, read without acquiring (which touches).
    const slots = (gateway.registry as unknown as { slots: Map<string, { touchedAt: number }> }).slots;
    const touchOrder = [...slots].sort(([, left], [, right]) => left.touchedAt - right.touchedAt)
      .map(([id]) => roles.get(id));
    const touchesDistinct = new Set([...slots.values()].map((slot) => slot.touchedAt)).size === slots.size;

    // D needs a slot: the oldest, C, is open, so A goes.
    const d = await createAndOpen(gateway, phone);
    roles.set(d.sessionId, "D-draft");
    const liveAfterD = live();
    await tick();
    // E needs a slot once the draft D is closed: C is open and D was never saved, so B goes.
    expect((await phone.request("session.close", { sessionId: d.sessionId, subscriptionToken: d.subscriptionToken })).ok).toBe(true);
    await tick();
    const e = await createAndOpen(gateway, phone);
    roles.set(e.sessionId, "E-open");
    const liveAfterE = live();
    // Nothing is eligible: C and E are open, D is unsaved. Once C closes, it goes.
    const refused = await phone.request("session.create", { commandId: gateway.commandId(), cwd: gateway.cwd });
    expect((await phone.request("session.close", { sessionId: c, subscriptionToken: openC.subscriptionToken })).ok).toBe(true);
    await tick();
    const f = await createAndOpen(gateway, phone);
    roles.set(f.sessionId, "F-open");
    const liveAfterF = live();
    const list = await phone.request("session.list", {});

    const recorded = gateway.record();
    const trace = {
      lock: "run-eviction-choice",
      exchanges: recorded.exchanges.map((entry) => labelled(entry, roles, gateway)),
      providerRequests: recorded.providerRequests as unknown as TraceValue[],
      observed: {
        runtimeLifecycle: gateway.runtimeLifecycle.map((entry) => labelled({ event: entry.event, session: entry.sessionId, reason: entry.reason }, roles, gateway)),
        live: { full: liveFull, afterD: liveAfterD, afterE: liveAfterE, afterF: liveAfterF },
        refused: labelled(refused.error, roles, gateway),
        list: labelled(list.result, roles, gateway),
      },
    };
    expectScenario(trace as unknown as Record<string, unknown>, EXPECTED[trace.lock]);
    expect(liveFull).toEqual(["A", "B", "C"]);
    expect(touchesDistinct).toBe(true);
    expect(touchOrder).toEqual(["C", "A", "B"]);
    expect(liveAfterD).toEqual(["B", "C", "D-draft"]);
    expect(liveAfterE).toEqual(["C", "D-draft", "E-open"]);
    expect(liveAfterF).toEqual(["D-draft", "E-open", "F-open"]);
    expect(refused.error).toMatchObject({ code: "busy" });
    const evictions = trace.observed.runtimeLifecycle.filter((entry) => JSON.stringify(entry).includes("runtime.evicted"));
    expect(evictions).toEqual(["A", "B", "C"].map((role) => ({ event: "runtime.evicted", session: `<session:${role}>`, reason: "capacity" })));
  }, 60_000);

  it("run-drain-blockers: a waiting extension command and a detached extension run hold the drain until they settle", async () => {
    const gateway = await startLockGateway("run-drain-blockers", {
      extensions: [{ name: "lock-ask.ts", source: WAITING_COMMAND }, { name: "lock-background.ts", source: DETACHED_RUN }],
    });
    gateways.push(gateway);
    const { phone, asking, detached, roles, commandResponse, statusBefore, statusWaiting, statusAfterAnswer, completed, statusComplete, activities } =
      await drainBlockersScenario(gateway);

    const recorded = gateway.record();
    const label = (response: { result?: unknown; error?: unknown }) => labelled(response.result ?? response.error ?? null, roles, gateway);
    const trace = {
      lock: "run-drain-blockers",
      providerRequests: recorded.providerRequests as unknown as TraceValue[],
      // A command alone never saves a new session, so only its transcript projection exists.
      commandTranscript: label(await phone.request("session.transcript", { sessionId: asking.sessionId })),
      canonicalJsonl: await gateway.canonical(detached.sessionId),
      observed: {
        commandResponse: label(commandResponse),
        drain: {
          before: label(statusBefore), waiting: label(statusWaiting), afterAnswer: label(statusAfterAnswer), completed, complete: label(statusComplete),
        },
        activities: activities.map((activity) => labelled({ status: activity.status, mode: activity.mode ?? null, state: activity.lifecycle?.state ?? null }, roles, gateway)),
      },
    };
    expectScenario(trace as unknown as Record<string, unknown>, EXPECTED[trace.lock]);
    const categories = (status: { result?: { blockers: Array<{ category: string; sessionId?: string }> } }) =>
      status.result!.blockers.map((blocker) => `${roles.get(blocker.sessionId ?? "") ?? "none"}:${blocker.category}`).sort();
    // A command's handler runs inside Pi's admission, so its wait is still the
    // prompt's preflight work, which owns its select.
    expect(categories(statusWaiting)).toEqual(["command:prompt-preflight", "detached:detached-extension-run"]);
    expect(categories(statusAfterAnswer)).toEqual(["detached:detached-extension-run"]);
    expect(statusWaiting.result.phase).toBe("waiting");
    expect(statusAfterAnswer.result.phase).toBe("waiting");
    expect(commandResponse.ok, JSON.stringify(commandResponse)).toBe(true);
    expect(completed).toBe(true);
    expect(statusComplete.result).toMatchObject({ phase: "complete", blockerCount: 0 });
    expect(trace.observed.activities).toEqual([{ status: "completed", mode: "asynchronous", state: "completed" }]);
  }, 60_000);
});


/** Each lock's expected trace (`test-support/lock-projections.ts` `expectScenario`): its normalized exchanges, canonical JSONL, provider conversations and observed state, with model-visible parts named by session shape. */
const EXPECTED: Record<string, unknown> = {
  "run-eviction-choice": {
    "lock": "run-eviction-choice",
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
                    "provider": "tron-lock-run-eviction-choice"
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
                  "provider": "tron-lock-run-eviction-choice"
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
                "provider": "tron-lock-run-eviction-choice"
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
                    "provider": "tron-lock-run-eviction-choice"
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
          "text": "session A turn"
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
        "method": "session.close",
        "params": {
          "sessionId": "<id>",
          "subscriptionToken": "<id>"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "closed": true
          }
        }
      },
      {
        "client": "phone",
        "method": "session.create",
        "params": {
          "commandId": "lock-command-0003",
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
                    "provider": "tron-lock-run-eviction-choice"
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
                  "provider": "tron-lock-run-eviction-choice"
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
                "provider": "tron-lock-run-eviction-choice"
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
                    "provider": "tron-lock-run-eviction-choice"
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
          "commandId": "lock-command-0004",
          "sessionId": "<id>",
          "text": "session B turn"
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
        "method": "session.close",
        "params": {
          "sessionId": "<id>",
          "subscriptionToken": "<id>"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "closed": true
          }
        }
      },
      {
        "client": "phone",
        "method": "session.create",
        "params": {
          "commandId": "lock-command-0005",
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
                    "provider": "tron-lock-run-eviction-choice"
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
                  "provider": "tron-lock-run-eviction-choice"
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
                "provider": "tron-lock-run-eviction-choice"
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
                    "provider": "tron-lock-run-eviction-choice"
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
          "commandId": "lock-command-0006",
          "sessionId": "<id>",
          "text": "session C turn"
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
        "method": "session.close",
        "params": {
          "sessionId": "<id>",
          "subscriptionToken": "<id>"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "closed": true
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
            "completionRevision": 1,
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
                    "provider": "tron-lock-run-eviction-choice"
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
                  "provider": "tron-lock-run-eviction-choice"
                },
                "override": 128000,
                "source": "session"
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
                "provider": "tron-lock-run-eviction-choice"
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
                "latestCacheHitRate": "<value>",
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
                    "provider": "tron-lock-run-eviction-choice"
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
                      "text": "session C turn",
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
                      "text": "Session C answered.",
                      "type": "text"
                    }
                  ],
                  "id": "<id>",
                  "kind": "message",
                  "modelId": "faux-1",
                  "parentId": "<id>",
                  "presentationId": "<id>",
                  "provider": "tron-lock-run-eviction-choice",
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
              "transcriptStart": 0,
              "transcriptTotal": 4
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
        "method": "session.open",
        "params": {
          "sessionId": "<id>"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "completionRevision": 1,
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
                    "provider": "tron-lock-run-eviction-choice"
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
                  "provider": "tron-lock-run-eviction-choice"
                },
                "override": 128000,
                "source": "session"
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
                "provider": "tron-lock-run-eviction-choice"
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
                "latestCacheHitRate": "<value>",
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
                    "provider": "tron-lock-run-eviction-choice"
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
                      "text": "session A turn",
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
                      "text": "Session A answered.",
                      "type": "text"
                    }
                  ],
                  "id": "<id>",
                  "kind": "message",
                  "modelId": "faux-1",
                  "parentId": "<id>",
                  "presentationId": "<id>",
                  "provider": "tron-lock-run-eviction-choice",
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
              "transcriptStart": 0,
              "transcriptTotal": 4
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
        "method": "session.close",
        "params": {
          "sessionId": "<id>",
          "subscriptionToken": "<id>"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "closed": true
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
            "completionRevision": 1,
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
                    "provider": "tron-lock-run-eviction-choice"
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
                  "provider": "tron-lock-run-eviction-choice"
                },
                "override": 128000,
                "source": "session"
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
                "provider": "tron-lock-run-eviction-choice"
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
                "latestCacheHitRate": "<value>",
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
                    "provider": "tron-lock-run-eviction-choice"
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
                      "text": "session B turn",
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
                      "text": "Session B answered.",
                      "type": "text"
                    }
                  ],
                  "id": "<id>",
                  "kind": "message",
                  "modelId": "faux-1",
                  "parentId": "<id>",
                  "presentationId": "<id>",
                  "provider": "tron-lock-run-eviction-choice",
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
              "transcriptStart": 0,
              "transcriptTotal": 4
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
        "method": "session.close",
        "params": {
          "sessionId": "<id>",
          "subscriptionToken": "<id>"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "closed": true
          }
        }
      },
      {
        "client": "phone",
        "method": "session.create",
        "params": {
          "commandId": "lock-command-0007",
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
                    "provider": "tron-lock-run-eviction-choice"
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
                  "provider": "tron-lock-run-eviction-choice"
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
                "provider": "tron-lock-run-eviction-choice"
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
                    "provider": "tron-lock-run-eviction-choice"
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
        "method": "session.close",
        "params": {
          "sessionId": "<id>",
          "subscriptionToken": "<id>"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "closed": true
          }
        }
      },
      {
        "client": "phone",
        "method": "session.create",
        "params": {
          "commandId": "lock-command-0008",
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
                    "provider": "tron-lock-run-eviction-choice"
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
                  "provider": "tron-lock-run-eviction-choice"
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
                "provider": "tron-lock-run-eviction-choice"
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
                    "provider": "tron-lock-run-eviction-choice"
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
        "method": "session.create",
        "params": {
          "commandId": "lock-command-0009",
          "cwd": "<tmp>/workspace"
        },
        "response": {
          "error": {
            "code": "busy",
            "message": "Gateway live runtime capacity is full; close or wait for an idle session",
            "retryable": true
          },
          "ok": false,
          "result": null
        }
      },
      {
        "client": "phone",
        "method": "session.close",
        "params": {
          "sessionId": "<id>",
          "subscriptionToken": "<id>"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "closed": true
          }
        }
      },
      {
        "client": "phone",
        "method": "session.create",
        "params": {
          "commandId": "lock-command-0010",
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
                    "provider": "tron-lock-run-eviction-choice"
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
                  "provider": "tron-lock-run-eviction-choice"
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
                "provider": "tron-lock-run-eviction-choice"
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
                    "provider": "tron-lock-run-eviction-choice"
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
        "method": "session.list",
        "params": {},
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "archivedCount": 0,
            "listRevision": 6,
            "projectionToken": "<id>",
            "sessions": [
              {
                "attentionRevision": 0,
                "completionRevision": 0,
                "createdAt": "<timestamp>",
                "cwd": "<tmp>/workspace",
                "firstMessage": "",
                "foregroundPhase": "idle",
                "hasActiveSubagents": false,
                "id": "<id>",
                "isUnread": false,
                "kind": "user",
                "messageCount": 0,
                "phase": "idle",
                "summaryRevision": 1,
                "updatedAt": "<timestamp>",
                "waitingForUser": false
              },
              {
                "attentionRevision": 0,
                "completionRevision": 0,
                "createdAt": "<timestamp>",
                "cwd": "<tmp>/workspace",
                "firstMessage": "",
                "foregroundPhase": "idle",
                "hasActiveSubagents": false,
                "id": "<id>",
                "isUnread": false,
                "kind": "user",
                "messageCount": 0,
                "phase": "idle",
                "summaryRevision": 1,
                "updatedAt": "<timestamp>",
                "waitingForUser": false
              },
              {
                "attentionRevision": 0,
                "completionRevision": 0,
                "createdAt": "<timestamp>",
                "cwd": "<tmp>/workspace",
                "firstMessage": "",
                "foregroundPhase": "idle",
                "hasActiveSubagents": false,
                "id": "<id>",
                "isUnread": false,
                "kind": "user",
                "messageCount": 0,
                "phase": "idle",
                "summaryRevision": 1,
                "updatedAt": "<timestamp>",
                "waitingForUser": false
              },
              {
                "attentionRevision": 1,
                "completionRevision": 1,
                "createdAt": "<timestamp>",
                "cwd": "<tmp>/workspace",
                "firstMessage": "session C turn",
                "foregroundPhase": "idle",
                "hasActiveSubagents": false,
                "id": "<id>",
                "isUnread": true,
                "kind": "user",
                "messageCount": 2,
                "phase": "idle",
                "summaryRevision": 7,
                "updatedAt": "<timestamp>",
                "waitingForUser": false
              },
              {
                "attentionRevision": 1,
                "completionRevision": 1,
                "createdAt": "<timestamp>",
                "cwd": "<tmp>/workspace",
                "firstMessage": "session B turn",
                "foregroundPhase": "idle",
                "hasActiveSubagents": false,
                "id": "<id>",
                "isUnread": true,
                "kind": "user",
                "messageCount": 2,
                "phase": "idle",
                "summaryRevision": 7,
                "updatedAt": "<timestamp>",
                "waitingForUser": false
              },
              {
                "attentionRevision": 1,
                "completionRevision": 1,
                "createdAt": "<timestamp>",
                "cwd": "<tmp>/workspace",
                "firstMessage": "session A turn",
                "foregroundPhase": "idle",
                "hasActiveSubagents": false,
                "id": "<id>",
                "isUnread": true,
                "kind": "user",
                "messageCount": 2,
                "phase": "idle",
                "summaryRevision": 7,
                "updatedAt": "<timestamp>",
                "waitingForUser": false
              }
            ]
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
            "text": "session A turn"
          }
        ]
      },
      {
        "sessionShape": "chat",
        "messages": [
          {
            "role": "user",
            "text": "session B turn"
          }
        ]
      },
      {
        "sessionShape": "chat",
        "messages": [
          {
            "role": "user",
            "text": "session C turn"
          }
        ]
      }
    ],
    "observed": {
      "runtimeLifecycle": [
        {
          "event": "runtime.loaded",
          "reason": "create",
          "session": "<session:A>"
        },
        {
          "event": "runtime.loaded",
          "reason": "create",
          "session": "<session:B>"
        },
        {
          "event": "runtime.loaded",
          "reason": "create",
          "session": "<session:C>"
        },
        {
          "event": "runtime.evicted",
          "reason": "capacity",
          "session": "<session:A>"
        },
        {
          "event": "runtime.loaded",
          "reason": "create",
          "session": "<session:D-draft>"
        },
        {
          "event": "runtime.evicted",
          "reason": "capacity",
          "session": "<session:B>"
        },
        {
          "event": "runtime.loaded",
          "reason": "create",
          "session": "<session:E-open>"
        },
        {
          "event": "runtime.evicted",
          "reason": "capacity",
          "session": "<session:C>"
        },
        {
          "event": "runtime.loaded",
          "reason": "create",
          "session": "<session:F-open>"
        }
      ],
      "live": {
        "full": [
          "A",
          "B",
          "C"
        ],
        "afterD": [
          "B",
          "C",
          "D-draft"
        ],
        "afterE": [
          "C",
          "D-draft",
          "E-open"
        ],
        "afterF": [
          "D-draft",
          "E-open",
          "F-open"
        ]
      },
      "refused": {
        "code": "busy",
        "message": "Gateway live runtime capacity is full; close or wait for an idle session",
        "retryable": true
      },
      "list": {
        "archivedCount": 0,
        "listRevision": 6,
        "projectionToken": "<id>",
        "sessions": [
          {
            "attentionRevision": 0,
            "completionRevision": 0,
            "createdAt": "<timestamp>",
            "cwd": "<tmp>/workspace",
            "firstMessage": "",
            "foregroundPhase": "idle",
            "hasActiveSubagents": false,
            "id": "<session:F-open>",
            "isUnread": false,
            "kind": "user",
            "messageCount": 0,
            "phase": "idle",
            "summaryRevision": 1,
            "updatedAt": "<timestamp>",
            "waitingForUser": false
          },
          {
            "attentionRevision": 0,
            "completionRevision": 0,
            "createdAt": "<timestamp>",
            "cwd": "<tmp>/workspace",
            "firstMessage": "",
            "foregroundPhase": "idle",
            "hasActiveSubagents": false,
            "id": "<session:E-open>",
            "isUnread": false,
            "kind": "user",
            "messageCount": 0,
            "phase": "idle",
            "summaryRevision": 1,
            "updatedAt": "<timestamp>",
            "waitingForUser": false
          },
          {
            "attentionRevision": 0,
            "completionRevision": 0,
            "createdAt": "<timestamp>",
            "cwd": "<tmp>/workspace",
            "firstMessage": "",
            "foregroundPhase": "idle",
            "hasActiveSubagents": false,
            "id": "<session:D-draft>",
            "isUnread": false,
            "kind": "user",
            "messageCount": 0,
            "phase": "idle",
            "summaryRevision": 1,
            "updatedAt": "<timestamp>",
            "waitingForUser": false
          },
          {
            "attentionRevision": 1,
            "completionRevision": 1,
            "createdAt": "<timestamp>",
            "cwd": "<tmp>/workspace",
            "firstMessage": "session C turn",
            "foregroundPhase": "idle",
            "hasActiveSubagents": false,
            "id": "<session:C>",
            "isUnread": true,
            "kind": "user",
            "messageCount": 2,
            "phase": "idle",
            "summaryRevision": 7,
            "updatedAt": "<timestamp>",
            "waitingForUser": false
          },
          {
            "attentionRevision": 1,
            "completionRevision": 1,
            "createdAt": "<timestamp>",
            "cwd": "<tmp>/workspace",
            "firstMessage": "session B turn",
            "foregroundPhase": "idle",
            "hasActiveSubagents": false,
            "id": "<session:B>",
            "isUnread": true,
            "kind": "user",
            "messageCount": 2,
            "phase": "idle",
            "summaryRevision": 7,
            "updatedAt": "<timestamp>",
            "waitingForUser": false
          },
          {
            "attentionRevision": 1,
            "completionRevision": 1,
            "createdAt": "<timestamp>",
            "cwd": "<tmp>/workspace",
            "firstMessage": "session A turn",
            "foregroundPhase": "idle",
            "hasActiveSubagents": false,
            "id": "<session:A>",
            "isUnread": true,
            "kind": "user",
            "messageCount": 2,
            "phase": "idle",
            "summaryRevision": 7,
            "updatedAt": "<timestamp>",
            "waitingForUser": false
          }
        ]
      }
    }
  },
  "run-drain-blockers": {
    "lock": "run-drain-blockers",
    "providerRequests": [
      {
        "sessionShape": "chatWithExtensionBackground",
        "messages": [
          {
            "role": "user",
            "text": "start the background run"
          }
        ]
      },
      {
        "sessionShape": "chatWithExtensionBackground",
        "messages": [
          {
            "role": "user",
            "text": "start the background run"
          },
          {
            "role": "assistant",
            "text": "",
            "toolCalls": [
              "lock_background"
            ]
          },
          {
            "role": "toolResult",
            "text": "Background run started.",
            "toolName": "lock_background"
          }
        ]
      }
    ],
    "commandTranscript": {
      "end": 3,
      "items": [
        {
          "id": "<id>",
          "kind": "modelChange",
          "modelRef": {
            "id": "<id>",
            "provider": "tron-lock-run-drain-blockers"
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
          "customType": "tron.chat-invocation.v1",
          "id": "<id>",
          "kind": "customEntry",
          "parentId": "<id>",
          "semantic": {
            "contextEffect": "none",
            "delivery": "stored",
            "direction": "ambientStatus",
            "invocationId": "<id>",
            "kind": "command",
            "lifecycle": "completed",
            "operationId": "<id>",
            "origin": {
              "confidence": "adapter",
              "kind": "extension",
              "ownerId": "extension:<digest>",
              "title": "Lock Ask"
            },
            "resourceInvocations": [
              {
                "arguments": "",
                "name": "lockask",
                "source": "extension"
              }
            ],
            "sequence": "<n>",
            "version": 1,
            "visibility": "visible"
          },
          "timestamp": "<timestamp>"
        }
      ],
      "leafEntryId": "<id>",
      "runtimeGeneration": "<id>",
      "start": 0,
      "total": 3
    },
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
        "provider": "tron-lock-run-drain-blockers",
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
          "provider": "tron-lock-run-drain-blockers",
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
                "model": "tron-lock-run-drain-blockers/faux-1"
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
                "provider": "tron-lock-run-drain-blockers"
              }
            },
            "model.thinking[role=chat]": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "model": "tron-lock-run-drain-blockers/faux-1",
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
                "lock_background",
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
                "model": "tron-lock-run-drain-blockers/faux-1"
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
                "provider": "tron-lock-run-drain-blockers"
              }
            },
            "model.thinking[role=chat]": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "model": "tron-lock-run-drain-blockers/faux-1",
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
                "lock_background",
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
            "sessionShape": "chatWithExtensionBackground#0"
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
              "text": "start the background run",
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
              "name": "lock_background",
              "type": "toolCall"
            }
          ],
          "durationMs": "<duration>",
          "model": "faux-1",
          "provider": "tron-lock-run-drain-blockers",
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
              "text": "Background run started.",
              "type": "text"
            }
          ],
          "details": {
            "asyncDir": "<tmp>/workspace/.pi/subagents/async-subagent-runs/lock-background-run",
            "runId": "<id>",
            "state": "running"
          },
          "durationMs": "<duration>",
          "isError": false,
          "role": "toolResult",
          "timestamp": "<timestamp>",
          "toolCallId": "<id>",
          "toolName": "lock_background"
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
              "text": "The background run is under way.",
              "type": "text"
            }
          ],
          "durationMs": "<duration>",
          "model": "faux-1",
          "provider": "tron-lock-run-drain-blockers",
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
        "customType": "tron.extension-activity.v1",
        "data": {
          "activityId": "<id>",
          "mode": "asynchronous",
          "observedAt": "<timestamp>",
          "owner": {
            "id": "<id>",
            "kind": "extension",
            "source": "auto",
            "title": "Lock Background"
          },
          "runId": "<id>",
          "sessionId": "<id>",
          "startedAt": "<timestamp>",
          "state": "completed",
          "summary": {},
          "terminalAt": "<timestamp>",
          "toolCallId": "<id>",
          "version": 1
        },
        "id": "<id>",
        "parentId": "<id>",
        "timestamp": "<timestamp>",
        "type": "custom"
      }
    ],
    "observed": {
      "commandResponse": {
        "operationId": "<id>"
      },
      "drain": {
        "before": {
          "blockerCount": 2,
          "blockerCounts": {
            "detached-extension-run": 1,
            "prompt-preflight": 1
          },
          "blockers": [
            {
              "admittedAt": "<timestamp>",
              "ageMs": "<duration>",
              "category": "detached-extension-run",
              "id": "<id>",
              "sessionId": "<session:detached>",
              "state": "active"
            },
            {
              "admittedAt": "<timestamp>",
              "ageMs": "<duration>",
              "category": "prompt-preflight",
              "id": "<id>",
              "progressAt": "<timestamp>",
              "sessionId": "<session:command>",
              "state": "active"
            }
          ],
          "drainId": "<id>",
          "omittedCount": 0,
          "phase": "idle",
          "revision": "<n>",
          "suspectProjectionCount": 0
        },
        "waiting": {
          "blockerCount": 2,
          "blockerCounts": {
            "detached-extension-run": 1,
            "prompt-preflight": 1
          },
          "blockers": [
            {
              "admittedAt": "<timestamp>",
              "ageMs": "<duration>",
              "category": "detached-extension-run",
              "id": "<id>",
              "sessionId": "<session:detached>",
              "state": "active"
            },
            {
              "admittedAt": "<timestamp>",
              "ageMs": "<duration>",
              "category": "prompt-preflight",
              "id": "<id>",
              "progressAt": "<timestamp>",
              "sessionId": "<session:command>",
              "state": "active"
            }
          ],
          "drainId": "<id>",
          "omittedCount": 0,
          "phase": "waiting",
          "revision": "<n>",
          "suspectProjectionCount": 0
        },
        "afterAnswer": {
          "blockerCount": 1,
          "blockerCounts": {
            "detached-extension-run": 1
          },
          "blockers": [
            {
              "admittedAt": "<timestamp>",
              "ageMs": "<duration>",
              "category": "detached-extension-run",
              "id": "<id>",
              "sessionId": "<session:detached>",
              "state": "active"
            }
          ],
          "drainId": "<id>",
          "omittedCount": 0,
          "phase": "waiting",
          "revision": "<n>",
          "suspectProjectionCount": 0
        },
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
        }
      },
      "activities": [
        {
          "mode": "asynchronous",
          "state": "completed",
          "status": "completed"
        }
      ]
    }
  },
};
