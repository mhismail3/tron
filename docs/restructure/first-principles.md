# First-principles structure plan (#2297)

This is the single structure plan. It replaces the structure plan (#2276), the ground-up charter, the
cleanup 5-whys and the scorecard; those decisions and preventions are folded in below.

## Order and rules

The order is Musk's, applied at every step:

1. Name the need behind each thing and who owns it.
2. Delete what has no need.
3. Simplify what survives.
4. Make it faster.
5. Automate last, and only a step that has proved itself.

The end state is a clean, organized repository with nothing lost in fidelity and no regressions.

- A move, merge or deletion lands only with fail-before/pass-after or behavior-preservation evidence, a
  fresh reviewer's ACCEPT and a green non-iOS `scripts/tron verify --changed`.
- No golden, timeout or tolerance edit may turn a red green. No waivers. Never remove the only guard of a
  behavior.
- iOS and Xcode work waits for #2285. Paths owned by #2279 and #2282 are off limits until those land.
- Persisted formats, user-visible capabilities, the manifest system, repository-wide conventions and gates
  required by the charter are listed under [Decisions for Mohsin](#decisions-for-mohsin). Everything else
  that is reversible and preserves behavior is decided and done here.

## Where we are (main `73545949a`)

Measured with `scripts/tron metrics`, `scripts/tron budgets`, `scripts/tron ownership` and the
#2297 inventories. Baseline is `047805caf`, the program's start.

| Measure | `047805caf` | `73545949a` |
|---|---:|---:|
| Hand-written lines (production / tests / tooling / docs) | 247,666 / 182,038 / 39,743 / 16,668 | 247,689 / 183,567 / 40,514 / 16,853 |
| Files over 500 lines | 219 | 219 |
| Modules / without a purpose card | 99 / 99 | 101 / 83 |
| Manifest files / lines (of which card keys) | 99 / 1,446 | 101 / 2,397 (817) |
| Files directly in `scripts/` | 95 | 92 |
| Cross-module references / module pairs | 1,494 / 622 | 1,511 / 625 |
| Gateway layer pairs: upward / two-way | 0 / 1 | 0 / 0 (`layer-baseline.json` empty) |
| iOS layer baseline: two-way / upward | 12 / 7 | 12 / 7 (#2296 Phase B) |
| Markdown files / lines / READMEs | 123 / 16,702 / 61 | 125 / 16,887 / 61 |
| Docs over budget / over twice budget | 22 / 0 | 22 / 0 |

The honest reading: #2297 so far added mapping and tooling (+771 tooling lines, +817 lines of cards,
+951 manifest lines, +2 modules). It did not simplify much. The deletions were one script, one duplicated lock function, one
doc-budget owner and the core-journeys ledger. The probes it ran found real defects: four failures that
did not name what broke, now fixed; three units nothing guarded, now guarded; and a probe that leaked
worktrees. At about 45 card lines per module, carding all 101 modules would add about 4,500 lines of
hand-kept mapping, most of it derivable. That is the wrong direction. The plan below cuts mapping first.

## 1. Manifests

**Today.** There are 101 `*.module.json` files.

| Kind | Count | Who reads it |
|---|---:|---|
| Only `layer` and `owns: ["**"]` | 35 | the ownership check |
| Other `{layer, owns}` with explicit file lists, which split mixed directories | 13 | the ownership check |
| `dependsOn` (Gateway) | 24 | the layer check (`tools/layers/layers.py`) |
| Purpose cards (`purpose`, `interfaces`, `uses`) | 18 | `tools/ownership/cards.py` |
| `riskClass` | 5 | verify selection |
| `verify` | 6 | verify selection |

`capabilities` has no users. Readers: ownership (`ownership.py`), cards (`cards.py`), layout (`layout.py`),
verify selection, layers, generated docs, metrics and the work tool.

**What each guarantee needs.**

| Guarantee | Smallest thing that keeps it |
|---|---|
| Every tracked file has exactly one owner | A module root and its exceptions. A directory without its own manifest belongs to its nearest ancestor's module, which removes the 35 trivial files. Explicit lists stay only where a directory is split. |
| Layer direction (Gateway, iOS) | `dependsOn` at module level. It is already the Gateway's declared edge, and `layers` derives the actual edges from the compiler and the Xcode index. |
| An agent knows what a module is for, who uses it and what breaks | A one-line `purpose`; dependents derived and printed by `scripts/tron ownership --card`; declared edges at module level; per-file interfaces only for entry points outsiders run (CLI, launchd, env, wire). |
| Test selection widening | Unchanged: `riskClass` and the L0–L2 rule. |

**Recommendation.** Keep per-module manifests. Make ownership inherit from the nearest ancestor and
delete the 35 trivial manifests. Replace per-file consumer lists with module-level `dependsOn`, which the
reference scanner checks for every carded module, and keep per-file `interfaces` only for external entry
points. Delete the unused `capabilities` key. This is [decision M1](#decisions-for-mohsin): it changes
the ownership and card conventions.

**Regression guard.** The ownership ledger (`--ledger`) must be byte-identical in path→module before and
after. Each card-check rule keeps its case in `tools/ownership/tests/test-cards.py`. The layer fixtures
in `tools/layers/tests/test-layers.py` must still fail on a planted upward import.

## 2. Agent instructions

**Today.** One root `AGENTS.md` (150 lines, the charter), 61 READMEs, 7 skills and 56 other Markdown
files.

- Several READMEs are module cards: what the module is, its interfaces and its invariants.
- Package `docs/` hold contracts and runbooks.
- Some files are history or evidence ledgers, which the charter forbids:
  - the four `docs/restructure/*` files, folded into this one;
  - `.pi/prompts/test-suite-audit.md`;
  - `.agents/skills/tron-home-audit/report.md`;
  - `packages/ios-app/docs/performance-baseline.md`.

**Recommendation.** Add a localized `AGENTS.md`, at most 150 lines, at each place an agent starts work:

- `packages/gateway/`
- `packages/ios-app/`
- `packages/mac-app/`
- `packages/push-relay/`
- `scripts/`, which also covers `tools/`

Each holds what an agent must know before editing there:

- the module map (generated from manifests, like the existing generated doc blocks);
- the package's invariants and its test lanes, with exact commands;
- the local hazards: leases, frozen paths, sealed payloads.

Folder READMEs under 40 lines fold into their package `AGENTS.md`. Contract docs (`settings-contract.md`,
`connection-resilience.md`, `presentation-parity.md`, `architecture.md`) stay, as the targets their tests
cite. The ledgers listed above are deleted after their owners confirm nothing reads them. The root charter
stays the one place for rules that apply everywhere. This is [decision M2](#decisions-for-mohsin): it
changes a repository-wide convention.

**Regression guard:** `scripts/check-documentation-policy.py` (links and paths), `scripts/tron budgets`,
and `check-agent-policy.sh` asserts for each new `AGENTS.md`.

**Dangling references.** 32 Gateway lock tests and test-support files cite "restructure plan §6.4, §6.5,
§6.6" in their opening comment. That plan no longer exists. Its content now lives in
`packages/gateway/docs/scenario-locks.md` (Framework, Persisted stores (V4), Wire contract (V7)) and in
mutation sampling in `tools/verify/README.md`. Repoint the comments; this needs no decision.

## 3. Layout and naming

**Root (15 entries).** Every entry has an owner and a reader. Keep the frozen root list in
`root.module.json`.

**`scripts/` and `tools/`.** Folding `tools/` into `scripts/` was considered on Nov 4 and rejected (S3'):
it rewrites about 96 referencing files for no agent gain, because `scripts/tron` is the front door.

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
| Protocol version | `version.ts` is the source; `gateway-payload-deploy.mjs` and `tron-profile-gateway-driver.mjs` keep copies | Read `version.ts`, as `tron_mac_replace.py` already does. The Swift copies are lockstep consumers. |
| Debug/Stable ports 9848/9847 | 14 files | #2296 item 18 |
| Host lock path | `host_lock.py`, plus documentary copies | Keep `host_lock.py` |
| `TRON_UI_LOCK_RENDERING` | read in shipped iOS code | #2296 item 16, after #2285 |

## 5. Standard components and patterns

| Area | Duplicates | One pattern | When |
|---|---|---|---|
| Gateway RPC | Module `RpcHandler` (`kernel/host/module-host.ts`) plus 168 `case`s in `transport/gateway-service.ts` | Module handlers. Move one method family per slice and extend the duplicate-method guard to the switch. | After the card and manifest slices; each slice has its RPC tests as guard |
| Gateway errors | 519 raw `throw new Error` on 114 files | `GatewayError(code)` on request paths (`transport/`, `kernel/run/`) only | Wire-code change: per path, with the wire golden unchanged |
| JSON writes | `foundation/durable-json.ts` (39 importers) plus about 14 inline temp→rename writers | `durableAtomicWriteJson` | One site per slice, keeping each site's fsync order, with a fail-before test |
| Logging | `GatewayLogger` plus 42 console/stdio sites | Logger, except CLI entry points | Per-file review |
| Python git and process helpers | 12 `git()` wrappers, 10 process-group runners | One `git()` and one runner in a shared tools module | Low risk, one slice |
| iOS sheet, row and loading | `Tron*` primitives exist, but `SettingsRendererRow`, `ListRow` and three loading states overlap | The `Tron*` owners in `presentation-parity.md` | After #2285 and #2282 |

## 6. Gates and tests

Every gate is local; there is no hosted CI. `.github` holds only Dependabot.

- **Static verify steps.** Ownership, residue, budgets, documentation policy, generated docs, agent
  policy, privacy, diff check, Gateway typecheck, lint and layers. Each costs under 2 s (median over 22
  reports), and each has caught a red in recorded runs or history.
- **Test lanes.** Gateway vitest has a median of 156 s. The iOS build has a median of 495 s.
- **Rule for a gate or test.** It is removed only when another gate demonstrably catches the same break.
  The proof is a planted break that the survivor catches, plus reviewer ACCEPT.

Candidates:

| Gate | Finding | Next step |
|---|---|---|
| `check-agent-policy.sh` | Its path asserts may duplicate the documentation policy; its safety-phrase asserts are charter-mandated | Plant a broken skill path. If the documentation policy catches it, drop only the duplicated asserts. |
| `scripts/tron mutate` | Never measured since it landed (no `test-results/mutate`) | Run it once on one lock-guarded file. Keep it if it kills mutants; otherwise [decision G1](#decisions-for-mohsin). |
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
- **Dead code.** Name-based scans are unreliable here. The 17 "unreferenced" Gateway exports are mostly
  `compatibility-manifest.ts`, a compile-time exhaustiveness inventory that `tsc` checks; it is not dead.
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
| Residue | Agents run `scripts/tron tidy --here` before reporting; verify refuses untracked files and ignored files with no named writer | Keep |
| Backlog | 78 open issues: 39 bugs, 17 tooling | Not in scope here |
| Verify speed | Static steps total under 10 s. Gateway tests dominate. | Keep selection; no new gate |

## Decisions for Mohsin

| # | Decision | Options | Recommendation |
|---|---|---|---|
| M1 | Manifest and card convention | (a) As now: per-file consumer lists on every module, about 4,500 lines when complete. (b) Ownership inherits from the nearest ancestor; delete 35 trivial manifests; module-level `dependsOn` checked against found references for every module; per-file `interfaces` only for external entry points. (c) Derive everything and declare nothing (fails "a new edge must be declared"). | **(b)** |
| M2 | Localized `AGENTS.md` | (a) None; READMEs stay. (b) Five: four packages plus `scripts/` (covering `tools/`), with folder READMEs under 40 lines folded in. (c) One per module (about 100 files). | **(b)** |
| G1 | `scripts/tron mutate` if one run shows little value | Keep on demand, or delete it with its test | Decide after the measurement |
| C1 | Hosted CI | None today (removed in `279ee16c7`); every gate is local | Keep none, per P2 |

## Execution order

Each slice is small and reversible, and lands with its own evidence.

| # | Slice | Evidence |
|---|---|---|
| 1 | Fold the four restructure docs into this file | Documentation policy and budgets |
| 1b | Repoint the 32 comments that cite the retired "restructure plan §6" to `scenario-locks.md` | Comment-only diff; the lock tests that verify selects pass |
| 2 | Delete the unused manifest key `capabilities` | Before the change a manifest using it is accepted; after, it is refused as an unknown key |
| 3 | Protocol-version readers in the two `.mjs` copies | Lockstep tests fail on a planted drift |
| 4 | One Python `git()` and one process-group runner for tools | Existing tool suites; interrupt tests |
| 5 | Agent-policy path asserts, if the planted break proves the overlap | The break is caught by the documentation policy |
| 6 | Gateway inline JSON writers, one site per slice | A durability test per site |
| 7 | Gateway RPC switch to module handlers, one method family per slice | RPC tests plus the duplicate-route guard |
| 8 | Error codes on request paths | Wire golden unchanged |
| 9 | After M1: trivial manifests and card simplification | Byte-identical ledger |
| 10 | After M2: localized `AGENTS.md`, folding READMEs | Link and budget checks |
| 11 | After #2285 and #2282: #2296 Phase B, iOS duplicates, then the largest files by owner | Each with its lane |
