import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockClient, type LockGateway } from "../../test-support/gateway-lock-harness.js";
import { normalizeTraceValue, type TraceValue } from "../../test-support/scenario-lock.js";
import { expectSessionLock, projectedSnapshot, type SessionLockExpectation } from "../../test-support/lock-projections.js";
import { awaitsWithin, waitFor } from "../../test-support/wait-for.js";

/**
 * Session lifecycle locks (restructure plan §6.4, V3; K-0 §7 E0d) guarding the
 * heap, eviction, cold load and drain owners that kernel slices E5 (`run/`) and
 * E7 (`session/`) move out of `RuntimeRegistry`. Each runs the real Gateway over
 * a loopback WebSocket (`gateway-lock-harness.ts`) with the faux provider.
 *
 * - `run-cold-load-eviction`: under a one-runtime cap, an open session is never
 *   reclaimed (a second create is refused); once its client closed it, the
 *   settled session is evicted for capacity by the next create, stays in the
 *   catalog with its attention state while cold, and is cold-loaded back by
 *   `session.open` with its canonical JSONL, transcript and context intact.
 * - `run-drain-snapshot`: the administrative drain (`waitUntilIdle`, what the
 *   restart and stop drains run) observed through `gateway.drain.status`: idle,
 *   a live run with a queued follow-up named as the blocker while waiting (an
 *   idle session is not), new work refused, and completion only after the
 *   follow-up ran.
 *
 * Session ids normalize to `<id>`, so `observed` names each session by its role.
 */

const gateways: LockGateway[] = [];
afterEach(async () => { await Promise.all(gateways.splice(0).map((gateway) => gateway.dispose())); });

interface Opened { readonly sessionId: string; readonly subscriptionToken: string; readonly open: { ok: boolean; result?: any; error?: any } }

async function createAndOpen(gateway: LockGateway, client: LockClient, cwd = gateway.cwd): Promise<Opened> {
  const created = await client.request("session.create", { commandId: gateway.commandId(), cwd });
  expect(created.ok, JSON.stringify(created)).toBe(true);
  return open(client, created.result.sessionId as string);
}

async function open(client: LockClient, sessionId: string): Promise<Opened> {
  const opened = await client.request("session.open", { sessionId });
  expect(opened.ok, JSON.stringify(opened)).toBe(true);
  expect((await client.request("session.sync", { sessionId, syncToken: opened.result.syncToken })).ok).toBe(true);
  return { sessionId, subscriptionToken: opened.result.subscriptionToken as string, open: opened };
}

/** A gate a scripted provider step holds until the test opens it. */
function gate(): { opened: Promise<void>; open(): void; reached: Promise<void>; reach(): void } {
  let open = (): void => {};
  let reach = (): void => {};
  const opened = new Promise<void>((resolve) => { open = resolve; });
  const reached = new Promise<void>((resolve) => { reach = resolve; });
  return { opened, open: () => open(), reached, reach: () => reach() };
}

/** Replace each session id by its role, so a normalized record still says which session. */
function labelled(value: unknown, roles: ReadonlyMap<string, string>, gateway: LockGateway): TraceValue {
  let text = JSON.stringify(value);
  for (const [sessionId, role] of roles) text = text.split(sessionId).join(`<session:${role}>`);
  return normalizeTraceValue(JSON.parse(text), { ...gateway.normalization, stableIds: [...roles.values()].map((role) => `<session:${role}>`) });
}

/** The live runtimes by role, as the registry's own load and eviction records leave them. */
function liveRoles(gateway: LockGateway, roles: ReadonlyMap<string, string>): string[] {
  const live = new Set<string>();
  for (const entry of gateway.runtimeLifecycle) {
    if (entry.event === "runtime.loaded") live.add(entry.sessionId);
    else live.delete(entry.sessionId);
  }
  return [...live].map((id) => roles.get(id) ?? "unknown").sort();
}

describe("session lifecycle kernel locks", () => {
  it("cold load and eviction: a capacity-evicted session keeps its catalog row and attention, and reloads intact", async () => {
    const gateway = await startLockGateway("run-cold-load-eviction", { maximumLiveRuntimes: 1 });
    gateways.push(gateway);
    const phone = await gateway.connect("phone");
    gateway.script([
      async () => {
        await gateway.observeLiveOperation(phone, first.sessionId);
        return fauxAssistantMessage("First answer before eviction.");
      },
      () => fauxAssistantMessage("Second session answer."),
      () => fauxAssistantMessage("Answer after the cold load."),
    ]);

    // A: one settled turn that completes while no client presents it (unread), then closed.
    const first = await createAndOpen(gateway, phone);
    const roles = new Map([[first.sessionId, "A"]]);
    expect((await phone.request("session.prompt", { commandId: gateway.commandId(), sessionId: first.sessionId, text: "remember the word lantern" })).ok).toBe(true);
    await gateway.settled(first.sessionId);
    const canonicalBefore = await gateway.canonical(first.sessionId);
    const listLive = await phone.request("session.list", {});
    // An open (subscribed) runtime is never reclaimed: the cap refuses a second one.
    const refusedWhileOpen = await phone.request("session.create", { commandId: gateway.commandId(), cwd: gateway.cwd });
    expect((await phone.request("session.close", { sessionId: first.sessionId, subscriptionToken: first.subscriptionToken })).ok).toBe(true);

    // B: the next create needs A's runtime slot; A is reloadable and unobserved.
    const second = await createAndOpen(gateway, phone);
    roles.set(second.sessionId, "B");
    const liveAfterEviction = liveRoles(gateway, roles);
    const listCold = await phone.request("session.list", {});

    // A again: B is persisted by its own turn, so once closed it is the one evicted
    // for capacity, and session.open cold-loads A from its file.
    expect((await phone.request("session.prompt", { commandId: gateway.commandId(), sessionId: second.sessionId, text: "a second session turn" })).ok).toBe(true);
    await gateway.settled(second.sessionId);
    expect((await phone.request("session.close", { sessionId: second.sessionId, subscriptionToken: second.subscriptionToken })).ok).toBe(true);
    const reopened = await open(phone, first.sessionId);
    const liveAfterColdLoad = liveRoles(gateway, roles);
    const canonicalReloaded = await gateway.canonical(first.sessionId);
    const read = await phone.request("session.attention.read", {
      sessionId: first.sessionId, throughCompletionRevision: reopened.open.result.completionRevision,
    });
    // The reloaded runtime carries the earlier turn into the next provider request.
    expect((await phone.request("session.prompt", { commandId: gateway.commandId(), sessionId: first.sessionId, text: "which word?" })).ok).toBe(true);
    await gateway.settled(first.sessionId);
    const transcript = await phone.request("session.transcript", { sessionId: first.sessionId });
    const listFinal = await phone.request("session.list", {});

    const recorded = gateway.record();
    const trace = {
      lock: "run-cold-load-eviction",
      exchanges: recorded.exchanges,
      events: recorded.events,
      providerRequests: recorded.providerRequests as unknown as TraceValue[],
      canonicalJsonl: await gateway.canonical(first.sessionId),
      observed: {
        runtimeLifecycle: gateway.runtimeLifecycle.map((entry) => labelled({ event: entry.event, session: entry.sessionId, reason: entry.reason }, roles, gateway)),
        liveAfterEviction, liveAfterColdLoad,
        canonicalUnchangedByEviction: JSON.stringify(canonicalReloaded) === JSON.stringify(canonicalBefore),
        list: {
          live: labelled(listLive.result, roles, gateway),
          cold: labelled(listCold.result, roles, gateway),
          final: labelled(listFinal.result, roles, gateway),
        },
        attentionRead: labelled(read.result, roles, gateway),
      },
    };
    expectSessionLock(trace.lock, { exchanges: recorded.exchanges, canonical: trace.canonicalJsonl, items: [],
      providers: recorded.providerRequests.map((request) => request.messages) }, EXPECTED[trace.lock]!);
    expect(projectedSnapshot(trace.observed), `${trace.lock}: what the lock observed`).toEqual(EXPECTED[trace.lock]!.observed);
    expect(trace.observed.runtimeLifecycle).toContainEqual({ event: "runtime.evicted", session: "<session:A>", reason: "capacity" });
    expect(trace.observed.runtimeLifecycle.filter((entry) => JSON.stringify(entry).includes("<session:A>") && JSON.stringify(entry).includes("runtime.loaded"))).toHaveLength(2);
    expect(refusedWhileOpen.error).toMatchObject({ code: "busy" });
    expect(liveAfterEviction).toEqual(["B"]);
    expect(liveAfterColdLoad).toEqual(["A"]);
    expect(trace.observed.canonicalUnchangedByEviction).toBe(true);
    expect(JSON.stringify(listCold.result)).toContain(first.sessionId);
    expect(read.ok, JSON.stringify(read)).toBe(true);
    expect(transcript.ok, JSON.stringify(transcript)).toBe(true);
    const last = recorded.providerRequests.at(-1)!;
    expect(JSON.stringify(last.messages)).toContain("remember the word lantern");
    expect(JSON.stringify(last.messages)).toContain("First answer before eviction.");
  });

  it("drain snapshot: a live run and its queued follow-up block the drain, new work is refused, and the drain completes after both", async () => {
    const gateway = await startLockGateway("run-drain-snapshot");
    gateways.push(gateway);
    const phone = await gateway.connect("phone");
    const held = gate();
    gateway.script([
      async () => { held.reach(); await held.opened; return fauxAssistantMessage("Held run settled."); },
      () => fauxAssistantMessage("Queued follow-up answered."),
    ]);
    const running = await createAndOpen(gateway, phone);
    const idle = await createAndOpen(gateway, phone);
    const roles = new Map([[running.sessionId, "running"], [idle.sessionId, "idle"]]);

    const statusIdle = await phone.request("gateway.drain.status", {});
    const admitted = await phone.request("session.prompt", { commandId: gateway.commandId(), sessionId: running.sessionId, text: "hold this run open" });
    expect(admitted.ok, JSON.stringify(admitted)).toBe(true);
    await awaitsWithin(held.reached, "the held provider request");
    // Accepted queued work stays authoritative: the drain waits for it, never clears it.
    const queued = await phone.request("session.prompt", { commandId: gateway.commandId(), sessionId: running.sessionId, text: "queued before the drain", behavior: "followUp" });
    // A prompt RPC's own work settles just after its response frame; wait for that
    // exact work, so each status names only the run and its queue.
    const rpcSettled = () => waitFor(() => !gateway.registry.administrativeDrainSnapshot().blockers
      .some((blocker) => blocker.category === "rpc-mutation"), "the prompt RPCs' own work to settle");
    await rpcSettled();
    const statusRunning = await phone.request("gateway.drain.status", {});

    // gateway.restart and gateway.stop begin the drain in their RPC turn and answer
    // with this snapshot; gateway-main's runRestartDrain/runStopDrain then wait.
    const begun = gateway.registry.beginAdministrativeDrain();
    const drained = gateway.registry.waitUntilIdle();
    await waitFor(() => gateway.registry.administrativeDrainSnapshot().phase === "waiting", "the drain to wait on the live run");
    await rpcSettled();
    const statusWaiting = await phone.request("gateway.drain.status", {});
    const refusedPrompt = await phone.request("session.prompt", { commandId: gateway.commandId(), sessionId: idle.sessionId, text: "new work during the drain" });
    const refusedCreate = await phone.request("session.create", { commandId: gateway.commandId(), cwd: gateway.cwd });

    held.open();
    const completed = await awaitsWithin(drained, "the drain to complete");
    const statusComplete = await phone.request("gateway.drain.status", {});

    const recorded = gateway.record();
    const label = (response: { result?: unknown; error?: unknown }) => labelled(response.result ?? response.error ?? null, roles, gateway);
    const trace = {
      lock: "run-drain-snapshot",
      exchanges: recorded.exchanges,
      providerRequests: recorded.providerRequests as unknown as TraceValue[],
      canonicalJsonl: await gateway.canonical(running.sessionId),
      observed: {
        completed,
        drain: {
          idle: label(statusIdle), running: label(statusRunning), begun: labelled(begun, roles, gateway), waiting: label(statusWaiting), complete: label(statusComplete),
        },
        refused: { prompt: label(refusedPrompt), create: label(refusedCreate) },
      },
    };
    expectSessionLock(trace.lock, { exchanges: recorded.exchanges, canonical: trace.canonicalJsonl, items: [],
      providers: recorded.providerRequests.map((request) => request.messages) }, EXPECTED[trace.lock]!);
    expect(projectedSnapshot(trace.observed), `${trace.lock}: what the lock observed`).toEqual(EXPECTED[trace.lock]!.observed);
    expect(completed).toBe(true);
    expect(queued.ok, JSON.stringify(queued)).toBe(true);
    expect(JSON.stringify(trace.canonicalJsonl)).toContain("Queued follow-up answered.");
    expect(statusIdle.result.phase).toBe("idle");
    expect(begun.phase).toBe("preparing");
    expect(statusWaiting.result.phase).toBe("waiting");
    expect(statusWaiting.result.blockerCount).toBeGreaterThan(0);
    expect(JSON.stringify(trace.observed.drain.waiting)).toContain("<session:running>");
    expect(JSON.stringify(trace.observed.drain.waiting)).not.toContain("<session:idle>");
    expect(refusedPrompt.ok).toBe(false);
    expect(refusedCreate.ok).toBe(false);
    expect(statusComplete.result).toMatchObject({ phase: "complete", blockerCount: 0 });
  });
});

/** What each converted lock in this file expects (`test-support/lock-projections.ts`), with what it observed. */
const EXPECTED: Record<string, SessionLockExpectation & { observed: unknown }> = {
  "run-cold-load-eviction": {
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
          "result": {}
        }
      },
      {
        "method": "session.open",
        "params": {},
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
                  "provider": "<LOCK>"
                },
                "override": 128000,
                "source": "session",
                "warning": "This new session and its context override are not yet saved to disk; they persist after the first user or assistant message."
              },
              "cwd": "<tmp>/workspace",
              "diagnostics": [],
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
                "pendingInteractions": [],
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
              "liveActivityRevision": 0,
              "model": {
                "provider": "<LOCK>"
              },
              "phase": "idle",
              "processOverview": {
                "activeCount": 0,
                "problemCount": 0,
                "recentCount": 0,
                "version": 1,
                "visibility": "hidden"
              },
              "queueRevision": 0,
              "queuedItems": [],
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
                  "kind": "modelChange",
                  "modelRef": {
                    "provider": "<LOCK>"
                  },
                  "semantic": {
                    "contextEffect": "none",
                    "delivery": "stored",
                    "direction": "ambientStatus",
                    "kind": "status",
                    "origin": {
                      "confidence": "boundary",
                      "kind": "gateway"
                    },
                    "version": 1,
                    "visibility": "visible"
                  }
                },
                {
                  "kind": "thinkingChange",
                  "level": "off",
                  "semantic": {
                    "contextEffect": "none",
                    "delivery": "stored",
                    "direction": "ambientStatus",
                    "kind": "status",
                    "origin": {
                      "confidence": "boundary",
                      "kind": "gateway"
                    },
                    "version": 1,
                    "visibility": "visible"
                  }
                }
              ],
              "transcriptStart": 0,
              "transcriptTotal": 2
            }
          }
        }
      },
      {
        "method": "session.sync",
        "params": {},
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
          "text": "remember the word lantern"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {}
        }
      },
      {
        "method": "session.list",
        "params": {},
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "archivedCount": 0,
            "listRevision": 1,
            "projectionToken": "<id>",
            "sessions": [
              {
                "attentionRevision": 1,
                "completionRevision": 1,
                "createdAt": "<timestamp>",
                "cwd": "<tmp>/workspace",
                "firstMessage": "remember the word lantern",
                "foregroundPhase": "idle",
                "hasActiveSubagents": false,
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
      {
        "method": "session.create",
        "params": {
          "commandId": "lock-command-0003",
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
        "method": "session.close",
        "params": {},
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "closed": true
          }
        }
      },
      {
        "method": "session.create",
        "params": {
          "commandId": "lock-command-0004",
          "cwd": "<tmp>/workspace"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {}
        }
      },
      {
        "method": "session.open",
        "params": {},
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
                  "provider": "<LOCK>"
                },
                "override": 128000,
                "source": "session",
                "warning": "This new session and its context override are not yet saved to disk; they persist after the first user or assistant message."
              },
              "cwd": "<tmp>/workspace",
              "diagnostics": [],
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
                "pendingInteractions": [],
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
              "liveActivityRevision": 0,
              "model": {
                "provider": "<LOCK>"
              },
              "phase": "idle",
              "processOverview": {
                "activeCount": 0,
                "problemCount": 0,
                "recentCount": 0,
                "version": 1,
                "visibility": "hidden"
              },
              "queueRevision": 0,
              "queuedItems": [],
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
                  "kind": "modelChange",
                  "modelRef": {
                    "provider": "<LOCK>"
                  },
                  "semantic": {
                    "contextEffect": "none",
                    "delivery": "stored",
                    "direction": "ambientStatus",
                    "kind": "status",
                    "origin": {
                      "confidence": "boundary",
                      "kind": "gateway"
                    },
                    "version": 1,
                    "visibility": "visible"
                  }
                },
                {
                  "kind": "thinkingChange",
                  "level": "off",
                  "semantic": {
                    "contextEffect": "none",
                    "delivery": "stored",
                    "direction": "ambientStatus",
                    "kind": "status",
                    "origin": {
                      "confidence": "boundary",
                      "kind": "gateway"
                    },
                    "version": 1,
                    "visibility": "visible"
                  }
                }
              ],
              "transcriptStart": 0,
              "transcriptTotal": 2
            }
          }
        }
      },
      {
        "method": "session.sync",
        "params": {},
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "synchronized": true
          }
        }
      },
      {
        "method": "session.list",
        "params": {},
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "archivedCount": 0,
            "listRevision": 2,
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
                "firstMessage": "remember the word lantern",
                "foregroundPhase": "idle",
                "hasActiveSubagents": false,
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
      {
        "method": "session.prompt",
        "params": {
          "commandId": "lock-command-0005",
          "text": "a second session turn"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {}
        }
      },
      {
        "method": "session.close",
        "params": {},
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "closed": true
          }
        }
      },
      {
        "method": "session.open",
        "params": {},
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
                  "provider": "<LOCK>"
                },
                "override": 128000,
                "source": "session"
              },
              "cwd": "<tmp>/workspace",
              "diagnostics": [],
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
                "pendingInteractions": [],
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
              "liveActivityRevision": 0,
              "model": {
                "provider": "<LOCK>"
              },
              "phase": "idle",
              "processOverview": {
                "activeCount": 0,
                "problemCount": 0,
                "recentCount": 0,
                "version": 1,
                "visibility": "hidden"
              },
              "queueRevision": 0,
              "queuedItems": [],
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
                  "kind": "modelChange",
                  "modelRef": {
                    "provider": "<LOCK>"
                  },
                  "semantic": {
                    "contextEffect": "none",
                    "delivery": "stored",
                    "direction": "ambientStatus",
                    "kind": "status",
                    "origin": {
                      "confidence": "boundary",
                      "kind": "gateway"
                    },
                    "version": 1,
                    "visibility": "visible"
                  }
                },
                {
                  "kind": "thinkingChange",
                  "level": "off",
                  "semantic": {
                    "contextEffect": "none",
                    "delivery": "stored",
                    "direction": "ambientStatus",
                    "kind": "status",
                    "origin": {
                      "confidence": "boundary",
                      "kind": "gateway"
                    },
                    "version": 1,
                    "visibility": "visible"
                  }
                },
                {
                  "content": [
                    {
                      "ordinal": 0,
                      "text": "remember the word lantern",
                      "type": "text"
                    }
                  ],
                  "kind": "message",
                  "role": "user",
                  "semantic": {
                    "contextEffect": "modelInput",
                    "delivery": "stored",
                    "direction": "inboundContext",
                    "kind": "resourcePrompt",
                    "lifecycle": "completed",
                    "origin": {
                      "confidence": "boundary",
                      "kind": "user"
                    },
                    "version": 1,
                    "visibility": "visible"
                  }
                },
                {
                  "content": [
                    {
                      "ordinal": 0,
                      "text": "First answer before eviction.",
                      "type": "text"
                    }
                  ],
                  "kind": "message",
                  "modelId": "faux-1",
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
                    "version": 1,
                    "visibility": "visible"
                  },
                  "stopReason": "stop",
                  "thinkingLevel": "off"
                }
              ],
              "transcriptStart": 0,
              "transcriptTotal": 4
            }
          }
        }
      },
      {
        "method": "session.sync",
        "params": {},
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "synchronized": true
          }
        }
      },
      {
        "method": "session.attention.read",
        "params": {
          "throughCompletionRevision": 1
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "attentionRevision": 2,
            "completionRevision": 1,
            "isUnread": false
          }
        }
      },
      {
        "method": "session.prompt",
        "params": {
          "commandId": "lock-command-0006",
          "text": "which word?"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {}
        }
      },
      {
        "method": "session.transcript",
        "params": {},
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "end": 6,
            "items": [
              {
                "kind": "modelChange",
                "modelRef": {
                  "provider": "<LOCK>"
                },
                "semantic": {
                  "contextEffect": "none",
                  "delivery": "stored",
                  "direction": "ambientStatus",
                  "kind": "status",
                  "origin": {
                    "confidence": "boundary",
                    "kind": "gateway"
                  },
                  "version": 1,
                  "visibility": "visible"
                }
              },
              {
                "kind": "thinkingChange",
                "level": "off",
                "semantic": {
                  "contextEffect": "none",
                  "delivery": "stored",
                  "direction": "ambientStatus",
                  "kind": "status",
                  "origin": {
                    "confidence": "boundary",
                    "kind": "gateway"
                  },
                  "version": 1,
                  "visibility": "visible"
                }
              },
              {
                "content": [
                  {
                    "ordinal": 0,
                    "text": "remember the word lantern",
                    "type": "text"
                  }
                ],
                "kind": "message",
                "role": "user",
                "semantic": {
                  "contextEffect": "modelInput",
                  "delivery": "stored",
                  "direction": "inboundContext",
                  "kind": "resourcePrompt",
                  "lifecycle": "completed",
                  "origin": {
                    "confidence": "boundary",
                    "kind": "user"
                  },
                  "version": 1,
                  "visibility": "visible"
                }
              },
              {
                "content": [
                  {
                    "ordinal": 0,
                    "text": "First answer before eviction.",
                    "type": "text"
                  }
                ],
                "kind": "message",
                "modelId": "faux-1",
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
                  "version": 1,
                  "visibility": "visible"
                },
                "stopReason": "stop",
                "thinkingLevel": "off"
              },
              {
                "content": [
                  {
                    "ordinal": 0,
                    "text": "which word?",
                    "type": "text"
                  }
                ],
                "kind": "message",
                "role": "user",
                "semantic": {
                  "contextEffect": "modelInput",
                  "delivery": "stored",
                  "direction": "inboundContext",
                  "kind": "resourcePrompt",
                  "lifecycle": "completed",
                  "origin": {
                    "confidence": "boundary",
                    "kind": "user"
                  },
                  "version": 1,
                  "visibility": "visible"
                }
              },
              {
                "content": [
                  {
                    "ordinal": 0,
                    "text": "Answer after the cold load.",
                    "type": "text"
                  }
                ],
                "kind": "message",
                "modelId": "faux-1",
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
                  "version": 1,
                  "visibility": "visible"
                },
                "stopReason": "stop",
                "thinkingLevel": "off"
              }
            ],
            "start": 0,
            "total": 6
          }
        }
      },
      {
        "method": "session.list",
        "params": {},
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "archivedCount": 0,
            "listRevision": 3,
            "projectionToken": "<id>",
            "sessions": [
              {
                "attentionRevision": 3,
                "completionRevision": 2,
                "createdAt": "<timestamp>",
                "cwd": "<tmp>/workspace",
                "firstMessage": "remember the word lantern",
                "foregroundPhase": "idle",
                "hasActiveSubagents": false,
                "isUnread": true,
                "kind": "user",
                "messageCount": 4,
                "phase": "idle",
                "summaryRevision": 15,
                "updatedAt": "<timestamp>",
                "waitingForUser": false
              },
              {
                "attentionRevision": 1,
                "completionRevision": 1,
                "createdAt": "<timestamp>",
                "cwd": "<tmp>/workspace",
                "firstMessage": "a second session turn",
                "foregroundPhase": "idle",
                "hasActiveSubagents": false,
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
    "messages": [
      {
        "content": [
          {
            "text": "remember the word lantern",
            "type": "text"
          }
        ],
        "role": "user"
      },
      {
        "content": [
          {
            "text": "First answer before eviction.",
            "type": "text"
          }
        ],
        "model": "faux-1",
        "provider": "<LOCK>",
        "role": "assistant",
        "stopReason": "stop",
        "thinkingLevel": "off"
      },
      {
        "content": [
          {
            "text": "which word?",
            "type": "text"
          }
        ],
        "role": "user"
      },
      {
        "content": [
          {
            "text": "Answer after the cold load.",
            "type": "text"
          }
        ],
        "model": "faux-1",
        "provider": "<LOCK>",
        "role": "assistant",
        "stopReason": "stop",
        "thinkingLevel": "off"
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
    "sessionEntries": [
      {
        "cwd": "<tmp>/workspace",
        "type": "session",
        "version": 3
      },
      {
        "modelId": "faux-1",
        "provider": "<LOCK>",
        "type": "model_change"
      },
      {
        "thinkingLevel": "off",
        "type": "thinking_level_change"
      }
    ],
    "providers": [
      [
        {
          "role": "user",
          "text": "remember the word lantern"
        }
      ],
      [
        {
          "role": "user",
          "text": "a second session turn"
        }
      ],
      [
        {
          "role": "user",
          "text": "remember the word lantern"
        },
        {
          "role": "assistant",
          "text": "First answer before eviction."
        },
        {
          "role": "user",
          "text": "which word?"
        }
      ]
    ],
    "observed": {
      "runtimeLifecycle": [
        {
          "event": "runtime.loaded",
          "reason": "create",
          "session": "<session:A>"
        },
        {
          "event": "runtime.evicted",
          "reason": "capacity",
          "session": "<session:A>"
        },
        {
          "event": "runtime.loaded",
          "reason": "create",
          "session": "<session:B>"
        },
        {
          "event": "runtime.evicted",
          "reason": "capacity",
          "session": "<session:B>"
        },
        {
          "event": "runtime.loaded",
          "reason": "open",
          "session": "<session:A>"
        }
      ],
      "liveAfterEviction": [
        "B"
      ],
      "liveAfterColdLoad": [
        "A"
      ],
      "canonicalUnchangedByEviction": true,
      "list": {
        "live": {
          "archivedCount": 0,
          "listRevision": 1,
          "projectionToken": "<id>",
          "sessions": [
            {
              "attentionRevision": 1,
              "completionRevision": 1,
              "createdAt": "<timestamp>",
              "cwd": "<tmp>/workspace",
              "firstMessage": "remember the word lantern",
              "foregroundPhase": "idle",
              "hasActiveSubagents": false,
              "isUnread": true,
              "kind": "user",
              "messageCount": 2,
              "phase": "idle",
              "summaryRevision": 7,
              "updatedAt": "<timestamp>",
              "waitingForUser": false
            }
          ]
        },
        "cold": {
          "archivedCount": 0,
          "listRevision": 2,
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
              "firstMessage": "remember the word lantern",
              "foregroundPhase": "idle",
              "hasActiveSubagents": false,
              "isUnread": true,
              "kind": "user",
              "messageCount": 2,
              "phase": "idle",
              "summaryRevision": 7,
              "updatedAt": "<timestamp>",
              "waitingForUser": false
            }
          ]
        },
        "final": {
          "archivedCount": 0,
          "listRevision": 3,
          "projectionToken": "<id>",
          "sessions": [
            {
              "attentionRevision": 3,
              "completionRevision": 2,
              "createdAt": "<timestamp>",
              "cwd": "<tmp>/workspace",
              "firstMessage": "remember the word lantern",
              "foregroundPhase": "idle",
              "hasActiveSubagents": false,
              "isUnread": true,
              "kind": "user",
              "messageCount": 4,
              "phase": "idle",
              "summaryRevision": 15,
              "updatedAt": "<timestamp>",
              "waitingForUser": false
            },
            {
              "attentionRevision": 1,
              "completionRevision": 1,
              "createdAt": "<timestamp>",
              "cwd": "<tmp>/workspace",
              "firstMessage": "a second session turn",
              "foregroundPhase": "idle",
              "hasActiveSubagents": false,
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
      },
      "attentionRead": {
        "attentionRevision": 2,
        "completionRevision": 1,
        "isUnread": false
      }
    }
  },
  "run-drain-snapshot": {
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
          "result": {}
        }
      },
      {
        "method": "session.open",
        "params": {},
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
                  "provider": "<LOCK>"
                },
                "override": 128000,
                "source": "session",
                "warning": "This new session and its context override are not yet saved to disk; they persist after the first user or assistant message."
              },
              "cwd": "<tmp>/workspace",
              "diagnostics": [],
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
                "pendingInteractions": [],
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
              "liveActivityRevision": 0,
              "model": {
                "provider": "<LOCK>"
              },
              "phase": "idle",
              "processOverview": {
                "activeCount": 0,
                "problemCount": 0,
                "recentCount": 0,
                "version": 1,
                "visibility": "hidden"
              },
              "queueRevision": 0,
              "queuedItems": [],
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
                  "kind": "modelChange",
                  "modelRef": {
                    "provider": "<LOCK>"
                  },
                  "semantic": {
                    "contextEffect": "none",
                    "delivery": "stored",
                    "direction": "ambientStatus",
                    "kind": "status",
                    "origin": {
                      "confidence": "boundary",
                      "kind": "gateway"
                    },
                    "version": 1,
                    "visibility": "visible"
                  }
                },
                {
                  "kind": "thinkingChange",
                  "level": "off",
                  "semantic": {
                    "contextEffect": "none",
                    "delivery": "stored",
                    "direction": "ambientStatus",
                    "kind": "status",
                    "origin": {
                      "confidence": "boundary",
                      "kind": "gateway"
                    },
                    "version": 1,
                    "visibility": "visible"
                  }
                }
              ],
              "transcriptStart": 0,
              "transcriptTotal": 2
            }
          }
        }
      },
      {
        "method": "session.sync",
        "params": {},
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "synchronized": true
          }
        }
      },
      {
        "method": "session.create",
        "params": {
          "commandId": "lock-command-0002",
          "cwd": "<tmp>/workspace"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {}
        }
      },
      {
        "method": "session.open",
        "params": {},
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
                  "provider": "<LOCK>"
                },
                "override": 128000,
                "source": "session",
                "warning": "This new session and its context override are not yet saved to disk; they persist after the first user or assistant message."
              },
              "cwd": "<tmp>/workspace",
              "diagnostics": [],
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
                "pendingInteractions": [],
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
              "liveActivityRevision": 0,
              "model": {
                "provider": "<LOCK>"
              },
              "phase": "idle",
              "processOverview": {
                "activeCount": 0,
                "problemCount": 0,
                "recentCount": 0,
                "version": 1,
                "visibility": "hidden"
              },
              "queueRevision": 0,
              "queuedItems": [],
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
                  "kind": "modelChange",
                  "modelRef": {
                    "provider": "<LOCK>"
                  },
                  "semantic": {
                    "contextEffect": "none",
                    "delivery": "stored",
                    "direction": "ambientStatus",
                    "kind": "status",
                    "origin": {
                      "confidence": "boundary",
                      "kind": "gateway"
                    },
                    "version": 1,
                    "visibility": "visible"
                  }
                },
                {
                  "kind": "thinkingChange",
                  "level": "off",
                  "semantic": {
                    "contextEffect": "none",
                    "delivery": "stored",
                    "direction": "ambientStatus",
                    "kind": "status",
                    "origin": {
                      "confidence": "boundary",
                      "kind": "gateway"
                    },
                    "version": 1,
                    "visibility": "visible"
                  }
                }
              ],
              "transcriptStart": 0,
              "transcriptTotal": 2
            }
          }
        }
      },
      {
        "method": "session.sync",
        "params": {},
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "synchronized": true
          }
        }
      },
      {
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
            "phase": "idle",
            "suspectProjectionCount": 0
          }
        }
      },
      {
        "method": "session.prompt",
        "params": {
          "commandId": "lock-command-0003",
          "text": "hold this run open"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {}
        }
      },
      {
        "method": "session.prompt",
        "params": {
          "behavior": "followUp",
          "commandId": "lock-command-0004",
          "text": "queued before the drain"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {}
        }
      },
      {
        "method": "gateway.drain.status",
        "params": {},
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "blockerCount": 2,
            "blockerCounts": {
              "foreground-agent-operation": 1,
              "queued-mutation": 1
            },
            "blockers": [
              {
                "admittedAt": "<timestamp>",
                "ageMs": "<duration>",
                "category": "foreground-agent-operation",
                "progressAt": "<timestamp>",
                "state": "active"
              },
              {
                "admittedAt": "<timestamp>",
                "ageMs": "<duration>",
                "category": "queued-mutation",
                "progressAt": "<timestamp>",
                "state": "active"
              }
            ],
            "drainId": "<id>",
            "omittedCount": 0,
            "phase": "idle",
            "suspectProjectionCount": 0
          }
        }
      },
      {
        "method": "gateway.drain.status",
        "params": {},
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "blockerCount": 2,
            "blockerCounts": {
              "foreground-agent-operation": 1,
              "queued-mutation": 1
            },
            "blockers": [
              {
                "admittedAt": "<timestamp>",
                "ageMs": "<duration>",
                "category": "foreground-agent-operation",
                "progressAt": "<timestamp>",
                "state": "active"
              },
              {
                "admittedAt": "<timestamp>",
                "ageMs": "<duration>",
                "category": "queued-mutation",
                "progressAt": "<timestamp>",
                "state": "active"
              }
            ],
            "drainId": "<id>",
            "omittedCount": 0,
            "phase": "waiting",
            "suspectProjectionCount": 0
          }
        }
      },
      {
        "method": "session.prompt",
        "params": {
          "commandId": "lock-command-0005",
          "text": "new work during the drain"
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
        "method": "session.create",
        "params": {
          "commandId": "lock-command-0006",
          "cwd": "<tmp>/workspace"
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
            "suspectProjectionCount": 0
          }
        }
      }
    ],
    "messages": [
      {
        "content": [
          {
            "text": "hold this run open",
            "type": "text"
          }
        ],
        "role": "user"
      },
      {
        "content": [
          {
            "text": "Held run settled.",
            "type": "text"
          }
        ],
        "model": "faux-1",
        "provider": "<LOCK>",
        "role": "assistant",
        "stopReason": "stop",
        "thinkingLevel": "off"
      },
      {
        "content": [
          {
            "text": "queued before the drain",
            "type": "text"
          }
        ],
        "role": "user"
      },
      {
        "content": [
          {
            "text": "Queued follow-up answered.",
            "type": "text"
          }
        ],
        "model": "faux-1",
        "provider": "<LOCK>",
        "role": "assistant",
        "stopReason": "stop",
        "thinkingLevel": "off"
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
    "sessionEntries": [
      {
        "cwd": "<tmp>/workspace",
        "type": "session",
        "version": 3
      },
      {
        "modelId": "faux-1",
        "provider": "<LOCK>",
        "type": "model_change"
      },
      {
        "thinkingLevel": "off",
        "type": "thinking_level_change"
      }
    ],
    "providers": [
      [
        {
          "role": "user",
          "text": "hold this run open"
        }
      ],
      [
        {
          "role": "user",
          "text": "hold this run open"
        },
        {
          "role": "assistant",
          "text": "Held run settled."
        },
        {
          "role": "user",
          "text": "queued before the drain"
        }
      ]
    ],
    "observed": {
      "completed": true,
      "drain": {
        "idle": {
          "blockerCount": 0,
          "blockerCounts": {},
          "blockers": [],
          "drainId": "<id>",
          "omittedCount": 0,
          "phase": "idle",
          "suspectProjectionCount": 0
        },
        "running": {
          "blockerCount": 2,
          "blockerCounts": {
            "foreground-agent-operation": 1,
            "queued-mutation": 1
          },
          "blockers": [
            {
              "admittedAt": "<timestamp>",
              "ageMs": "<duration>",
              "category": "foreground-agent-operation",
              "progressAt": "<timestamp>",
              "state": "active"
            },
            {
              "admittedAt": "<timestamp>",
              "ageMs": "<duration>",
              "category": "queued-mutation",
              "progressAt": "<timestamp>",
              "state": "active"
            }
          ],
          "drainId": "<id>",
          "omittedCount": 0,
          "phase": "idle",
          "suspectProjectionCount": 0
        },
        "begun": {
          "blockerCount": 2,
          "blockerCounts": {
            "foreground-agent-operation": 1,
            "queued-mutation": 1
          },
          "blockers": [
            {
              "admittedAt": "<timestamp>",
              "ageMs": "<duration>",
              "category": "foreground-agent-operation",
              "progressAt": "<timestamp>",
              "state": "active"
            },
            {
              "admittedAt": "<timestamp>",
              "ageMs": "<duration>",
              "category": "queued-mutation",
              "progressAt": "<timestamp>",
              "state": "active"
            }
          ],
          "drainId": "<id>",
          "omittedCount": 0,
          "phase": "preparing",
          "suspectProjectionCount": 0
        },
        "waiting": {
          "blockerCount": 2,
          "blockerCounts": {
            "foreground-agent-operation": 1,
            "queued-mutation": 1
          },
          "blockers": [
            {
              "admittedAt": "<timestamp>",
              "ageMs": "<duration>",
              "category": "foreground-agent-operation",
              "progressAt": "<timestamp>",
              "state": "active"
            },
            {
              "admittedAt": "<timestamp>",
              "ageMs": "<duration>",
              "category": "queued-mutation",
              "progressAt": "<timestamp>",
              "state": "active"
            }
          ],
          "drainId": "<id>",
          "omittedCount": 0,
          "phase": "waiting",
          "suspectProjectionCount": 0
        },
        "complete": {
          "blockerCount": 0,
          "blockerCounts": {},
          "blockers": [],
          "drainId": "<id>",
          "omittedCount": 0,
          "phase": "complete",
          "suspectProjectionCount": 0
        }
      },
      "refused": {
        "prompt": {
          "code": "busy",
          "message": "The Gateway is draining accepted work",
          "retryable": true
        },
        "create": {
          "code": "busy",
          "message": "The Gateway is draining accepted work",
          "retryable": true
        }
      }
    }
  },
};
