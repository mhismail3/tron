# First-principles structure plan (#2297)

This is the single structure plan. Each standing residue rule has its own owner: branch end-of-life in `.agents/skills/tron-work/SKILL.md`, epic closure in
`tools/work/README.md`, Mac rollback retention in `packages/mac-app/docs/development.md`, and scratch and
evidence aging in `tools/ownership/tidy.py`.

## Order and rules

The order is Musk's, applied at every step:

1. Name the need behind each thing and who owns it.
2. Delete what has no need.
3. Simplify what survives.
4. Make it faster.
5. Automate last, and only a step that has proved itself.

The end state is a clean, organized repository with nothing lost in fidelity and no regressions.

- Each slice of this program lands only with all three of:
  - fail-before/pass-after or behavior-preservation evidence;
  - a fresh reviewer's ACCEPT;
  - a green non-iOS `scripts/tron verify --changed`.
- No golden, timeout or tolerance edit may turn a red green. No waivers. Never remove the only guard of a
  behavior.
- iOS and Xcode work waits for #2285. Paths owned by #2279 and #2282 are off limits until those land.
- The following are Mohsin's call and go under [Decisions for Mohsin](#decisions-for-mohsin):
  - changes to persisted formats or bytes;
  - changes to wire output;
  - changes to user-visible capabilities;
  - replacing the manifest system, or changing what its manifests or cards must declare;
  - repository-wide convention changes;
  - removing a gate the charter requires.

  A slice that turns out to need one of these stops and adds a row. Everything else that is reversible
  and preserves behavior is decided and done here, for example deleting a manifest option that no
  manifest sets.
- A move updates its consumers in the same change (AGENTS.md "No unrequested compatibility").
- These slices are post-checkpoint work. They never gate #2173 (PRINCIPLES P9).

### Per-slice method

1. Read the module's card (`scripts/tron ownership --card`).
2. Probe its units (`scripts/tron probe`, [verdicts](../../tools/verify/README.md#removal-probes)).
3. Silent unit: delete it if nothing needs it; otherwise add the test that fails without it.
4. Cascade: make the failing check name what broke.
5. Precise: keep it.
6. Work bottom-up, leaves of the dependency graph first. The kernel, `AppModel.swift` and
   `runtime-registry.integration.test.ts` come last.

## Current state

Measured at `73545949a` with `scripts/tron metrics 73545949a` (sizes, cards, references),
`scripts/tron budgets 73545949a` (docs) and `scripts/tron ownership` (modules).

- **Size.** 488,623 hand-written lines (production 247,689, tests 183,567, tooling 40,514, docs 16,853).
  219 files are over 500 lines.
- **Modules.** 101 modules; 19 have a purpose line (18 full cards plus the root manifest).
  The 101 manifests total 2,397 lines, 817 of them card keys.
- **References.** 1,511 cross-module file references across 625 module pairs.
- **Layers.** The Gateway layer baseline is empty. The iOS baseline has 12 two-way and 7 upward pairs.
- **Docs.** 125 Markdown files (61 READMEs). 22 docs are over budget; none is over twice its budget.

A card today averages about 45 manifest lines. Carding every module the same way would mean about 4,500
lines of hand-kept, mostly derivable mapping. The plan below cuts mapping first.

## 1. Manifests

**Today.** There are 101 `*.module.json` files.

| Kind | Count | Who reads it |
|---|---:|---|
| Only `layer` and `owns: ["**"]` | 35 | the ownership check |
| Other `{layer, owns}` with explicit file lists, which split mixed directories | 13 | the ownership check |
| `dependsOn` (Gateway) | 29 | the layer check (`tools/layers/layers.py`) |
| Purpose cards (`purpose`, `interfaces`, `uses`) | 18 (`purpose` alone also in `root.module.json`) | `tools/ownership/cards.py` |
| `riskClass` | 5 | verify selection |
| `verify` | 6 | verify selection |

Programs that read manifests: ownership (`ownership.py`), cards (`cards.py`), layout (`layout.py`), verify
selection, layers, generated docs, metrics and the work tool. The optional `capabilities` key was
validated only by `ownership.py` and set by no manifest; its own slice removes it.

**What each guarantee needs.**

| Guarantee | Smallest thing that keeps it |
|---|---|
| Every tracked file has exactly one owner | A module root and its exceptions. A whole-directory module with only a layer is declared by its package manifest's `directories` entry instead of its own file, which removes the 35 trivial files and keeps every module id, layer and owner (folding them into the ancestor's module would merge layers). Explicit lists stay only where a directory is split. |
| Layer direction (Gateway, iOS) | `dependsOn` at module level. It is already the Gateway's declared edge, and `layers` derives the actual edges from the compiler and the Xcode index. |
| An agent knows what a module is for, who uses it and what breaks | A one-line `purpose`; dependents derived and printed by `scripts/tron ownership --card`; declared edges at module level; per-file interfaces only for entry points outsiders run (CLI, launchd, env, wire). |
| Test selection widening | Unchanged: `riskClass` and the L0–L2 rule. |

**Decided (M1).** Keep per-module manifests. Make ownership inherit from the nearest ancestor and
delete the 35 trivial manifests. Replace per-file consumer lists with module-level `dependsOn`, which the
reference scanner checks for every carded module, and keep per-file `interfaces` only for external entry
points. This is [decision M1](#decisions-for-mohsin): it changes the ownership and card conventions,
including the current rule of one manifest per module directory. Removing `capabilities` is not part of
M1: no manifest sets it, so removing it changes no manifest, no owner and no check result. It is the
reversible deletion of an unused option. If Mohsin wants the reserved field back, the slice reverts.

**Regression guard.** The ownership ledger (`--ledger`) must be byte-identical in path→module before and
after. Each card-check rule keeps its case in `tools/ownership/tests/test-cards.py`. The layer fixtures
in `tools/layers/tests/test-layers.py` must still fail on a planted upward import.

## 2. Agent instructions

**Today.** One root `AGENTS.md` (150 lines, the charter), 61 READMEs, 7 skills and 56 other Markdown
files.

- Several READMEs are module cards: what the module is, its interfaces and its invariants.
- Package `docs/` hold contracts and runbooks.
- `packages/ios-app/docs/performance-baseline.md` records measured numbers, which makes it evidence.
  It waits for #2285 with the iOS work.
- `.pi/prompts/test-suite-audit.md` and `.agents/skills/tron-home-audit/report.md` look like audits but
  are a prompt and a report template. They stay.

**Decided (M2).** Add a localized `AGENTS.md`, at most 150 lines, at each place an agent starts work:

- `packages/gateway/`
- `packages/ios-app/`
- `packages/mac-app/`
- `packages/push-relay/`
- `scripts/`, which also covers `tools/`

Each holds what an agent must know before editing there. Every fact keeps one owner: `AGENTS.md` takes
the module map and local hazards, and the package README or docs keep the human overview and contracts.
The superseded README sections are deleted in the same slice. Its contents:

- the module map (generated from manifests, like the existing generated doc blocks);
- the package's invariants and its test lanes, with exact commands;
- the local hazards: leases, frozen paths, sealed payloads.

Folder READMEs under 40 lines fold into their package `AGENTS.md`. Contract docs (`settings-contract.md`,
`connection-resilience.md`, `presentation-parity.md`, `architecture.md`) stay, as the targets their tests
cite. The root charter
stays the one place for rules that apply everywhere. This is [decision M2](#decisions-for-mohsin): it
changes a repository-wide convention.

**Regression guard:** `scripts/check-documentation-policy.py` (links and paths), `scripts/tron budgets`,
and `check-agent-policy.sh` asserts for each new `AGENTS.md`.

**Dangling references.** Gateway lock tests, test-support, `scenario-locks.md`, the Gateway README and the
ownership README cite sections §4.1, §5.6, §6.1, §6.4, §6.5 and §6.6 of a plan that no longer exists.
Repoint each citation to its current owner:

| Old citation | New owner |
|---|---|
| §6.4 scenario locks | `scenario-locks.md#locks` |
| Lock framework | `scenario-locks.md#framework` |
| §6.5 V4 store locks and §6.6 store mutation paths | `scenario-locks.md#persisted-stores-v4` |
| §6.5 V7 wire lock | `scenario-locks.md#wire-contract-v7` |
| §4.1 B3 (no silent migration on open), §4.1 B4 lockstep | the charter's "Architecture invariants" |
| §5.6 module README shape | the section list stated in place in `packages/gateway/README.md` |
| §6.1 "kernel ports are accepted once K-0 defines them" (ownership README) | Removed. Ports exist in code (for example `LineageRuntimePort`), but `ownership.py` never accepted a port name in `dependsOn`; the clause described a feature that does not exist. |

This needs no decision. `packages/ios-app/UITests/Locks/TronUILockTests.swift` (§6.6) waits for #2279.

## 3. Layout and naming

**Root (15 entries).** Every entry has an owner and a reader. Keep the frozen root list in
`root.module.json`.

**`scripts/` and `tools/`.** Do not fold `tools/` into `scripts/`. It would rewrite about 96 referencing
files for no agent gain, because `scripts/tron` is the front door.

- Keep `tools/<tool>/` as one directory per tool, with its tests and manifest.
- `scripts/` has 92 top-level files.
- A file leaves the top level only when its own test needs a home beside it, as `scripts/version/` and
  `scripts/models/` did. A probe or test proves the move. There is no blanket move.
- The layout guard keeps `scriptsTop` shrink-only.

**Names.**

| Kind | Convention |
|---|---|
| Python importable modules | snake_case (`tron_mac_replace.py`) |
| CLIs | kebab-case; suffixless when people type them (`tron-dev`) |
| Tests | `test-<unit>` or `<unit>.test.mjs` beside the unit |

The 11 snake and 72 kebab names already follow this split. No renames.

**`config/`.** Three files, each with one reader. Keep.

**`test-results/`.** Ignored; owned by `tidy` aging (14 days). Keep.

## 4. Untangling

**Production two-way module pairs: 32 of 464.**

- About 26 are dispatcher pairs. `scripts/tron` names the tools, and the tools name `scripts/tron` in their
  messages. These are fine.
- Two are false positives from the reference scanner reading strings (`"index.ts"`) and comments.
- The pairs that matter are `gateway-main`↔`home` and `package`↔`pi-sdk`, both composition. The runtime
  pairs (`run`↔`resources`, `run`↔`host`, `run`↔`projection`) appear only through tests and
  `test-support`.
- The Gateway layer baseline is empty.

**iOS.** `state` (L2) has five upward edges. That is #2296 Phase B, and it waits for #2282 and #2285.

**Values with more than one owner, to fix here:**

| Value | Today | Fix |
|---|---|---|
| Protocol version | `config/GatewayProtocol.json` is the contract. The Gateway, deploy helper, launcher, iOS and Mac copies are lockstep consumers checked by `scripts/gateway_protocol_contract.py`; the profiling driver's copy was not checked. | The contract check covers the driver too |
| Debug/Stable ports 9848/9847 | 39 files (`git grep -l '9848\|9847'`, excluding tests, `*Tests.swift`, Markdown and goldens; about 20 of them are iOS hosted fixtures) | #2296 item 18 |
| Host lock path | `host_lock.py`, plus documentary copies | Keep `host_lock.py` |
| `TRON_UI_LOCK_RENDERING` | read in shipped iOS code | #2296 item 16, after #2285 |

## 5. Standard components and patterns

| Area | Duplicates | One pattern | When |
|---|---|---|---|
| Gateway RPC | Module `RpcHandler` (`kernel/host/module-host.ts`) plus 168 `case`s in `transport/gateway-service.ts` | Module handlers. Move one method family per slice and extend the duplicate-method guard to the switch. | After the card and manifest slices; each slice has its RPC tests as guard |
| Gateway errors | 517 raw `throw new Error` in 113 files (`git grep -c 'throw new Error(' -- 'packages/gateway/src/*.ts' ':!*.test.ts'`); `publicError` turns each into code `internal` on the wire | `GatewayError(code)` on request paths | A converted site changes wire output: [decision W1](#decisions-for-mohsin) |
| JSON writes | `foundation/durable-json.ts` (30 non-test importers) plus about 14 inline temp→rename writers | `durableAtomicWriteJson` for durable state only | Per site: first decide whether the file is durable state or a disposable projection. The model-queue projection, for example, is serialized by its owner and rewritten on demand, so it keeps its light writer. Durable sites move one per slice, keeping their exact bytes; a byte change stops the slice and becomes a persisted-format decision row. |
| Logging | `GatewayLogger` plus 42 console/stdio sites | Logger, except CLI entry points | Per-file review |
| Python git and process helpers | `def git(` in 11 non-test files under `scripts/` and `tools/` (12 with `packages/ios-app/scripts/write-build-identity.py`); `start_new_session` process-group runners at 14 non-test sites in `scripts/` and `tools/` | Keep. Each wrapper is 4 to 6 lines and raises its own tool's error. Sharing them would add a cross-module edge to every tool for no gain, and their Git options differ. | — |
| iOS sheet, row and loading | `Tron*` primitives exist, but `SettingsRendererRow`, `ListRow` and three loading states overlap | The `Tron*` owners in `presentation-parity.md` | After #2285 and #2282 |

## 6. Gates and tests

Every gate is local; there is no hosted CI. `.github` holds only Dependabot.

- **Static verify steps.** Ownership, residue, budgets, documentation policy, generated docs, agent
  policy, privacy, diff check, Gateway typecheck, lint and layers. Each takes seconds
  (each run's step timings are in `test-results/verify/<sha>.json`).
- **Test lanes.** These dominate the cost: Gateway vitest runs minutes per selection, and the iOS build
  takes longer.
- **Rule for a gate or test.** It is removed only when another gate demonstrably catches the same break.
  The proof is a planted break that the survivor catches, plus reviewer ACCEPT.

Candidates:

| Gate | Finding | Next step |
|---|---|---|
| `check-agent-policy.sh` | Its path asserts may duplicate the documentation policy; its safety-phrase asserts are charter-mandated | Plant a broken skill path. If the documentation policy catches it, drop only the duplicated asserts. |
| `scripts/tron mutate` | Measured after 5d at 33165e9c4 (seed 1465). `kernel/run/run-markers.ts`: 6 of 6 sampled mutants killed by its 22 selected lock files in 331 s. `modules/apps/swift-app-store.ts`: 0 of 12 killed by its one lock file in 10 s, so that file's lock coverage is thin. It separates covered from thin lock coverage. | Keep on demand ([G1](#decisions-for-mohsin)). |
| `scripts/tron health` | Consumer is Home's improvement loop (`improvement-loop.md`), on demand | Keep. |
| `scripts/tron probe` | It found real defects, but costs minutes to hours per unit | Keep it on demand. Never schedule it. |
| Pre-commit privacy hook | Same script as the verify step, earlier (staged) | Keep both: verify covers commits made without the hook. |

## 7. Size

- **Large files.** There are 219 files over 500 lines.
  - The largest are tests: `runtime-registry.integration.test.ts` (13,385 lines) and
    `test-ios-test-infrastructure.py` (6,849).
  - The largest production files are `AppModel.swift` (5,502), `runtime-slot.ts` (4,821) and
    `runtime-registry.ts` (4,509).
  - Split these only by owner (change-together), last in the bottom-up order: kernel and `AppModel` at the
    end.
- **Dead code.** Name-based scans are unreliable here. Slice 5c removed the dead ones; the 10 Gateway
  exports still named only at their declaration are `compatibility-manifest.ts`, a compile-time
  exhaustiveness inventory that `tsc` checks; it is not dead.
  Delete only with a typecheck and lint pass plus a reviewer.
- **Dependencies.** No unused runtime npm dependency was found in the Gateway.
- **Docs.** 22 docs are over budget and none is over twice its budget. Folding the restructure docs and the
  ledgers shrinks this.

## 8. Other

| Area | Finding | Action |
|---|---|---|
| Versioning | `VERSION.env` → `scripts/version/tron-version sync` writes every mirror; `check` and its test guard them | Keep |
| Data directories (`~/.tron`, `~/.tron-dev`, `~/Library/Developer/Tron`) | Owned by the Gateway, `tron-dev` and the iOS lane respectively | Keep. Path literals in scripts consolidate with the ports work (#2296 item 18). |
| Hygiene | Weekly `tidy --prune` automation exists (a168d0f1) | Keep |
| Gateway test scratch | Leaked `/tmp/tron-gateway-tests-*` roots came from stop paths that sent SIGKILL. Measured with the runner: a group SIGTERM at 1, 8 and 20 s into a run removed its root within 0.06 s; only SIGKILL left one. | Every stop path sends SIGTERM first; no reaper. An outside SIGKILL, or a Vitest still tearing down when the grace ends, can still leave one root. |
| Residue | Agents run `scripts/tron tidy --here` before reporting; verify refuses untracked files and ignored files with no named writer | Keep |
| Backlog | 78 open issues: 39 bugs, 17 tooling | Not in scope here |
| Verify speed | Test lanes dominate; static steps take seconds (`test-results/verify/<sha>.json`). | Keep selection; no new gate |

## Decisions for Mohsin

Mohsin decided M1, M2, W1 and C1 on 2026-11-06 by taking the recommendations, and delegated G1 to
the measurement in section 6.

| # | Decision | Options | Decided |
|---|---|---|---|
| M1 | Manifest and card convention | (a) As now: per-file consumer lists on every module, about 4,500 lines when complete. (b) Ownership inherits from the nearest ancestor; delete 35 trivial manifests; module-level `dependsOn` checked against found references for every module; per-file `interfaces` only for external entry points. (c) Derive everything and declare nothing (fails "a new edge must be declared"). | **(b)** |
| M2 | Localized `AGENTS.md` | (a) None; READMEs stay. (b) Five: four packages plus `scripts/` (covering `tools/`), with folder READMEs under 40 lines folded in. (c) One per module (about 100 files). | **(b)** |
| G1 | `scripts/tron mutate` if one run shows little value | Keep on demand, or delete it with its test | **Keep on demand**: one run killed 6 of 6 on a well-guarded file and 0 of 12 on a thinly guarded one |
| W1 | Wire error codes on request paths | (a) Keep raw throws, which go out as `internal`. (b) Convert them to typed `GatewayError` codes, which changes what clients see (code and message), path by path. | **(b)**, one path per slice. Each is a lockstep wire change (AGENTS.md "Architecture invariants"): it updates the wire golden, and iOS handling ships together; if clients would misread the old protocol, the protocol version rises. |
| C1 | Hosted CI | None today; every gate is local | **Keep none.** The pre-merge check and the post-land batch already run every gate locally. |

## Execution order

Each slice is small and reversible, and lands with its own evidence.

| # | Slice | Evidence |
|---|---|---|
| 1 | Fold the four restructure docs into this file (done) | Documentation policy and budgets |
| 1b | Repoint the citations of the retired plan (table in section 2) (done) | Comment- and doc-only diff; the lock tests that verify selects pass |
| 2 | Delete the never-set manifest key `capabilities` (validator, README and tests) (done) | Before the change a manifest using it is accepted; after, it is refused as an unknown key |
| 3 | The contract check covers the profiling driver's protocol copy (done) | Planted drift: the old checker passes; the new one names it |
| 4 | Dropped: shared Python helpers (section 5) | — |
| 5 | Agent-policy existence asserts for files its catalog check already reads (`.agents/README.md`, the iOS skill) (done) | A planted removal still fails the agent policy |
| 5b | Retire the causal auto-revert design doc (the design for closed #2194); `tools/verify/batch.md` owns what was built (done) | No inbound link; documentation policy |
| 5c | Delete Gateway exports that nothing names (each name occurs only at its declaration) (done: fdffebe2d; the 10 names left are the compatibility inventory `tsc` checks) | Typecheck and lint pass after removal |
| 5d | `scripts/tron mutate` runs through the Gateway test runner under the host lock (done: 49edd20ee, da07b5631) | Its new case saw the caller's HOME before the fix |
| 6 | Gateway inline JSON writers: move only durable state that lacks fsync; disposable projections keep their light writer. Done: `update-config.json` (86f873901), Tron's `mcp.json` rewrites (857dbeefb). Next: `update-progress.json`, then the project `.pi/settings.json` writer | Per site: a crash-ordering test that fails first, plus byte-identical output |
| 7 | Gateway RPC switch to module handlers, one method family per slice. A move is not purely structural: a module `read` is admitted while the Gateway drains and is cancelled on disconnect, while a switch read outside `restartDrainMethods` is refused while draining. Each family's slice states that change (decision D5 already makes module reads drain-admitted) | RPC tests plus the duplicate-route guard |
| 8 | After W1: error codes on request paths. Queued: iOS branches on codes (`GatewayClientDiagnostics.swift` classifies them; `LiveViewing.swift` treats a retryable `internal` as transient), so each path first needs its iOS call sites shown code-agnostic, and iOS waits for #2285 | Wire golden updated per path with reviewer ACCEPT; iOS handling checked |
| 9 | After M1: trivial manifests and card simplification. Done for 18 non-iOS manifests (b7bd05f5d, as `directories` entries). The 17 iOS ones wait on branch `struct/2297-m1-ios-directories`: their change selects the iOS source policy, red on main (#2275). Card simplification follows | Byte-identical ledger |
| 10 | After M2: localized `AGENTS.md`, folding READMEs, one package per slice. Gateway done: its guide points to `scripts/tron docs modules` rather than inlining the 44-line generated map, and folds only `gateway/platform`, since the other five READMEs under 40 lines (receipts, automations-contract, session, runtime, projection) would take it past 150 lines; they stay. Mac, push relay and `scripts/` follow; iOS waits for #2285. | Link and budget checks |
| 11 | After #2285 and #2282: #2296 Phase B, iOS duplicates, then the largest files by owner | Each with its lane |
