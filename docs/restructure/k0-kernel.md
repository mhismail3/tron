# K-0: Gateway kernel design

Phase 2 step 1 of [the restructure plan](plan.md#phase-2-gateway-kernel-m2-highest-risk-independent-review-on-every-slice)
(issue #1524). It fixes the kernel ports, the module host contract, the Pi seam and the
extraction order. **The maintainer approves it before any Phase 2 extraction slice lands.**
Code references are `file:line` at base `096b35f8a`, relative to the Gateway's `src/`.
Behavior invariants B1–B6 (plan §4.1) bind every step: each port below is placed at a
call site that exists today, with the same ordering, sync/async shape and failure handling.

## 1. Starting point

| Fact | Evidence |
|---|---|
| `RuntimeSlot` (11,165 lines) builds the Pi runtime, the module host, the Home profile, the request pipeline and the task-worker role in one closure | `sessions/runtime-slot.ts:2212-2608` (`runtimeFactory`) |
| Slot dependencies: 60 fields, 19 of them Home/task; hooks: 10, 3 of them Home | `sessions/runtime-slot.ts:522-635`, `:455-486` |
| The registry (5,030 lines) is also a composition root: it constructs Swift apps, display, workspace, model queues and `HomeOwner`, and passes itself to Home | `sessions/runtime-registry.ts:762-866` (`taskSessions: this` at `:865`) |
| Home and automations reach the registry's concrete class | `home/home-owner.ts:162`, `home/home-task-dispatcher.ts:217`, `home/home-session-read.ts:29`, `sessions/owned-session-dispatch.ts:20` |
| Module host is one fat interface carrying every module's service | `extensions/tron-modules.ts:32-80` (`TronModuleHost`), lists `:102-224`, `:236-301` |
| Upward edges recorded by the layer ratchet | `gateway/run` → 13 L3/L4 modules, `gateway/extensions` → 11, `gateway/projection` → display (`packages/gateway/layer-baseline.json`) |
| Pi is imported at runtime by 50 production files (39 more type-only) | §4 |

## 2. Kernel primitives and ports

The kernel is `kernel/{session,run,host,resources,delegation,settings,projection,pi}`
(plan §5.2). It exposes **operations** (called by transport and modules) and **hooks**
(implemented by modules through their descriptor). It imports no module.

| Primitive | Owns (moves from) | Operations it exposes |
|---|---|---|
| K1 `session/` | slots map, per-session mutation lane (`runtime-registry.ts:531`), catalog and page sources (`:1896-2813`), acquire/cold load/heap admission (`:3334-3585`, `:3990-4242`), eviction (`:4303-4457`), archive/delete (`:3724-3990`), administrative drain (`:4661-4888`), fork/export; `session-catalog`, `catalog-*`, `session-archive-store`, `session-export`, `fork-boundary` | `SessionOperations`: `acquire`, `create(cwd, profile, owner?)`, `fork`, `archive`, `delete`, `export`, `readCut`, `subscribe`, `presence`, `serialize(sessionId, fn)` |
| K2 `run/` | prompt admission (`runtime-slot.ts:8344-9289`), queue/steer/follow-up (`:9538-9866`), abort (`:9323-9525`), compaction (`:9949-10108`), receipts and ownership writes (`:3911-4538`), request pipeline (`:2517-2568`), drain work tokens (`:1630-1877`); `invocation-receipts`, `run-markers`, `bounded-tool-cancellation`, `context-delivery-receipts`, `gateway-work-registry`, `runtime/compaction-policy` | `RunOperations`: `prompt`, `steer`, `abort`, `clearQueue`, `replaceQueue`, `compact`, `setModel/Thinking/Tools`, `executeBash`, `admitOwned(prompt, ownership)` |
| K3 `host/` | module registry and per-session extension list (replaces `TRON_MODULES` wiring), semantic UI broker (`sessions/semantic-ui-broker.ts`, `runtime-slot.ts:1035-1075`), remote extension host (`extensions/host/*`), extension activity/history, owner attribution | `ModuleHost` (§3) |
| K4 `resources/` | agent instructions, resource invocation/distribution, trust gating (`admin/trust-service.ts`), packages | `ResourceOperations`: `trust.requireResolved`, `instructions`, `expand` |
| K5 `delegation/` | worker sessions, task-worker role, subagent runs, child-session admission, steer/stop/interrupt/report across sessions (§5) | `DelegationOperations`: `createWorker`, `resumeWorker`, `lease`, `admit`, `steer`, `stop`, `interrupt`, `armDeadline`, `evidence`, `controlSubagentRun`, `settleSubagents` |
| K6 `settings/` | `admin/settings-*` model, resolver, the one change path, approvals | `SettingsAccess` (today late-bound: `runtime-slot.ts:562`, `runtime-registry.ts:917`) |
| K7 `projection/` | snapshot (`runtime-slot.ts:7577-7763`), transcript/history pages (`:7763-7845`), process and extension activity (`:7845-7930`, `:3209-3411`), attention; `projection`, `history`, `process-activity*`, `session-attention-store`, `extension-run-projection` | `ProjectionOperations`: `snapshot`, `transcriptPage`, `history`, `processHistory`, `attention` |
| K8 `pi/` | every runtime `@earendil-works/*` import and every adaptation of Pi internals (§4) | `PiServices` |

### 2.1 Hooks (each replaces a named reach-in)

A policy hook has **one implementer**; registering a second fails at startup. The two
lifecycle observer hooks take an ordered list in composition order, because four owners
observe session removal today (`gateway-main.ts:275-281`, `runtime-registry.ts:1449-1450`,
`:3853-3854`). Kernel-internal consumers (attention, archive, drain) stay direct calls.
Each hook runs at today's call site with today's sync/async shape and failure rule.

| Hook | Shape | Replaces (call site today) | Implementer | Failure rule (unchanged) |
|---|---|---|---|---|
| `sessionProfile` | sync `(sessionId, cwd) → profile name or undefined` | `homeProfile` read in `isHomeProfile` (`runtime-slot.ts:2199-2205`; dep `:607`) | Home | throws → runtime creation fails |
| `profiles` | named `SessionProfile` (below) | the `home ?` branches of `runtimeFactory` (`:2224-2227`, `:2267`, `:2327-2333`, `:2378-2392`, `:2474`, `:2510-2512`, `:2516`) | Home | — |
| `requestPolicy` | `{wrapStream, wrapTransformContext, wrapPrepareRequest}` per profile | `homeRequestPolicy` (`:2510`, wrapping order `:2551-2568`) | Home | guard stays innermost on stream, outermost on context/prepare |
| `inputAdmission` | async, inside the lane, before SDK admission; may return a trigger | `homeInboxAdmission` (`:8833-8858`), `homeInboxRelease` (`:8274`), `homeInboxSettlement` (`:4111`), `admitHomeWake` (`:8230-8320`) | Home | rejection fails the prompt |
| `appendGuard` | sync, around every canonical append | `installCanonicalWriteGuard` (`:1012-1033`), `homeChapterAdmission` (`:11082-11101`), `homeMemory.entriesCommitted` (`:7173`) | Home | throw refuses the append; observer is queued in a microtask |
| `runSettled` | `{quiescent, idle}` | `homeQuiescent` (`:4487`), `homeIdle` (`:8322`), chapter hooks (`:462-471`) | Home | awaited / fire-and-forget as today |
| `runTerminal` | async, best-effort | `notifyAgentTerminal` (`:3752-3779`, skipped for task workers) | notifications | caught → `session.diagnostic terminal-notification-failed` |
| `interactionRequired` | detached | `notifications.userInputRequired` (`:1058-1074`) | notifications | as today |
| `toolResultProjection` | `(tool, details) → display projection`, plus a browser-result observer | `admitToolDisplayProjection` (`sessions/projection.ts:28`), `refreshDisplayReferences` (`runtime-slot.ts:2134-2172`), browser result observer (`extensions/owner-attribution.ts:17-18`) | display | as today |
| `sessionRemoval` (observers) | async, before delete/rekey; may refuse | registry `beforeSessionDelete/beforeSessionRekey` (`runtime-registry.ts:682-683`) | automations | rejection refuses the delete/rekey |
| `sessionRetired` (observers) | sync | `browserLiveViews.retireSession` (`runtime-slot.ts:2775`), `sessionRekeyed/sessionClosed` (`runtime-registry.ts:681`, `:684`), search invalidator (`:1449`, `:1466`, `:3853`) | display, transport, session-search | each caught as today |
| `modelUsed` | sync, off the critical path | `noteModelUsed` (`runtime-slot.ts:4662`) | providers | ignored |

```ts
interface SessionProfile {             // today: the "home" literal and its branches
  modules: readonly string[];          // curated extension list (HOME_MODULE_NAMES + tron-home*)
  resources: ProfileResourceOptions;   // noExtensions, noContextFiles, skills/system-prompt overrides
  tools?: readonly string[];           // executable ceiling (HOME_TOOL_NAMES)
  modelRuntime: "gateway" | "session"; // Home borrows the Gateway runtime (runtime-slot.ts:2225)
  compaction: "policy" | "disabled";
  delegation: "managed" | "tasks-only";// Home never loads managed pi-subagents (:2327)
  requestPolicy?: (sessionId: string) => RequestPolicy | undefined;
  model?: { recorded(sessionId: string): ModelRef | undefined; changed(sessionId: string, m: ModelRef): Promise<void> };
}
```

The other Home dependencies leave the kernel without a hook: `homeTask`, `homeDelegate`,
`homeTaskSettings`, `homeMemoryTools`, `sessionRead`, `sessionSearch`, `homeWebTransport`
and `homeProfileChanges` are closed over by Home's own extension (§3); `homeChapterState`
folds into `appendGuard`; `validateTaskMarker` and `homeTaskDiagnostic` go to K5;
`homeModel`/`homeModelChanged`/`homeModelRuntime` become the profile's `model` and
`modelRuntime` (`runtime-slot.ts:2224-2227`, `:2416-2422`, `:2507`, `:9886`).

## 3. Module host contract and descriptor

The descriptor generalizes today's `TronModule` (`extensions/tron-modules.ts:81-96`).
The decisive change: **a module's own services are created at `start` and closed over**,
so the per-session context carries only kernel facts. `TronModuleHost`'s service fields
(knowledge, swiftApps, notifications, scheduleToolOperations, homeMemoryTools,
homeDelegate, …) disappear from the kernel.

```ts
interface ModuleDescriptor {
  name: string;                          // = Pi inline extension name, "<inline:name>" source (B2)
  purpose: string; tools: readonly string[]; commands: readonly string[]; // modules.list row
  dependsOn?: readonly string[];         // other modules' contracts; mirrors the manifest
  start(host: GatewayHost): ModuleInstance | Promise<ModuleInstance>;     // once, in list order
}
interface ModuleInstance {
  extension?: (session: SessionContext) => ExtensionFactory | undefined;  // per runtime
  hooks?: Partial<KernelHooks>;          // §2.1, one implementer each
  profiles?: Record<string, SessionProfile>;
  rpc?: Record<string, RpcHandler>;      // method → handler; transport routes (decision D5)
  capabilities?: readonly string[];      // handshake capability strings
  contract?: unknown;                    // typed via the module's contract.ts
  stop?(): Promise<void>;                // reverse list order at shutdown
}
interface GatewayHost {                  // kernel operations + platform, nothing module-specific
  tronHome: string; agentDir: string; machineId?: string;
  sessions: SessionOperations; runs: RunOperations; delegation: DelegationOperations;
  projection: ProjectionOperations; resources: ResourceOperations; settings: SettingsAccess;
  pi: PiServices; modules: { contract<T>(name: string): T }; log: GatewayLogger;
}
interface SessionContext {               // what TronModuleHost keeps (tron-modules.ts:33-41)
  sessionId(): string; cwd(): string; profile: string; title(): string; presented(): boolean;
  joinTerminalReceiptWrites(): Promise<void>; settings(): SettingsToolAccess | undefined;
}
```

**Composition.** `main/modules.ts` is one ordered array, one line per module. The array
order is the Pi extension registration order, which is model-visible (tool order and
prompt sections, B2), so it reproduces today's order exactly: managed-subagent factories,
Pi built-ins (`extensions/pi-builtins.ts`), `TRON_MODULES` in definition order, then
`tron-model-queue` and `tron-home-task-worker` (`runtime-slot.ts:2333-2369`). Kernel-owned
extensions (`tron-invocation-settlement`, `tron-compaction-policy`, task worker) appear in
the array by name at those positions. `start` runs in array order, which replaces today's
late binding (`setKnowledgeService`, `setSessionSearchService`, `setSettings`:
`runtime-registry.ts:898-920`); a module needing a later module's contract reads it lazily.
`modules.list` keeps reporting exactly the `TRON_MODULES` rows (`tron-modules.ts:306-313`).

## 4. K8 Pi seam

**Rule.** Outside `kernel/pi/`, production code imports nothing from `@earendil-works/*`
(decision D2 covers type-only imports). Tests and `test-support` stay exempt: the faux
provider is Pi's (92 test files import Pi). `kernel/pi` is the plan's one sanctioned
re-export seam (§4.2.5), and its export list is the patch-removal checklist.

**Runtime imports at base** (production, excluding tests):

| Package | Runtime names (files) |
|---|---|
| `pi-coding-agent` | session: `createAgentSessionRuntime`, `createAgentSessionServices`, `createAgentSessionFromServices`, `AgentSessionRuntime` (runtime-slot); `SessionManager` (3), `parseSessionEntries`; config: `SettingsManager` (11, incl. `client/work-owner-status.ts:21`), `ModelRuntime` (3, incl. `gateway-main.ts:181`), `DefaultResourceLoader` (2), `DefaultPackageManager` (3), `ProjectTrustStore`, `hasTrustRequiringProjectResources`, `CredentialSynchronizationError`; tools: `create{Bash,Edit,Find,Grep,Ls,PowerShell,Read,Write}ToolDefinition` (`admin/tool-catalog.ts`, `sessions/direct-bash-process-owner.ts`), `getShellConfig`; built-ins: `createCodemodeExtension`, `createMcpExtension`, `createToolSearchExtension` (`extensions/pi-builtins.ts`); misc: `estimateTokens` (3), `stripFrontmatter`, `Theme`/`initTheme` |
| `pi-ai` | `Type` (17 tool-schema files), `StringEnum` (3), `clampThinkingLevel` (5), `getSupportedThinkingLevels` (3), `getCurrentSystemMessage`, `getCurrentTools`, `isRetryableAssistantError`, `lazyStream`, `normalizeContext` |
| `pi-tui` | `Box`, `Text`, `TruncatedText`, `truncateToWidth`, `visibleWidth`, `CURSOR_MARKER`, `KeybindingsManager`, `TUI_KEYBINDINGS`, `TuiMainScreen`, `setCapabilities` (`extensions/host/*`, ask-user) |
| `pi-agent-core` | types only (`AgentMessage`, `StreamFn`, `AgentTurnDecision`, …) |

`version.ts:32-38` reads the four package versions; it moves into `kernel/pi` too.

**Patched APIs Tron depends on** (`packages/gateway/pi-coding-agent-patch.json`
`removeWhen`; patch header items 1-5):

| Patch item | Tron call sites |
|---|---|
| 1 `projectDir` | `createAgentSessionServices({projectDir})` `runtime-slot.ts:2373`; `SettingsManager.create(projectDir, …)` `:2330`, `admin/trust-service.ts:83`, `admin/package-service.ts:107`, `admin/session-free-extensions.ts:41`; `DefaultPackageManager({projectDir})` `admin/package-service.ts:115`; `hasTrustRequiringProjectResources(cwd, projectDir)` `admin/trust-service.ts:81`; `session.projectDir` `runtime-slot.ts:1278` |
| 2 image-only queue dequeue, 3 queued image normalization | `session.steer/followUp(text, images)` `runtime-slot.ts:9746-9747` |
| 4 idle `systemPrompt` keeps extension sections | `session.systemPrompt` `runtime-slot.ts:8826`, `:8844`, `:10383`, `:10406` |
| 5 revocable run start | throwing from `preflightResult` `runtime-slot.ts:8871-8888` |

**Pi internals Tron adapts** (named adapters in `kernel/pi`, wrapping order unchanged):
`SessionManager._appendEntry` replaced by the canonical write guard (`runtime-slot.ts:1012-1033`,
private); `ModelRuntime.streamSimple` rebound per request (`:2235-2252`); `agent.streamFunction`,
`convertToLlm`, `prepareRequest`, `transformContext`, `finishTurn` reassigned (`:2517-2603`);
`runtime.setBeforeSessionInvalidate/setRebindSession` (`:2772-2778`). The `pi-subagents` fork
(`packages/gateway/pi-subagents-pin.json`) stays an installed package behind `delegation/`;
its reviewed provider contract is pinned at `home/home-task-worker-extension.ts:3`.

## 5. Home: generic delegation versus Home policy

Automations already use the worker-session boundary (`automations/automation-executor.ts`
via `sessions/owned-session-dispatch.ts`), so that boundary is generic, not Home's.

| Goes to `kernel/delegation` (generic) | Stays in `modules/home` (policy) |
|---|---|
| `owned-session-dispatch.ts` (create/resume/lease/acknowledge/deadline) | `home-owner.ts` (designation, chapters, publication), `home-chapter-*`, `home-session-recovery.ts` |
| Registry worker paths: `create(cwd, profile, report)` `runtime-registry.ts:3016`, `resumeTaskWorker` `:2120`, `acquireOwnedSessionLease`/recovery evidence/marker clear `:2128-2169`, task-worker evidence `:4478-4646` | `home-task-dispatcher.ts` (what to delegate, when, to whom), `home-task-authorization.ts`, `home-task-worker-choice.ts`, `home-task-spend.ts`, `home-task-store.ts` (task ledger; D4) |
| Slot worker role: `bindTaskWorker` `runtime-slot.ts:2980`, turn-boundary end/report reminder `:2570-2603`, worker tools `:2477-2499`, steer/stop/interrupt/cancel `:8183-8230`, `settleTaskSubagents` `:8034` | `home-wake-inbox.ts` (when results wake Home; D4), `home-request-policy.ts`, `home-memory*.ts`, `home-profile.ts`, `home-research-tools.ts`, `tron-home-extension.ts` |
| Report and check-in: `home-task-report.ts`, `home-task-checkin.ts`, `home-task-worker-extension.ts`, `home-task-subagents.ts` (settlement fact) | Profile `home` (§2.1), hooks `sessionProfile`, `requestPolicy`, `inputAdmission`, `appendGuard`, `runSettled` |
| Subagent runs: `managed-subagents.ts`, `child-session-admission.ts`, `delegated-provider.ts`, `subagent-catalog.ts`, artifact/activity tracking `runtime-slot.ts:5560-7100`, run control `:7927-8116` | `HomeOwner` construction moves from `runtime-registry.ts:796-866` into Home's `start`, taking `SessionOperations` + `DelegationOperations` instead of `RuntimeRegistry` |

Persisted names do not change: custom entry types (`HOME_TASK_MARKER`, `HOME_TASK_REPORT`,
`tron.home-task-report-reminder.v1`), receipt types and store paths keep their values even
where the constant moves (B3; renaming is a migration). Model-visible text (report tool,
reminder `runtime-slot.ts:2588-2589`, worker prompt in `home-task-worker-extension.ts:55`)
moves byte-identical (B2). Generic files drop the `home` prefix only in `move` commits.

## 6. Pilot module: **apps** (recommended)

| | apps | notifications |
|---|---|---|
| Production files / lines | 2 files, 518 lines (`apps/`) | 4 files, 1,538 lines (`notifications/`) |
| Kernel hooks exercised | none | `runTerminal`, `interactionRequired` |
| Consumers outside the module | registry constructor (`runtime-registry.ts:767`, `:896`, `:1862`), slot host (`runtime-slot.ts:2292`), `tron-modules.ts:171-178`, 4 RPCs + capability (`transport/gateway-service.ts:89`, `:627`, `:801-818`) | slot (3 sites), Home, automations, device revoke, Mac replace, 6 RPCs (`transport/gateway-service.ts:1124-1215`), `gateway-main.ts:160` |
| Locks today | `apps.store` lock; `swift_app` in the `run-prompt-stream` tool list and prompt hash; wire lock | `notifications.store` lock only; no golden records a terminal or interaction push |

Apps exercises exactly what the pilot must measure (descriptor, `start`-owned store, tool,
RPC routing, capability, one module contract: the internal workspace, today an L3 module
the registry constructs at `runtime-registry.ts:765`, ≤ 1 composition line) on code that is
already locked, without also testing a hook. Notifications becomes the first hook consumer
in E5, after its push lock (E0b) exists.

## 7. Extraction order and guarding locks

Every kernel slice is risk-class (review) and runs `scripts/tron verify --changed`, which
selects all locks for kernel paths. "Locks" names the goldens that must stay unchanged.

| Step | Change | Guarding locks (Phase 0 unless marked new) |
|---|---|---|
| E0 lock slices | New scenario locks: (a) Home activation, wake and task dispatch (provider requests with Home prompt hash and tools, canonical JSONL, frames); (b) terminal and input-required pushes (harness `notifications`, `test-support/gateway-lock-harness.ts:203-210`); (c) automation owned run; (d) cold load/eviction and administrative drain snapshot | known-bad per lock |
| E1 pilot | `modules/apps` with descriptor; registry stops constructing `SwiftAppStore` | `apps.store`, `run-prompt-stream`, `protocol.wire`, `delegation-subagent` (tool text) |
| E2 `kernel/pi` | Seam module; value imports rerouted file by file (`move`), adapters for the internals in §4; layer rule added (D2) | `sdk-behavior-trace`, Pi persisted-state corpus, all `run-*`, `delegation-subagent`, `npm run test:pi-sdk-rollback` |
| E3 `kernel/host` | `ModuleDescriptor`/`SessionContext`; `TRON_MODULES` entries become descriptors in place; `TronModuleHost` shrinks to `SessionContext` | `run-prompt-stream` (tool order, prompt hash), `run-extension-ui`, `admin-settings-change`, `protocol.wire` (`modules.list`), E0a |
| E4 `kernel/projection` | snapshot, pages, process/extension activity out of the slot; `toolResultProjection` hook for display | `transport-reconnect-snapshot`, all `run-*` events, `session-attention`, `delegation-subagent` process activity |
| E5 `kernel/run` | admission, queue, abort, compaction, receipts, request pipeline; hooks `requestPolicy`, `inputAdmission`, `appendGuard`, `runSettled`, `runTerminal`, `interactionRequired` replace the Home and notification reach-ins | all `run-*`, `run-markers`, `run.store`, `command-receipts`, E0a, E0b, E0d |
| E6 `kernel/delegation` | §5 left column; Home and automations take `DelegationOperations` | `delegation-subagent`, `home-task-store`, E0a, E0c, subagent parity |
| E7 `kernel/session` | catalog, acquisition, heap, eviction, archive/delete, drain out of the registry; `HomeOwner` built by Home's `start` | `session-catalog.store`, `session-archive`, `session-attention`, `home.store`, Pi corpus, E0a, E0d |
| E8 (Phase 3) `modules/home` | Home files move under its descriptor; Phase 2 ends with Home on the ports in place | all of the above (`verify --all`) |

Order rationale: the strongest-locked, least-coupled seams first (E1-E3 change wiring, not
behavior); then read-only projection (E4); then run, the behavior core (E5); delegation
depends on run ownership (E6); the registry depends on all of them (E7). E2 precedes E3-E8
so moved files are not re-touched for imports (D1). Each step is several slices of one owner
and one change type (`move` before `simplify`), ≤ ~800 changed non-moved lines. K4 and K6 are
file moves (`admin/settings-*`, `admin/trust-service.ts`, `sessions/agent-instructions.ts`,
`sessions/resource-*.ts`) that may run in parallel with E3-E7 on disjoint files, guarded by
`admin-settings-change`, `settings-approvals`, `admin.store` and `run-prompt-stream`.

## 8. Invariants carried through

- **B1/B2:** extension order, names, tool schemas, prompt sections and model-visible text are
  untouched; `run-prompt-stream` and `delegation-subagent` record tools and prompt hashes.
- **B3:** no persisted name, path or format changes in Phase 2 (§5).
- **B4:** no wire change; RPC routing moves handlers, not shapes (`protocol.wire`).
- **B5:** one live runtime per session (K1 keeps the slots map and `installCanonicalWriteGuard`'s
  single-owner check); the lock order registry mutex → session lane → attention lane →
  Home `recordMutex` (`runtime-registry.ts:527-529`, `:548-558`) is kept when Home leaves.
- **B6:** no credential, trust or exposure path changes; Stable stays maintainer-only.

## 9. Risks

| Risk | Mitigation |
|---|---|
| A hook adds an `await` or reorders work (e.g. `homeChapterAdmission` must stay synchronous after admission awaits, `runtime-slot.ts:597-598`) | Hook table fixes sync/async per call site; reviewer checks every hook call against base |
| Request-pipeline wrapping order changes (guard innermost, `runtime-slot.ts:2551-2557`) | One adapter owns the composition; E0a/E5 locks record provider requests |
| Late-bound services become start-order bugs | `start` in array order; lazy contract reads; E3 locks |
| Home extraction breaks lock ordering or publication gating (`homePublicationUncertain`, `runtime-registry.ts:574`) | Move with the lane code; E0a + `home.store`; no simplification in the same commit |
| Lock gaps for Home, pushes, automations, drain | E0 lands first; no slice touches an unlocked behavior |
| Pi upgrade (#1025) during extraction | Land it before E2 or after E2 only (plan §11) |
| Hot-owner churn conflicts with bug fixes (`runtime-slot.ts` 140 commits/30 days at baseline) | Small slices, announcements in #1395/#1398, fast landing |
| Kernel contract tests drift into unit tests | Each names one port and invariant and uses the real kernel with the faux model |

## 10. Open decisions (maintainer)

- **D1** Pi seam timing: E2 before extraction (recommended) or last, as plan step 4 lists.
- **D2** Seam rule scope: all `@earendil-works/*` imports including types (recommended) or
  runtime values only.
- **D3** Pilot: apps (recommended), notifications, or both in sequence.
- **D4** Task ledger and wake inbox: Home module (recommended) or `kernel/delegation`.
- **D5** Pilot RPC routing: descriptor `rpc` routed by `GatewayService` before its switch
  (recommended) or apps RPCs stay in the switch until Phase 3.
- **D6** Hook cardinality: single-implementer policy hooks plus ordered lifecycle observer
  lists (recommended), or ordered lists everywhere.
