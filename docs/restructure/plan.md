# Tron multi-agent-native restructure — master plan

Status: **approved plan, executed by Home** (§14). Baseline revision: `main` at
`dc289f47e` (2026-10-19).

This file's lifecycle:
- The first steward slice commits it as `docs/restructure/plan.md`. Before
  that, the draft lives in the Tron internal workspace at
  `files/multi-agent-restructure/plan.md`.
- After that commit, only steward slices edit it. Live status goes in the
  master epic body, not here.
- It is exempt from doc budgets until epic exit (M6). At exit its surviving
  rules have moved into the charter and module docs, and the file is deleted.

**Read order.**
- Workers: §0 decisions → §4 invariants → §8 slice protocol, then the section
  their brief names.
- Scopers add §5 and §10.
- Home reads §14 (Home runbook) and Appendices A and E.

| § | Contents |
|---|---|
| 0 | Decisions |
| 1–3 | Mission, baseline, metrics and targets |
| 4 | Behavior, process and multi-agent invariants |
| 5 | Target architecture: layers, kernel, trees, docs |
| 6 | Verification system: manifests, `verify`, locks, checkers |
| 7 | Phases and milestones |
| 8 | Slice protocol |
| 9 | GitHub tracking model |
| 10 | Scoping playbook |
| 11 | Risks |
| 12 | Open decisions |
| 13 | Roles |
| 14 | **Home runbook** |
| A–F | Issue map, issue templates, announcement, evidence, dispatch briefs, glossary |

---

## 0. Decisions (from the planning interview)

| Topic | Decision |
|---|---|
| Epic relationship | New master epic **supersedes and absorbs** #1264, #224, #1285, #629, #1102, #781. Old epics close with pointers; still-valid children are re-parented. #1264's "no split by size / no new targets" rules are replaced by this charter. |
| Metrics | All four are first-class, ranked **Confidence → Locality → Size → Cost**. |
| Invariance | User-observable behavior and user data are preserved. Internal wire, APIs, logs and file layouts may change. Persisted schemas may migrate **once, forward-only, with automatic backup**, in dedicated migration slices. |
| Version skew | **Lockstep.** iOS, Gateway and Mac ship as one versioned set; a mismatch refuses clearly. No N-1 shims. |
| Landing | **Trunk-based small slices**: one issue, one worktree, fast landing. No long-lived refactor branch. |
| Concurrent work | Bug fixes continue everywhere. New features pause in *hot owners* until their target module exists. |
| Harness | **Pi owns the loop.** Tron gets an explicit kernel of harness primitives on top. Capabilities become modules that use only a narrow host contract. Every Pi touchpoint goes through one seam; upstreaming the patch is a later, separate effort. |
| Multi-agent native | **Both** dev-time (parallel coding agents) and product-time (delegation, workers and subagents as kernel primitives). |
| Verification | A behavior-lock harness is built in Phase 0 and is **mandatory for every restructure slice**. It runs locally, with no hosted gate, queue or receipt. |
| Boundaries | Mechanical import/reference checks with a ratchet first. These are promoted to compiler boundaries (TS project references, Swift modules) once a layer is clean and build cost is measured. |
| Moves | Progressive, owner by owner, toward a target tree defined up front. |
| Docs | Co-located, size-budgeted owner docs. Top-level docs become thin indexes. History, evidence and measurements stay out of the repo. |
| Tests | Journey catalog plus pruning. **Kernel contract tests are allowed** (real kernel, faux model); classic mocked unit tests remain banned. |
| UI proof | Accessibility-tree snapshot **and** screenshot diff per catalogued screen state, plus interaction journeys. |
| Tooling languages | Prune; no language migration. |
| Tracking | Epic → Phase → Area → **Module issue with a file checklist** → Slice. A tool proves every tracked file is covered. |
| Execution | Home dispatches workers, **at most 4 in parallel**, with **one simulator-heavy iOS job** in the epic at a time. Fresh-context review applies to risky slices. |
| Backlog | Phase 0 triages all open issues, epics, worktrees and branches. Nothing unmerged or live is deleted without the maintainer's approval. |
| Targets | **Stretch** (see §3). |
| Rulebook | AGENTS.md, CONTRIBUTING, skills and work tooling are in scope and get rewritten into a short, check-backed charter. That rewrite is the **first slice**, and the maintainer approves it. |
| Rollout | Debug Gateway and simulator per slice. A **milestone handoff** to the maintainer's Stable and iPhone follows each milestone or risky phase, with one day of real use before the next risky phase. |
| Deliverable | This plan, approved, is handed to **Home**. Home's steward commits it and creates the epic plus the Phase and Area skeleton. Scoping workers create the leaf issues (§14). |

---

## 1. Mission and non-goals

**Mission.** Make Tron a codebase where any agent, in parallel with others, can
find the one owner of a behavior quickly, change it while touching few files, and
prove mechanically that nothing else changed. The core (the harness primitives
that define how a model runs, acts, delegates and is extended) must be small,
explicit, documented and dependency-directed. Every capability is a module on top
of it.

**Non-goals.**
- No new product features and no user-visible changes. This includes copy,
  timing users can perceive, notification text, and model-visible prompts and
  tools.
- No rewrite of Pi's loop, and no Pi upgrade inside this epic (coordinate #1025
  separately).
- No hosted CI, merge queue, landing gate, receipt service or automatic revert.
  These were measured and rejected in #1253/#1255. Verification here is
  mandatory *for restructure slices* but runs locally and is owned by the worker.
- No compatibility shims, re-exports or dual readers (charter rule, unchanged).

---

## 2. Baseline (measured at `dc289f47e`)

Phase 0's metrics tool will recompute all of these under precise definitions.
These figures come from a first-pass classification.

| Measure | Value |
|---|---|
| Tracked files / hand-written files | 1,306 / 1,153 |
| Hand-written lines (excl. data, binary, config, lockfiles) | **~434k**: production ~255k (712 files), tests ~121k (293), tooling ~31k (92), docs ~26.5k (56) |
| Gateway `src` | production 96.7k, tests 62.0k (118 files: 86 integration, 32 E2E) |
| iOS Swift | app ~150k, tests ~20k, plus ~10k hosted fixtures compiled into `Sources/App` |
| Production files > 500 lines | **133** (~154k lines, 60% of production code); 60 files > 800 |
| Test files > 1,000 lines | 21 (largest: `runtime-registry.integration.test.ts` 13,171) |
| Largest owners | `RuntimeSlot` 11,149 (340 methods), `RuntimeRegistry` 5,016, `GatewayServer` 3,120, `GatewayService` 3,096, `projection.ts` 2,455, iOS `AppModel` 5,697, `ChatView` 3,814, `SessionPresentationStore` 3,238, `GatewayClient` 3,053 |
| Gateway directory cycles | **23 two-way directory pairs** among ~20 `src/` directories; `sessions/` imports 16 others |
| Conflict surface | **44%** of 2,073 non-merge commits (30 days) touched one of 10 shared files |
| Top churn files (30 days) | Gateway README 295, iOS `development.md` 293, iOS `architecture.md` 236, `observability.md` 203, `runtime-slot.ts` 140, registry test 128 |
| Docs | 26.5k lines; iOS `architecture.md` 3,565, `development.md` 3,210, Gateway README 2,188, `home.md` 1,983 |
| Coordination debt | 73 worktrees, 189 branches, 153 open issues, ~556 commits/week |
| Pi patch surface | 868-line patch over 10 `pi-coding-agent` files, plus the `pi-subagents` fork |

---

## 3. Metrics, definitions and targets

Ranked. A lower-ranked metric never justifies regressing a higher one.

### M1. Confidence (precondition; slices cannot land without it)
- **Lock coverage:** the share of catalogued capabilities (§6.3) that have at
  least one behavior lock, one journey, and a recorded known-bad control.
  **Target: 100%.**
- **Lock determinism:** each lock produces identical output on 5 consecutive
  reruns. **Target: 5/5 for every lock.**
- **Lock sensitivity:** the share of sampled semantic mutations caught by
  locks, measured at milestones (§6.6). **Target: ≥ 90% for kernel and
  protocol code; reported for everything else.**

### M2. Locality and conflict surface (primary objective)
- **Layer violations:** import or reference edges against the declared
  direction, plus directory or module cycles. **Target: 0** (Gateway and iOS),
  enforced by ratchet.
- **File size:** hand-written files over 500 lines. **Target: 0**, except
  recorded exceptions in the owning manifest, each with a reason and an
  exit condition.
- **Hotspot share:** the share of non-merge commits in a trailing 30-day
  window that touch any of the 10 most-touched files. **Target: < 10%**
  (from 44%).
- **Registration footprint:** lines a new capability must add outside its
  own module. **Target: ≤ 1 line per composition root.**
- **Navigation probe** (milestones only): a fresh agent answers a fixed set of
  "where is X decided / how do I change Y" questions. Record the files and
  tokens read. The trend must improve each milestone.

### M3. Size
- Hand-written lines by category (production, tests, tooling, docs).
  **Target: ≤ 260k total (−40%)**, reported per category.
- Each **phase** must be net-negative. A single slice may grow only if it names
  the locality gain it buys.
- Planning budget (a guide, not a promise): docs −70%, tests −40%,
  production −35%, tooling −35%. Production at −35% without behavior change is
  the riskiest number; it never outranks M1 or M2.
- Golden and fixture data is tracked separately, so adding locks does not
  fight this metric.

### M4. Verification cost (guardrail)
- **Slice verification:** wall time of `scripts/tron verify --changed` on a
  warm tree. **Target: p50 < 5 min**; any single module < 5 min.
- Full lock suite time is reported every milestone. It is a budget, not an
  objective.

### Measurement
Phase 0 builds `scripts/tron metrics`. It is read-only and deterministic, and
writes `test-results/metrics/<sha>.json`. `scripts/tron metrics --compare <base>`
prints the delta table that every slice pastes into its closing comment. It is
never a gate.

---

## 4. Invariants

### 4.1 Behavior invariants (what "no functionality change" means)
- **B1 User-observable behavior.** iOS UI and UX (structure, copy, layout,
  identity, focus, scroll, keyboard, motion), Mac app UI, notifications, and
  CLI output that users rely on stay identical.
- **B2 Model-visible surface.** System-prompt sections, tool names, schemas and
  descriptions, tool-result text, and compaction/retry behavior are behavior.
  The model sees them, so they are locked exactly like UI.
- **B3 User data.** Every existing persisted store stays readable: canonical
  session JSONL, settings, credentials, knowledge, episodic, automations,
  devices, uploads, Home state and receipts.
  - A format change happens only in a **migration slice**. It is forward-only,
    runs once, takes an automatic backup first, and is batched so a Stable
    rollback restores the backup.
  - Migrations need the maintainer's explicit approval per slice.
- **B4 Lockstep wire.** A slice may change the iOS↔Gateway↔Mac wire only if all
  sides change in the same slice and a version mismatch refuses clearly. Wire
  slices are risk-class slices (§8.4).
- **B5 Architecture invariants (unchanged from AGENTS.md).**
  - One live runtime per canonical session.
  - Per-session mutation serialization; distinct sessions run concurrently.
  - Accepted prompts survive iOS disconnects.
  - Reconnect gets an authoritative snapshot, and interrupted prompts are never
    replayed.
  - Mutations carry command IDs with bounded receipts.
  - Trust is not a sandbox.
  - Exposure binding rules hold.
  - Wrapper credentials stay separate from device credentials.
- **B6 Security and operations.** Credential locations, the privacy guard,
  Stable/production as maintainer-only, and process/simulator cleanup are
  unchanged.

### 4.2 Process invariants (every worker, every slice)
1. **One slice = one issue, one worktree, one owner module.** Claim with
   `scripts/tron work start`. Announce the exact files in the module issue
   before editing.
2. **Lock before touch.** The module's locks exist and pass on the base before
   its first refactor slice. If they are missing, the next slice is a *lock
   slice*.
3. **Goldens are immutable in refactor slices.** If a golden would change, the
   slice is not a refactor. Stop, then either fix the slice or escalate it as
   a behavior/migration decision.
4. **One change type per commit:** `move`, `simplify`, `delete`, `lock`, `doc`,
   `migration` or `tooling`. Never move and change in the same commit. Moves
   must show a moved-lines report with only declared edits (renames, imports,
   visibility).
5. **No shims.** Replace imports atomically. No re-exports, aliases or
   fallbacks. The one deliberate seam is the Pi adapter (§5.2).
6. **Ratchets only tighten.** Layer violations, file-size exceptions, doc
   budgets and unowned files can only go down. `scripts/tron verify` fails a
   slice that adds one.
7. **Every tracked file has exactly one owner module.** Every file appears in
   exactly one module-issue checklist. Moved files carry their audit state.
8. **Delete with an oracle.** Removing a test or mechanism names the surviving
   behavioral oracle and shows a known-bad control failing it. "Unused by grep"
   is not proof (check dynamic registration, generated, external and runtime
   consumers).
9. **Feature pause in hot owners.** No new features in: `RuntimeSlot`,
   `RuntimeRegistry`, `GatewayService`, `GatewayServer`, `gateway-main`,
   `protocol/types.ts`, `projection.ts`, iOS `AppModel`,
   `SessionPresentationStore`, `ChatView` and `GatewayClient`, until the
   target module for that feature exists. Bug fixes in an owner under
   restructure coordinate in its module issue first.
10. **Short evidence.** Closing comments use the template in Appendix D
    (≤ 25 lines). Long logs go to `test-results/` or the internal workspace and
    are linked, not pasted. Docs never carry history.
11. **Resources.** At most 4 restructure workers. At most one simulator-heavy
    iOS job in the epic at a time. Clean up your own processes. Never touch
    Stable, the installed app, or another worker's tree. Never `git stash`.
12. **Stop conditions:**
    - a golden diff;
    - an unknown dynamic consumer;
    - an overlap with another live claim;
    - two diagnosed verification failures you can't explain;
    - a needed change outside the slice's owner;
    - a needed wire/persisted change in a non-migration slice.

    Stop, comment in the module issue, and hand back.

### 4.3 Multi-agent-native design principles (dev-time)
- **D1 No universal touchpoints.** Nothing is edited by most changes. Central
  registries become distributed module descriptors plus one-line composition.
  Cross-module indexes (signals, RPC list, settings keys, test catalog) are
  **generated on demand**, not hand-edited.
- **D2 The module is the unit of ownership, claim, docs, tests and
  verification.** One manifest declares its files, layer, dependencies,
  capabilities and verify commands.
- **D3 Contracts at boundaries.** Modules talk through declared ports in the
  kernel, or through declared module contracts. Parallel work on two modules
  therefore never edits the same file.
- **D4 Tests live with their module.** One journey per file. Fixtures belong to
  their module, and shared test support is small and owned.
- **D5 Verification is selectable from manifests and conservative.** Unknown
  or unowned files, kernel or contract changes, and config/toolchain changes
  widen the selection to all locks. This avoids the #1259 selector failure:
  dynamic edges are declared, not inferred.

### 4.4 Multi-agent-native design principles (product-time)
- **D6 Delegation is a kernel primitive.** Tasks, workers, subagents, child
  sessions, steer, interrupt and report are kernel operations with one owner
  each. Home is a *module* (policy, memory, profile, chapters) built on them,
  not threaded through `RuntimeSlot`.
- **D7 Isolation by session.** Each agent (root, worker or subagent) is a
  session with its own serialized mutation lane, budget and lifecycle. Its
  cross-agent effects go only through kernel delegation operations, which are
  observable and idempotent.

---

## 5. Target architecture

This is the destination that scoping workers map every file toward. The
**kernel interfaces** are designed in Phase 2's first slice (K-0) and approved
by the maintainer. Names below are the intended shape, not frozen APIs.

### 5.1 Layers (all packages)

```text
L5 composition   gateway main / iOS App / Mac App     knows every module; wiring only
L4 surfaces      transport+RPC dispatch / iOS UI      routes to modules; no domain state
L3 modules       one folder per capability            uses only kernel ports + declared module contracts
L2 kernel        harness primitives                   owns session/run/delegation/host lifecycles
L1 contracts     wire + persisted value types         pure values, no behavior owners
L0 platform      fs durability, logging, process,     no upward imports
                 locks, bounded text, timing
```

Dependencies point only downward. A module may depend on another module only
through that module's declared `contract` (types and a port interface), and the
manifest must list the dependency. Cycles are violations.

### 5.2 Gateway: the kernel (harness primitives)

Pi remains the loop authority: turns, tools, extension API, skills/resources,
compaction, retries and canonical JSONL. The Tron kernel is what Tron adds on
top, and nothing else:

| Primitive | Owns | Today mostly in |
|---|---|---|
| **K1 Session** | identity, admission, live-slot lifecycle, catalog, fork/branch, canonical file access, archive/export | `runtime-registry`, `session-catalog`, `catalog-*`, `fork-boundary`, `session-archive*`, `session-export` |
| **K2 Run** | prompt admission, queue/steer/follow-up, abort/interrupt, command receipts, run markers, compaction policy hookup, bounded tool cancellation | `runtime-slot` (bulk), `invocation-receipts`, `run-markers`, `bounded-tool-cancellation`, `runtime/compaction-policy` |
| **K3 Module host** | module registration, extension factories, the host contract given to modules, extension UI broker and remote extension host, extension activity/history | `tron-modules`, `extensions/host/*`, `semantic-ui-broker`, `extension-*` |
| **K4 Resources** | skills, prompts, packages, agent instructions, project trust gating, resource distribution | `agent-instructions`, `resource-*`, `admin/trust-service`, `package-*`, `hook-resources` |
| **K5 Delegation** | tasks, workers, subagents, child-session admission, delegated provider, managed-subagents adapter, steer/interrupt/report across sessions | `managed-subagents`, `child-session-admission`, `delegated-*`, `subagent-catalog`, `home-task-dispatcher/store/subagents` (generic parts) |
| **K6 Settings** | layered keys, resolver, single change path, approvals, risk, presentation projection | `admin/settings-*` |
| **K7 Projection** | client snapshot/events, history paging, process activity, attention | `projection`, `history`, `process-activity*`, `session-attention-store`, `extension-run-projection` |
| **K8 Pi seam** | the **only** code that imports `@earendil-works/*` at runtime. Wraps session creation, extension and resource loading, and model runtime. Lists every patched API it relies on (the patch's removal checklist). | scattered imports across ~all directories |

**Hooks instead of reach-ins.** Today `RuntimeSlot` imports Home, settings,
providers, extensions and transport directly. After K-0, the kernel exposes
explicit ports. Examples: run-lifecycle hooks, request-policy hook, context and
compaction policy hook, prompt-section contributors, tool exposure. Modules
implement those ports. The kernel imports **no** module.

### 5.3 Gateway: target tree

```text
packages/gateway/src/
  platform/     L0: util/, durable-json, logger, path containment, process env,
                lifecycle helpers (startup budget, shutdown step, exit)
  contracts/    L1: envelope, JsonValue, errors, json-budget, shared wire values
  kernel/       L2: session/ run/ host/ resources/ delegation/ settings/
                projection/ pi/
  modules/      L3: one folder per capability, each with module.ts (descriptor:
                extension factories, RPC handlers, wire contract, stores),
                README.md, locks/, tests:
                home/ episodic/ knowledge/ automations/ notifications/
                display/ (display, browser live, native capture, computer)
                apps/ machine/ (fs, terminal, uploads, git, workspace inspection)
                search/ integrations/ providers/ (model queue, usage, model
                policy) admin/ (packages, MCP admin, auth broker, device install,
                gateway update, mac replace) ask-user/ workspace/ mac-terminal/
  transport/    L4: server, HTTP/WS admission, outbound queue, auth/devices,
                LAN/Tailscale, RPC dispatcher that routes to module-registered
                handlers (replaces the 3k-line GatewayService switch)
  main/         L5: composition root (module list), startup/shutdown
  client/       terminal chat client (separate entry; L4 consumer of contracts)
```

`protocol/types.ts` (1,392 lines, a hotspot) splits into `contracts/` (shared
envelope) plus each module's own `contract.ts`. The iOS `GatewayProtocol` and
Models mirror that per-feature split.

### 5.4 iOS target

```text
packages/ios-app/
  Core/                      TronMobileCore target (exists): wire contracts per
                             feature, transport, nonvisual support
  SwiftAppEngine/            (exists)
  Sources/
    App/                     entry, scenes, composition (AppModel reduced to wiring)
    Kernel/                  connection/lifecycle, presentation-activity fences,
                             confirmed-mutation coordination, snapshot cache
    Shared/Presentation/     TronPresentation components, theme, shared rows/sheets
    Features/<Name>/{State,UI}/   Chat, Home, Knowledge, Automations, Settings,
                             Terminal, SwiftApps, Onboarding, Notifications,
                             Integrations, Diagnostics, Workspace, Subagents
  Fixtures/                  Hosted*Fixture sources (out of Sources/App;
                             HOSTED_TEST only; separate target if build data allows)
  UITests/<Feature>/  Locks/<Feature>/
```

Rules: a feature never references another feature's internals. Shared code goes
to `Kernel/` or `Shared/`. Within one Swift module, imports can't express this,
so Phase 0 builds a **reference-graph checker** from the build's index store
(folder → folder symbol references) and ratchets it. Folders that reach zero
violations become real Swift modules (#224's intent) when matched build
measurements show no regression.

### 5.5 Mac, relay, tooling
- **Mac:** keep the `Server/`, `Wizard/`, `MenuBar/`, `NativeHost/` and
  `App/` owners. Apply the same manifest, size budgets, dead-code audit and
  a11y/screenshot locks for the wizard and menu. The native helpers
  (`native-computer-control`, `native-gateway-client`, the C launcher) are
  modules with their own locks.
- **Relay:** small and cohesive. It gets a manifest, a lock over its existing
  worker integration test, and an audit. No scope growth.
- **Tooling:** `scripts/tron` stays the single entry point. Scripts are grouped
  by owner (`tools/work`, `tools/verify`, iOS test, Mac, dev, profile) with
  per-owner manifests. Prune duplicates, retired-machinery residue and one-off
  research. No language ports.

### 5.6 Docs target
- **Module README** (≤ 150 lines, fixed sections): Purpose · Owns · Contract
  (public surface and ports) · Invariants · Entry points · Signals · Verify
  (commands) · Not here.
- **Package docs** become ≤ 200-line indexes plus genuinely cross-module
  contracts (e.g. connection resilience). Each of those has a ≤ 300-line budget
  and a single owner.
- **Root:** README ≤ 150; AGENTS.md charter ≤ 150; CONTRIBUTING merges into the
  charter or the skills.
- **Generated, not committed:** `scripts/tron docs <index>` prints the RPC
  list, settings keys, signals table, capability catalog, test catalog and
  module map from manifests and code.
- **Out of the repo:** research, measurements, history and evidence. These go
  in issues or the internal workspace.
  - Example: `docs/agent-first-verification.md` reduces to its surviving rules
    inside the charter, with its evidence linked from #1255.

---

## 6. Verification system (Phase 0 deliverable)

**Goal:** a worker can run one command and get mechanical evidence that a
restructure slice changed nothing user-observable. Build on what exists rather
than inventing a parallel framework:
- `sdk-behavior-trace` (normalized golden plus `git diff --no-index`);
- the Pi persisted-state corpus recorder;
- `packages/protocol-fixtures`;
- hosted iOS fixtures;
- `ios-gateway-e2e-test` with its fault proxy;
- the real-Gateway UITests;
- the privacy, documentation and presentation-source policies.

### 6.1 Module manifest (V1)
- A co-located `module.json` sits beside each module's README. The format is
  finalized in slice 0.4.
- Fields:

  | Field | Meaning |
  |---|---|
  | `id` | module name |
  | `layer` | layer from §5.1 |
  | `owns` | globs |
  | `dependsOn` | modules and kernel ports |
  | `capabilities` | catalog entries (§6.3) |
  | `verify` | `{locks, journeys, contract tests, static}` |
  | `riskClass` | review trigger (§8.4) |
  | `exceptions` | file-size/doc-budget exceptions, each with a reason and exit condition |
  | `dynamicEdges` | runtime-registered, spawned, fs-read or generated consumers |

- There is no central registry. Tools discover manifests by glob, so adding a
  module never touches a shared file (D1).
- During the as-is phase, a manifest may claim scattered files by explicit
  path. The manifest moves with the code.

### 6.2 `scripts/tron verify` (V2): the one command
```text
scripts/tron verify --changed [--base <ref>]   # what a slice runs
scripts/tron verify --module <id>               # one module's full set
scripts/tron verify --all                       # milestone / kernel changes
scripts/tron verify --update-locks <module>     # lock / approved-migration slices only
```
1. **Static checks, always:**
   - typecheck (production and test support);
   - lint;
   - layer/import ratchet (V5);
   - size/doc-budget ratchet (V6);
   - ownership completeness (every file has one manifest owner);
   - documentation links;
   - privacy guard;
   - `git diff --check`;
   - a moved-lines report (V10).
2. **Selection:** changed paths (old and new names) map to owning manifests,
   then to their `verify` sets, then to the locks of every module whose
   `dependsOn` reaches them.
   - Kernel, contracts, platform, toolchain, test-support or unowned paths
     select **all** locks.
   - `dynamicEdges` are part of the closure.
   - The run prints *why* each set was selected.
3. **Run** the selected sets with existing runners (`scripts/tron test gateway`,
   `scripts/tron-ios-test`, tooling CLI tests). These keep their lease and
   cleanup ownership.
4. **Report:** `test-results/verify/<sha>.json`, plus a short summary for the
   closing comment.
   - It must contain a non-empty count of executed passing tests per runner.
   - Skipped or empty runs count as failures of evidence.

It is local and worker-owned. It never queues, waits on another worker, caches
a pass or writes a receipt.

### 6.3 Capability catalog
Each manifest lists its user-visible capabilities. The union is the catalog,
generated with `scripts/tron docs capabilities`. Starting set for scoping:

| Area | Capabilities |
|---|---|
| Access | pairing, devices and revocation, LAN/Tailscale exposure |
| Sessions | create, list, open, fork, archive, export, search |
| Runs | prompt/stream, steer, follow-up, abort, retry, compaction, attachments and uploads |
| Tools | bash/processes, files, display, browser live view, native capture, computer use, ask_user, notify, schedule, settings tool, knowledge tools, Swift apps, Jev, connections |
| Extensibility | extensions and packages, trust, extension UI, MCP and OAuth, hooks |
| Agents | subagents/delegation; Home (status, tasks, memory, profile, research) |
| Memory | knowledge (sources, curation, connectors), episodic memory |
| Background | automations, notifications/push |
| Configuration | settings, models, providers, auth |
| Machine | PTY terminal, Mac Terminal SSH, workspace inspection/git |
| Lifecycle | Gateway update, rollback, restart drain, diagnostics |
| Mac app | install wizard, menu bar, pairing invite, native host |
| iOS | share extension, Swift app engine, onboarding, offline cache and reconnect |

### 6.4 Gateway behavior locks (V3)
- Generalize `sdk-behavior-trace` into a **scenario lock** framework. One
  scenario per capability runs through the real `RuntimeRegistry` and the
  `GatewayServer` loopback WebSocket, with the faux provider, isolated
  `HOME`/`TMPDIR`, and a fixed clock and ID seed where possible.
- Recorded and normalized:
  - client-visible frames (topic plus payload shape and values);
  - canonical JSONL;
  - provider requests (system-prompt section headings plus normalized-text
    hash, tool schemas, messages);
  - files written under the module's stores;
  - notifications enqueued.
- Normalization is explicit and owned in one place: IDs, timestamps, durations,
  temp paths and machine-specific values. A lock's golden lives in
  `modules/<m>/locks/*.golden.json`. A diff is reported with `git diff --no-index`.
- **Kernel contract tests** (newly allowed) assert one kernel port's contract
  with the real kernel and the faux model. Each one names the port and
  invariant it protects. Mocking kernel internals stays forbidden.

### 6.5 Persisted-data and wire locks (V4, V7)
- **Persisted corpus:** extend the Pi corpus recorder to a synthetic,
  privacy-clean corpus for **every** Tron store (§4.1 B3).
  - The lock boots a Gateway on a staged copy, reads, projects and snapshots.
  - It protects readability across refactors, and is the test bed for every
    migration slice. Migration slices assert: backup taken, forward result
    correct, and rollback by restoring the backup.
- **Wire contract:** the Gateway protocol contract checks (`protocol-fixtures`,
  `verify-gateway-protocol-contract.py`, `RealGatewayPiBoundaryTests`) become
  per-feature contract locks. A wire change must update both ends in one slice
  and pass the lockstep mismatch refusal journey.

### 6.6 iOS UI locks (V5-UI) and lock sensitivity
- **Screen-state catalog:** each feature manifest lists hosted-fixture states.
  For each state:
  - an **accessibility-tree snapshot** (element type, identifier, label, value,
    traits, frame rounded to points), which must match exactly;
  - a **screenshot diff** at a tight perceptual tolerance on one pinned
    simulator model and OS, with animations off, a fixed clock, locale and
    time zone, and default plus one large Dynamic Type size.
- Interaction journeys (scroll continuity, composer, keyboard, focus, sheets)
  remain XCUITests and are part of the lock set.
- **Golden storage:** text a11y snapshots are committed. Screenshot goldens are
  committed as compressed PNGs for a budgeted state set (≤ ~80 states). The
  final decision is in slice 0.9 after measuring size and determinism.
- **Mac:** wizard and menu a11y snapshots use the same pattern.
- **Known-bad:** each lock records, at creation, a temporary injected change
  that makes it fail. The change is reverted and the evidence kept in the issue.
- **Sensitivity:** at each milestone, sample mutations for kernel, protocol and
  each touched module. TS uses an evaluated mutation tool (Stryker candidate,
  decided in 0.10); Swift uses a scripted sampled set. Report the detection
  rate against target M1.

### 6.7 Structure checkers (V5, V6, V8, V9, V10)
- **V5 Layer/reference checker.**
  - Gateway: TS import graph checked against manifest layers and `dependsOn`.
  - iOS: folder/feature reference graph from the index store.
  - Mac: same as iOS.
  - The baseline file lists today's violations. It can only shrink, and new
    violations fail.
- **V6 Budget checker.** File-size (500) and doc budgets, with the
  per-manifest exception list as a ratchet.
- **V8 Ledger.** `scripts/tron work ledger` compares `git ls-files` with
  manifest ownership and with module-issue checklists (via GitHub). It reports
  unowned, unchecklisted, double-claimed and unaudited files, and keeps audit
  state across renames with `--sync <module-issue>`.
- **V9 Metrics.** See §3.
- **V10 Moved-lines report.** `git diff --color-moved` with indentation-tolerant
  matching, summarized as moved / changed-in-move / new / deleted lines per
  file. A `move` commit must show only declared edits. Reviewers read only the
  non-moved lines.

---

## 7. Phases and milestones

The phases overlap. After M0, work in different phases runs in parallel on
**disjoint owners**, within the 4-worker and one-heavy-iOS-job limits. Order
inside a phase follows dependencies, not the list order.

### Phase 0: Foundations (no production behavior change) → **M0**
| # | Slice | Output | Depends on |
|---|---|---|---|
| S0 | **Bootstrap** (steward) | This plan committed as `docs/restructure/plan.md`; `restructure` label; master, Phase and Phase 0 Area epics; Appendix A filled (§14.3.1) | none |
| C | **Census** (read-only) | In-flight work table and dispositions; maintainer decisions on claims and feature pauses (§14.4) | S0 |
| 0.1 | **Charter** | AGENTS.md rewritten as a check-backed charter of ≤ 150 lines. Encodes: this plan's invariants, kernel contract tests allowed, locks mandatory for restructure slices, the feature pause, docs policy, size budgets, and evidence brevity. CONTRIBUTING folds in. **Requires the maintainer's approval.** | S0 |
| 0.2 | **Backlog triage** | Every open issue is closed, kept, or re-parented. #1264/#224/#1285/#629/#1102/#781 are superseded with pointers. Worktree and branch audit uses the housekeeping skill, and the maintainer approves any deletion. Outputs: a protected-work list and the feature-pause list. Starts with the §14.3 supersessions, then the remaining backlog. | C |
| 0.3 | Metrics tool | `scripts/tron metrics` (+`--compare`); baseline JSON recorded | S0 |
| 0.4 | As-is ownership | `module.json` for current logical owners (big directories split by file list); ownership-completeness check | 0.3 |
| 0.5 | Module issues | Scoping workers create the Area and Module issues with full file checklists (§9); ledger tool V8 | 0.4 |
| 0.6 | Layer checker | V5 for Gateway TS plus baseline ratchet; iOS/Mac index-store reference graph plus baseline | 0.4 |
| 0.7 | Budget checker | V6 plus exception baseline | 0.4 |
| 0.8 | Gateway lock framework | V3 generalizing `sdk-behavior-trace`; first **kernel** locks: prompt/stream, steer, abort, compaction, reconnect snapshot, subagent, settings change, extension UI | 0.4 |
| 0.9 | iOS UI lock framework | a11y plus screenshot locks over hosted fixtures; golden-storage decision; first locks on smoke, chat and settings states | 0.4 |
| 0.10 | Persisted, wire and sensitivity | V4 corpus for all stores; wire contract locks; mutation-tool evaluation | 0.8 |
| 0.11 | `scripts/tron verify` | V2 orchestration, selection and report; V10 moved-lines | 0.6–0.10 |

**M0 exit:**
- the charter is approved;
- every tracked file is owned and checklisted;
- baselines are recorded;
- `verify --all` passes twice identically on `main`;
- every lock has known-bad evidence.

No Stable handoff is needed, because there is no runtime change.

### Phase 1: Delete and decompose prose (fast wins, lowest risk) → **M1**
- Delete dead code, dead tests, stale plans and research prose, retired
  machinery residue, unused scripts and exports, and stale fixtures. This
  absorbs the remaining #1285/#797/#399 scope. Each deletion carries a
  surviving oracle.
- **Doc decomposition first.** Docs are the #1 conflict magnet. Split Gateway
  README, iOS `architecture.md` and `development.md`, `observability.md`,
  `home.md` and `settings-model.md` into module READMEs placed beside today's
  owners. Generated indexes replace hand-edited tables.
- Relocate hosted fixtures out of `Sources/App` (a move only).
- **M1 exit:** docs −50% or more; hotspot list free of docs; a Stable handoff
  if any shipped code changed.

### Phase 2: Gateway kernel → **M2** (highest risk; independent review on every slice)
1. **K-0 design** (≤ 300 lines). Covers:
   - kernel primitive list (K1–K8) and the port interfaces;
   - the module host contract and module descriptor;
   - the Pi seam surface and patched-API inventory;
   - placement of Home's generic delegation pieces versus its policy.

   **The maintainer reviews this.**
2. **Pilot module:** move one small capability end to end (candidate:
   notifications or apps) into `modules/` using the descriptor. Measure the
   registration footprint, locks and navigation. Adjust K-0 if needed.
3. **Kernel extraction:** carve `RuntimeSlot` and `RuntimeRegistry` into
   `kernel/{run,session,projection,delegation,host}`. Invert Home, settings,
   provider and extension reach-ins into ports.
4. **Pi seam:** route every runtime `@earendil-works/*` import through
   `kernel/pi`, with a layer rule that forbids it elsewhere.

**M2 exit:**
- the kernel imports no module;
- zero layer violations inside `kernel/`;
- no kernel file over 500 lines;
- `RuntimeSlot` and `RuntimeRegistry` are gone as god objects;
- full locks pass;
- milestone mutation sensitivity is reported;
- **Stable handoff plus 1 day of use.**

### Phase 3: Gateway modules, transport and contracts → **M3**
- Move every capability into `modules/<m>` with descriptor, contract, README,
  locks and tests.
- Split `GatewayService` into module-registered RPC handlers and
  `protocol/types.ts` into per-module contracts.
- Reduce `GatewayServer` to transport and `gateway-main` to the module list.
- Split large tests by journey along with their modules (for example the
  registry test's 13k lines).
- **M3 exit:** zero Gateway layer violations; zero Gateway files over 500 lines
  (or recorded exceptions); registration ≤ 1 line per module;
  **Stable handoff.**

### Phase 4: iOS → **M4** (UI-risk; independent review for State/UI slices)
- Reduce `AppModel` to composition plus `Kernel/`.
- Move features into `Features/<Name>/{State,UI}`.
- Split `ChatView`, `SessionPresentationStore`, `ComposerDraftCoordinator` and
  `GatewayClient` by cohesive operation.
- Make per-feature wire models mirror the Gateway contracts.
- Drive the reference ratchet to zero.
- Promote clean features to Swift modules **when matched build measurements
  allow** (absorbs #224).
- **M4 exit:** zero reference violations; no file over 500 lines (or
  exceptions); all UI locks identical; **device install plus Stable handoff
  plus 1 day of use.**

### Phase 5: Mac, relay, tooling, work tooling, skills → **M5**
- Mac and relay: manifests, audit, budgets, locks.
- `scripts/` and `tools/` pruning and grouping.
- Simplify the work tooling to what this tracking model needs, keeping every
  safety property (never discard unmerged work).
- Reduce the skills to the few recurring procedures. Policy and evidence
  scripts lose their retired-machinery residue.

### Phase 6: Test catalog and compiler boundaries → **M6 = epic exit**
- **Journey catalog:** each capability has one to three named journeys, its
  locks, and its contract tests. Overlapping or implementation-coupled tests
  are pruned once an oracle is proven.
- **Compiler boundaries:** TS project references for platform, contracts,
  kernel, modules and transport, plus the remaining Swift module promotion, each
  with measured build cost.
- **Epic exit:** every §3 target is met or carries an explicit exception the
  maintainer approves; the ledger is 100% `done`; final Stable handoff.

---

## 8. Slice protocol (worker playbook)

### 8.1 Before editing
1. Read the charter, the epic summary, your **module issue**, and the module's
   README and manifest. Don't read the whole repo.
2. `scripts/tron work start <slice-issue> --area <owned paths>`.
   Check `scripts/tron work status` for overlaps.
3. Post the **announcement** (Appendix C) in the module issue: exact files,
   change type, locks to run, and risk class.
4. Baseline: `scripts/tron verify --module <m>` on your base. If it fails on
   base, stop and file a bug. Don't fix unrelated breakage inside the slice.

### 8.2 Change
- One change type per commit (§4.2.4). Prefer a `move` commit followed by a
  `simplify` commit.
- Move complete cohesive operations: helpers, local types and invariants
  together. Keep admission, serialization, cancellation and cleanup with their
  authority.
- Update the manifest (`owns`, `dependsOn`), README, tests and the checklist
  path in the same slice.
- If you touch behavior without a lock, stop: the next slice is the lock slice.

### 8.3 Verify and land
1. `scripts/tron verify --changed`. Goldens must be unchanged.
2. Every `move` commit needs a clean moved-lines report.
3. Every deletion needs its surviving oracle plus known-bad evidence.
4. `scripts/tron metrics --compare <base>`.
5. Review if the slice is risk-class (§8.4).
6. `git fetch && git rebase origin/main`. Rerun **only** verify sets
   invalidated by the integrated diff. Kernel or contract changes from others
   mean `verify --all`.
7. `git push origin HEAD:main`. Never force.
8. Close with the evidence template (Appendix D). Update the module checklist
   states (`ledger --sync`).

### 8.4 Risk classes (fresh-context, read-only reviewer before landing)
Review is required for slices that touch:
- the kernel;
- contracts or the wire;
- persistence or migrations;
- security, auth or trust;
- concurrency or lifecycle (admission, cancellation, shutdown, receipts);
- iOS State or UI;
- the Mac installer or launcher.

A pure `move` with a clean moved-lines report and passing locks in a non-risk
module self-lands.

The reviewer checks:
- the moved-lines report;
- semantic edits;
- lock selection completeness;
- ownership and cleanup;
- the hazards in §11.

The reviewer reports defects; it is not a landing authority.

### 8.5 Stop conditions
Listed in §4.2.12. Stopping is a valid outcome. Leave a short comment and keep
your branch.

---

## 9. GitHub tracking model

### 9.1 Hierarchy
GitHub sub-issues allow nesting 8 levels deep and up to 100 children per parent.
That is enough room, so no issue per file is needed.

```text
[epic] Multi-agent-native restructure (master)            level 1
 ├─ [epic] Phase N: <name>                                 level 2
 │   ├─ [epic] Area: <package/layer>  (e.g. Gateway kernel) level 3
 │   │   ├─ Module: <module id>   (file checklist)         level 4  kind:maintenance
 │   │   │   ├─ Slice: <type> <what>                       level 5  claimable
 │   │   │   │   └─ (optional) sub-slice / follow-up       level 6
```

- Phase and Area issues carry the `epic` label. The work tooling already
  excludes `epic` from claims, so only Module and Slice issues are claimable.
  Module issues are claimed only by **scoping** workers.
- Labels: the existing `kind:` and `area:` labels, plus one new `restructure`
  label for filtering. It is added through `work bootstrap` in slice 0.2.
  No phase labels: the parent link carries the phase.
- Dependencies use `work issue block`, for coordination only (never a landing
  lock).

### 9.2 Module issue = the audit ledger
- The body holds the module's purpose, its target location, its locks, and a
  **checklist of every file it owns**:
  `- [ ] `path` — state`.
- States:

  | State | Meaning |
  |---|---|
  | `unreviewed` | not yet read |
  | `keep` | stays as is |
  | `delete` | to be removed |
  | `simplify` | to be reduced in place |
  | `move→<dest>` | to be relocated |
  | `done` | final location, within budget, fully reviewed |

- "Fully reviewed" means substantive types, functions, state, branches,
  failure paths, callers and cross-file effects were inspected (the code-health
  skill's ledger standard).
- `scripts/tron work ledger` proves:
  - every `git ls-files` path is in exactly one module issue;
  - every module issue lists only real files;
  - state rolls up per module, area, phase and epic.
- Issue bodies cap at 65,536 characters. Modules with more than ~350 files
  split into sub-modules.

### 9.3 What the master epic body holds
It stays short and current:
- the decisions table (§0);
- the targets (§3);
- a link to the charter;
- the current milestone, plus a metrics delta table regenerated by
  `scripts/tron metrics`;
- the active claims, from the dashboard;
- decisions awaiting the maintainer.

No running history; history lives in child issues.

---

## 10. Scoping playbook (for workers who create the nested breakdown)

A scoping worker owns one **Area** or **Module** issue and produces slices.
Other workers then execute them without re-deriving context.

1. **Inventory.** Run `scripts/tron work ledger --module <m>` to get the owned
   files. Read each one fully, and record states in the checklist.
2. **Trace operations, not folders.** For each capability the module serves,
   follow one real operation:
   - entrypoint → admission → state owner → observable result → retirement;
   - the failure, cancellation and restart paths;
   - every cross-module and dynamic edge (registration, spawned processes,
     fs-read resources, generated consumers).

   Put the edges in the manifest's `dependsOn` and `dynamicEdges`.
3. **Map to target.** Give each file a destination (§5) or a deletion with a
   named oracle. Name the kernel ports the module will need, and raise any
   missing port to the K-0 owner instead of inventing one.
4. **Locks first.** List the capabilities and screen states. Check that their
   locks exist (`verify --module`). Missing locks become the first slices.
5. **Cut slices.** Each slice:
   - is one owner and one change type;
   - takes ≤ ~1 working session;
   - changes ≤ ~800 lines (moves may be larger if the moved-lines report is
     clean);
   - can land independently;
   - has its locks named;
   - has a risk class.

   Order them: locks → deletions → moves → simplifications → budget cleanup.
   Record `blocks` links only for true ordering.
6. **File slices** as sub-issues using Appendix B. Each is self-contained: a
   worker should not need to read the scoping thread.
7. **Close the scoping slice** once every file has a state other than
   `unreviewed` and every non-`keep` state has a slice. List the
   cross-boundary questions you couldn't resolve as explicit issues (never as
   prose buried in a comment).

---

## 11. Risks and hazards (what reviewers look for)

| Risk | Mitigation |
|---|---|
| A hidden behavior change in a "mechanical" TS move. Examples: module evaluation order or top-level side effects; `instanceof` across duplicated classes; changed `this` binding; async ordering when a helper gains an `await`. | Moved-lines report; no top-level side effects in moved modules; locks; review for kernel/lifecycle |
| Swift moves change `private`/`fileprivate` reach, actor isolation (`@MainActor` inference), or initialization order. SwiftUI extraction changes `@State` scoping, view identity or animation. | UI locks (a11y plus screenshot) plus interaction journeys; UI-class review; a rule that extracting a view must not change the hierarchy or state ownership in a `move` commit |
| Locks with blind spots. | Known-bad at creation, milestone mutation sensitivity, real-use Stable handoffs, catalog completeness via the ledger |
| Flaky locks erode trust. | 5/5 determinism before adoption; one owned normalization; a fixed clock and seed; flakes are bugs fixed at the lock, never retried |
| Conflicts with ~556 commits/week. | Small slices, announcements, docs decomposed first (biggest hotspot), feature pause in hot owners, fast landing |
| Kernel design is wrong. | K-0 review by the maintainer; a pilot module before mass migration; ports can change until M2 |
| The selector misses dynamic consumers (the #1259 lesson). | Declared `dynamicEdges`; unknown means all; kernel/contract/platform changes mean all |
| Process bloat returns: long evidence, ceremony. | ≤ 25-line closing template; charter ≤ 150 lines; no evidence in docs; metrics generated |
| Host load or swapping. | ≤ 4 workers; one heavy iOS job; owned cleanup; measure swap before heavy runs |
| A Pi SDK upgrade (#1025) lands mid-epic. | Schedule it before Phase 2 starts or after the K8 seam lands; never during kernel extraction |
| −40% LOC pressure tempts unsafe deletion. | Ranking: size never outranks confidence or locality; every deletion needs an oracle |

---

## 12. Open decisions (resolved inside named slices, with a recommendation)

| Decision | Slice | Recommendation |
|---|---|---|
| Manifest format | 0.4 | `module.json` beside the README |
| Screenshot golden storage and size budget | 0.9 | Commit compressed PNGs for ≤ ~80 states; text a11y snapshots for everything |
| iOS/Mac reference-graph technique | 0.6 | Xcode index store from the existing Test build; fall back to a swift-syntax symbol scan |
| Mutation tool | 0.10 | Evaluate Stryker for TS on kernel only; scripted sampled mutations for Swift |
| Kernel ports and module descriptor | K-0 | Maintainer review |
| Hosted fixtures as a separate target | Phase 1/4 | Only if the build measurement is neutral or better |
| Which feature epics pause (e.g. #1192 computer use, #1156 Swift apps) | 0.2 | Pause where they touch hot owners; continue in leaf modules |
| Work-tooling simplification scope | Phase 5 | Keep start/land/close/ledger/dashboard; re-evaluate release/handoff/recover against actual use |

---

## 13. Execution and roles

- **Coordinator: Home** (runbook in §14). Home has no shell or GitHub write
  access, so it acts through dispatched workers: steward, census, scopers,
  slice workers, reviewers and the milestone preparer. Home:
  - keeps the epic body current;
  - dispatches slices (at most 4 concurrently, disjoint owners, one heavy iOS
    job);
  - schedules milestone handoffs;
  - surfaces decisions to the maintainer.

  It never assigns merge turns or retries pushes for workers.
- **Scoping workers:** own Area and Module issues (§10).
- **Slice workers:** own one slice (§8).
- **Reviewers:** fresh context, read-only, for risk-class slices (§8.4).
- **Maintainer:** approves the charter (0.1), deletions of unmerged or live
  work (0.2), the K-0 kernel design, migrations, and exceptions to the
  targets. Performs the milestone Stable/iPhone handoffs and uses each for
  a day (§14.7, §14.8).

---

## 14. Home runbook (Home owns execution of this epic)

Home is the coordinator. This section is complete on its own: a Home activation
that has read §0–§13 and this section knows what to do next.

### 14.1 Facts about Home's tools that shape this runbook
- **Home has no shell, Git or GitHub write access.** Its tools are `delegate`,
  `task`, `read_file`, `session_search`/`session_read`, `ask_user`, `notify`,
  `display`, `web_*`, `knowledge`, `settings`, `profile`, `memory_search`,
  `date` and `zoom`.
  - Every issue mutation, Git operation, census and metric is done by a
    **worker** Home dispatches.
- `read_file` reads only inside explicitly trusted projects. The repository is
  trusted, so Home reads this plan at `docs/restructure/plan.md` in the primary
  checkout.
  - The primary checkout lags `main` until a worker fast-forwards it. If a
    section looks stale, ask the steward to sync the primary (ff-only, clean
    only) or quote the section.
- `delegate` takes a stable `taskId`, an `intent` (≤ 64 KiB), a trusted
  `target` (the repository root) and a `title`. Workers create their own
  worktrees with `scripts/tron work start`.
  - Workers have project tools, `report` and `checkin`, and may launch **their
    own** subagents (scouts, reviewers).
  - They cannot schedule, attach missions, or control runs they didn't start.
- The `task` tool (`list`, `status`, `steer`, `interrupt`, `stop`, `resume`,
  `rename`) acts **only on Home-dispatched tasks**. Sessions started elsewhere
  (the maintainer's chats, other harnesses) cannot be steered by Home. They are
  coordinated through issue comments (posted by a worker) and the maintainer.
- The Gateway enforces no worker cap. **This epic's own policy caps it**:
  - at most 4 concurrent restructure workers, plus at most 1 steward;
  - at most one simulator-heavy iOS job (build/test/UI-lock) in the epic at a
    time;
  - reviewers and read-only census or scoping tasks count toward the 4 if they
    run builds.

### 14.2 Standing roles Home dispatches
| Role | Task ID pattern | Lifetime | Does |
|---|---|---|---|
| **Steward** | `rs-steward-<n>` | one bounded session per batch of issue work | All GitHub writes for the epic: create, edit, parent, labels, close, comment. Epic body refresh. Metrics snapshot. Ledger sync. Supersession of old epics. Census. Primary checkout ff-sync. Never edits product code. |
| **Census** | `rs-census-<date>` | one-shot, read-only | Inventory of live and in-flight work (§14.4) |
| **Scoper** | `rs-scope-<module>` | one Module or Area issue | §10 playbook; files slice issues through `work issue create` (it may do its own issue writes for its module's subtree) |
| **Slice worker** | `rs-<issue>` | one slice issue | §8 protocol; lands on `main` |
| **Reviewer** | `rs-review-<issue>` | one-shot, read-only | §8.4 review of a slice branch head; reports defects. Never edits or lands. |
| **Milestone preparer** | `rs-m<k>` | one-shot | Prepares a clean Debug candidate plus the handoff checklist for the maintainer (§14.8). Never touches Stable. |

Every brief starts from the matching template in Appendix E. Fill in the issue
numbers. Keep briefs self-contained: never rely on the worker reading Home's
chat.

### 14.3 Kickoff sequence (first activations after approval)
Do these in order. Each numbered step is a `delegate` unless it says *ask*.

1. **S0 bootstrap (steward).**
   - Commit this plan (from the internal workspace draft) to
     `docs/restructure/plan.md`. Fill in Appendix A's issue map after step 2.
   - Add the `restructure` label to `.github/work.json` and run
     `work bootstrap --apply`.
   - Create the master epic and the Phase 0–6 epics, plus the Phase 0 Area
     epics (Gateway, iOS, Mac, relay, tooling, docs, process).
   - Record the issue numbers in the plan's Appendix A.
   - Report the numbers to Home.
   - *Gate: none. The plan was approved by the maintainer when they handed it
     to Home.*
2. **Census (read-only).** §14.4. It reports the in-flight table and proposed
   dispositions.
3. **Ask the maintainer** (`ask_user`, one form):
   - which stale or foreign claims to release (`work release`, which retains
     every local file and branch);
   - which feature epics pause;
   - whether the #1264 integration worker and the #1285 workers continue under
     the new epic or stop.

   Put the census table in the question context. Default to *continue* for any
   live worker.
4. **Supersession (steward).** Apply §14.5 for #1264, #224, #1285, #629, #1102
   and #781, plus the maintainer's answers from step 3.
5. **Charter 0.1 (slice worker).** Draft the AGENTS.md charter on a branch,
   **without landing**. Then *ask* the maintainer to approve it, showing the
   diff summary and key rules (use `display` for the rendered draft). On
   approval, the worker lands it.
6. **Phase 0 tooling in parallel** (≤ 4): 0.3 metrics → 0.4 ownership →
   {0.6 layer, 0.7 budget, 0.8 Gateway locks}, then 0.9 iOS locks (heavy),
   0.10, 0.11. Respect the "Depends on" column in §7.
7. **Scoping:** once 0.4 lands, dispatch scopers for Module issues (0.5),
   ≤ 2 at a time. Scoping is read-heavy, and its builds count toward the cap.
8. **M0 check** (§14.8). Then open Phases 1–4 on disjoint owners.

### 14.4 Coordinating existing workers (census procedure)
The census worker (read-only, isolated `HOME`/`TMPDIR` for anything it runs)
produces one table, which it posts as a comment on the master epic and returns
in its report:

1. **Sources:**
   - `scripts/tron work dashboard --json <tmp>` (in-progress, stale, blocked,
     orphans, disagreements);
   - `scripts/tron work status --json`;
   - `git worktree list --porcelain`;
   - for each worktree: dirty state, unpushed commits relative to `origin/main`,
     and last commit time;
   - `scripts/tron dev status` (who owns the Debug Gateway).
2. **Liveness:** liveness is never inferred from a claim.
   - Home cross-checks each claim's session with `task list` (Home-owned) and
     `session_read`/`session_search` (other sessions): recent activity or a
     running state.
   - Unknown stays unknown. It never becomes "dead".
3. **Overlap:** intersect each in-flight branch's changed paths
   (`git diff --name-only origin/main...<branch>`) with:
   - the hot-owner list (§4.2.9);
   - Phase 0/1 targets;
   - other in-flight branches.
4. **Disposition proposal per item:**
   - **continue** (bug fix or out of scope);
   - **coordinate** (overlaps an upcoming slice: sequence it, and its owner
     announces in the module issue);
   - **fold in** (the work becomes a restructure slice);
   - **park** (the feature pause applies; keep the branch);
   - **release** (stale, owner absent, nothing unpublished beyond what release
     backs up). Release needs maintainer approval.
5. **Never:**
   - stop, steer or edit a foreign worker;
   - delete a branch or worktree;
   - reset the primary checkout.

   Stopping a *Home-owned* task requires Home's own decision and a reason.
   Releasing another session's claim requires the maintainer.

**Snapshot at plan time** (refresh with the census; this list goes stale fast):
27 in-progress claims, 14 flagged stale by the dashboard: #330, #394, #395,
#626, #825, #833, #885, #944, #1016, #1112, #1240, #1241, #1242, #1244. Nine
are blocked, and #1025 has a claim/status disagreement. #1264's integration
worktree and three #1285 worktrees exist. #1120 (Gateway exit hang) is active
in the primary checkout. Overlap with hot owners is likely for #1240/#1241/#1242/
#1244 (registry/settings/Home test types), #825, #1016, #892 and #585
(sessions/Home), and #394/#395/#1333 (iOS State/UI).

**Messages to in-flight Home tasks** (`task steer`, once, short):
> Epic #E now governs restructuring. Bug fixes continue. Before editing any of
> [hot owners], announce the exact files in the owning module issue, or in
> #E if none exists yet. New features in those owners pause. Finish and land
> your current scope normally. Plan: `docs/restructure/plan.md`.

For foreign sessions, the steward posts the same text as a comment on their
issue.

### 14.5 Issue management recipes (executed by the steward)
All writes go through `scripts/tron work …`, which runs the privacy guard and
writes an audit. Reads may use `gh`.

| Operation | Commands |
|---|---|
| Create an epic | `work issue create --type epic --title T --body-file F --area <area>…` then `work issue parent <new> --epic <parent>` |
| Create a module or slice | `work issue create --type task --kind kind:maintenance --area <area> --title T --body-file F --status Ready --priority P2`, then `work issue labels <n> --add restructure`, then `work issue parent <n> --epic <parent>` |
| Order | `work issue block <later> --blocked-by <earlier>` (coordination only) |
| Supersede an epic | 1) `work issue edit <old> --body-file F`: prepend "Superseded by #E — <one line>" and keep the remaining-scope text. 2) For each open child: `work issue parent <child> --epic <new parent> --replace-parent` (or close as `not_planned` with a pointer if obsolete). 3) `work issue close <old> --reason not_planned --comment-file F` (epic closure requires zero open children). |
| Update the master epic body | Regenerate it from the §9.3 template with fresh `scripts/tron metrics` output and the dashboard. Replace the whole body (`work issue edit`). No appended history. |
| Ledger sync | `scripts/tron work ledger --sync <module-issue>` after each landed slice in that module. Slice workers do this themselves; the steward runs a full `ledger` check weekly and at milestones. |
| Comment | `work comment <n> --body-file F` |

A nonzero GraphQL exit is **uncertain**, not failed. Inspect remote state
before retrying, and never replay blindly (work README).

### 14.6 Dispatch loop (every Home activation that touches the epic)
1. `task list`: settle reports, read new check-ins, and handle any
   `needsAttention` first.
2. For each finished slice task, check its report against the Appendix D
   template:
   - verify output present;
   - goldens unchanged;
   - metrics delta;
   - landed SHA.

   If anything is missing, `resume` with a one-line request. Don't accept
   prose.
3. **Capacity:** count running restructure tasks (≤ 4) and heavy iOS jobs (≤ 1).
4. **Pick next slices:** `Ready` slices whose blockers are closed, whose owner
   module has no other active slice, and whose paths don't overlap any active
   claim (`work status --area`).
   - Prefer, in order: locks, then hotspot-reducing slices (docs, hot owners),
     then deletions, then moves, then simplifications.
   - A slice in a risk class gets a reviewer task as soon as its worker reports
     a branch head ready for review. The worker lands only after the review
     reports no blocking defect (the worker owns fixes).
5. **Every ~10 landed slices or weekly:** dispatch a steward refresh (epic
   body, metrics, ledger).
6. **Stuck work:**
   - No check-in for 90 minutes on a running slice: `task status`, then one
     `steer` asking for the current step.
   - A second silence of 60 minutes: `interrupt`, then ask for a checkpoint
     commit plus a report.
   - Never stop a worker mid-landing without a reason.
7. Notify the maintainer only for decisions (§14.7) and milestone handoffs.
   Batch questions into one `ask_user` form.

### 14.7 Decisions that belong to the maintainer (always `ask_user`)
- Charter 0.1 approval.
- The K-0 kernel design.
- Each migration slice.
- Any golden change.
- Releasing another session's claim.
- Deleting any branch or worktree with unmerged or uncertain work.
- Pausing or resuming feature epics.
- Exceptions to §3 targets.
- Adding a dependency (e.g. a mutation tool).
- Milestone handoffs (the maintainer performs them).
- Anything involving Stable, the installed app, production or a physical
  device.

Home decides everything else: slice order, scoping splits, retries, reviewer
dispatch, steering its own tasks, and closing obsolete restructure issues.

### 14.8 Milestones and handoffs
1. Dispatch a steward to compute the milestone's exit criteria from §7 using
   `scripts/tron metrics` and `verify --all` (run twice; outputs must be
   identical).
2. If the exit criteria are met and shipped code changed, dispatch the
   milestone preparer. It:
   - checks `scripts/tron dev status` and coordinates if another worktree's
     candidate is running;
   - builds a **clean** Debug candidate from `main`;
   - runs the smoke journeys;
   - writes a ≤ 20-line handoff checklist with the exact commands the
     maintainer runs (`scripts/tron dev handoff --tailscale`, then promote in
     iOS), what to use for a day, and how to roll back.
3. `notify` plus `ask_user`: "M<k> ready for handoff". Wait for the
   maintainer's confirmation of one day of use before starting the next
   risk-class phase. Non-risk slices may continue meanwhile.

### 14.9 Home's own hygiene
- At each activation that acts on the epic, re-read §14 and the master epic
  body (via a steward report or `read_file` of the plan). Don't rely on chat
  memory for numbers. Appendix A's issue map is the source of truth for issue
  numbers.
- Keep briefs short and self-contained. Paste the relevant template, never
  history.
- Prefer the worker model queue. Choose an explicit stronger model, with a
  reason, only for kernel (Phase 2) slices, K-0 design and reviewers of
  risk-class slices.
- Record a terse decision line in the master epic (via the steward) whenever
  the maintainer decides something. Decisions never live only in Home's chat.

---

## Appendix A. Issue map (filled once by S0; edited only by the steward)

| Node | Issue |
|---|---|
| Master epic | #E = _TBD_ |
| Phase 0 Foundations · 1 Delete & docs · 2 Kernel · 3 Gateway modules · 4 iOS · 5 Mac/relay/tooling · 6 Catalog & boundaries | _TBD each_ |
| Phase 0 areas: Process · Tooling · Gateway locks · iOS locks · Ownership/ledger | _TBD_ |
| Superseded epics | #1264, #224, #1285, #629, #1102, #781 → closed, children re-parented |

### Master epic body template (regenerated in full; never appended)

```markdown
## Outcome
Multi-agent-native restructure with no user-observable change. Plan:
`docs/restructure/plan.md` (decisions §0, targets §3, invariants §4, Home runbook §14).

## Milestone
M<k> <name> — <state>. Next: <one line>.

## Metrics (scripts/tron metrics, <sha> vs baseline dc289f47e)
| Metric | Baseline | Now | Target |
|---|---|---|---|
| Hand-written LOC | 434k | … | ≤260k |
| Files >500 lines | 133 | … | 0 (+exceptions) |
| Layer violations / dir cycles | …/23 | … | 0/0 |
| Hotspot share (30d) | 44% | … | <10% |
| Lock coverage / determinism | 0% | … | 100% / 5-of-5 |
| Slice verify p50 | — | … | <5 min |
| Ledger done | 0/1153 | … | 100% |

## Active
<dashboard rows: slice issue · worker task · owner module>

## Waiting on the maintainer
<bullets or "none">

## Decisions
<date — decision — issue link, one line each, newest first, max 15; older ones move to the plan's §0 table>
```

## Appendix B. Module and slice issue bodies

### Module issue
```markdown
Parent: <area epic>. Module: `<id>` · layer L<k> · target `<dest path>`
Owns capabilities: <list> · Risk class: <none|kernel|…>
Locks: <existing / missing → slice #…>
Manifest: `<path>/module.json`

## Files (ledger; states: unreviewed|keep|delete|simplify|move→<dest>|done)
- [ ] `path/a.ts` — unreviewed
- [ ] `path/b.ts` — unreviewed

## Edges
dependsOn: <modules/ports> · dynamicEdges: <registration, spawn, fs, generated>

## Slices
<sub-issues listed by GitHub; scoper keeps order via blocked-by>
```

### Slice issue
```markdown
Parent module: #<m>. Type: lock|delete|move|simplify|doc|migration|tooling.
Risk class: <none|kernel|contracts|persistence|security|lifecycle|ios-ui|mac-installer>.
Heavy: <none|ios-sim|mac>. Predicted paths: `<globs>`.

## Change
<exact operation(s); source → destination; what stays where; ports used>

## Proof
Locks/journeys: `<verify sets>`; known-bad: <what must fail if broken>.
For delete: surviving oracle `<test>` + known-bad.

## Done when
Goldens unchanged; `verify --changed` green with non-empty counts; moved-lines clean (moves);
metrics delta recorded; module checklist synced; owning README/manifest updated.

## Out of scope / stop if
<adjacent owners, protected paths, any golden diff>
```

## Appendix C. Announcement comment (module issue, before editing)
```markdown
**Slice #<s> starting** · type <t> · risk <r> · branch `<b>`
Files: `<exact list>` · Locks to run: `<sets>` · Expected land: <hours>
```

## Appendix D. Closing evidence (≤ 25 lines; `work issue close --comment-file`)
```markdown
**Landed** <sha> on main (base <sha>). Type <t>. Review: <none|#… no blocking defects>.
Change: <2–4 lines: what moved/was deleted/simplified, where>.
Verify: `scripts/tron verify --changed` → <runner: passed/total> … ; goldens unchanged.
Known-bad: <mutation> → failed as expected (restored).        # lock/delete/semantic slices
Moved-lines: <moved N / edited-in-move M (declared: renames/imports)>.  # moves
Metrics Δ: LOC prod/test/tool/docs <…>; files>500 <…>; violations <…>; hotspot <…>.
Ledger: module #<m> files <…> → done.
Residual: <unknowns, follow-up issues #…, or "none">.
Artifacts: test-results/verify/<sha>.json, test-results/metrics/<sha>.json
```

## Appendix E. Dispatch brief templates (Home → `delegate` intent)

Every brief starts with this **common header**, filled in:
```text
You are a Tron restructure <role> for epic #<E> (task <taskId>).
Read first, in order: AGENTS.md (charter), docs/restructure/plan.md §0, §4, §8 and
the section named below, then your issue #<n> and the module issue it links.
Rules that override your own judgment: plan §4 invariants and §4.2 process; never
touch Stable, the installed app, production or devices; ≤1 simulator-heavy job;
clean up everything you start; never git stash; never edit another worker's tree.
Send `checkin` at milestones and about every 30 min. End with `report` containing the
Appendix D evidence (or, if you stopped, the stop reason and your preserved branch/commit).
```

**E1 Steward (S0 bootstrap)** — plan §14.3 step 1, §14.5, Appendix A:
```text
Bootstrap the epic. 1) Copy the approved plan from the Tron internal workspace
files/multi-agent-restructure/plan.md into docs/restructure/plan.md on a docs branch (run the
privacy guard; it must contain no personal paths); land it. 2) Add label `restructure`
to .github/work.json; `scripts/tron work bootstrap --apply`. 3) Create master epic, Phase 0–6
epics, Phase 0 area epics per Appendix A; parent them; bodies from Appendix A/B
templates. 4) Fill Appendix A in the plan with the numbers; land. 5) Fast-forward the
primary checkout only if clean and strictly behind. Report the issue map. Do not
supersede old epics or touch any other issue yet.
```

**E2 Census** — §14.4. Read-only; post the table on #E; report proposed dispositions.

**E3 Steward (supersession / refresh / ledger)** — §14.5 recipe named in the brief, plus
the maintainer's decisions verbatim. Never edit product code.

**E4 Scoper** — §10 for module/area #<n>; create slice issues per Appendix B; keep the
module checklist complete; report the slice list with order and risk classes.

**E5 Slice worker** — §8 for slice #<n>. If locks are missing, stop and report that a
lock slice is needed (don't write behavior changes without locks).

**E6 Reviewer** — §8.4 for slice #<n> at branch `<b>` head `<sha>`. Read-only: the
moved-lines report, semantic edits, lock selection, ownership/cleanup, §11 hazards.
Report: blocking defects (with file:line and reason), non-blocking notes, and what
you could not verify. Do not edit, push or land.

**E7 Milestone preparer** — §14.8 step 2. Debug Gateway only; never handoff, update,
restart or promote Stable yourself.

**E8 Charter worker (0.1)** — rewrite AGENTS.md (≤150 lines) and fold CONTRIBUTING in,
encoding plan §0, §4, §6.2 mandatory-for-restructure, kernel contract tests, feature
pause list, docs policy, size budgets, evidence brevity. Preserve all safety rules
(Stable/prod, secrets, device/simulator leases, process cleanup, no stash) in intent.
Do not land: report the branch + a ≤40-line summary of rule changes for maintainer
approval; land only after Home relays approval.

## Appendix F. Glossary
- **Lock:** a recorded, normalized observation of behavior at a real boundary,
  with a golden, deterministic replay and a known-bad control.
- **Journey:** an end-to-end or integration test of a user capability.
- **Kernel contract test:** a real kernel with a faux model, asserting one
  port's invariant.
- **Owner/module:** the unit of files, claim, docs, verification and audit
  (`module.json`).
- **Hot owner:** a file or owner touched by most changes today (§4.2.9).
  Features there pause.
- **Slice:** one issue, one worktree, one change type, landed independently.
- **Steward:** the Home-dispatched worker that performs all epic issue
  bookkeeping.
- **Ratchet:** a recorded baseline that may only shrink.
