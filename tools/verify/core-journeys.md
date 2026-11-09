# Core-journey coverage map

The six core journeys of [principles P2](../../docs/PRINCIPLES.md#p2-whole-system-health-is-a-batch-signal-not-a-commit-gate)
mapped to the tests that actually exercise them. A file's existence or an old pass is
not proof: every row names what the test drives, what is real and what is controlled.
Run results belong in `test-results/` and reports, not in this map. Gap fixes belong to
#2142 (children below); golden and pixel oracle replacement to #2189. Update a row when its test or boundary changes.

## Boundaries

| Label | What runs | Controlled |
|---|---|---|
| **Process** | Built Gateway `dist/index.js` as its own process, started by `scripts/ios-gateway-e2e-test` with a fault proxy (`scripts/ios-gateway-fault-proxy.mjs`); Pi in that process; real socket from the simulator. `restart-gateway` restarts the process on the same data; `respawn-exited-gateway` starts it again after a supervised Gateway exits on its own. | `tron-e2e/e2e-model` scripted provider extension written by `scripts/ios-gateway-e2e-fixture.sh`; proxy link faults. |
| **Native** | Process boundary driven by the production app UI (`HOSTED_TEST` build, `TronMobileUITests`) after real pairing. | Same as Process. |
| **Lock socket** | `startLockGateway` (`packages/gateway/test-support/gateway-lock-harness.ts`): in-process `GatewayServer`, loopback `ws` client, real `RuntimeRegistry`/Pi SDK, temp disk. | Faux provider. Restart = dispose and start on the same root in the same Node process. |
| **Registry** | Real `RuntimeRegistry`/owners and Pi SDK in the Vitest process; RPCs via `GatewayService.invoke`, no socket. | Faux provider; `f.restart()` recreates the registry in-process. |
| **Child** | Registry plus the real managed `pi-subagents` install running child Pi sessions with their own canonical JSONL. A foreground run records the fixture's own pid (`packages/gateway/test-support/home-task-fixture.ts`), so it is not proof of a separate child process; async/detached runners are separate processes the fixture awaits. | Faux parent provider, scripted local HTTP child model. |

No row is live-provider, physical-device or durable Keychain proof. `RealGatewayPiBoundaryTests`
uses in-memory profile/token stores (`packages/ios-app/E2ETests/RealGatewayPiBoundaryTests.swift`).

## 1. Prompt / reply — accepted prompt streams and settles the correct reply once

| Test (full ID) | Boundary | Input → behavioral assertion | Failure / recovery |
|---|---|---|---|
| `packages/gateway/src/e2e/sessions/run.lock.integration.test.ts` › gateway/run kernel locks › prompt/stream | Lock socket | `session.prompt` "read the notes" → canonical roles exactly user, assistant, toolResult, assistant; 2 provider requests; snapshot event seen | Sibling cases: abort settles `stopReason: aborted` with 1 request; steer/follow-up order |
| `TronMobileUITests/RealGatewayPairAndChatUITests/testInvitationLinkPairsCompletesSetupStreamsAndReconnectsAfterBackground` | Native | Pair by invitation, type unique prompt, Send → sent row present; streamed reply reaches its completion marker | Then reconnect phases (row 6) |
| `TronMobileE2ETests/RealGatewayPiBoundaryTests/testStreamsReconnectsAndSettlesExtensionTools` | Process | Prompt with commandId, accepted response dropped → `command.status` completed with operationId; reconnect snapshot idle with reply; prompt appears exactly once | Lost response; detached completion after client retirement |

**GAP #2230:** the assistant reply is counted exactly once only by the lock's inline
canonical-message check; the Process/Native rows assert presence, not exactly-once or canonical persistence.

## 2. Delegate / result — real child result returns; owned cancellation and settlement

| Test | Boundary | Input → behavioral assertion | Failure / recovery |
|---|---|---|---|
| `packages/gateway/src/e2e/kernel/delegation/delegation.lock.integration.test.ts` › gateway/delegation kernel locks › subagent: a foreground subagent runs a real child… | Child (foreground) | "delegate the lock task" → non-error subagent result containing child answer; parent idle, no active child; 2 parent requests; child JSONL has task | Success only |
| `packages/gateway/src/e2e/modules/home/home-task-subagents-settlement.e2e.test.ts` (11 cases, e.g. "stops a running async run when the task is stopped, and no turn starts after settlement") | Child | Home task launches real runs → task settles only after runs join; counts | Stop, error, 24 h deadline, bounded stop join → `unknown` |
| `…/home-task-subagents-controls.e2e.test.ts`, `…/home-task-subagents-reports.e2e.test.ts` (26 cases) | Child | Waits/wakes, steer, supervisor reply, report refused while run live | Foreign-run control refused; restart finds live run → `detached-work-outlived-task` |
| `packages/gateway/src/e2e/kernel/delegation/process-transcript-stop.integration.test.ts` › stops only the exact connection-owned child transcript… | Child | Stop targets exact child only | Other children untouched |

`TronSubagentParityUITests` uses hosted fixture data: projection only, not this journey.
**GAP #2231:** no socket or native test delegates and cancels from a client.

## 3. Approval tap — no effect before exact acceptance; stale/denied cannot authorize; effect once

| Test | Boundary | Input → behavioral assertion | Failure / recovery |
|---|---|---|---|
| `packages/gateway/src/e2e/admin/native-change.e2e.test.ts` › typed changes and exact native acceptance › publishes the exact built-in card, refuses local/generic/stale answers… | Registry | Card published; two concurrent exact answers → one applies, other `not_found`; settings file written once; one history entry; replay of same command returns same result | Wrong digest / local / generic → `invalid_request`; retired epoch / revision → `conflict`; no history before acceptance |
| same file › decline or Stop before acceptance has no effect (both); an unanswered exact change card expires…; recovers the actual native response receipt after a fixture kill at pending/effects/completion | Registry | No file/history change; late tap refused | Kill-cut recovery without replaying effects |
| `packages/gateway/src/e2e/modules/apps/apps-install.integration.test.ts` › … › offers without installing, reviews exact source/config, installs once… | Registry | Offer → `apps.list` empty; reviewed install creates once, same command idempotent | Stale install `conflict`; crash-cut cases without replay |
| `TronMobileUITests/RealGatewayPairAndChatUITests/testPendingAppReviewInstallLight` | Native | Real `swift_app` offer → no app directory through review; explicit confirm tap creates `app.json`, pending row leaves | — |
| `…/testTrustedProjectsListsAndAddsProjectsUntrusted` | Native | Trust changes only after the card's exact digest tap | — |
| `…/testProjectLifecycleDenialRetainsUntrustedRepository` | Native | Deny → no repository or trust; denied trust keeps the repository untrusted | Denial path |

**GAP #2232:** stale/wrong-digest/double-tap refusals are proven only through in-process
`GatewayService.invoke`; no socket or native case for the shared change card.

## 4. Settings change — next operation sees it; scope, refusal and truthful Undo

| Test | Boundary | Input → behavioral assertion | Failure / recovery |
|---|---|---|---|
| `packages/gateway/src/e2e/admin/settings-gate.e2e.test.ts` › typed settings at real runtime boundaries › open chats follow live retry defaults while a canonical Session override stays local… | Registry | Global retry 0→1→2 and a Session override change the *next* prompt's provider attempt counts per chat; unset restores Global | Session fence |
| `packages/gateway/src/e2e/admin/settings-three-layer.e2e.test.ts` › approved three-layer settings at real Gateway boundaries › applies, logs and undoes through receipts…; refuses a stale expected value… | Registry | Change applied and logged; Undo restores; Undo of Undo linked | A second Undo command for the same change `conflict`; stale expected value refused with no effect |
| `packages/gateway/src/e2e/admin/admin.lock.integration.test.ts` › gateway/admin kernel locks › settings change: a Global change is recorded… | Lock socket | WebSocket `settings.change` → applied, file and Global/Session resolve show new value | — |
| `TronMobileUITests/RealGatewayPairAndChatUITests/testAgentBehaviorQueuesSaveReopenAndResetLight` | Native | Worker/subagent/background queues: ordered save, reopen, remove, empty ≠ reset; Changes Before/After; Undo restores explicit empty queue in the Gateway store | Reset removes override |

`TronSettingsChangesReviewUITests` is hosted renderer data: presentation only.
**GAP #2233:** no native or socket test shows the next prompt/dispatch consuming a UI change or its Undo.

## 5. Home wake — durable addressed wake consumed once, including restart

| Test | Boundary | Input → behavioral assertion | Failure / recovery |
|---|---|---|---|
| `packages/gateway/src/e2e/modules/home/home-wake.e2e.test.ts` › Home wakes on its own task results (#749) › wakes exactly once after a restart that finds pending results; restarts during a wake: its trigger is never replayed… | Registry | Pending result → exactly one wake model call after restart; result in chapter once; no duplicate push | In-process registry restart mid-wake → trigger acknowledged or `outcome-unknown`, never resent |
| same file › keeps one delivery when a user prompt races a wake; never wakes Home again after Stop ends a wake…; does not wake a paused/disabled Home | Registry | One result, one user message, one operation | Stop/pause/disable refusals |
| `packages/gateway/src/modules/home/home-wake-inbox.integration.test.ts` › Wake inbox frozen-owner crash cuts (8 cuts + 5 evidence modes) | Registry (disk reopen) | No effect replay across each cut; acknowledges only with proof | Malformed/duplicate evidence → `outcome-unknown` |
| `packages/gateway/src/e2e/automations/automation-home.e2e.test.ts` › real Gateway: paused crash claims and a partial canonical batch recover exactly once with one push across restart (+10 cases) | Lock socket | Automation firings delivered to Home once; one push across restart | Cancellation/claim fences; wake cannot approve settings/trust |
| `TronMobileUITests/RealGatewayPairAndChatUITests/testHomeAutomationEditorAndAttributedMessageLight` | Native | Editor creates Home automation; Run Now → attributed Automation chip in Home | — |

**GAP #2234:** restart is in-process only; the native case asserts presence, not consume-once.

## 6. Reconnect / restart — snapshot and accepted receipt survive; no replay

| Test | Boundary | Input → behavioral assertion | Failure / recovery |
|---|---|---|---|
| `packages/gateway/src/e2e/transport/transport.lock.integration.test.ts` › gateway/transport kernel locks › reconnect snapshot… | Lock socket | Client drops mid-run; live snapshot names the operation; settled snapshot has reply; 1 provider request; 1 user row | Same Gateway, client loss |
| `packages/gateway/src/transport/command-receipts.lock.integration.test.ts` (3 cases) | Lock socket | Replay, fence, bound, prune of command receipts | Duplicate inside lane |
| `packages/gateway/src/e2e/sessions/runtime-registry.integration.test.ts` › … › does not infer a completion from an unstamped accepted marker after restart; recovers a canonical successful completion missed before restart | Registry | Restart recovery of accepted markers | No inferred completion |
| `TronMobileE2ETests/RealGatewayPiBoundaryTests/testStreamsReconnectsAndSettlesExtensionTools` (`exerciseForegroundReconnect`) | Process | `restart-gateway` with an **idle** session while app backgrounded → reconnect without Retry; transcript, user count and idle catalog row unchanged | Rejected upgrades 401/403/503, blackhole, frame ceiling |
| `TronMobileUITests/RealGatewayPairAndChatUITests/testGatewayRestartWaitsForLiveWorkThenRestartsIdleAndReconnects` | Native (supervised fixture) | Restart over a held turn → "scheduled after 1 accepted operation"; idle Restart → Restarting and its notice; reconnect after each supervised exit and respawn | A drain that counts its own RPC (#1559) shows the wrong count |
| `TronMobileUITests/RealGatewayPairAndChatUITests/testInvitationLinkPairsCompletesSetupStreamsAndReconnectsAfterBackground`; `…/testForegroundAndReconnectKeepSheetsAndTheirContent`; `…/testImageOnlySteerLeavesTheQueueOnceDelivered` | Native | Blackhole, held/replaced open, background/foreground: draft, keyboard, reply and anchored rows retained; sheets keep content; queued steer delivered once | Definitive rejection then explicit retry |

**GAP #2235:** no in-flight accepted prompt across a real Gateway-process restart.

## Oracle audit

On its normal (non-update, golden-present) path, `compareWithGolden`
(`packages/gateway/test-support/scenario-lock.ts`) runs a lock's behavioral `validate`
only when the whole trace equals its golden, so these goldens gate the assertions above:

| Journey | Golden (under `packages/gateway/src/`) | Whole-prompt / schema content | Owner |
|---|---|---|---|
| Prompt/reply | `test-fixtures/pi-sdk/session-shapes.golden.json` (`session-shapes.lock`); the transcript, messages and responses are inline checks in `e2e/sessions/run.lock.integration.test.ts` | prompt hash + section headings + system entry | #2189 |
| Delegate | `e2e/kernel/delegation/locks/delegation-subagent.golden.json` (narrowed: system entries and Tron entries); the rest inline in `e2e/kernel/delegation/delegation.lock.integration.test.ts` | tool parameter schemas | #2189 |
| Home wake | `e2e/modules/home/locks/home-activation-wake.golden.json` (narrowed: provider requests and system entries); the rest inline in `e2e/modules/home/home.lock.integration.test.ts` | prompt hashes + full tool schemas | #2189 |
| Home restart | `e2e/modules/home/locks/home-contention-restart.golden.json` (narrowed: Home's system entry and Tron entries); the rest inline in `e2e/modules/home/home-restart.lock.integration.test.ts` | full tool descriptions/schemas | #2236 |
| Settings | `e2e/admin/admin.lock.integration.test.ts` (named checks) | whole exchange/file trace | #2236 |
| Reconnect | `e2e/transport/transport.lock.integration.test.ts` (named checks); the reconnect, lifecycle and cold-load prompt hashes are in `test-fixtures/pi-sdk/session-shapes.golden.json` | prompt hash | #2189 |
| Wire | `e2e/protocol/locks/protocol-wire.golden.json` | method shapes, prompt section headings | #2236 |

Native pixel/geometry oracles in the reconnect journey
(`packages/ios-app/UITests/RealGateway/RealGatewayPairAndChatUITests.swift`): anchored rows
`changedPixelFraction < 0.01` across transport retirement and 3-point frame equalities for
reply, composer and anchor. They protect real reader anchoring; replacement only with
reviewed parity (#2236). The Registry/Child rows assert behavior directly; `native-change`
and `settings-gate` only write evidence JSON, which is not compared.
