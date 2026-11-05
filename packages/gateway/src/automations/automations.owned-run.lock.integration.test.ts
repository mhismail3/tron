import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockGateway } from "../../test-support/gateway-lock-harness.js";
import { normalizeTraceValue, type TraceValue } from "../../test-support/scenario-lock.js";
import { expectScenario } from "../../test-support/lock-projections.js";
import { automationOwnedRunScenario } from "../../test-support/lock-scenarios.js";

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
 * trip. The lock records the client exchanges (command-receipted mutations,
 * the settled automation and run reads), event shapes, provider requests, both
 * sessions' canonical JSONL (ownership markers and invocation receipts), the
 * automation records, every command receipt, and the runtime-marker store the
 * acknowledged runs leave empty.
 */

const gateways: LockGateway[] = [];
afterEach(async () => { await Promise.all(gateways.splice(0).map((gateway) => gateway.dispose())); });

/**
 * Per-run digests the shared normalization keeps because they are not under an
 * identity key: the occurrence id and the command-receipt identity hash (both
 * digests of generated ids) and the assistant completion id (a generated Pi
 * entry id). Each distinct value becomes `<key:N>` in first-appearance order, so
 * a run, its receipt and its reads still visibly name the same occurrence.
 */
const DERIVED_IDENTITIES = new Set(["occurrenceId", "identityHash", "assistantCompletionId"]);
function stabilizeDerivedIdentities(value: TraceValue): TraceValue {
  const seen = new Map<string, string>();
  const visit = (node: TraceValue, key?: string): TraceValue => {
    if (typeof node === "string" && key !== undefined && DERIVED_IDENTITIES.has(key)) {
      const scoped = `${key}\0${node}`;
      if (!seen.has(scoped)) seen.set(scoped, `<${key}:${[...seen.keys()].filter((entry) => entry.startsWith(`${key}\0`)).length + 1}>`);
      return seen.get(scoped)!;
    }
    if (Array.isArray(node)) return node.map((child) => visit(child));
    if (node !== null && typeof node === "object") return Object.fromEntries(Object.entries(node).map(([name, child]) => [name, visit(child, name)]));
    return node;
  };
  return visit(value);
}

/** The ids of a session's assistant entries, raw, in file order. */
async function assistantEntryIds(gateway: LockGateway, sessionId: string): Promise<string[]> {
  const slot = await gateway.registry.acquire(sessionId);
  return (await readFile(slot.sessionFile!, "utf8")).trimEnd().split("\n").flatMap((line) => {
    const entry = JSON.parse(line) as { id?: string; type?: string; message?: { role?: string } };
    return entry.type === "message" && entry.message?.role === "assistant" ? [entry.id!] : [];
  });
}


describe("gateway/automations owned-run lock", () => {
  it("automation-owned-run: a session prompt and a workspace prompt run now through the owned-session boundary", async () => {
    const gateway = await startLockGateway("automation-owned-run", { automations: true });
    gateways.push(gateway);
    const { sessionId, existing, workspace } = await automationOwnedRunScenario(gateway);
    const automationFile = (automationId: string) => join(gateway.tronHome, "gateway", "automations", `${automationId}.json`);
    const recorded = gateway.record();
    const receipts = join(gateway.tronHome, "gateway", "command-receipts");
    const completions = [(await assistantEntryIds(gateway, sessionId)).at(-1), (await assistantEntryIds(gateway, workspace.executionSessionId)).at(-1)];
    const trace = {
      lock: "automation-owned-run",
      exchanges: recorded.exchanges,
      events: recorded.events,
      providerRequests: recorded.providerRequests as unknown as TraceValue[],
      sessionJsonl: await gateway.canonical(sessionId),
      workspaceJsonl: await gateway.canonical(workspace.executionSessionId),
      automations: {
        session: await gateway.file(automationFile(existing.automationId)),
        workspace: await gateway.file(automationFile(workspace.automationId)),
      },
      // Receipt file names are digests of the device identity; their contents are the contract.
      commandReceipts: (await Promise.all((await gateway.tree(receipts)).map(async (name) =>
        normalizeTraceValue(JSON.parse(await readFile(join(receipts, name), "utf8")), gateway.normalization))))
        .sort((left, right) => String((left as { commandId?: string }).commandId).localeCompare(String((right as { commandId?: string }).commandId))),
      // The owned operation's runtime marker is cleared once the scheduler acknowledges the terminal.
      runtimeMarkers: await gateway.tree(join(gateway.tronHome, "gateway", "runtime-markers")),
    };
    const stable = stabilizeDerivedIdentities(trace as unknown as TraceValue);
    expectScenario(stable as unknown as Record<string, unknown>, EXPECTED["automation-owned-run"]);
    expect([existing.state, workspace.state]).toEqual(["succeeded", "succeeded"]);
    expect(existing.executionSessionId).toBe(sessionId);
    // Each run names the final assistant entry of its own session as its completion.
    expect([existing.assistantCompletionId, workspace.assistantCompletionId]).toEqual(completions);
    expect(trace.commandReceipts.map((receipt) => (receipt as { method?: string }).method)).toEqual([
      "session.create", "session.prompt", "automation.create", "automation.runNow", "automation.create", "automation.runNow",
    ]);
    expect(trace.runtimeMarkers).toEqual([]);
    expect(workspace.executionSessionId).not.toBe(sessionId);
    expect(recorded.providerRequests).toHaveLength(5);
    for (const [jsonl, text] of [[trace.sessionJsonl, "run the scheduled notes check"], [trace.workspaceJsonl, "run the workspace notes check"]] as const) {
      const roles = jsonl.flatMap((entry) => {
        const role = (entry as { message?: { role?: string } }).message?.role;
        return role ? [role] : [];
      });
      expect(roles.slice(-4)).toEqual(["user", "assistant", "toolResult", "assistant"]);
      expect(JSON.stringify(jsonl)).toContain(text);
    }
  });
});

/** Each lock's expected trace (`test-support/lock-projections.ts` `expectScenario`): the scenario's normalized trace without event schemas, with model-visible parts named by session shape. */
const EXPECTED: Record<string, unknown> = {
  "automation-owned-run": {
    "lock": "automation-owned-run",
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
                    "provider": "tron-lock-automation-owned-run"
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
                  "provider": "tron-lock-automation-owned-run"
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
                "provider": "tron-lock-automation-owned-run"
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
                    "provider": "tron-lock-automation-owned-run"
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
          "text": "get ready for scheduled checks"
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
        "method": "automation.create",
        "params": {
          "commandId": "lock-command-0003",
          "definition": {
            "action": {
              "kind": "sessionPrompt",
              "text": "run the scheduled notes check"
            },
            "activation": "draft",
            "name": "Lock session check",
            "target": {
              "kind": "existingSession",
              "sessionId": "<id>"
            },
            "trigger": {
              "at": "<timestamp>",
              "kind": "once"
            }
          }
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "action": {
              "kind": "sessionPrompt",
              "text": "run the scheduled notes check"
            },
            "activation": "draft",
            "consecutiveFailureCount": 0,
            "createdAt": "<timestamp>",
            "executionDeadlineSeconds": 3600,
            "history": [],
            "id": "<id>",
            "misfirePolicy": "latest",
            "name": "Lock session check",
            "overlapPolicy": "skip",
            "provenance": {
              "kind": "mobile"
            },
            "revision": "<n>",
            "schemaVersion": 2,
            "stateRevision": 1,
            "target": {
              "kind": "existingSession",
              "sessionId": "<id>"
            },
            "trigger": {
              "at": "<timestamp>",
              "kind": "once"
            },
            "updatedAt": "<timestamp>"
          }
        }
      },
      {
        "client": "phone",
        "method": "automation.runNow",
        "params": {
          "automationId": "<id>",
          "commandId": "lock-command-0004",
          "expectedRevision": 1
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "actionSnapshot": {
              "kind": "sessionPrompt",
              "text": "run the scheduled notes check"
            },
            "automationRevision": 1,
            "createdAt": "<timestamp>",
            "executionSessionId": "<id>",
            "manual": true,
            "occurrenceId": "<occurrenceId:1>",
            "operationId": "<id>",
            "preAdmissionAttemptCount": 0,
            "runId": "<id>",
            "scheduledFor": "<timestamp>",
            "state": "queued",
            "targetSnapshot": {
              "kind": "existingSession",
              "sessionId": "<id>"
            },
            "triggerSnapshot": {
              "at": "<timestamp>",
              "kind": "once"
            }
          }
        }
      },
      {
        "client": "phone",
        "method": "automation.create",
        "params": {
          "commandId": "lock-command-0005",
          "definition": {
            "action": {
              "kind": "sessionPrompt",
              "text": "run the workspace notes check"
            },
            "activation": "draft",
            "name": "Lock workspace check",
            "target": {
              "cwd": "<tmp>/workspace",
              "kind": "workspace",
              "sessionPolicy": "newPerRun"
            },
            "trigger": {
              "at": "<timestamp>",
              "kind": "once"
            }
          }
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "action": {
              "kind": "sessionPrompt",
              "text": "run the workspace notes check"
            },
            "activation": "draft",
            "consecutiveFailureCount": 0,
            "createdAt": "<timestamp>",
            "executionDeadlineSeconds": 3600,
            "history": [],
            "id": "<id>",
            "misfirePolicy": "latest",
            "name": "Lock workspace check",
            "overlapPolicy": "skip",
            "provenance": {
              "kind": "mobile"
            },
            "revision": "<n>",
            "schemaVersion": 2,
            "stateRevision": 1,
            "target": {
              "cwd": "<tmp>/workspace",
              "kind": "workspace",
              "sessionPolicy": "newPerRun"
            },
            "trigger": {
              "at": "<timestamp>",
              "kind": "once"
            },
            "updatedAt": "<timestamp>"
          }
        }
      },
      {
        "client": "phone",
        "method": "automation.runNow",
        "params": {
          "automationId": "<id>",
          "commandId": "lock-command-0006",
          "expectedRevision": 1
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "actionSnapshot": {
              "kind": "sessionPrompt",
              "text": "run the workspace notes check"
            },
            "automationRevision": 1,
            "createdAt": "<timestamp>",
            "executionSessionId": "<id>",
            "manual": true,
            "occurrenceId": "<occurrenceId:2>",
            "operationId": "<id>",
            "preAdmissionAttemptCount": 0,
            "runId": "<id>",
            "scheduledFor": "<timestamp>",
            "state": "queued",
            "targetSnapshot": {
              "cwd": "<tmp>/workspace",
              "kind": "workspace",
              "sessionPolicy": "newPerRun"
            },
            "triggerSnapshot": {
              "at": "<timestamp>",
              "kind": "once"
            }
          }
        }
      },
      {
        "client": "phone",
        "method": "automation.get",
        "params": {
          "automationId": "<id>"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "action": {
              "kind": "sessionPrompt",
              "text": "run the scheduled notes check"
            },
            "activation": "draft",
            "consecutiveFailureCount": 0,
            "createdAt": "<timestamp>",
            "executionDeadlineSeconds": 3600,
            "history": [
              {
                "actionSnapshot": {
                  "kind": "sessionPrompt",
                  "text": "run the scheduled notes check"
                },
                "assistantCompletionId": "<assistantCompletionId:1>",
                "automationRevision": 1,
                "claimId": "<id>",
                "claimedAt": "<timestamp>",
                "createdAt": "<timestamp>",
                "executionSessionId": "<id>",
                "hostEpoch": "<id>",
                "invocationId": "<id>",
                "manual": true,
                "occurrenceId": "<occurrenceId:1>",
                "operationId": "<id>",
                "preAdmissionAttemptCount": 0,
                "runId": "<id>",
                "scheduledFor": "<timestamp>",
                "startedAt": "<timestamp>",
                "state": "succeeded",
                "targetSnapshot": {
                  "kind": "existingSession",
                  "sessionId": "<id>"
                },
                "terminalAt": "<timestamp>",
                "triggerSnapshot": {
                  "at": "<timestamp>",
                  "kind": "once"
                }
              }
            ],
            "id": "<id>",
            "lastRun": {
              "actionSnapshot": {
                "kind": "sessionPrompt",
                "text": "run the scheduled notes check"
              },
              "assistantCompletionId": "<assistantCompletionId:1>",
              "automationRevision": 1,
              "claimId": "<id>",
              "claimedAt": "<timestamp>",
              "createdAt": "<timestamp>",
              "executionSessionId": "<id>",
              "hostEpoch": "<id>",
              "invocationId": "<id>",
              "manual": true,
              "occurrenceId": "<occurrenceId:1>",
              "operationId": "<id>",
              "preAdmissionAttemptCount": 0,
              "runId": "<id>",
              "scheduledFor": "<timestamp>",
              "startedAt": "<timestamp>",
              "state": "succeeded",
              "targetSnapshot": {
                "kind": "existingSession",
                "sessionId": "<id>"
              },
              "terminalAt": "<timestamp>",
              "triggerSnapshot": {
                "at": "<timestamp>",
                "kind": "once"
              }
            },
            "misfirePolicy": "latest",
            "name": "Lock session check",
            "overlapPolicy": "skip",
            "provenance": {
              "kind": "mobile"
            },
            "revision": "<n>",
            "schemaVersion": 2,
            "stateRevision": 5,
            "target": {
              "kind": "existingSession",
              "sessionId": "<id>"
            },
            "trigger": {
              "at": "<timestamp>",
              "kind": "once"
            },
            "updatedAt": "<timestamp>"
          }
        }
      },
      {
        "client": "phone",
        "method": "automation.run.get",
        "params": {
          "automationId": "<id>",
          "runId": "<id>"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "actionSnapshot": {
              "kind": "sessionPrompt",
              "text": "run the scheduled notes check"
            },
            "assistantCompletionId": "<assistantCompletionId:1>",
            "automationRevision": 1,
            "claimId": "<id>",
            "claimedAt": "<timestamp>",
            "createdAt": "<timestamp>",
            "executionSessionId": "<id>",
            "hostEpoch": "<id>",
            "invocationId": "<id>",
            "manual": true,
            "occurrenceId": "<occurrenceId:1>",
            "operationId": "<id>",
            "preAdmissionAttemptCount": 0,
            "runId": "<id>",
            "scheduledFor": "<timestamp>",
            "startedAt": "<timestamp>",
            "state": "succeeded",
            "targetSnapshot": {
              "kind": "existingSession",
              "sessionId": "<id>"
            },
            "terminalAt": "<timestamp>",
            "triggerSnapshot": {
              "at": "<timestamp>",
              "kind": "once"
            }
          }
        }
      },
      {
        "client": "phone",
        "method": "automation.get",
        "params": {
          "automationId": "<id>"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "action": {
              "kind": "sessionPrompt",
              "text": "run the workspace notes check"
            },
            "activation": "draft",
            "consecutiveFailureCount": 0,
            "createdAt": "<timestamp>",
            "executionDeadlineSeconds": 3600,
            "history": [
              {
                "actionSnapshot": {
                  "kind": "sessionPrompt",
                  "text": "run the workspace notes check"
                },
                "assistantCompletionId": "<assistantCompletionId:2>",
                "automationRevision": 1,
                "claimId": "<id>",
                "claimedAt": "<timestamp>",
                "createdAt": "<timestamp>",
                "executionSessionId": "<id>",
                "hostEpoch": "<id>",
                "invocationId": "<id>",
                "manual": true,
                "occurrenceId": "<occurrenceId:2>",
                "operationId": "<id>",
                "preAdmissionAttemptCount": 0,
                "runId": "<id>",
                "scheduledFor": "<timestamp>",
                "startedAt": "<timestamp>",
                "state": "succeeded",
                "targetSnapshot": {
                  "cwd": "<tmp>/workspace",
                  "kind": "workspace",
                  "sessionPolicy": "newPerRun"
                },
                "terminalAt": "<timestamp>",
                "triggerSnapshot": {
                  "at": "<timestamp>",
                  "kind": "once"
                }
              }
            ],
            "id": "<id>",
            "lastRun": {
              "actionSnapshot": {
                "kind": "sessionPrompt",
                "text": "run the workspace notes check"
              },
              "assistantCompletionId": "<assistantCompletionId:2>",
              "automationRevision": 1,
              "claimId": "<id>",
              "claimedAt": "<timestamp>",
              "createdAt": "<timestamp>",
              "executionSessionId": "<id>",
              "hostEpoch": "<id>",
              "invocationId": "<id>",
              "manual": true,
              "occurrenceId": "<occurrenceId:2>",
              "operationId": "<id>",
              "preAdmissionAttemptCount": 0,
              "runId": "<id>",
              "scheduledFor": "<timestamp>",
              "startedAt": "<timestamp>",
              "state": "succeeded",
              "targetSnapshot": {
                "cwd": "<tmp>/workspace",
                "kind": "workspace",
                "sessionPolicy": "newPerRun"
              },
              "terminalAt": "<timestamp>",
              "triggerSnapshot": {
                "at": "<timestamp>",
                "kind": "once"
              }
            },
            "misfirePolicy": "latest",
            "name": "Lock workspace check",
            "overlapPolicy": "skip",
            "provenance": {
              "kind": "mobile"
            },
            "revision": "<n>",
            "schemaVersion": 2,
            "stateRevision": 5,
            "target": {
              "cwd": "<tmp>/workspace",
              "kind": "workspace",
              "sessionPolicy": "newPerRun"
            },
            "trigger": {
              "at": "<timestamp>",
              "kind": "once"
            },
            "updatedAt": "<timestamp>"
          }
        }
      },
      {
        "client": "phone",
        "method": "automation.run.get",
        "params": {
          "automationId": "<id>",
          "runId": "<id>"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "actionSnapshot": {
              "kind": "sessionPrompt",
              "text": "run the workspace notes check"
            },
            "assistantCompletionId": "<assistantCompletionId:2>",
            "automationRevision": 1,
            "claimId": "<id>",
            "claimedAt": "<timestamp>",
            "createdAt": "<timestamp>",
            "executionSessionId": "<id>",
            "hostEpoch": "<id>",
            "invocationId": "<id>",
            "manual": true,
            "occurrenceId": "<occurrenceId:2>",
            "operationId": "<id>",
            "preAdmissionAttemptCount": 0,
            "runId": "<id>",
            "scheduledFor": "<timestamp>",
            "startedAt": "<timestamp>",
            "state": "succeeded",
            "targetSnapshot": {
              "cwd": "<tmp>/workspace",
              "kind": "workspace",
              "sessionPolicy": "newPerRun"
            },
            "terminalAt": "<timestamp>",
            "triggerSnapshot": {
              "at": "<timestamp>",
              "kind": "once"
            }
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
            "end": 8,
            "items": [
              {
                "id": "<id>",
                "kind": "modelChange",
                "modelRef": {
                  "id": "<id>",
                  "provider": "tron-lock-automation-owned-run"
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
                    "text": "get ready for scheduled checks",
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
                    "text": "Ready for scheduled checks.",
                    "type": "text"
                  }
                ],
                "id": "<id>",
                "kind": "message",
                "modelId": "faux-1",
                "parentId": "<id>",
                "presentationId": "<id>",
                "provider": "tron-lock-automation-owned-run",
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
                    "text": "run the scheduled notes check",
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
                    "kind": "gateway",
                    "ownerId": "<id>",
                    "title": "Automation"
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
                "provider": "tron-lock-automation-owned-run",
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
                    "text": "The scheduled check found: lock notes.",
                    "type": "text"
                  }
                ],
                "id": "<id>",
                "kind": "message",
                "modelId": "faux-1",
                "parentId": "<id>",
                "presentationId": "<id>",
                "provider": "tron-lock-automation-owned-run",
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
            "total": 8
          }
        }
      }
    ],
    "providerRequests": [
      {
        "sessionShape": "chatWithAutomations",
        "messages": [
          {
            "role": "user",
            "text": "get ready for scheduled checks"
          }
        ]
      },
      {
        "sessionShape": "chatWithAutomations",
        "messages": [
          {
            "role": "user",
            "text": "get ready for scheduled checks"
          },
          {
            "role": "assistant",
            "text": "Ready for scheduled checks."
          },
          {
            "role": "user",
            "text": "run the scheduled notes check"
          }
        ]
      },
      {
        "sessionShape": "chatWithAutomations",
        "messages": [
          {
            "role": "user",
            "text": "get ready for scheduled checks"
          },
          {
            "role": "assistant",
            "text": "Ready for scheduled checks."
          },
          {
            "role": "user",
            "text": "run the scheduled notes check"
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
          }
        ]
      },
      {
        "sessionShape": "chatWithAutomations",
        "messages": [
          {
            "role": "user",
            "text": "run the workspace notes check"
          }
        ]
      },
      {
        "sessionShape": "chatWithAutomations",
        "messages": [
          {
            "role": "user",
            "text": "run the workspace notes check"
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
          }
        ]
      }
    ],
    "sessionJsonl": [
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
        "provider": "tron-lock-automation-owned-run",
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
          "provider": "tron-lock-automation-owned-run",
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
                "model": "tron-lock-automation-owned-run/faux-1"
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
                "provider": "tron-lock-automation-owned-run"
              }
            },
            "model.thinking[role=chat]": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "model": "tron-lock-automation-owned-run/faux-1",
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
                "computer",
                "schedule"
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
                "model": "tron-lock-automation-owned-run/faux-1"
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
                "provider": "tron-lock-automation-owned-run"
              }
            },
            "model.thinking[role=chat]": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "model": "tron-lock-automation-owned-run/faux-1",
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
                "computer",
                "schedule"
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
            "sessionShape": "chatWithAutomations#0"
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
              "text": "get ready for scheduled checks",
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
              "text": "Ready for scheduled checks.",
              "type": "text"
            }
          ],
          "durationMs": "<duration>",
          "model": "faux-1",
          "provider": "tron-lock-automation-owned-run",
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
            "kind": "gateway",
            "ownerId": "<id>",
            "title": "Automation"
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
              "text": "run the scheduled notes check",
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
          "provider": "tron-lock-automation-owned-run",
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
              "text": "The scheduled check found: lock notes.",
              "type": "text"
            }
          ],
          "durationMs": "<duration>",
          "model": "faux-1",
          "provider": "tron-lock-automation-owned-run",
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
            "kind": "gateway",
            "ownerId": "<id>",
            "title": "Automation"
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
    "workspaceJsonl": [
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
        "provider": "tron-lock-automation-owned-run",
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
          "provider": "tron-lock-automation-owned-run",
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
                "model": "tron-lock-automation-owned-run/faux-1"
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
                "provider": "tron-lock-automation-owned-run"
              }
            },
            "model.thinking[role=chat]": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "model": "tron-lock-automation-owned-run/faux-1",
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
                "computer",
                "schedule"
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
                "model": "tron-lock-automation-owned-run/faux-1"
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
                "provider": "tron-lock-automation-owned-run"
              }
            },
            "model.thinking[role=chat]": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "model": "tron-lock-automation-owned-run/faux-1",
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
                "computer",
                "schedule"
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
            "kind": "gateway",
            "ownerId": "<id>",
            "title": "Automation"
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
            "sessionShape": "chatWithAutomations#0"
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
              "text": "run the workspace notes check",
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
          "provider": "tron-lock-automation-owned-run",
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
              "text": "The workspace check found: lock notes.",
              "type": "text"
            }
          ],
          "durationMs": "<duration>",
          "model": "faux-1",
          "provider": "tron-lock-automation-owned-run",
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
            "kind": "gateway",
            "ownerId": "<id>",
            "title": "Automation"
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
    "automations": {
      "session": {
        "action": {
          "kind": "sessionPrompt",
          "text": "run the scheduled notes check"
        },
        "activation": "draft",
        "consecutiveFailureCount": 0,
        "createdAt": "<timestamp>",
        "executionDeadlineSeconds": 3600,
        "history": [
          {
            "actionSnapshot": {
              "kind": "sessionPrompt",
              "text": "run the scheduled notes check"
            },
            "assistantCompletionId": "<assistantCompletionId:1>",
            "automationRevision": 1,
            "claimId": "<id>",
            "claimedAt": "<timestamp>",
            "createdAt": "<timestamp>",
            "executionSessionId": "<id>",
            "hostEpoch": "<id>",
            "invocationId": "<id>",
            "manual": true,
            "occurrenceId": "<occurrenceId:1>",
            "operationId": "<id>",
            "preAdmissionAttemptCount": 0,
            "runId": "<id>",
            "scheduledFor": "<timestamp>",
            "startedAt": "<timestamp>",
            "state": "succeeded",
            "targetSnapshot": {
              "kind": "existingSession",
              "sessionId": "<id>"
            },
            "terminalAt": "<timestamp>",
            "triggerSnapshot": {
              "at": "<timestamp>",
              "kind": "once"
            }
          }
        ],
        "id": "<id>",
        "lastRun": {
          "actionSnapshot": {
            "kind": "sessionPrompt",
            "text": "run the scheduled notes check"
          },
          "assistantCompletionId": "<assistantCompletionId:1>",
          "automationRevision": 1,
          "claimId": "<id>",
          "claimedAt": "<timestamp>",
          "createdAt": "<timestamp>",
          "executionSessionId": "<id>",
          "hostEpoch": "<id>",
          "invocationId": "<id>",
          "manual": true,
          "occurrenceId": "<occurrenceId:1>",
          "operationId": "<id>",
          "preAdmissionAttemptCount": 0,
          "runId": "<id>",
          "scheduledFor": "<timestamp>",
          "startedAt": "<timestamp>",
          "state": "succeeded",
          "targetSnapshot": {
            "kind": "existingSession",
            "sessionId": "<id>"
          },
          "terminalAt": "<timestamp>",
          "triggerSnapshot": {
            "at": "<timestamp>",
            "kind": "once"
          }
        },
        "misfirePolicy": "latest",
        "name": "Lock session check",
        "overlapPolicy": "skip",
        "provenance": {
          "kind": "mobile"
        },
        "revision": "<n>",
        "schemaVersion": 2,
        "stateRevision": 5,
        "target": {
          "kind": "existingSession",
          "sessionId": "<id>"
        },
        "trigger": {
          "at": "<timestamp>",
          "kind": "once"
        },
        "updatedAt": "<timestamp>"
      },
      "workspace": {
        "action": {
          "kind": "sessionPrompt",
          "text": "run the workspace notes check"
        },
        "activation": "draft",
        "consecutiveFailureCount": 0,
        "createdAt": "<timestamp>",
        "executionDeadlineSeconds": 3600,
        "history": [
          {
            "actionSnapshot": {
              "kind": "sessionPrompt",
              "text": "run the workspace notes check"
            },
            "assistantCompletionId": "<assistantCompletionId:2>",
            "automationRevision": 1,
            "claimId": "<id>",
            "claimedAt": "<timestamp>",
            "createdAt": "<timestamp>",
            "executionSessionId": "<id>",
            "hostEpoch": "<id>",
            "invocationId": "<id>",
            "manual": true,
            "occurrenceId": "<occurrenceId:2>",
            "operationId": "<id>",
            "preAdmissionAttemptCount": 0,
            "runId": "<id>",
            "scheduledFor": "<timestamp>",
            "startedAt": "<timestamp>",
            "state": "succeeded",
            "targetSnapshot": {
              "cwd": "<tmp>/workspace",
              "kind": "workspace",
              "sessionPolicy": "newPerRun"
            },
            "terminalAt": "<timestamp>",
            "triggerSnapshot": {
              "at": "<timestamp>",
              "kind": "once"
            }
          }
        ],
        "id": "<id>",
        "lastRun": {
          "actionSnapshot": {
            "kind": "sessionPrompt",
            "text": "run the workspace notes check"
          },
          "assistantCompletionId": "<assistantCompletionId:2>",
          "automationRevision": 1,
          "claimId": "<id>",
          "claimedAt": "<timestamp>",
          "createdAt": "<timestamp>",
          "executionSessionId": "<id>",
          "hostEpoch": "<id>",
          "invocationId": "<id>",
          "manual": true,
          "occurrenceId": "<occurrenceId:2>",
          "operationId": "<id>",
          "preAdmissionAttemptCount": 0,
          "runId": "<id>",
          "scheduledFor": "<timestamp>",
          "startedAt": "<timestamp>",
          "state": "succeeded",
          "targetSnapshot": {
            "cwd": "<tmp>/workspace",
            "kind": "workspace",
            "sessionPolicy": "newPerRun"
          },
          "terminalAt": "<timestamp>",
          "triggerSnapshot": {
            "at": "<timestamp>",
            "kind": "once"
          }
        },
        "misfirePolicy": "latest",
        "name": "Lock workspace check",
        "overlapPolicy": "skip",
        "provenance": {
          "kind": "mobile"
        },
        "revision": "<n>",
        "schemaVersion": 2,
        "stateRevision": 5,
        "target": {
          "cwd": "<tmp>/workspace",
          "kind": "workspace",
          "sessionPolicy": "newPerRun"
        },
        "trigger": {
          "at": "<timestamp>",
          "kind": "once"
        },
        "updatedAt": "<timestamp>"
      }
    },
    "commandReceipts": [
      {
        "commandId": "lock-command-0001",
        "createdAt": "<timestamp>",
        "identityHash": "<identityHash:1>",
        "method": "session.create",
        "result": {
          "sessionId": "<id>"
        },
        "status": "completed",
        "version": 1
      },
      {
        "commandId": "lock-command-0002",
        "createdAt": "<timestamp>",
        "identityHash": "<identityHash:1>",
        "method": "session.prompt",
        "result": {
          "operationId": "<id>"
        },
        "status": "completed",
        "version": 1
      },
      {
        "commandId": "lock-command-0003",
        "createdAt": "<timestamp>",
        "identityHash": "<identityHash:1>",
        "method": "automation.create",
        "result": {
          "action": {
            "kind": "sessionPrompt",
            "text": "run the scheduled notes check"
          },
          "activation": "draft",
          "consecutiveFailureCount": 0,
          "createdAt": "<timestamp>",
          "executionDeadlineSeconds": 3600,
          "history": [],
          "id": "<id>",
          "misfirePolicy": "latest",
          "name": "Lock session check",
          "overlapPolicy": "skip",
          "provenance": {
            "kind": "mobile"
          },
          "revision": "<n>",
          "schemaVersion": 2,
          "stateRevision": 1,
          "target": {
            "kind": "existingSession",
            "sessionId": "<id>"
          },
          "trigger": {
            "at": "<timestamp>",
            "kind": "once"
          },
          "updatedAt": "<timestamp>"
        },
        "status": "completed",
        "version": 1
      },
      {
        "commandId": "lock-command-0004",
        "createdAt": "<timestamp>",
        "identityHash": "<identityHash:1>",
        "method": "automation.runNow",
        "result": {
          "actionSnapshot": {
            "kind": "sessionPrompt",
            "text": "run the scheduled notes check"
          },
          "automationRevision": 1,
          "createdAt": "<timestamp>",
          "executionSessionId": "<id>",
          "manual": true,
          "occurrenceId": "<occurrenceId:1>",
          "operationId": "<id>",
          "preAdmissionAttemptCount": 0,
          "runId": "<id>",
          "scheduledFor": "<timestamp>",
          "state": "queued",
          "targetSnapshot": {
            "kind": "existingSession",
            "sessionId": "<id>"
          },
          "triggerSnapshot": {
            "at": "<timestamp>",
            "kind": "once"
          }
        },
        "status": "completed",
        "version": 1
      },
      {
        "commandId": "lock-command-0005",
        "createdAt": "<timestamp>",
        "identityHash": "<identityHash:1>",
        "method": "automation.create",
        "result": {
          "action": {
            "kind": "sessionPrompt",
            "text": "run the workspace notes check"
          },
          "activation": "draft",
          "consecutiveFailureCount": 0,
          "createdAt": "<timestamp>",
          "executionDeadlineSeconds": 3600,
          "history": [],
          "id": "<id>",
          "misfirePolicy": "latest",
          "name": "Lock workspace check",
          "overlapPolicy": "skip",
          "provenance": {
            "kind": "mobile"
          },
          "revision": "<n>",
          "schemaVersion": 2,
          "stateRevision": 1,
          "target": {
            "cwd": "<tmp>/workspace",
            "kind": "workspace",
            "sessionPolicy": "newPerRun"
          },
          "trigger": {
            "at": "<timestamp>",
            "kind": "once"
          },
          "updatedAt": "<timestamp>"
        },
        "status": "completed",
        "version": 1
      },
      {
        "commandId": "lock-command-0006",
        "createdAt": "<timestamp>",
        "identityHash": "<identityHash:1>",
        "method": "automation.runNow",
        "result": {
          "actionSnapshot": {
            "kind": "sessionPrompt",
            "text": "run the workspace notes check"
          },
          "automationRevision": 1,
          "createdAt": "<timestamp>",
          "executionSessionId": "<id>",
          "manual": true,
          "occurrenceId": "<occurrenceId:2>",
          "operationId": "<id>",
          "preAdmissionAttemptCount": 0,
          "runId": "<id>",
          "scheduledFor": "<timestamp>",
          "state": "queued",
          "targetSnapshot": {
            "cwd": "<tmp>/workspace",
            "kind": "workspace",
            "sessionPolicy": "newPerRun"
          },
          "triggerSnapshot": {
            "at": "<timestamp>",
            "kind": "once"
          }
        },
        "status": "completed",
        "version": 1
      }
    ],
    "runtimeMarkers": []
  },
};
