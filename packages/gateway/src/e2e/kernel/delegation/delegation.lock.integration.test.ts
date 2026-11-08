import { readFile, realpath } from "node:fs/promises";
import { fauxAssistantMessage, fauxToolCall, type TranscriptContext } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { disposeFixtures, fixture } from "../../../../test-support/home-task-fixture.js";
import { startScriptedChild, type ChildModelServer } from "../../../../test-support/home-task-subagent-child.js";
import { expectScenario } from "../../../../test-support/lock-projections.js";
import { compareWithGolden, lockPaths, lockUpdateRequested, normalizeTraceValue, type TraceValue } from "../../../../test-support/scenario-lock.js";
import { waitFor } from "../../../../test-support/wait-for.js";

/**
 * Kernel subagent lock (packages/gateway/docs/scenario-locks.md#locks) for the `gateway/delegation`
 * module: one foreground subagent run through the real managed pi-subagents
 * install, a real child Pi process and the real `RuntimeRegistry`. The parent's
 * model is the faux provider; the child's model is the scripted local HTTP model
 * server the Home task subagent cases use, which answers `CHILD-DONE`.
 *
 * This lock enters at the registry, not the WebSocket: the delegation kernel's
 * contract is the session's canonical record and its process activity, which
 * the transport only projects. It runs in the nested serial pass
 * (`vitest.nested.config.ts`) because it activates the managed install and
 * spawns a real child. It records the parent's provider requests, canonical
 * JSONL, the settled subagent process activity and the child's canonical
 * session, asserted exactly (`expectScenario`). The entries no other lock
 * covers stay in the narrowed `locks/delegation-subagent.golden.json`: both
 * sessions' system entries (the parent's prompt with the `subagent` tool and its
 * skills, the `task-child` prompt with its acceptance contract) and the parent
 * session's settings, context-window and extension-activity entries. Each is
 * an ordered `{ narrowedGolden }` placeholder in the inline trace.
 */

const MODULE = "gateway/e2e";
const BOUND = { boundMs: 30_000 };
const servers: ChildModelServer[] = [];
afterEach(async () => {
  for (const server of servers.splice(0)) await server.close();
  await disposeFixtures();
});

const NARROWED_ENTRY_TYPES = new Set(["tron.settings.v1", "tron.context-window.v1", "tron.extension-activity.v1"]);

function narrowed(entry: TraceValue): boolean {
  const record = entry as { type?: unknown; customType?: unknown; message?: { role?: unknown } };
  return (record.type === "message" && record.message?.role === "system")
    || (record.type === "custom" && NARROWED_ENTRY_TYPES.has(String(record.customType)));
}

/** A session's entries split into the narrowed golden's entries and the inline trace, which keeps each narrowed entry's place. */
function split(entries: TraceValue[]): { kept: TraceValue[]; inline: TraceValue[] } {
  const kept: TraceValue[] = [];
  const inline = entries.map((entry) => {
    if (!narrowed(entry)) return entry;
    kept.push(entry);
    return { narrowedGolden: kept.length - 1 };
  });
  return { kept, inline };
}

function messages(context: TranscriptContext): string[] {
  return context.messages.filter((message) => (message as { role?: unknown }).role !== "system")
    .map((message) => String((message as { role?: unknown }).role));
}

describe("gateway/delegation kernel locks", () => {
  it("subagent: a foreground subagent runs a real child to completion and returns its answer to the parent", async () => {
    const f = await fixture(false, false, undefined, true);
    const server = await startScriptedChild(f);
    servers.push(server);
    const requests: string[][] = [];
    f.faux.setResponses([
      (context) => {
        requests.push(messages(context));
        return fauxAssistantMessage([fauxToolCall("subagent", { agent: "task-child", task: "Lock child task", async: false }, { id: "lock-subagent" })], { stopReason: "toolUse" });
      },
      (context) => { requests.push(messages(context)); return fauxAssistantMessage("The child finished."); },
    ]);
    const slot = await f.registry.create(f.cwd);
    await slot.prompt("delegate the lock task");
    await waitFor(() => !slot.isBusy && !slot.catalogHasActiveSubagents, "the parent and its child to settle", BOUND);
    const roots = [f.root, await realpath(f.root)];
    const normalization = { roots, stableIds: ["lock-subagent"] };
    const canonical = (await readFile(slot.sessionFile!, "utf8")).trimEnd().split("\n").map((line) => JSON.parse(line));
    const activity = (slot.snapshot().processActivities ?? []).filter((item) => item.kind === "subagent");
    const childFile = canonical.flatMap((entry) => {
      const details = entry.type === "message" && entry.message.role === "toolResult" ? entry.message.details : undefined;
      const results = (details as { results?: Array<{ sessionFile?: string }> } | undefined)?.results ?? [];
      return results.flatMap((result) => result.sessionFile ? [result.sessionFile] : []);
    })[0];
    const child = childFile
      ? (await readFile(childFile, "utf8")).trimEnd().split("\n").map((line) => normalizeTraceValue(JSON.parse(line), normalization))
      : [];
    const trace = {
      lock: "delegation-subagent",
      providerRequests: requests as unknown as TraceValue[],
      canonicalJsonl: canonical.map((entry) => normalizeTraceValue(entry, normalization)),
      processActivity: activity.map((item) => normalizeTraceValue(item, normalization)),
      childJsonl: child,
    };
    const parent = split(trace.canonicalJsonl);
    const childEntries = split(trace.childJsonl);
    await compareWithGolden({
      module: MODULE, ...lockPaths(import.meta.url, trace.lock),
      trace: { lock: trace.lock, canonicalJsonl: parent.kept, childJsonl: childEntries.kept },
      update: lockUpdateRequested(MODULE),
      validate: () => {
        const result = canonical.find((entry) => entry.type === "message" && entry.message.role === "toolResult");
        expect(result?.message.toolName).toBe("subagent");
        expect(result?.message.isError).toBe(false);
        expect(JSON.stringify(result?.message.content)).toContain("CHILD-DONE");
        expect(requests).toHaveLength(2);
        expect(child.length).toBeGreaterThan(0);
        expect(JSON.stringify(child)).toContain("Lock child task");
      },
    });
    expectScenario({ ...trace, canonicalJsonl: parent.inline, childJsonl: childEntries.inline }, EXPECTED);
  }, 60_000);
});

/** The trace without the narrowed golden's entries (`expectScenario`): provider requests, both sessions' other entries and the subagent's process activity. */
const EXPECTED: unknown = {
  "lock": "delegation-subagent",
  "providerRequests": [
    [
      "user"
    ],
    [
      "user",
      "assistant",
      "toolResult"
    ]
  ],
  "canonicalJsonl": [
    {
      "cwd": "<tmp>/project",
      "id": "<id>",
      "timestamp": "<timestamp>",
      "type": "session",
      "version": 3
    },
    {
      "id": "<id>",
      "modelId": "faux-1",
      "parentId": "<id>",
      "provider": "tron-task-faux",
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
      "narrowedGolden": 0
    },
    {
      "narrowedGolden": 1
    },
    {
      "narrowedGolden": 2
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
      "narrowedGolden": 3
    },
    {
      "id": "<id>",
      "message": {
        "content": [
          {
            "text": "delegate the lock task",
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
              "agent": "task-child",
              "async": false,
              "task": "Lock child task"
            },
            "id": "lock-subagent",
            "name": "subagent",
            "type": "toolCall"
          }
        ],
        "durationMs": "<duration>",
        "model": "faux-1",
        "provider": "tron-task-faux",
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
      "narrowedGolden": 4
    },
    {
      "id": "<id>",
      "message": {
        "content": [
          {
            "text": "Run fan-out: 1/64 used, 63 remaining\nCHILD-DONE\nMission: <id> (completed)",
            "type": "text"
          }
        ],
        "details": {
          "artifacts": {
            "dir": "<tmp>/sessions/subagent-artifacts",
            "files": [
              {
                "inputPath": "<tmp>/sessions/subagent-artifacts/<id>_task-child_0_input.md",
                "jsonlPath": "<tmp>/sessions/subagent-artifacts/<id>_task-child_0.jsonl",
                "metadataPath": "<tmp>/sessions/subagent-artifacts/<id>_task-child_0_meta.json",
                "outputPath": "<tmp>/sessions/subagent-artifacts/<id>_task-child_0_output.md",
                "transcriptPath": "<tmp>/sessions/subagent-artifacts/<id>_task-child_0_transcript.jsonl"
              }
            ]
          },
          "context": "fresh",
          "mission": {
            "acceptance": {
              "childReportParseError": "Structured acceptance report not found.",
              "criteria": [
                {
                  "evidence": [
                    "manual-notes",
                    "residual-risks"
                  ],
                  "id": "<id>",
                  "must": "Return a concise result and residual risks when applicable",
                  "severity": "required"
                }
              ],
              "effectiveAcceptance": {
                "criteria": [
                  {
                    "evidence": [
                      "manual-notes",
                      "residual-risks"
                    ],
                    "id": "<id>",
                    "must": "Return a concise result and residual risks when applicable",
                    "severity": "required"
                  }
                ],
                "evidence": [
                  "manual-notes",
                  "residual-risks"
                ],
                "explicit": false,
                "inferredReason": [
                  "default lightweight attestation"
                ],
                "level": "attested",
                "stopRules": [],
                "verify": []
              },
              "evidenceStatus": "rejected",
              "explicit": false,
              "inferredReason": [
                "default lightweight attestation"
              ],
              "runtimeChecks": [
                {
                  "id": "<id>",
                  "message": "Structured acceptance report not found.",
                  "status": "failed"
                }
              ],
              "status": "rejected",
              "verifyRuns": []
            },
            "artifacts": [
              {
                "kind": "output",
                "path": "<tmp>/sessions/subagent-artifacts/<id>_task-child_0_output.md"
              },
              {
                "description": "Child transcript",
                "kind": "other",
                "path": "<tmp>/sessions/subagent-artifacts/<id>_task-child_0_transcript.jsonl"
              }
            ],
            "createdAt": "<timestamp>",
            "cwd": "<tmp>/project",
            "decisions": [],
            "id": "<id>",
            "objective": "[prompt redacted]",
            "ownerSessionId": "<tmp>/sessions/<timestamp>_<id>.jsonl",
            "receipts": [],
            "runs": [
              {
                "agent": "task-child",
                "completedAt": "<timestamp>",
                "mode": "single",
                "runId": "<id>",
                "startedAt": "<timestamp>",
                "status": "completed"
              }
            ],
            "schemaVersion": 1,
            "status": "completed",
            "summary": "Run fan-out: 1/64 used, 63 remaining\nCHILD-DONE",
            "title": "[prompt redacted]",
            "updatedAt": "<timestamp>",
            "workflowChildren": []
          },
          "missionId": "<id>",
          "missionPath": "<tmp>/agent/missions/projects/<digest>/<id>.json",
          "mode": "single",
          "results": [
            {
              "acceptance": {
                "childReportParseError": "Structured acceptance report not found.",
                "criteria": [
                  {
                    "evidence": [
                      "manual-notes",
                      "residual-risks"
                    ],
                    "id": "<id>",
                    "must": "Return a concise result and residual risks when applicable",
                    "severity": "required"
                  }
                ],
                "effectiveAcceptance": {
                  "criteria": [
                    {
                      "evidence": [
                        "manual-notes",
                        "residual-risks"
                      ],
                      "id": "<id>",
                      "must": "Return a concise result and residual risks when applicable",
                      "severity": "required"
                    }
                  ],
                  "evidence": [
                    "manual-notes",
                    "residual-risks"
                  ],
                  "explicit": false,
                  "inferredReason": [
                    "default lightweight attestation"
                  ],
                  "level": "attested",
                  "stopRules": [],
                  "verify": []
                },
                "evidenceStatus": "rejected",
                "explicit": false,
                "inferredReason": [
                  "default lightweight attestation"
                ],
                "runtimeChecks": [
                  {
                    "id": "<id>",
                    "message": "Structured acceptance report not found.",
                    "status": "failed"
                  }
                ],
                "status": "rejected",
                "verifyRuns": []
              },
              "agent": "task-child",
              "artifactPaths": {
                "inputPath": "<tmp>/sessions/subagent-artifacts/<id>_task-child_0_input.md",
                "jsonlPath": "<tmp>/sessions/subagent-artifacts/<id>_task-child_0.jsonl",
                "metadataPath": "<tmp>/sessions/subagent-artifacts/<id>_task-child_0_meta.json",
                "outputPath": "<tmp>/sessions/subagent-artifacts/<id>_task-child_0_output.md",
                "transcriptPath": "<tmp>/sessions/subagent-artifacts/<id>_task-child_0_transcript.jsonl"
              },
              "context": "fresh",
              "exitCode": 0,
              "finalOutput": "CHILD-DONE",
              "index": 0,
              "launchContractDigest": "<base64:64>",
              "launchResolvedExtensions": {
                "configured": [],
                "disableAmbientExtensions": true,
                "effective": [
                  "sha256:<digest>",
                  "sha256:<digest>",
                  "sha256:<digest>"
                ],
                "omitted": {
                  "configured": 0,
                  "effective": 0,
                  "required": 0,
                  "runtime": 0
                },
                "required": [
                  "tron-web-research",
                  "tron-model-queue"
                ],
                "runtime": [
                  "sha256:<digest>"
                ],
                "source": "launch-resolved",
                "version": 1
              },
              "model": "task-child/child",
              "outputMode": "inline",
              "outputState": "present",
              "progressSummary": {
                "durationMs": "<duration>",
                "sessionName": "task-child: [Tron workspace handoff] You are a delegated worker for T...",
                "tokens": 0,
                "toolCount": 0
              },
              "requestedModel": "task-child/child",
              "sessionFile": "<tmp>/sessions/<timestamp>_<id>/<id>/run-0/session.jsonl",
              "sessionName": "task-child: [Tron workspace handoff] You are a delegated worker for T...",
              "sessionOwnerId": "<id>",
              "task": "[prompt redacted]",
              "transcriptPath": "<tmp>/sessions/subagent-artifacts/<id>_task-child_0_transcript.jsonl",
              "usage": {
                "cacheRead": "<value>",
                "cacheWrite": "<value>",
                "cost": "<value>",
                "input": "<value>",
                "output": "<value>",
                "turns": "<value>"
              }
            }
          ],
          "runFanoutBudget": {
            "limit": 64,
            "remaining": 63,
            "used": 1
          },
          "runId": "<id>",
          "timeoutMs": 1800000,
          "totalChildUsage": {
            "cacheRead": 0,
            "cacheWrite": 0,
            "cost": "<value>",
            "input": 0,
            "output": 0,
            "turns": 1
          },
          "totalCost": {
            "costUsd": 0,
            "inputTokens": 0,
            "outputTokens": 0
          }
        },
        "durationMs": "<duration>",
        "isError": false,
        "role": "toolResult",
        "timestamp": "<timestamp>",
        "toolCallId": "lock-subagent",
        "toolName": "subagent",
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
        "api": "<api>",
        "content": [
          {
            "text": "The child finished.",
            "type": "text"
          }
        ],
        "durationMs": "<duration>",
        "model": "faux-1",
        "provider": "tron-task-faux",
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
  "processActivity": [
    {
      "childSessionRef": "<id>",
      "executionMode": "synchronous",
      "kind": "subagent",
      "lifecycle": {
        "attention": "none",
        "observedAt": "<timestamp>",
        "recentUntil": "<timestamp>",
        "sequence": "<n>",
        "state": "completed",
        "terminalAt": "<timestamp>",
        "version": 1
      },
      "model": "task-child/child",
      "outputTruncated": false,
      "processId": "<id>",
      "runId": "<id>",
      "source": "delegatedAgent",
      "startedAt": "<timestamp>",
      "title": "task-child",
      "toolCallId": "lock-subagent",
      "version": 1,
      "visibility": "recent"
    }
  ],
  "childJsonl": [
    {
      "cwd": "<tmp>/project",
      "id": "<id>",
      "timestamp": "<timestamp>",
      "type": "session",
      "version": 3
    },
    {
      "id": "<id>",
      "modelId": "child",
      "parentId": "<id>",
      "provider": "task-child",
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
      "id": "<id>",
      "name": "subagent-task-child-<id>-1",
      "parentId": "<id>",
      "timestamp": "<timestamp>",
      "type": "session_info"
    },
    {
      "narrowedGolden": 0
    },
    {
      "id": "<id>",
      "message": {
        "content": [
          {
            "text": "Task: [Tron workspace handoff]\nYou are a delegated worker for Tron. Keep the working directory supplied by your launcher. Tron's separate internal workspace is \"<tmp>/tron/workspace\" (available). Ordinary durable global documents belong in files/; state/<owner>/ is capability-owned. Do not copy projects, sessions, settings, credentials, or existing extension stores here. Read-only tasks remain read-only. Use only tools actually supplied; report to your parent rather than assuming iOS presentation tools. Pass these workspace facts to any further delegated tasks. Lifecycle transitions of the hosting or any Stable/production Gateway remain manual user actions; follow repository instructions for an isolated development Gateway.\n[/Tron workspace handoff]\n\nLock child task",
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
      "id": "<id>",
      "message": {
        "api": "openai-completions",
        "content": [
          {
            "text": "CHILD-DONE",
            "type": "text"
          }
        ],
        "durationMs": "<duration>",
        "model": "child",
        "provider": "task-child",
        "rawStopReason": "stop",
        "responseId": "<id>",
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
    }
  ]
};
