# K-0: Gateway kernel design

Phase 2 step 1 of [the restructure plan](plan.md#phase-2-gateway-kernel-m2-highest-risk-review-per-84)
(issue #1524). It fixes the kernel ports, the module host contract, the Pi seam and the
extraction order. **Approved by the maintainer on 2026-10-20 with decisions D1–D7 (§10).**
References are `file:line` at base `096b35f8a`, relative to the Gateway's `src/`. Invariants
B1–B6 (plan §4.1) bind every step: each port sits at a call site that exists today, with the
same ordering, sync/async shape and failure handling.

## 1. Starting point

| Fact | Evidence |
|---|---|
| `RuntimeSlot` (11,165 lines) builds the Pi runtime, module host, Home profile, request pipeline and task-worker role in one closure | `kernel/run/runtime-slot.ts:2212-2608` (`runtimeFactory`) |
| Slot dependencies: 60 fields (18 `home*`, plus `validateTaskMarker`); hooks: 10 (3 Home); 14 more branches on `liveProfile()` | `kernel/run/runtime-slot.ts:522-635`, `:455-486`, `:1290-10431` |
| The registry (5,030 lines) is also a composition root: it builds Swift apps, display, workspace, model queues and `HomeOwner`, and passes itself to Home | `kernel/session/runtime-registry.ts:762-866` (`taskSessions: this` `:865`) |
| Home and automations reach the concrete registry | `modules/home/home-owner.ts:162`, `modules/home/home-task-dispatcher.ts:217`, `modules/home/home-session-read.ts:29`, `kernel/delegation/delegation-operations.ts:20` |
| The module host is one interface carrying every module's service | `extensions/tron-modules.ts:32-80` (`TronModuleHost`), lists `:102-224`, `:236-301` |
| Upward edges in the layer ratchet | `gateway/run` → 13 L3/L4 modules, `gateway/extensions` → 11, `gateway/projection` → display (`packages/gateway/layer-baseline.json`) |
| Pi: 50 production files import runtime values (39 more types only), plus 4 `import.meta.resolve` sites | §4 |

## 2. Kernel primitives and ports

`kernel/{session,run,host,resources,delegation,settings,projection,pi}` (plan §5.2) expose
**operations** (called by transport and modules) and **hooks** (implemented by modules). The
kernel imports no module. Slot↔registry callbacks (`broadcast`, `summaryChanged`, `changed`,
`settled`, `rekey`, `closed`: `runtime-slot.ts:455-460`, `:477-484`) become calls inside the kernel.

| Primitive | Owns (moves from) | Operations |
|---|---|---|
| K1 `session/` | slots map, `serializeSessionMutation` (`runtime-registry.ts:531`), catalog and page sources (`:1896-2813`), acquire/cold load/heap admission (`:3334-3659`, `:3990-4242`), eviction (`:4303-4457`), archive/delete (`:3724-3990`), drain (`:4661-4888`), fork/export, attention and archive projections; `session-catalog`, `catalog-*`, `session-archive-store`, `session-export`, `fork-boundary`, `blob-store` | `SessionOperations`: `acquire`, `create(cwd, profile, owner?)`, `fork`, `archive`, `delete`, `export`, `readCut`, `subscribe`, `presented`, `serialize(sessionId, fn)` |
| K2 `run/` | prompt admission (`runtime-slot.ts:8344-9289`), queue/steer/follow-up (`:9538-9866`), abort (`:9323-9525`), compaction (`:9949-10108`), receipts and ownership writes (`:3911-4538`), request pipeline (`:2517-2568`), drain work tokens (`:1630-1877`), direct bash; `invocation-receipts`, `run-markers`, `bounded-tool-cancellation`, `context-delivery-receipts`, `gateway-work-registry`, `direct-bash-process-owner`, `runtime/compaction-policy` | `RunOperations`: `prompt`, `steer`, `abort`, `clearQueue`, `replaceQueue`, `compact`, `setModel/Thinking/Tools`, `executeBash`, `admitOwned(prompt, ownership)` |
| K3 `host/` | module registry, descriptors, per-runtime extension list, hook dispatch, semantic UI broker (`sessions/semantic-ui-broker.ts`), remote extension host (`extensions/host/*`), extension activity/history and notification receipts, owner attribution, `extension-artifact-discovery` | `ModuleHost` (§3) |
| K4 `resources/` | agent instructions, resource invocation/distribution, trust (`admin/trust-service.ts`), packages, `admin/hook-resources.ts` | `ResourceOperations` |
| K5 `delegation/` | worker sessions, task-worker role, worker→task index, subagent runs, child-session admission, cross-session steer/stop/interrupt/report (§5) | `DelegationOperations` (§5) |
| K6 `settings/` | `admin/settings-*`: model, resolver, the one change path, approvals | `SettingsAccess` (late-bound today: `runtime-slot.ts:560`, `runtime-registry.ts:917`) |
| K7 `projection/` | snapshot (`runtime-slot.ts:7577-7763`), pages (`:7763-7845`), process/extension activity (`:7845-7930`, `:3209-3411`); `projection`, `history`, `process-activity*`, `session-attention-store`, `extension-run-projection` | `ProjectionOperations`: `snapshot`, `transcriptPage`, `history`, `processHistory`, `attention` |
| K8 `pi/` | every `@earendil-works/*` import and resolution, every adaptation of Pi internals (§4) | `PiServices` |

### 2.1 Hooks

K3 owns hook dispatch from E1 on. Hooks are **resolved at call time**, never captured when a
slot is built (registry closures are captured today, `runtime-registry.ts:1266-1320`). A
policy hook has one implementer (a second fails at startup); lifecycle observers are ordered
lists in composition order, because four owners observe session removal today
(`gateway-main.ts:275-281`, `runtime-registry.ts:1449-1450`, `:3853-3854`).

| Hook | Shape | Replaces (call site today) | Implementer |
|---|---|---|---|
| `extensionAdmission` | sync loader admission with live browser observer and actual managed producer admission | product reservation policy supplied at `extensionsOverride`; generic registration maps and late owner lookup stay in K3 | core |
| `profileDecision` | sync `(sessionId, cwd) → name \| "unrecorded"`; `unrecorded` uses the creation profile given to K1 `create`, once | `homeProfile` + `explicitHomeSessionId` (`runtime-slot.ts:607`, `:997`, `:2199-2205`, cleared `:2273`) | Home |
| `requestPolicy` | per runtime: `admit`, `deliveryHeadroom`, `settle`, `cancel`, `transferOperation`, `contextEvidence`, `wrapStream` (innermost), `wrapTransformContext`, `wrapPrepareRequest` (outermost) | `HomeRequestPolicy` (`modules/home/home-request-policy.ts:313-521`); calls `runtime-slot.ts:8826`, `:8844`, `:9390`, settle ×4, transfer ×2, wraps `:2551-2568` | Home |
| `inputAdmission` | async in the lane before SDK admission; may return a wake trigger; `release`, `settle` | `homeInboxAdmission` (`:8833-8858`), `homeInboxRelease` (`:8274`), `homeInboxSettlement` (`:4111`), `admitHomeWake` (`:8230-8320`) | Home |
| `appendGuard` | sync around each canonical append (throw refuses); `committed` observer queued in a microtask; `admission(metrics)` sync after admission awaits | write guard body (`:1022-1029`), `homeChapterState`, `homeChapterAdmission` (`:11063-11117`), `homeMemory.entriesCommitted` (`:7173`) | Home |
| `runSettled` | `quiescent` (awaited), `idle` (sync) | `homeQuiescent` (`:4487`), `homeIdle` (`:8322`) | Home |
| `runTerminal` | async, best-effort; skipped for task workers | `notifyAgentTerminal` (`:3752-3779`); failure → `session.diagnostic terminal-notification-failed` | notifications |
| `interactionRequired` | detached; presence sampled at admission | `userInputRequired` (`:1058-1074`) | notifications |
| `toolResultProjection` | display projection + browser result observer | `admitToolDisplayProjection` (`display/display-contract.ts:127`; calls `runtime-slot.ts:2145`, `sessions/projection.ts:1368`), `kernel/host/extension-registration.ts` | display |
| `modelRuntimeInstalled` | sync, owner runtimes only | `openAIModelEligibility.attachRuntime` (`runtime-slot.ts:2243`), Kimi/Jev pricing (`runtime-registry.ts:1827`) | providers |
| `modelUsed` | sync, off the critical path | `noteModelUsed` (`runtime-slot.ts:4662`) | providers |
| `sessionRemoval` (observers) | async before delete/rekey; rejection refuses | `beforeSessionDelete/Rekey` (`runtime-registry.ts:682-683`) | automations |
| `sessionLineage` | sync: `state(sessionId)` (sealed, materializing reserved successor, lineage id, ordinal, attempt, path), `assertWritable(sessionId)`, `publicationUncertain()`; async read-only `openRefusal(sessionId, path)` before SDK open | `HomeOwner.chapterStateFor`/`isHomeChapter` reads in acquire, catalog, attention, retain, cold scan and the slot; `assertChapterWritable`; the registry's `homePublicationUncertain` gate | Home |
| `sessionRetired` (observers) | sync, each caught | `retireSession` (`runtime-slot.ts:2775`, `:10879`), `sessionRekeyed/Closed` (`runtime-registry.ts:681`, `:684`), search invalidator (`:1449`, `:1466`, `:3853`) | display, transport, search |

### 2.2 Session profiles

A profile replaces the `"home"` literal: `runtimeFactory`'s `home ?` branches (`:2224-2227`,
`:2267`, `:2327-2333`, `:2378-2392`, `:2414`, `:2416-2454`, `:2474`, `:2510-2516`) and the 14
`liveProfile()` sites. The live runtime handle carries its profile (today the
`runtimeProfiles` WeakMap, `:985`, `:2509`) with its request policy and compaction/context
policies (today `:673-679`).

```ts
interface SessionProfile {
  extensions: "ordinary" | readonly string[];  // curated list: HOME_MODULE_NAMES, tron-home, tron-home-research
  resources: ProfileResourceOptions;           // noExtensions, noContextFiles, skill/system-prompt overrides (:2378-2392)
  projectTrust: "inspect" | "never";           // :2267
  projectSettings: boolean; managedSubagents: boolean; directBash: boolean; // :2327-2330, :2414
  tools?: readonly string[];                   // executable ceiling, HOME_TOOL_NAMES (:2474)
  modelRuntime: "gateway" | "session";         // :2224-2227
  model?: { recorded(id): ModelRef | undefined; changed(id, m): Promise<void>; physicalOnly: true }; // :2416, :2507, :9876-9886
  launchDefaults: "settings-profile-layer" | "none";  // :2449-2454, :2496-2504
  compaction: "policy" | "disabled";           // :2516, :9953
  settingsActor: "home" | "agent";             // :1322-1326 ("worker" stays K5's)
  chapter: boolean;                            // appendGuard, isHomeChapter (:1290), reload/replace (:2765, :2840, :2990)
  replaceableByAutomation: boolean;            // :2702
  subagentCatalog: boolean; profileChanges: boolean; // :10431, :1475
  requestPolicy?(sessionId): RequestPolicy | undefined;
}
```

`settings.model.resolve` keeps receiving the profile name as its `home` input (`:2451`): the
Profile settings layer is K6 behavior, not a reach-in.

### 2.3 Destinations of the remaining slot inputs

| Today (`runtime-slot.ts`) | Destination |
|---|---|
| `agentDir`, `blobs`, `exports`, `archivedAt`, `beforeRunAdmission`, `sessionAudience`, `isSessionPresented`, `resolveForkBoundary`, `markers`, `workRegistry`, `extensionActivityRecency`, `processActivityRecency` | kernel-internal (K1/K2/K7) |
| `createModelRuntime`, `homeModelRuntime`, `openAIModelEligibility` | K8 `PiServices.modelRuntime(profile)` + `modelRuntimeInstalled` |
| `runtimeDisposalTimedOut`, `persistenceDiagnostic`, `compactionDiagnostic`, `stopSteeringDiagnostic`, `manualCompactionAdopted`, `codemodeDiagnostic`, `extensionArtifactWarning`, `resources` | one `KernelDiagnostics` sink and the platform `ResourceRecorder`, given by composition |
| `displayArtifacts`, `browserLiveViews`, `knowledge`, `connections`, `swiftApps`, `notifications`, `scheduleToolOperations`, `sessionSearch`, `sessionRead`, `homeWebTransport`, `workspace`, `machineId`, `mcpAuth` | closed over by the owning module's extension (§3); `mcpAuth` by the module implementing K3's `McpAuthPort` |
| `jev` (built per runtime, `:2293`) | `tron-core` builds it from `SessionContext.modelRuntime` |
| `managedSubagents`, `delegatedArtifactRoot`, `validateTaskMarker`, `homeTaskDiagnostic`, `ownedTurns.waitingTask`, `homeTaskSettings` | K5 |
| `modelQueue` (`tron-model-queue`, `:2349-2360`) | providers module extension using `SessionContext.delegation` |
| `homeTask`, `homeDelegate`, `homeMemoryTools`, `homeProfileChanges` | Home's extension closures |
| `homeModel`, `homeModelChanged`, `homeChapterState`, `homeMaterializationAuthority` (`:971`), `homeLimitStop` (`:972`), `homeWakeTrigger` (`:974`), hooks `homeChapterRefused/LimitStopped` (`:462-471`) | Home state behind `profileDecision`, `appendGuard`, `inputAdmission`; Home reports its own diagnostics |
| hook `assistantResponseCompleted` (`:471`; registry `:1307-1318`) | K7 attention, reading K5 `isTaskWorker` instead of `homeTaskWorkers` |

## 3. Module host contract and descriptor

The descriptor generalizes `TronModule` (`extensions/tron-modules.ts:81-96`). A module's
services are created in `start` and closed over; per-runtime facts come from `SessionContext`.

```ts
interface ModuleDescriptor<C = void> {
  name: string;                     // = Pi inline extension name, "<inline:name>" source (B2)
  purpose: string; tools: readonly string[]; commands: readonly string[]; // modules.list row
  start(host: GatewayHost): ModuleInstance<C> | Promise<ModuleInstance<C>>; // once, list order
}
interface ModuleInstance<C> {
  extension?(session: SessionContext): ExtensionFactory | undefined;  // per runtime
  hooks?: Partial<KernelHooks>; profiles?: Record<string, SessionProfile>;
  rpc?: Record<string, RpcHandler>; capabilities?: readonly string[]; // decision D5
  contract?: C;                     // typed; peers import the module's contract.ts type
  stop?(): Promise<void>;           // reverse order at shutdown
}
interface GatewayHost {             // kernel operations + platform; nothing module-specific
  tronHome: string; agentDir: string; machineId?: string; log: GatewayLogger;
  sessions: SessionOperations; runs: RunOperations; delegation: DelegationOperations;
  projection: ProjectionOperations; resources: ResourceOperations; settings: SettingsAccess;
  pi: PiServices; contract<C>(module: ModuleDescriptor<C>): C;  // declared dependsOn only
}
interface SessionContext {          // per runtime; TronModuleHost minus services
  sessionId(): string; cwd(): string; profile: SessionProfile; title(): string; presented(): boolean;
  modelRuntime: ModelRuntime;                                   // :2228 (jev, Home model)
  contextPolicy(): ContextWindowPolicy | undefined;             // tron-modules.ts:40
  compaction: { policy(); stopped(event): boolean; changed(): void }; // tron-modules.ts:41-43
  joinTerminalReceiptWrites(): Promise<void>; settings(): SettingsToolAccess | undefined;
  delegation: { taskWorker?: TaskWorkerHandle; queueSelection(role); ownsSubagentRun(id): boolean;
    ownsSupervisorRequest(id): boolean; providerToolVersion(tool): string | undefined }; // :2349-2368
}
```

**Composition.** `main/modules.ts` is one ordered array, one line per module; `start` runs in
order, replacing late binding (`setKnowledgeService`, `setSessionSearchService`, `setSettings`:
`runtime-registry.ts:898-920`). Pi extension registration order is model-visible (tool order,
prompt sections: B2) and is reproduced exactly per profile:
- ordinary (`runtime-slot.ts:2333-2369`): managed-subagent factories, Pi built-ins
  (`kernel/host/pi-builtins.ts`), `TRON_MODULES` in definition order, `tron-model-queue`,
  `tron-home-task-worker`;
- Home (`extensions/tron-modules.ts:288-300`): the kept modules in `TRON_MODULES` order, then
  `tron-home`, then `tron-home-research`; no settlement, built-ins, managed or queue extensions.

Kernel-owned extensions (`tron-invocation-settlement`, `tron-compaction-policy`,
`tron-context-window`, task worker) hold named positions in the array. `modules.list` keeps
reporting exactly the `TRON_MODULES` rows (`tron-modules.ts:306-313`).

## 4. K8 Pi seam

**Rule.** Outside `kernel/pi/`, production code neither imports nor resolves
`@earendil-works/*` (D2: type-only imports included). Tests and `test-support` stay exempt: the
faux provider is Pi's. `kernel/pi` is the plan's one sanctioned re-export seam (§4.2.5); its
export list is the patch-removal checklist.

| Package | Runtime names at base (production) |
|---|---|
| `pi-coding-agent` | `createAgentSessionRuntime`, `createAgentSessionServices`, `createAgentSessionFromServices`, `AgentSessionRuntime` (runtime-slot); `SessionManager` (3 files), `parseSessionEntries`; `SettingsManager` (11, incl. `client/work-owner-status.ts:21`), `ModelRuntime` (3, incl. `gateway-main.ts:181`), `DefaultResourceLoader` (2), `DefaultPackageManager` (3), `ProjectTrustStore`, `hasTrustRequiringProjectResources`, `CredentialSynchronizationError`; `create{Bash,Edit,Find,Grep,Ls,PowerShell,Read,Write}ToolDefinition` (`admin/tool-catalog.ts`, `sessions/direct-bash-process-owner.ts`), `getShellConfig`; `createCodemodeExtension`, `createMcpExtension`, `createToolSearchExtension` (`kernel/host/pi-builtins.ts`); `estimateTokens` (3), `stripFrontmatter`, `Theme`, `initTheme` |
| `pi-ai` | `Type` (17 tool-schema files), `StringEnum` (3), `clampThinkingLevel` (5), `getSupportedThinkingLevels` (3), `getCurrentSystemMessage`, `getCurrentTools`, `isRetryableAssistantError`, `lazyStream`, `normalizeContext` |
| `pi-tui` | `Box`, `Text`, `TruncatedText`, `truncateToWidth`, `visibleWidth`, `CURSOR_MARKER`, `KeybindingsManager`, `TUI_KEYBINDINGS`, `TuiMainScreen`, `setCapabilities` (`extensions/host/*`, ask-user) |
| `pi-agent-core` | types only |
| resolution | `sessions/managed-subagents.ts:356-362` (host require, jiti aliases incl. `pi-ai/compat`, `/oauth`, `/providers/all`, `typebox`), `gateway-main.ts:856` (`bundle/cli.js` for MCP admin), `sessions/session-export.ts:145-156`, `sessions/delegated-provider.ts:49`; versions `version.ts:32-38` |

**Patched APIs** (`packages/gateway/pi-coding-agent-patch.json` `removeWhen`; patch items 1-5):

| Patch item | Tron call sites |
|---|---|
| 1 `projectDir` | `createAgentSessionServices({projectDir})` `runtime-slot.ts:2373`; `SettingsManager.create(projectDir, …)` `:2330`, `runtime/compaction-policy.ts:133`, `admin/trust-service.ts:83`, `admin/package-service.ts:107`, `admin/session-free-extensions.ts:41`; `DefaultPackageManager({projectDir})` `admin/package-service.ts:115`, `:172`; `hasTrustRequiringProjectResources(cwd, projectDir)` `admin/trust-service.ts:81`; `session.projectDir` `runtime-slot.ts:1278` |
| 2 image-only dequeue, 3 queued image normalization | `session.steer/followUp(text, images)` `runtime-slot.ts:9746-9747` |
| 4 idle `systemPrompt` keeps extension sections | `session.systemPrompt` `runtime-slot.ts:8826`, `:8844`, `:10383`, `:10406` |
| 5 revocable run start | throwing from `preflightResult` `runtime-slot.ts:8871-8888` |

**Pi internals adapted** (named adapters, order unchanged): `SessionManager._appendEntry`
guard (`runtime-slot.ts:1012-1033`, private); `ModelRuntime.streamSimple` rebound
(`:2235-2252`); `agent.streamFunction/convertToLlm/prepareRequest/transformContext/finishTurn`
(`:2517-2603`); `setBeforeSessionInvalidate/setRebindSession` (`:2772-2778`); the process-global
theme set at module load (`sessions/semantic-ui-broker.ts:61`), which becomes an explicit
`pi.initTheme()` call from composition. The `pi-subagents` fork
(`packages/gateway/pi-subagents-pin.json`) stays an installed package behind `delegation/`.

## 5. Home: generic delegation versus Home policy

Automations already use the worker-session boundary (`automations/automation-executor.ts` via
`kernel/delegation/delegation-operations.ts`), so it is generic. Plan §5.2 puts the "generic parts" of
`home-task-*` in K5; the line below is what is generic.

| `kernel/delegation` (generic) | `modules/home` (policy) |
|---|---|
| `delegation-operations.ts`: `createWorker`, `resumeWorker`, `acknowledge`, `subagentRunsSettled`, `armDeadline`, `enforceDeadline`; K5's `HomeTaskReportOwner` owns report admission and sealing | `home-owner.ts` (designation, chapters, publication; `homePublicationUncertain`, `runtime-registry.ts:574`, moves with it), `home-chapter-*`, `home-session-recovery.ts` |
| Registry worker paths: `create(cwd, profile, report)` `runtime-registry.ts:3016`; K5 owns resumed-worker lease/bind/failure release over the actual native lane/rebuild backend (no Registry resume wrapper); leases/evidence/markers `:2128-2169`, task-worker evidence `:4478-4646`, the actual attribution index now in `DelegationOperations` (first-registration-wins, not live role state; native attention/catalog reads and batch publication stay C1, wire `homeTaskId` unchanged) | `home-task-dispatcher.ts` (what to delegate, when, to whom), `home-task-authorization.ts`, `home-task-worker-choice.ts`, `home-task-spend.ts`, `home-task-store.ts` (Home's task ledger; D4) |
| K5 `worker-control.ts`: steering input and Stop/Interrupt identity fences; `worker-settlement.ts`: live join/wake owner; `subagent-control.ts`: actual provider I/O; `subagent-settlement.ts`: canonical stop/join/notice/receipt algorithm over actual native I/O. K5 `worker-turn-boundary.ts` owns actual turn-boundary report/budget/reminder policy; Slot installs it over the same native frame and SDK runtime. K5 `OwnedTurnOwner` owns the actual observer map, held-task/wake state and cancellation algorithm over the same native frame. The same K5 `OwnedTurnOwner` holds the live worker report binding and lane-protected bind validation/rebuild orchestration; native creation seeds that owner once. Slot retains SDK tool installation, rebuild and publication I/O, not a separate worker field or bind route. Native prompt/per-tool cancellation stay K2; the actual shared registry-owned DelegationOperations acquires workers and binds native interruption in kernel composition. Home and automations use that same service, not per-dispatch adapters. | `home-wake-inbox.ts` (D4), `home-request-policy.ts`, `home-memory*.ts`, `home-profile.ts`, `home-research-tools.ts`, `tron-home-extension.ts` (`HOME_OPERATING_CONTEXT`, used for headroom `runtime-slot.ts:8844`, comes through `requestPolicy`) |
| `home-task-report.ts`, `home-task-checkin.ts`, `task-subagents.ts`, `home-task-worker-extension.ts` (the worker prompt at `:55` is model-visible text and moves byte-identical) | Profile `home`, hooks `profileDecision`, `requestPolicy`, `inputAdmission`, `appendGuard`, `runSettled` |
| Subagents: `managed-subagents.ts`, `child-session-admission.ts`, `delegated-provider.ts`, `subagent-catalog.ts`; existing `OwnedTurnOwner` holds live activity/correlation, watcher/read-generation/receipt maps and run/supervisor/Stop authority. `subagent-artifact-status.ts` owns bounded file/header proofs; `subagent-artifact-reconcile.ts` and `subagent-activity.ts` own actual admission, canonical folding/receipts and lifecycle algorithms over that same state. Native retains physical SDK/canonical/work I/O and process-to-child projections, not artifact/run forwarding routes. | `HomeOwner` construction leaves `runtime-registry.ts:796-866` for Home's `start` |

`HomeOwner` receives one actual `SessionOperations` authority for canonical evidence,
leases, runtime reads and mutation ordering. The duplicate `taskSessions` input and
`HomeNativeOwners.workers` field are absent. `HomeSessionPort` holds only substantive
Home chapter/model/wake policy: creation recipe, saved model choice, chapter metrics,
conversation proof, uncertain-publication retirement and wake admission. Native reads
and publications have no Home callback facade. Home calls K5's projection reader on the
same selected native cut; K5 owns cold artifact proof and its late admitted-root guard.
The current shared orchestration service is `RuntimeRegistry.delegation`; ordinary
native leases, prompts, recovery evidence and marker I/O are addressed directly, not
through K5 passthroughs. The §3 `GatewayHost` operations sketch remains a target, not the
current platform/contract-only host. The native frame composes the sole K5
`OwnedTurnOwner` for held-turn/terminal observers and actual run/artifact authority;
canonical terminal classification, persistence and SDK abort I/O remain native.

Persisted names never change in Phase 2: custom entry types (`HOME_TASK_MARKER`,
`HOME_TASK_REPORT`, `tron.home-task-report-reminder.v1`), receipt types and store paths keep
their values where constants move (B3). Generic files drop the `home` prefix only in `move`
commits.

## 6. Pilot module: **apps** (D3)

| | apps | notifications |
|---|---|---|
| Production lines (`wc -l`) | 518 in 2 files | 1,538 in 4 files |
| Hooks exercised | none | `runTerminal`, `interactionRequired` |
| Consumers outside the module | registry (`runtime-registry.ts:767`, `:896`, `:1862`), slot host (`runtime-slot.ts:2292`), `tron-modules.ts:171-178`, 4 RPCs + capability (`transport/gateway-service.ts:89`, `:627`, `:801-818`) | slot (3 sites), Home, automations, device revoke, Mac replace, 6 RPCs (`transport/gateway-service.ts:1124-1215`), `gateway-main.ts:160` |
| Locks today | `apps.store`; `swift_app` in `run-prompt-stream` tools and prompt hash; `protocol.wire` | `notifications.store` only; no golden records a push |

Apps exercises what the pilot must measure (descriptor, `start`-owned store, tool, RPC
routing, capability, one module contract: the internal workspace, today built by the registry
at `runtime-registry.ts:765`, and ≤ 1 composition line) on already-locked code, without a hook.
Notifications is the first hook consumer, in E5, after its push lock (E0b).

## 7. Extraction order and guarding locks

Every kernel slice is risk-class (review). Until `scripts/tron verify` (Phase 0 slice 0.11)
lands, a slice runs the named locks and the full Gateway suite directly. Locks stay unchanged.

| Step | Change | Guarding locks |
|---|---|---|
| E0 locks | New scenario locks: (a) Home: first runtime of a new Home session, activation, wake, task dispatch (provider requests with Home prompt hash and tools, JSONL, frames); (b) terminal and input-required pushes (`test-support/gateway-lock-harness.ts:203-210`); (c) automation owned run; (d) cold load, eviction, drain snapshot; (e) `projectDir` subdirectory session with trust | known-bad per lock |
| E1 host core + pilot | `kernel/host`: descriptor, `SessionContext`, hook dispatch, `main/modules.ts`, RPC routing (D5); `modules/apps` as the first descriptor; the registry stops constructing the Apps store | `apps.store`, `run-prompt-stream`, `protocol.wire`, `delegation-subagent` |
| E2 `kernel/pi` | seam module; imports and resolutions rerouted file by file (`move`); adapters of §4; layer rule (D2) | `sdk-behavior-trace`, Pi corpus, all `run-*`, `delegation-subagent`, E0e, `npm run test:pi-sdk-rollback`, `runtime-compaction` (#1340 revocation), `project-root` |
| E3 host rest | remaining `TRON_MODULES` become descriptors in place; `TronModuleHost` shrinks to `SessionContext` | `run-prompt-stream`, `run-extension-ui`, `admin-settings-change`, `protocol.wire`, E0a |
| E4 `kernel/projection` | snapshot, pages, activity out of the slot; `toolResultProjection` | `transport-reconnect-snapshot`, all `run-*` events, `session-attention`, `delegation-subagent` |
| E5 `kernel/run` | admission, queue, abort, compaction, receipts, request pipeline, profiles (§2.2); the Home and notification hooks | all `run-*`, `run-markers`, `run.store`, `command-receipts`, E0a, E0b, E0d |
| E6 `kernel/delegation` | delegation files, generic task report/check-in/worker extension, owned-session dispatch port (#1692, #1696) | `delegation-subagent`, `home-task-store`, E0a, E0c, subagent parity |
| E7 `kernel/session` | catalog, acquisition, heap, eviction, archive/delete, drain; `HomeOwner` built by Home's `start`; then the rest of §5's left column (registry worker paths, slot worker role, `task-subagents.ts`, `DelegationOperations` for Home and automations) | `session-catalog.store`, `session-archive`, `session-attention`, `home.store`, Pi corpus, E0a, E0d |
| E8 (Phase 3) | Home files move under `modules/home`; then the E7 remainder: display, providers and settings hooks, registry and slot out of `gateway/run`, the delegation tail | Change-relevant behavior/integration locks and fresh boundary review |

Order: wiring first (E1-E3), then read-only projection (E4), the behavior core (E5),
delegation, which depends on run ownership (E6), and the registry, which depends on all
(E7). E7 closed (maintainer, 2026-10-23) once the registry no longer constructed or called Home; its remaining items moved to E8. Net lines and deleted concepts are metrics, not slice or phase/E8 exit gates. Temporary forwarding, mirror and compatibility plumbing is not a way to close a slice: move actual consumers and delete superseded routes in the same change, including multi-file migrations. Acceptance requires one canonical owner, narrow explicit dependencies and preserved behavior. A retained seam must have a genuine blocker, actual consumer, removal issue and concrete exit condition in #1348’s simplification ledger; filing a follow-up alone is not a blocker. The exit review states deleted/remaining mechanisms and net lines, distinguishes enduring ownership contracts from temporary debt, and removes unnecessary dead code. Home leaves the registry through `sessionLineage` (§2.1; decision A, maintainer 2026-10-23): the kernel asks Home only for lineage facts, never through a HomeOwner mirror, and the registry's Home procedures (reserved-successor materialization, publication retirement, task recovery and dispatch) move to Home over K1 operations. The rest of §5's left column follows E7 (maintainer, 2026-10-22): while `gateway/run` owns the slot
and registry, which import delegation, a delegation→run import is a hard two-way pair (#1348 layers probe). E2 before E3-E7 keeps moved files from being re-touched for imports (D1). K4 and K6 are
file moves on disjoint files that may run beside E3-E7 (`admin-settings-change`,
`settings-approvals`, `admin.store`, `run-prompt-stream`). Each step is several slices of one
owner and one change type (`move` before `simplify`), ≤ ~800 non-moved lines.

## 8. Invariants carried through

- **B1/B2:** per-profile extension order, names, schemas, prompt sections and model-visible
  text unchanged; `run-prompt-stream`, `delegation-subagent` and E0a record them.
- **B3:** no persisted name, path or format changes (§5). **B4:** no wire change; RPC routing
  moves handlers, not shapes (`protocol.wire`).
- **B5:** one live runtime per session (K1 keeps the slots map and the write guard's
  single-owner check). Lock order is kept: `serializeSessionMutation` → registry mutex →
  session lane → attention lane → Home `recordMutex` (`runtime-registry.ts:527-558`, `:3729-3736`).
- **B6:** no credential, trust or exposure path changes; Stable stays maintainer-only.

## 9. Risks

| Risk | Mitigation |
|---|---|
| A hook adds an `await` or reorders work (`homeChapterAdmission` is sync after admission awaits, `runtime-slot.ts:597-598`) | §2.1 fixes shape per call site; review checks each hook call against base |
| Request-pipeline order changes (guard innermost, `:2551-2557`) | one adapter owns the composition; E0a/E5 record provider requests |
| Hooks or contracts captured before `start` | call-time resolution; `start` in list order; E1/E3 locks |
| Home extraction breaks lock order or publication gating | move with the lane code; E0a + `home.store`; no simplify in the same commit |
| Top-level side effects move (`semantic-ui-broker.ts:61` theme) | explicit `pi.initTheme()` in composition; `run-extension-ui` |
| Profile fields miss a `liveProfile()` branch | §2.2 maps all 14; E0a; review greps `liveProfile` to zero |
| Lock gaps (Home, pushes, automations, drain, `projectDir`) | E0 lands first; no slice touches unlocked behavior |
| Pi upgrade (#1025) mid-extraction | land before or right after E2 (plan §11) |
| Hot-owner churn (`runtime-slot.ts` 140 commits/30 days at baseline) | small slices, announcements in #1395/#1398, fast landing |

## 10. Decisions (maintainer, 2026-10-20)

- **D1** Pi seam timing: E2, early, right after the pilot (not last).
- **D2** Seam rule: all `@earendil-works/*` imports, type-only included.
- **D3** Pilot: apps.
- **D4** Task ledger and wake inbox stay in `modules/home` (Home's authorization, choice
  and wake policy); only worker lifecycle and reports are generic.
- **D5** RPC routing in E1: descriptor `rpc` routed before `GatewayService`'s switch.
- **D6** Hooks: single-implementer policy hooks plus ordered observer lists.
- **D7** Profiles: a `SessionProfile` object (§2.2), not a kernel-known `"home"` name.
