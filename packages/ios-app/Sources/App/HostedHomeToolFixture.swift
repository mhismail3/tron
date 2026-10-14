#if HOSTED_TEST
import Foundation
import TronMobileCore

/// The Home fixture's chat transcript of every Home tool call (`-home-tool-transcript`),
/// with each result's text and typed details as the Gateway's tools return them, and
/// the learned profile `home.profileList` answers. Synthetic data only.
enum HostedHomeToolFixture {
    static var transcript: [TranscriptItem] {
        try! JSONDecoder.gateway.decode([TranscriptItem].self, from: Data(transcriptJSON.utf8))
    }

    static var profileList: JSONValue {
        try! JSONDecoder.gateway.decode(JSONValue.self, from: Data(profileJSON.utf8))
    }

    private static let profileJSON = #"""
{"items": [{"id": "9a364c45-34fe-4f0a-93e6-fc507e2b0bdc", "revisionId": "6c6089c8-e735-4a20-8208-a22da0f17b79", "kind": "preference", "text": "For UI changes, show **screenshots** first, then test, validate and land.", "confirmed": false, "status": "active", "createdAt": "2026-10-12T09:00:00Z", "updatedAt": "2026-10-12T09:00:00Z"}, {"id": "6a26bfb7-f0d1-44ce-b0ae-9da01da3e55c", "revisionId": "7a26bfb7-f0d1-44ce-b0ae-9da01da3e55c", "kind": "preference", "text": "Ask every decision with the `ask_user` question tool, never in prose.", "confirmed": true, "status": "active", "createdAt": "2026-10-11T09:00:00Z", "updatedAt": "2026-10-13T09:00:00Z"}, {"id": "00a809ef-ca94-49ec-938d-1a11444c657b", "revisionId": "e074d3c2-5ff5-4069-a7e4-bf05abaec1bf", "kind": "standing-decision", "text": "Settings layers, top wins: Chat > Home profile > Project > Mac > Built-in.", "confirmed": false, "status": "active", "createdAt": "2026-10-12T10:00:00Z", "updatedAt": "2026-10-12T10:00:00Z"}, {"id": "9d8a53ff-0353-44c8-be5c-125cf20d843d", "revisionId": "932cdf7c-c2ea-4d98-b397-fcd7f93be814", "kind": "delegation-default", "text": "Start workers on Opus 5.5 with Home's thinking level; subagents use Haiku 5.5.", "confirmed": true, "status": "active", "createdAt": "2026-10-10T10:00:00Z", "updatedAt": "2026-10-13T11:00:00Z"}, {"id": "2b1f0000-0000-4000-8000-000000000001", "revisionId": "2b1f0000-0000-4000-8000-000000000002", "kind": "fact", "text": "Mohsin's Mac hosts the Stable Gateway; iOS builds install over Synology.", "confirmed": false, "status": "active", "createdAt": "2026-10-09T10:00:00Z", "updatedAt": "2026-10-09T10:00:00Z"}, {"id": "3f3264c8-5ad4-44bd-853b-c0b3a2008196", "revisionId": "3f3264c8-5ad4-44bd-853b-c0b3a2008197", "kind": "standing-decision", "text": "Settings layers: Chat over Project over Mac.", "confirmed": false, "status": "superseded", "createdAt": "2026-10-08T10:00:00Z", "updatedAt": "2026-10-08T10:00:00Z"}], "unclassified": 0}
"""#

    private static let transcriptJSON = #"""
[
 {
  "id": "home-tool-delegate-intro",
  "parentId": null,
  "presentationId": "home-tool-delegate-intro",
  "timestamp": "2026-10-13T22:00:01Z",
  "kind": "message",
  "role": "assistant",
  "content": [
   {
    "id": "home-tool-delegate-intro-text",
    "ordinal": 0,
    "type": "text",
    "text": "Delegating the sheets."
   }
  ]
 },
 {
  "id": "home-tool-delegate-call",
  "parentId": null,
  "presentationId": "home-tool-delegate-call",
  "timestamp": "2026-10-13T22:00:02Z",
  "kind": "message",
  "role": "assistant",
  "content": [
   {
    "id": "home-tool-delegate-call-content",
    "ordinal": 0,
    "type": "toolCall",
    "toolCallId": "home-tool-delegate",
    "name": "delegate",
    "arguments": {
     "taskId": "tron-home-tool-sheets-1",
     "title": "Home tool detail sheets",
     "target": "/Users/fixture/Workspace/tron",
     "intent": "Mohsin wants **Home tool detail sheets** and a *Profile* row on Manage Home.\n\n## Scope\n- Purpose-built sheets for `delegate`, `task`, `settings`, `profile`, `zoom`, `date`, `memory_search`.\n- A Profile row above Memory.\n\n## Process\n1. File an issue with `scripts/tron work`.\n2. Implement the visuals and show screenshots.\n3. Test, validate and land.\n\nFollow AGENTS.md. Use shared components only. Ask every decision with ask_user.\n\nWorker choice: model anthropic/claude-opus-5-5 (Home profile); thinking medium (Home profile)."
    }
   }
  ]
 },
 {
  "id": "home-tool-delegate-result",
  "parentId": "home-tool-delegate-call",
  "presentationId": "home-tool-delegate-result",
  "timestamp": "2026-10-13T22:00:03Z",
  "kind": "message",
  "role": "toolResult",
  "content": [
   {
    "id": "home-tool-delegate-result-text",
    "ordinal": 0,
    "type": "text",
    "text": "Task admitted; a report is required for its result."
   }
  ],
  "toolCallId": "home-tool-delegate",
  "toolName": "delegate",
  "toolLabel": "Delegate",
  "isError": false,
  "durationMs": 42,
  "details": {
   "taskId": "tron-home-tool-sheets-1",
   "sessionId": "worker-session",
   "operationId": "task-0b7c",
   "queuePosition": null,
   "worker": {
    "model": "anthropic/claude-opus-5-5",
    "thinking": "medium",
    "modelSource": "Home profile",
    "thinkingSource": "Home profile"
   }
  }
 },
 {
  "id": "home-tool-delegate-refused-call",
  "parentId": null,
  "presentationId": "home-tool-delegate-refused-call",
  "timestamp": "2026-10-13T22:00:04Z",
  "kind": "message",
  "role": "assistant",
  "content": [
   {
    "id": "home-tool-delegate-refused-call-content",
    "ordinal": 0,
    "type": "toolCall",
    "toolCallId": "home-tool-delegate-refused",
    "name": "delegate",
    "arguments": {
     "taskId": "tron-audit-1",
     "target": "/Users/fixture/Workspace/tron",
     "intent": "Read-only audit of the settings surfaces.",
     "thinking": "high",
     "reason": "Deep audit"
    }
   }
  ]
 },
 {
  "id": "home-tool-delegate-refused-result",
  "parentId": "home-tool-delegate-refused-call",
  "presentationId": "home-tool-delegate-refused-result",
  "timestamp": "2026-10-13T22:00:05Z",
  "kind": "message",
  "role": "toolResult",
  "content": [
   {
    "id": "home-tool-delegate-refused-result-text",
    "ordinal": 0,
    "type": "text",
    "text": "thinking needs a model: name the model the worker runs with, or omit thinking to keep the Gateway default"
   }
  ],
  "toolCallId": "home-tool-delegate-refused",
  "toolName": "delegate",
  "toolLabel": "Delegate",
  "isError": true,
  "durationMs": 42,
  "details": {}
 },
 {
  "id": "home-tool-task-status-intro",
  "parentId": null,
  "presentationId": "home-tool-task-status-intro",
  "timestamp": "2026-10-13T22:00:06Z",
  "kind": "message",
  "role": "assistant",
  "content": [
   {
    "id": "home-tool-task-status-intro-text",
    "ordinal": 0,
    "type": "text",
    "text": "Checking on it."
   }
  ]
 },
 {
  "id": "home-tool-task-status-call",
  "parentId": null,
  "presentationId": "home-tool-task-status-call",
  "timestamp": "2026-10-13T22:00:07Z",
  "kind": "message",
  "role": "assistant",
  "content": [
   {
    "id": "home-tool-task-status-call-content",
    "ordinal": 0,
    "type": "toolCall",
    "toolCallId": "home-tool-task-status",
    "name": "task",
    "arguments": {
     "action": "status",
     "taskId": "tron-home-tool-sheets-1"
    }
   }
  ]
 },
 {
  "id": "home-tool-task-status-result",
  "parentId": "home-tool-task-status-call",
  "presentationId": "home-tool-task-status-result",
  "timestamp": "2026-10-13T22:00:08Z",
  "kind": "message",
  "role": "toolResult",
  "content": [
   {
    "id": "home-tool-task-status-result-text",
    "ordinal": 0,
    "type": "text",
    "text": "{\"version\": 1, \"taskId\": \"tron-home-tool-sheets-1\", \"revision\": 4, \"homeId\": \"home-fixture\", \"generation\": 1, \"routeGeneration\": 1, \"wake\": null, \"intent\": {\"text\": \"Mohsin wants **Home tool detail sheets** and a *Profile* row on Manage Home.\\n\\n## Scope\\n- Purpose-built sheets for `delegate`, `task`, `settings`, `profile`, `zoom`, `date`, `memory_search`.\\n- A Profile row above Memory.\\n\\n## Process\\n1. File an issue with `scripts/tron work`.\\n2. Implement the visuals and show screenshots.\\n3. Test, validate and land.\\n\\nFollow AGENTS.md. Use shared components only. Ask every decision with ask_user.\\n\\nWorker choice: model anthropic/claude-opus-5-5 (Home profile); thinking medium (Home profile).\"}, \"intentDigest\": \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\", \"target\": \"/Users/fixture/Workspace/tron\", \"grantRef\": null, \"scopeRef\": null, \"lifecycle\": \"active\", \"sessionId\": \"worker-session\", \"operationId\": \"task-0b7c\", \"stopIntent\": null, \"spend\": {\"sourceDigest\": \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\", \"inputTokens\": 1250000, \"outputTokens\": 48200}, \"reportRef\": null, \"terminalEvidence\": null, \"createdAt\": 1791960000000, \"updatedAt\": 1791962700000, \"title\": \"Home tool detail sheets\", \"project\": \"tron\", \"workerSessionId\": \"worker-session\", \"queuePosition\": null, \"workerModel\": {\"provider\": \"anthropic\", \"id\": \"claude-opus-5-5\"}, \"subagents\": {\"started\": 3, \"stoppedAtEnd\": null}, \"subagentRuns\": {\"total\": 1, \"runs\": [{\"runId\": \"run-1\", \"agent\": \"scout\", \"state\": \"running\", \"startedAt\": \"2026-10-13T22:10:00Z\", \"lastActivityAt\": \"2026-10-13T22:40:00Z\"}]}, \"ownerSettlement\": null}"
   }
  ],
  "toolCallId": "home-tool-task-status",
  "toolName": "task",
  "toolLabel": "Task",
  "isError": false,
  "durationMs": 42,
  "details": {
   "version": 1,
   "taskId": "tron-home-tool-sheets-1",
   "revision": 4,
   "homeId": "home-fixture",
   "generation": 1,
   "routeGeneration": 1,
   "wake": null,
   "intent": {
    "text": "Mohsin wants **Home tool detail sheets** and a *Profile* row on Manage Home.\n\n## Scope\n- Purpose-built sheets for `delegate`, `task`, `settings`, `profile`, `zoom`, `date`, `memory_search`.\n- A Profile row above Memory.\n\n## Process\n1. File an issue with `scripts/tron work`.\n2. Implement the visuals and show screenshots.\n3. Test, validate and land.\n\nFollow AGENTS.md. Use shared components only. Ask every decision with ask_user.\n\nWorker choice: model anthropic/claude-opus-5-5 (Home profile); thinking medium (Home profile)."
   },
   "intentDigest": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
   "target": "/Users/fixture/Workspace/tron",
   "grantRef": null,
   "scopeRef": null,
   "lifecycle": "active",
   "sessionId": "worker-session",
   "operationId": "task-0b7c",
   "stopIntent": null,
   "spend": {
    "sourceDigest": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "inputTokens": 1250000,
    "outputTokens": 48200
   },
   "reportRef": null,
   "terminalEvidence": null,
   "createdAt": 1791960000000,
   "updatedAt": 1791962700000,
   "title": "Home tool detail sheets",
   "project": "tron",
   "workerSessionId": "worker-session",
   "queuePosition": null,
   "workerModel": {
    "provider": "anthropic",
    "id": "claude-opus-5-5"
   },
   "subagents": {
    "started": 3,
    "stoppedAtEnd": null
   },
   "subagentRuns": {
    "total": 1,
    "runs": [
     {
      "runId": "run-1",
      "agent": "scout",
      "state": "running",
      "startedAt": "2026-10-13T22:10:00Z",
      "lastActivityAt": "2026-10-13T22:40:00Z"
     }
    ]
   },
   "ownerSettlement": null
  }
 },
 {
  "id": "home-tool-task-report-call",
  "parentId": null,
  "presentationId": "home-tool-task-report-call",
  "timestamp": "2026-10-13T22:00:09Z",
  "kind": "message",
  "role": "assistant",
  "content": [
   {
    "id": "home-tool-task-report-call-content",
    "ordinal": 0,
    "type": "toolCall",
    "toolCallId": "home-tool-task-report",
    "name": "task",
    "arguments": {
     "action": "report",
     "taskId": "tron-settings-model-decisions-1",
     "offset": 0,
     "limit": 4096
    }
   }
  ]
 },
 {
  "id": "home-tool-task-report-result",
  "parentId": "home-tool-task-report-call",
  "presentationId": "home-tool-task-report-result",
  "timestamp": "2026-10-13T22:00:10Z",
  "kind": "message",
  "role": "toolResult",
  "content": [
   {
    "id": "home-tool-task-report-result-text",
    "ordinal": 0,
    "type": "text",
    "text": "{\"taskId\": \"tron-settings-model-decisions-1\", \"offset\": 0, \"bytes\": 484, \"text\": \"{\\\"version\\\": 1, \\\"taskId\\\": \\\"tron-settings-model-decisions-1\\\", \\\"homeId\\\": \\\"home-fixture\\\", \\\"generation\\\": 1, \\\"operationId\\\": \\\"task-3671\\\", \\\"resultId\\\": \\\"772-settings-decisions-folded\\\", \\\"outcome\\\": \\\"final\\\", \\\"text\\\": \\\"I folded Mohsin's 16 decisions into `packages/gateway/docs/settings-model.md` and pushed them to **PR #773**.\\\\n\\\\n**PR #773**\\\\n- New head: `c82dc874c`.\\\\n- `gh pr view 773`: state=OPEN.\\\\n\\\\n## Verification\\\\n- whitespace passed\\\\n- privacy passed\\\\n\\\\n## Residual risks\\\\n- None known.\\\"}\", \"nextOffset\": null}"
   }
  ],
  "toolCallId": "home-tool-task-report",
  "toolName": "task",
  "toolLabel": "Task",
  "isError": false,
  "durationMs": 42,
  "details": {
   "taskId": "tron-settings-model-decisions-1",
   "offset": 0,
   "bytes": 484,
   "text": "{\"version\": 1, \"taskId\": \"tron-settings-model-decisions-1\", \"homeId\": \"home-fixture\", \"generation\": 1, \"operationId\": \"task-3671\", \"resultId\": \"772-settings-decisions-folded\", \"outcome\": \"final\", \"text\": \"I folded Mohsin's 16 decisions into `packages/gateway/docs/settings-model.md` and pushed them to **PR #773**.\\n\\n**PR #773**\\n- New head: `c82dc874c`.\\n- `gh pr view 773`: state=OPEN.\\n\\n## Verification\\n- whitespace passed\\n- privacy passed\\n\\n## Residual risks\\n- None known.\"}",
   "nextOffset": null
  }
 },
 {
  "id": "home-tool-task-steer-call",
  "parentId": null,
  "presentationId": "home-tool-task-steer-call",
  "timestamp": "2026-10-13T22:00:11Z",
  "kind": "message",
  "role": "assistant",
  "content": [
   {
    "id": "home-tool-task-steer-call-content",
    "ordinal": 0,
    "type": "toolCall",
    "toolCallId": "home-tool-task-steer",
    "name": "task",
    "arguments": {
     "action": "steer",
     "taskId": "tron-home-tool-sheets-1",
     "operationId": "task-0b7c",
     "text": "Mohsin added: the **Profile** row goes *above* Memory."
    }
   }
  ]
 },
 {
  "id": "home-tool-task-steer-result",
  "parentId": "home-tool-task-steer-call",
  "presentationId": "home-tool-task-steer-result",
  "timestamp": "2026-10-13T22:00:12Z",
  "kind": "message",
  "role": "toolResult",
  "content": [
   {
    "id": "home-tool-task-steer-result-text",
    "ordinal": 0,
    "type": "text",
    "text": "{\"accepted\":true}"
   }
  ],
  "toolCallId": "home-tool-task-steer",
  "toolName": "task",
  "toolLabel": "Task",
  "isError": false,
  "durationMs": 42,
  "details": {
   "accepted": true
  }
 },
 {
  "id": "home-tool-task-rejected-call",
  "parentId": null,
  "presentationId": "home-tool-task-rejected-call",
  "timestamp": "2026-10-13T22:00:13Z",
  "kind": "message",
  "role": "assistant",
  "content": [
   {
    "id": "home-tool-task-rejected-call-content",
    "ordinal": 0,
    "type": "toolCall",
    "toolCallId": "home-tool-task-rejected",
    "name": "task",
    "arguments": {
     "action": "steer",
     "taskId": "tron-home-tool-sheets-1",
     "operationId": "task-0b7c",
     "generation": 1,
     "message": "Also cover settings."
    }
   }
  ]
 },
 {
  "id": "home-tool-task-rejected-result",
  "parentId": "home-tool-task-rejected-call",
  "presentationId": "home-tool-task-rejected-result",
  "timestamp": "2026-10-13T22:00:14Z",
  "kind": "message",
  "role": "toolResult",
  "content": [
   {
    "id": "home-tool-task-rejected-result-text",
    "ordinal": 0,
    "type": "text",
    "text": "Validation failed for tool \"task\":\n  - generation: schema is false\n  - message: schema is false\n  - root: must not have additional properties\n  - action: must be equal to constant\n  - generation: schema is false\n\nReceived arguments:\n{\n  \"action\": \"steer\"\n}"
   }
  ],
  "toolCallId": "home-tool-task-rejected",
  "toolName": "task",
  "toolLabel": "Task",
  "isError": true,
  "durationMs": 42,
  "details": {}
 },
 {
  "id": "home-tool-settings-resolve-intro",
  "parentId": null,
  "presentationId": "home-tool-settings-resolve-intro",
  "timestamp": "2026-10-13T22:00:15Z",
  "kind": "message",
  "role": "assistant",
  "content": [
   {
    "id": "home-tool-settings-resolve-intro-text",
    "ordinal": 0,
    "type": "text",
    "text": "Reading and changing settings."
   }
  ]
 },
 {
  "id": "home-tool-settings-resolve-call",
  "parentId": null,
  "presentationId": "home-tool-settings-resolve-call",
  "timestamp": "2026-10-13T22:00:16Z",
  "kind": "message",
  "role": "assistant",
  "content": [
   {
    "id": "home-tool-settings-resolve-call-content",
    "ordinal": 0,
    "type": "toolCall",
    "toolCallId": "home-tool-settings-resolve",
    "name": "settings",
    "arguments": {
     "action": "resolve",
     "keys": [
      "model.ref[role=worker]",
      "run.retry.maxRetries"
     ]
    }
   }
  ]
 },
 {
  "id": "home-tool-settings-resolve-result",
  "parentId": "home-tool-settings-resolve-call",
  "presentationId": "home-tool-settings-resolve-result",
  "timestamp": "2026-10-13T22:00:17Z",
  "kind": "message",
  "role": "toolResult",
  "content": [
   {
    "id": "home-tool-settings-resolve-result-text",
    "ordinal": 0,
    "type": "text",
    "text": "{\"layers\":[\"chat\",\"profile\",\"mac\",\"builtin\"],\"keys\":[]}"
   }
  ],
  "toolCallId": "home-tool-settings-resolve",
  "toolName": "settings",
  "toolLabel": "Settings",
  "isError": false,
  "durationMs": 42,
  "details": {
   "target": {
    "kind": "home"
   },
   "layers": [
    "chat",
    "profile",
    "mac",
    "builtin"
   ],
   "keys": [
    {
     "key": "model.ref[role=worker]",
     "group": "model",
     "value": {
      "provider": "anthropic",
      "id": "claude-opus-5-5"
     },
     "display": "Claude Opus 5.5",
     "layer": "profile",
     "applied": true,
     "badges": [],
     "layers": []
    },
    {
     "key": "run.retry.maxRetries",
     "group": "run",
     "value": 3,
     "display": "3",
     "layer": "builtin",
     "applied": true,
     "badges": [],
     "layers": []
    }
   ],
   "diagnostics": []
  }
 },
 {
  "id": "home-tool-settings-change-call",
  "parentId": null,
  "presentationId": "home-tool-settings-change-call",
  "timestamp": "2026-10-13T22:00:18Z",
  "kind": "message",
  "role": "assistant",
  "content": [
   {
    "id": "home-tool-settings-change-call-content",
    "ordinal": 0,
    "type": "toolCall",
    "toolCallId": "home-tool-settings-change",
    "name": "settings",
    "arguments": {
     "action": "change",
     "reason": "Mohsin asked for more retries on flaky providers.",
     "changes": [
      {
       "key": "run.retry.maxRetries",
       "layer": "profile",
       "op": "set",
       "value": 6
      }
     ]
    }
   }
  ]
 },
 {
  "id": "home-tool-settings-change-result",
  "parentId": "home-tool-settings-change-call",
  "presentationId": "home-tool-settings-change-result",
  "timestamp": "2026-10-13T22:00:19Z",
  "kind": "message",
  "role": "toolResult",
  "content": [
   {
    "id": "home-tool-settings-change-result-text",
    "ordinal": 0,
    "type": "text",
    "text": "Pending the maintainer's approval (request req-1, expires 2026-10-14T00:00:00Z). Nothing changed yet."
   }
  ],
  "toolCallId": "home-tool-settings-change",
  "toolName": "settings",
  "toolLabel": "Settings",
  "isError": false,
  "durationMs": 42,
  "details": {
   "status": "pending",
   "tier": "approve",
   "approval": {
    "requestId": "req-1",
    "digest": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    "expiresAt": "2026-10-14T00:00:00Z"
   },
   "changes": [
    {
     "changeId": "ch-1",
     "key": "run.retry.maxRetries",
     "layer": "profile",
     "status": "pending",
     "tier": "approve",
     "before": 3,
     "after": 6
    }
   ]
  }
 },
 {
  "id": "home-tool-profile-learn-intro",
  "parentId": null,
  "presentationId": "home-tool-profile-learn-intro",
  "timestamp": "2026-10-13T22:00:20Z",
  "kind": "message",
  "role": "assistant",
  "content": [
   {
    "id": "home-tool-profile-learn-intro-text",
    "ordinal": 0,
    "type": "text",
    "text": "Saving what you said."
   }
  ]
 },
 {
  "id": "home-tool-profile-learn-call",
  "parentId": null,
  "presentationId": "home-tool-profile-learn-call",
  "timestamp": "2026-10-13T22:00:21Z",
  "kind": "message",
  "role": "assistant",
  "content": [
   {
    "id": "home-tool-profile-learn-call-content",
    "ordinal": 0,
    "type": "toolCall",
    "toolCallId": "home-tool-profile-learn",
    "name": "profile",
    "arguments": {
     "action": "learn",
     "kind": "preference",
     "text": "For UI changes, show **screenshots** first, then test and land."
    }
   }
  ]
 },
 {
  "id": "home-tool-profile-learn-result",
  "parentId": "home-tool-profile-learn-call",
  "presentationId": "home-tool-profile-learn-result",
  "timestamp": "2026-10-13T22:00:22Z",
  "kind": "message",
  "role": "toolResult",
  "content": [
   {
    "id": "home-tool-profile-learn-result-text",
    "ordinal": 0,
    "type": "text",
    "text": "Saved profile item note 9a364c45-34fe-4f0a-93e6-fc507e2b0bdc (preference, inferred until you confirm it): For UI changes, show screenshots first, then test and land."
   }
  ],
  "toolCallId": "home-tool-profile-learn",
  "toolName": "profile",
  "toolLabel": "Profile",
  "isError": false,
  "durationMs": 42,
  "details": {
   "status": "saved",
   "action": "learn",
   "id": "9a364c45-34fe-4f0a-93e6-fc507e2b0bdc",
   "revisionId": "6c6089c8-e735-4a20-8208-a22da0f17b79",
   "kind": "preference"
  }
 },
 {
  "id": "home-tool-profile-supersede-call",
  "parentId": null,
  "presentationId": "home-tool-profile-supersede-call",
  "timestamp": "2026-10-13T22:00:23Z",
  "kind": "message",
  "role": "assistant",
  "content": [
   {
    "id": "home-tool-profile-supersede-call-content",
    "ordinal": 0,
    "type": "toolCall",
    "toolCallId": "home-tool-profile-supersede",
    "name": "profile",
    "arguments": {
     "action": "supersede",
     "id": "3f3264c8-5ad4-44bd-853b-c0b3a2008196",
     "kind": "standing-decision",
     "text": "Settings layers, top wins: Chat > Home profile > Project > Mac > Built-in.",
     "reason": "Mohsin restated the order."
    }
   }
  ]
 },
 {
  "id": "home-tool-profile-supersede-result",
  "parentId": "home-tool-profile-supersede-call",
  "presentationId": "home-tool-profile-supersede-result",
  "timestamp": "2026-10-13T22:00:24Z",
  "kind": "message",
  "role": "toolResult",
  "content": [
   {
    "id": "home-tool-profile-supersede-result-text",
    "ordinal": 0,
    "type": "text",
    "text": "Superseded profile item note 3f3264c8 with note 00a809ef."
   }
  ],
  "toolCallId": "home-tool-profile-supersede",
  "toolName": "profile",
  "toolLabel": "Profile",
  "isError": false,
  "durationMs": 42,
  "details": {
   "status": "saved",
   "action": "supersede",
   "id": "00a809ef-ca94-49ec-938d-1a11444c657b",
   "revisionId": "e074d3c2-5ff5-4069-a7e4-bf05abaec1bf",
   "kind": "standing-decision",
   "supersededId": "3f3264c8-5ad4-44bd-853b-c0b3a2008196",
   "previousText": "Settings layers: Chat over Project over Mac."
  }
 },
 {
  "id": "home-tool-profile-refused-call",
  "parentId": null,
  "presentationId": "home-tool-profile-refused-call",
  "timestamp": "2026-10-13T22:00:25Z",
  "kind": "message",
  "role": "assistant",
  "content": [
   {
    "id": "home-tool-profile-refused-call-content",
    "ordinal": 0,
    "type": "toolCall",
    "toolCallId": "home-tool-profile-refused",
    "name": "profile",
    "arguments": {
     "action": "retire",
     "id": "missing-note"
    }
   }
  ]
 },
 {
  "id": "home-tool-profile-refused-result",
  "parentId": "home-tool-profile-refused-call",
  "presentationId": "home-tool-profile-refused-result",
  "timestamp": "2026-10-13T22:00:26Z",
  "kind": "message",
  "role": "toolResult",
  "content": [
   {
    "id": "home-tool-profile-refused-result-text",
    "ordinal": 0,
    "type": "text",
    "text": "Profile retire refused: retire requires reason"
   }
  ],
  "toolCallId": "home-tool-profile-refused",
  "toolName": "profile",
  "toolLabel": "Profile",
  "isError": false,
  "durationMs": 42,
  "details": {
   "status": "refused",
   "action": "retire",
   "reason": "retire requires reason"
  }
 },
 {
  "id": "home-tool-zoom-intro",
  "parentId": null,
  "presentationId": "home-tool-zoom-intro",
  "timestamp": "2026-10-13T22:00:27Z",
  "kind": "message",
  "role": "assistant",
  "content": [
   {
    "id": "home-tool-zoom-intro-text",
    "ordinal": 0,
    "type": "text",
    "text": "Looking back."
   }
  ]
 },
 {
  "id": "home-tool-zoom-call",
  "parentId": null,
  "presentationId": "home-tool-zoom-call",
  "timestamp": "2026-10-13T22:00:28Z",
  "kind": "message",
  "role": "assistant",
  "content": [
   {
    "id": "home-tool-zoom-call-content",
    "ordinal": 0,
    "type": "toolCall",
    "toolCallId": "home-tool-zoom",
    "name": "zoom",
    "arguments": {
     "id": 1120,
     "n": 4
    }
   }
  ]
 },
 {
  "id": "home-tool-zoom-result",
  "parentId": "home-tool-zoom-call",
  "presentationId": "home-tool-zoom-result",
  "timestamp": "2026-10-13T22:00:29Z",
  "kind": "message",
  "role": "toolResult",
  "content": [
   {
    "id": "home-tool-zoom-result-text",
    "ordinal": 0,
    "type": "text",
    "text": "1120+2|summary: **Mohsin** asked for the #890 handoff; Home sent the exact command.\n1122+2|summary: The worker took the claim and pushed `feat/890` with a checkpoint."
   }
  ],
  "toolCallId": "home-tool-zoom",
  "toolName": "zoom",
  "toolLabel": "Zoom",
  "isError": false,
  "durationMs": 42,
  "details": {
   "status": "ok"
  }
 },
 {
  "id": "home-tool-zoom-invalid-call",
  "parentId": null,
  "presentationId": "home-tool-zoom-invalid-call",
  "timestamp": "2026-10-13T22:00:30Z",
  "kind": "message",
  "role": "assistant",
  "content": [
   {
    "id": "home-tool-zoom-invalid-call-content",
    "ordinal": 0,
    "type": "toolCall",
    "toolCallId": "home-tool-zoom-invalid",
    "name": "zoom",
    "arguments": {
     "id": 7,
     "n": 3
    }
   }
  ]
 },
 {
  "id": "home-tool-zoom-invalid-result",
  "parentId": "home-tool-zoom-invalid-call",
  "presentationId": "home-tool-zoom-invalid-result",
  "timestamp": "2026-10-13T22:00:31Z",
  "kind": "message",
  "role": "toolResult",
  "content": [
   {
    "id": "home-tool-zoom-invalid-result-text",
    "ordinal": 0,
    "type": "text",
    "text": "No line 7+3."
   }
  ],
  "toolCallId": "home-tool-zoom-invalid",
  "toolName": "zoom",
  "toolLabel": "Zoom",
  "isError": false,
  "durationMs": 42,
  "details": {
   "status": "invalid-arguments"
  }
 },
 {
  "id": "home-tool-date-call",
  "parentId": null,
  "presentationId": "home-tool-date-call",
  "timestamp": "2026-10-13T22:00:32Z",
  "kind": "message",
  "role": "assistant",
  "content": [
   {
    "id": "home-tool-date-call-content",
    "ordinal": 0,
    "type": "toolCall",
    "toolCallId": "home-tool-date",
    "name": "date",
    "arguments": {
     "id": 1286
    }
   }
  ]
 },
 {
  "id": "home-tool-date-result",
  "parentId": "home-tool-date-call",
  "presentationId": "home-tool-date-result",
  "timestamp": "2026-10-13T22:00:33Z",
  "kind": "message",
  "role": "toolResult",
  "content": [
   {
    "id": "home-tool-date-result-text",
    "ordinal": 0,
    "type": "text",
    "text": "1286+0|2026-10-13 22:30:58 +02:00"
   }
  ],
  "toolCallId": "home-tool-date",
  "toolName": "date",
  "toolLabel": "Date",
  "isError": false,
  "durationMs": 42,
  "details": {
   "status": "ok",
   "date": {
    "id": 1286,
    "at": "2026-10-13T20:30:58.000Z"
   }
  }
 },
 {
  "id": "home-tool-memory-search-call",
  "parentId": null,
  "presentationId": "home-tool-memory-search-call",
  "timestamp": "2026-10-13T22:00:34Z",
  "kind": "message",
  "role": "assistant",
  "content": [
   {
    "id": "home-tool-memory-search-call-content",
    "ordinal": 0,
    "type": "toolCall",
    "toolCallId": "home-tool-memory-search",
    "name": "memory_search",
    "arguments": {
     "query": "handoff 890",
     "from": 1100
    }
   }
  ]
 },
 {
  "id": "home-tool-memory-search-result",
  "parentId": "home-tool-memory-search-call",
  "presentationId": "home-tool-memory-search-result",
  "timestamp": "2026-10-13T22:00:35Z",
  "kind": "message",
  "role": "toolResult",
  "content": [
   {
    "id": "home-tool-memory-search-result-text",
    "ordinal": 0,
    "type": "text",
    "text": "memory_search \"handoff 890\" in messages [1100, 1132): 2 match(es), 2 shown, 0 [omitted], 0 capped.\n1110+0|echo: \u2026 the **loading pulse**: branch `feat/890-sheets` has unfinished work. Take the claim with `scripts/tron work handoff 890`.\n1131+0|talk: I ran the **handoff** and the worker resumed."
   }
  ],
  "toolCallId": "home-tool-memory-search",
  "toolName": "memory_search",
  "toolLabel": "Memory search",
  "isError": false,
  "durationMs": 42,
  "details": {
   "status": "ok",
   "search": {
    "query": "handoff 890",
    "from": 1100,
    "to": 1132,
    "matches": 2,
    "shown": 2,
    "omitted": 0,
    "capped": 0
   }
  }
 }
]
"""#
}
#endif
