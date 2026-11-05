import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockGateway } from "../../test-support/gateway-lock-harness.js";
import { normalizeTraceValue, type TraceValue } from "../../test-support/scenario-lock.js";
import { expectScenario } from "../../test-support/lock-projections.js";
import { projectRootTrustScenario } from "../../test-support/lock-scenarios.js";

/**
 * Project-root lock (restructure plan §6.4, V3; K-0 §7 E0e) guarding the Pi seam
 * slice E2 (`kernel/pi`) at the `projectDir` patch call sites (K-0 §4 patch
 * item 1): a chat whose cwd is a subdirectory of a Git project, through the real
 * Gateway over a loopback WebSocket (`gateway-lock-harness.ts`).
 *
 * The scenario records, with the root and the subdirectory each carrying a
 * `.pi/` and an `AGENTS.md`:
 * - trust inspection resolves the subdirectory to the root and asks for a
 *   decision (`trust.inspect`), and `session.create` refuses until one exists;
 * - the decision a client makes for the subdirectory is saved for the root;
 * - the chat keeps its own cwd while its Project layer is the root's: root
 *   settings resolve for the chat, the root's skill and extension tool reach the
 *   provider request and the subdirectory's do not, both instruction files are
 *   in the prompt, the root's compaction budgets apply, and the extension sees
 *   `cwd` and `projectDir` apart;
 * - revoking the root's decision reloads the chat without the Project layer.
 * `project-root.integration.test.ts` covers outside edits, linked worktrees and
 * MCP at the registry; this lock pins what clients and the model see.
 */

const gateways: LockGateway[] = [];
afterEach(async () => { await Promise.all(gateways.splice(0).map((gateway) => gateway.dispose())); });

describe("gateway/session-catalog project-root lock", () => {
  it("projectDir: a subdirectory chat of a trusted Git project loads the root's Project layer and keeps its cwd", async () => {
    const gateway = await startLockGateway("project-root-trust");
    gateways.push(gateway);
    const { root, project, nested, phone, systemPrompt, undecided, refused, decided, rootInspection, nestedInspection, created, sessionId, opened,
      chatSettings, projectSettings, revoked, transcript } = await projectRootTrustScenario(gateway);

    const recorded = gateway.record();
    const trace = {
      lock: "project-root-trust",
      exchanges: recorded.exchanges,
      // Whether an instant tool emits a progress frame before its result is host
      // timing; its settled result is in the transcript and JSONL.
      events: recorded.events.filter((event) => (event as { topic: string }).topic !== "session.toolProgress"),
      providerRequests: recorded.providerRequests as unknown as TraceValue[],
      canonicalJsonl: await gateway.canonical(sessionId),
      // The trust store is keyed by path; normalization rewrites values, so list its entries.
      files: { trust: normalizeTraceValue(Object.entries(JSON.parse(await readFile(join(gateway.agentDir, "trust.json"), "utf8")))
        .map(([path, trusted]) => ({ path, trusted })), gateway.normalization) },
      // The prompt hash already covers the whole text; these name what it must hold.
      observed: Object.fromEntries(["root-lock-skill", "nested-lock-skill", "ROOT-INSTRUCTIONS", "NESTED-INSTRUCTIONS"]
        .map((marker) => [marker, systemPrompt().includes(marker)])),
    };
    expectScenario(trace as unknown as Record<string, unknown>, EXPECTED["project-root-trust"]);
    const [projectDir, cwd] = [project, nested].map((path) => path.split(root).join("<tmp>"));
    expect(undecided.result).toMatchObject({ projectDir: project, requiresDecision: true, effectiveDecision: null });
    expect(refused.error).toMatchObject({ code: "trust_required" });
    expect(decided.ok, JSON.stringify(decided)).toBe(true);
    expect(rootInspection.result).toMatchObject({ projectDir: project, savedDecision: true });
    expect(nestedInspection.result).toMatchObject({ cwd: nested, projectDir: project, savedDecision: true });
    expect(JSON.stringify(chatSettings.result)).toContain('"value":7');
    expect(opened.result.session.compactionPolicy.currentBudgets).toMatchObject({ reserveTokens: 4_096, keepRecentTokens: 240 });
    expect(revoked.ok, JSON.stringify(revoked)).toBe(true);
    expect(recorded.providerRequests).toHaveLength(3);
    expect(recorded.providerRequests[2]!.tools).not.toContain("project_probe");
    expect(transcript.ok).toBe(true);
    expect(trace.observed).toEqual({ "root-lock-skill": true, "nested-lock-skill": false, "ROOT-INSTRUCTIONS": true, "NESTED-INSTRUCTIONS": true });
    const first = recorded.providerRequests[0]!;
    expect(first.tools).toContain("project_probe");
    expect(first.tools).not.toContain("nested_probe");
    const messages = JSON.stringify(recorded.providerRequests[1]!.messages);
    expect(messages).toContain(`cwd=${cwd} projectDir=${projectDir}`);
    expect(trace.files.trust).toContainEqual({ path: projectDir, trusted: false });
  });
});

/** Each lock's expected trace (`test-support/lock-projections.ts` `expectScenario`): the scenario's normalized trace without event schemas, with model-visible parts named by session shape. */
const EXPECTED: Record<string, unknown> = {
  "project-root-trust": {
    "lock": "project-root-trust",
    "exchanges": [
      {
        "client": "phone",
        "method": "trust.inspect",
        "params": {
          "cwd": "<tmp>/project/packages/app"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "cwd": "<tmp>/project/packages/app",
            "defaultDecision": "ask",
            "effectiveDecision": null,
            "projectDir": "<tmp>/project",
            "requiresDecision": true,
            "savedDecision": null
          }
        }
      },
      {
        "client": "phone",
        "method": "session.create",
        "params": {
          "commandId": "lock-command-0001",
          "cwd": "<tmp>/project/packages/app"
        },
        "response": {
          "error": {
            "code": "trust_required",
            "details": {
              "cwd": "<tmp>/project/packages/app",
              "defaultDecision": "ask",
              "effectiveDecision": null,
              "projectDir": "<tmp>/project",
              "requiresDecision": true,
              "savedDecision": null
            },
            "message": "Choose whether to trust this project before loading agent resources",
            "retryable": false
          },
          "ok": false,
          "result": null
        }
      },
      {
        "client": "phone",
        "method": "settings.change",
        "params": {
          "changes": [
            {
              "key": "permissions.projectTrust",
              "layer": "global",
              "op": "set",
              "qualifiers": {
                "project": "<tmp>/project/packages/app"
              },
              "value": true
            }
          ],
          "commandId": "lock-command-0002",
          "reason": "Trust the lock project",
          "target": {
            "kind": "global"
          }
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "changes": [
              {
                "after": true,
                "before": null,
                "changeId": "<id>",
                "key": "permissions.projectTrust",
                "layer": "global",
                "qualifiers": {
                  "project": "<tmp>/project"
                },
                "result": {
                  "cwd": "<tmp>/project",
                  "defaultDecision": "ask",
                  "effectiveDecision": true,
                  "projectDir": "<tmp>/project",
                  "requiresDecision": true,
                  "savedDecision": true
                },
                "status": "applied"
              }
            ],
            "review": {
              "digest": "<base64:64>",
              "items": [
                {
                  "after": "Trusted",
                  "before": "Not set",
                  "detail": "Global stored value\nglobal\nTrusting a project runs its extensions and hooks.",
                  "exact": "{\"target\":{\"kind\":\"global\"},\"key\":\"permissions.projectTrust\",\"layer\":\"global\",\"qualifiers\":{\"project\":\"<tmp>/project\"},\"op\":\"set\",\"before\":null,\"after\":true}",
                  "label": "Trust for this project"
                }
              ],
              "reason": "Trust the lock project",
              "requiresTap": true,
              "title": "Trust for this project"
            },
            "status": "applied"
          }
        }
      },
      {
        "client": "phone",
        "method": "trust.inspect",
        "params": {
          "cwd": "<tmp>/project"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "cwd": "<tmp>/project",
            "defaultDecision": "ask",
            "effectiveDecision": true,
            "projectDir": "<tmp>/project",
            "requiresDecision": true,
            "savedDecision": true
          }
        }
      },
      {
        "client": "phone",
        "method": "trust.inspect",
        "params": {
          "cwd": "<tmp>/project/packages/app"
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "cwd": "<tmp>/project/packages/app",
            "defaultDecision": "ask",
            "effectiveDecision": true,
            "projectDir": "<tmp>/project",
            "requiresDecision": true,
            "savedDecision": true
          }
        }
      },
      {
        "client": "phone",
        "method": "session.create",
        "params": {
          "commandId": "lock-command-0003",
          "cwd": "<tmp>/project/packages/app"
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
                  "keepRecentTokens": 240,
                  "reserveTokens": 4096
                },
                "extensionMayOverride": false,
                "next": {
                  "effectiveThinkingLevel": "off",
                  "enabled": false,
                  "instructions": "",
                  "keepRecentTokens": 240,
                  "model": {
                    "id": "<id>",
                    "provider": "tron-lock-project-root-trust"
                  },
                  "requestedThinkingLevel": "off",
                  "reserveTokens": 4096,
                  "source": {
                    "enabled": "global",
                    "instructions": "global",
                    "keepRecentTokens": "project",
                    "reserveTokens": "project",
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
                "minimum": 5360,
                "model": {
                  "id": "<id>",
                  "provider": "tron-lock-project-root-trust"
                },
                "override": 128000,
                "source": "session",
                "warning": "This new session and its context override are not yet saved to disk; they persist after the first user or assistant message."
              },
              "cwd": "<tmp>/project/packages/app",
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
                "provider": "tron-lock-project-root-trust"
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
                    "provider": "tron-lock-project-root-trust"
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
        "method": "settings.resolve",
        "params": {
          "keys": [
            "run.retry.maxRetries"
          ],
          "target": {
            "kind": "session",
            "sessionId": "<id>"
          }
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "diagnostics": [],
            "keys": [
              {
                "applied": true,
                "badges": [
                  {
                    "detail": "Project: 7 retries; committed: Not set",
                    "kind": "state",
                    "label": "Uncommitted"
                  }
                ],
                "display": "7 retries",
                "group": "run",
                "key": "run.retry.maxRetries",
                "layer": "project",
                "layers": [
                  {
                    "applied": true,
                    "display": "7 retries",
                    "layer": "project",
                    "value": 7
                  },
                  {
                    "applied": true,
                    "layer": "session"
                  },
                  {
                    "applied": true,
                    "layer": "global"
                  }
                ],
                "overridden": false,
                "presentation": {
                  "editable": true,
                  "effect": "next-request",
                  "help": "How many times a failed request is retried.",
                  "importance": "essential",
                  "label": "Retries",
                  "order": 40,
                  "projectSettable": true,
                  "sessionOverridable": true,
                  "timing": "live",
                  "valueKind": "integer"
                },
                "projectSetting": {
                  "file": "<tmp>/project/.pi/settings.json",
                  "path": "retry.maxRetries"
                },
                "subgroup": "Retry",
                "value": 7
              }
            ],
            "layers": [
              "project",
              "session",
              "global"
            ],
            "renderer": {
              "version": 1
            },
            "sections": [
              {
                "description": "Proxy and retained overrides",
                "id": "<id>",
                "order": 50,
                "title": "Connection"
              }
            ],
            "target": {
              "kind": "session",
              "sessionId": "<id>"
            }
          }
        }
      },
      {
        "client": "phone",
        "method": "settings.resolve",
        "params": {
          "keys": [
            "run.retry.maxRetries",
            "permissions.projectTrust"
          ],
          "target": {
            "cwd": "<tmp>/project/packages/app",
            "kind": "project"
          }
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "diagnostics": [],
            "keys": [
              {
                "applied": true,
                "badges": [
                  {
                    "kind": "scope",
                    "label": "<tmp>/project"
                  }
                ],
                "display": "Trusted",
                "group": "trust",
                "key": "permissions.projectTrust",
                "layer": "global",
                "layers": [
                  {
                    "applied": true,
                    "display": "Trusted",
                    "layer": "global",
                    "value": true
                  }
                ],
                "overridden": true,
                "presentation": {
                  "confirm": "Trusting a project runs its extensions and hooks.",
                  "control": "readOnly",
                  "editable": false,
                  "effect": "reload",
                  "help": "Lets this project's extensions, hooks and settings load.",
                  "importance": "essential",
                  "label": "Trust for this project",
                  "note": "Update Tron to edit",
                  "order": 10,
                  "projectSettable": false,
                  "sessionOverridable": false,
                  "timing": "live",
                  "valueKind": "boolean"
                },
                "qualifiers": {
                  "project": "<tmp>/project"
                },
                "value": true
              },
              {
                "applied": true,
                "badges": [
                  {
                    "detail": "Project: 7 retries; committed: Not set",
                    "kind": "state",
                    "label": "Uncommitted"
                  }
                ],
                "display": "7 retries",
                "group": "run",
                "key": "run.retry.maxRetries",
                "layer": "project",
                "layers": [
                  {
                    "applied": true,
                    "display": "7 retries",
                    "layer": "project",
                    "value": 7
                  },
                  {
                    "applied": true,
                    "layer": "global"
                  }
                ],
                "overridden": false,
                "presentation": {
                  "editable": false,
                  "effect": "next-request",
                  "help": "How many times a failed request is retried.",
                  "importance": "essential",
                  "label": "Retries",
                  "order": 40,
                  "projectSettable": true,
                  "sessionOverridable": true,
                  "timing": "live",
                  "valueKind": "integer"
                },
                "projectSetting": {
                  "file": "<tmp>/project/.pi/settings.json",
                  "path": "retry.maxRetries"
                },
                "subgroup": "Retry",
                "value": 7
              }
            ],
            "layers": [
              "project",
              "global"
            ],
            "renderer": {
              "version": 1
            },
            "sections": [
              {
                "description": "Proxy and retained overrides",
                "id": "<id>",
                "order": 50,
                "title": "Connection"
              },
              {
                "description": "Project trust decisions and default policy",
                "id": "<id>",
                "order": 55,
                "title": "Trusted Projects"
              }
            ],
            "target": {
              "cwd": "<tmp>/project/packages/app",
              "kind": "project"
            }
          }
        }
      },
      {
        "client": "phone",
        "method": "session.prompt",
        "params": {
          "commandId": "lock-command-0004",
          "sessionId": "<id>",
          "text": "where does this chat run?"
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
        "method": "settings.change",
        "params": {
          "changes": [
            {
              "key": "permissions.projectTrust",
              "layer": "global",
              "op": "set",
              "qualifiers": {
                "project": "<tmp>/project/packages/app"
              },
              "value": false
            }
          ],
          "commandId": "lock-command-0005",
          "reason": "Stop trusting the lock project",
          "target": {
            "kind": "global"
          }
        },
        "response": {
          "error": null,
          "ok": true,
          "result": {
            "changes": [
              {
                "after": false,
                "before": true,
                "changeId": "<id>",
                "key": "permissions.projectTrust",
                "layer": "global",
                "qualifiers": {
                  "project": "<tmp>/project"
                },
                "result": {
                  "cwd": "<tmp>/project",
                  "defaultDecision": "ask",
                  "effectiveDecision": false,
                  "projectDir": "<tmp>/project",
                  "requiresDecision": true,
                  "savedDecision": false
                },
                "status": "applied"
              }
            ],
            "review": {
              "digest": "<base64:64>",
              "items": [
                {
                  "after": "Not trusted",
                  "before": "Trusted",
                  "detail": "Global stored value\nglobal\nTrusting a project runs its extensions and hooks.",
                  "exact": "{\"target\":{\"kind\":\"global\"},\"key\":\"permissions.projectTrust\",\"layer\":\"global\",\"qualifiers\":{\"project\":\"<tmp>/project\"},\"op\":\"set\",\"before\":true,\"after\":false}",
                  "label": "Trust for this project"
                }
              ],
              "reason": "Stop trusting the lock project",
              "requiresTap": false,
              "title": "Trust for this project"
            },
            "status": "applied"
          }
        }
      },
      {
        "client": "phone",
        "method": "session.prompt",
        "params": {
          "commandId": "lock-command-0006",
          "sessionId": "<id>",
          "text": "and after revoking trust?"
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
            "end": 8,
            "items": [
              {
                "id": "<id>",
                "kind": "modelChange",
                "modelRef": {
                  "id": "<id>",
                  "provider": "tron-lock-project-root-trust"
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
                    "text": "where does this chat run?",
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
                    "name": "project_probe",
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
                "provider": "tron-lock-project-root-trust",
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
                    "text": "cwd=<tmp>/project/packages/app projectDir=<tmp>/project",
                    "type": "text"
                  }
                ],
                "details": {},
                "durationMs": "<duration>",
                "extensionOrigin": {
                  "owner": {
                    "id": "<id>",
                    "kind": "extension",
                    "source": "auto",
                    "title": "Root Probe"
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
                "toolLabel": "Project probe",
                "toolName": "project_probe",
                "toolSegmentId": "<id>"
              },
              {
                "content": [
                  {
                    "id": "<id>",
                    "ordinal": 0,
                    "text": "The chat runs in the subdirectory of the trusted project.",
                    "type": "text"
                  }
                ],
                "id": "<id>",
                "kind": "message",
                "modelId": "faux-1",
                "parentId": "<id>",
                "presentationId": "<id>",
                "provider": "tron-lock-project-root-trust",
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
                    "text": "and after revoking trust?",
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
                    "text": "Trust was revoked for the project.",
                    "type": "text"
                  }
                ],
                "id": "<id>",
                "kind": "message",
                "modelId": "faux-1",
                "parentId": "<id>",
                "presentationId": "<id>",
                "provider": "tron-lock-project-root-trust",
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
        "sessionShape": "trustedProjectSubdirectory",
        "messages": [
          {
            "role": "user",
            "text": "where does this chat run?"
          }
        ]
      },
      {
        "sessionShape": "trustedProjectSubdirectory",
        "messages": [
          {
            "role": "user",
            "text": "where does this chat run?"
          },
          {
            "role": "assistant",
            "text": "",
            "toolCalls": [
              "project_probe"
            ]
          },
          {
            "role": "toolResult",
            "text": "cwd=<tmp>/project/packages/app projectDir=<tmp>/project",
            "toolName": "project_probe"
          }
        ]
      },
      {
        "sessionShape": "revokedProjectSubdirectory",
        "messages": [
          {
            "role": "user",
            "text": "where does this chat run?"
          },
          {
            "role": "assistant",
            "text": "",
            "toolCalls": [
              "project_probe"
            ]
          },
          {
            "role": "toolResult",
            "text": "cwd=<tmp>/project/packages/app projectDir=<tmp>/project",
            "toolName": "project_probe"
          },
          {
            "role": "assistant",
            "text": "The chat runs in the subdirectory of the trusted project."
          },
          {
            "role": "user",
            "text": "and after revoking trust?"
          }
        ]
      }
    ],
    "canonicalJsonl": [
      {
        "cwd": "<tmp>/project/packages/app",
        "id": "<id>",
        "timestamp": "<timestamp>",
        "type": "session",
        "version": 3
      },
      {
        "id": "<id>",
        "modelId": "faux-1",
        "parentId": "<id>",
        "provider": "tron-lock-project-root-trust",
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
          "provider": "tron-lock-project-root-trust",
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
                "model": "tron-lock-project-root-trust/faux-1"
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
                "provider": "tron-lock-project-root-trust"
              }
            },
            "model.thinking[role=chat]": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "model": "tron-lock-project-root-trust/faux-1",
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
                "project_probe",
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
                "model": "tron-lock-project-root-trust/faux-1"
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
                "provider": "tron-lock-project-root-trust"
              }
            },
            "model.thinking[role=chat]": {
              "at": "<timestamp>",
              "from": "global",
              "qualifiers": {
                "model": "tron-lock-project-root-trust/faux-1",
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
                "project_probe",
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
            "cwd": "<cwd>\n<tmp>/project/packages/app\n</cwd>",
            "sessionShape": "projectSubdirectorySystem#0"
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
              "text": "where does this chat run?",
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
              "name": "project_probe",
              "type": "toolCall"
            }
          ],
          "durationMs": "<duration>",
          "model": "faux-1",
          "provider": "tron-lock-project-root-trust",
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
              "text": "cwd=<tmp>/project/packages/app projectDir=<tmp>/project",
              "type": "text"
            }
          ],
          "details": {},
          "durationMs": "<duration>",
          "isError": false,
          "role": "toolResult",
          "timestamp": "<timestamp>",
          "toolCallId": "<id>",
          "toolName": "project_probe"
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
              "text": "The chat runs in the subdirectory of the trusted project.",
              "type": "text"
            }
          ],
          "durationMs": "<duration>",
          "model": "faux-1",
          "provider": "tron-lock-project-root-trust",
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
          "content": "",
          "role": "system",
          "timestamp": "<timestamp>",
          "toolsRemoved": [
            {
              "name": "project_probe"
            }
          ],
          "sections": {
            "sessionShape": "projectSubdirectorySystem#1"
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
              "text": "and after revoking trust?",
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
              "text": "Trust was revoked for the project.",
              "type": "text"
            }
          ],
          "durationMs": "<duration>",
          "model": "faux-1",
          "provider": "tron-lock-project-root-trust",
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
    "files": {
      "trust": [
        {
          "path": "<tmp>/project",
          "trusted": false
        },
        {
          "path": "<tmp>/workspace",
          "trusted": true
        }
      ]
    },
    "observed": {
      "root-lock-skill": true,
      "nested-lock-skill": false,
      "ROOT-INSTRUCTIONS": true,
      "NESTED-INSTRUCTIONS": true
    }
  },
};
