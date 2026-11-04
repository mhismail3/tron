# Repository structure plan (Phase A: audit and proposal)

Status: proposal for maintainer approval. Nothing here moves, deletes or rewrites a tracked
file on main. Base: main `68d341905` (2026-11-04, after #2134 and #2141 landed). Branch
`docs/structure-plan-20261104`. Implementation runs after approval, one slice at a time.

## 0. Summary

- **Coverage, mechanically proven.** `docs/restructure/inventory.tsv` has one row per tracked
  file and per ignored/untracked path in the primary checkout, including empty ignored
  directories that `git status` hides. On this branch: **1,984 tracked (main's 1,968 plus 16
  Phase-A files) + 80 ignored = 2,064 rows, 0 unaccounted, 0 without a verdict, 0 stale**
  (`python3 docs/restructure/inventory.py check`, which fails on any of the three).
  Columns: path, status, kind, module, layer, size, last commit, purpose, callers, overlap
  cluster, verdict, target, note. All 344 standalone tooling/config/doc files outside package
  source (every file in `scripts/`, `tools/`, package `scripts/`, package-root config and pins,
  root files, `.github`, `.agents`, `docs`) have a per-file audit row with purpose, code callers
  and overlap cluster (`docs/restructure/audit/*.tsv`, from five read-only scouts). Package code
  inherits its module's row (`modules.tsv`); plan decisions override scouts (`targets.tsv`).
- **Verdicts on main's files:** keep 1,783 · move 153 · merge 12 · delete 20 (18 of them
  superseded Pi archives). Ignored: 58 delete, 10 auto-prune, 12 keep (caches, deps, generated,
  local config).
- **End state:** root 13 entries (from 31 on disk / 23 tracked); `tools/` folds into
  `scripts/<area>/`; `scripts/` top level 5 executables (from 108 flat files); 8 root manifests
  become 1; scratch in one ignored `.scratch/`; two commit-time guards and one sweep keep it so.

## 1. Inventory findings

Per-path detail is in the ledger; this section records what drives the plan.

**Root (31 entries on disk).** Tracked: `.agents .codex .github .pi(prompts only) config docs
packages scripts tools`, files `.gitattributes .gitignore .node-version AGENTS.md README.md
VERSION.env` and 8 manifests (`root budgets docs-index layers metrics ownership verify work
.module.json`). Ignored: `.ci-tools/` 268M (pinned toolchain cache, keep), `.claude/` (per-user,
keep), `.pi/` 1.1G (47 agent workflow scripts/notes plus August pi-subagents artifacts with no
current writer), `test-results/` 1.0G (tool evidence plus 279 loose agent scratch files),
`build/` 47M, `node_modules/` 44M (no root package.json), `tmp/` (empty), `h3.log` (manual
xctrace output): the last four have no writer and are deleted.

**Manifests (101).** Package manifests match real module boundaries and feed layers/verify;
keep them. Root sprawl is tooling: 7 root manifests each own one `tools/<x>/**` plus its
`scripts/test-*.py`, because tests live in a different directory from their tool. Co-locating
tests removes the reason for root manifests; only `root.module.json` must stay (it owns root
files). Three tools manifests are single-directory owners that disappear with their moves.

**scripts/ (108 flat files, 8 manifests) and tools/ (47).** One job is split across two homes
(`tools/verify/verify.py` + `scripts/test-tron-verify*.py`; `tools/work` + `scripts/test-work-*`).
`scripts/` mixes entry points, libraries, 36 tests, 2 docs, 1 fixture and 8 manifests. The
existing manifests already group files by area (cli, dev, ios, mac, policy, profile,
protocol-contract, triage), so the target directories follow them. Several jobs have two
documented entry points (`scripts/tron test ios` vs `scripts/tron-ios-test`, `scripts/tron dev`
vs `scripts/tron-dev`, `scripts/tron ios generate` vs `scripts/generate-xcode-project`), and
profile/triage/simulator have none in `scripts/tron`.

**Frozen paths (verified in source).** Executed by repo path from code that is older than the
checkout: `scripts/tron` (`admin/diagnose.ts:375`; `document-admission.ts:74` marker),
`scripts/tron_mac_replace.py` (`mac-replace-service.ts:98`), `scripts/tron-ios-device`
(`ios-device-install-service.ts:653`), and `scripts/tron-fsevents-guard`, which the replace
orchestrator reads at an arbitrary revision (`tron_mac_replace_platform.py:487`
`git show <rev>:scripts/tron-fsevents-guard`; `tron_mac_reinstall.py:481`). Their content may
change (siblings repointed in the same commit); their path may not. The Mac payload key
`app/scripts/gateway-payload-deploy.mjs` is payload-relative, so the repo source may move. Both
LaunchAgents (`fsevents-guard`, `ios-builds`) embed source, not repo paths.

**Package-root config/pins.** Gateway: `layer-baseline.json` (read by path by layers), three Pi
pins and `third_party/`, `artifacts/` (read by Gateway runtime, payload staging and updaters;
`package.json` has a `file:` dependency) and four vitest configs whose basenames verify parses:
all keep. `artifacts/` holds 18 unreferenced superseded archives (tron.3–8, 32M; the pin names
only tron.9 and tron.10): delete. iOS/Mac `project.yml`, xcconfigs, entitlements and
`layer-baseline.json`: keep.

**Agent-config dirs.** `.agents/skills` is the one skill home (Pi reads it; `check-agent-policy.sh`
forbids copies). `.pi/` is Pi's project config dir (only `prompts/test-suite-audit.md` tracked)
misused as scratch because the subagent tool text says "write it to a file under request cwd,
such as .pi/<name>.js". `.claude/` is per-user, globally ignored. `.codex/environments/environment.toml`
is stale (its `scripts/tron dev -bdt`/`--stop` actions no longer exist), no repo consumer. No
duplicates or symlinks.

**Residue elsewhere.** `packages/ios-app/build` 5.5G (still written by `tron-ios-device` while
`tron-ios-test` already uses `~/Library/Developer/Tron/ios`), `packages/ios-app/packages/` 628M
(accidental doubled path, no writer), `packages/mac-app/build` 2.5G, three package
`test-results/`. Outside the repo: `~/Library/Developer/Tron/ios` 91G (2,855 test-run dirs >7d;
`tron-ios-test prune` keeps 50 per worktree but nothing runs it). Two orphan worktree dirs
(`tron-worktrees/batch-efa0efe43`, `d1-verify-3495d13`, 2.1G each, gitdir pruned). The installed
pre-commit hook is stale (runs `cargo fmt` for the retired `packages/agent`). 112 local
branches, 46 merged or idle >14 days.

**Defects found on the way (fixed in the named slice).** `packages/push-relay/package-lock.json`
is tracked but matched by `.gitignore` (S2); `MacTerminalSSH/Package.resolved` is an ignored
lockfile (S2, charter: exact pins); `packages/gateway/dist` keeps outputs of deleted sources
(S2: clean build in bundle); three Gateway tests break the naming/colocation convention and
four tooling files lack a purpose line (S1).

## 2. Overlap clusters: one entry point per job

| Job | Today | Survivor | Merge in / delete |
|---|---|---|---|
| Doc budgets | `tools/budgets` (docs-only since #2134) and `check-documentation-policy.py` (AGENTS/README budgets) | scripts/policy/check-documentation-policy.py | budgets rules and tests merge; `scripts/tron budgets` arm removed |
| Front doors | `scripts/tron test ios`/`tron-ios-test`; `dev`/`tron-dev`; `version`/`tron-version`; `ios generate`/`generate-xcode-project` | `scripts/tron <cmd>` | `tron-*` move into areas as implementations; profile, triage, ios simulator, release-doctor get arms |
| Payload build | `scripts/gateway-{install-inputs,payload-deploy}.mjs` and `packages/mac-app/scripts/*` | `packages/mac-app/scripts/` (gateway-payload module) | the two `.mjs` and tests move there |
| Structure checks | `tools/ownership`, `tools/layers`, `tools/metrics`, housekeeping skill's manual steps | `scripts/structure/` (`ownership --layout/--ledger`, `layers`, `metrics`, `tidy`) | 3 manifests → 1; skill calls `tidy` |
| Retention | `tron-ios-test prune` (iOS store, newest 50/worktree), nothing for repo evidence/scratch | `tron-ios-test` owns `~/Library/Developer/Tron/ios` (runs prune on exit); `tidy` owns `.scratch/` and `test-results/` | no overlap: one owner per store |
| Gateway test lock | `tools/verify/gateway.py` lock/queue and a copy in `batch.py` | `gateway.py` | batch imports it (S3) |
| iOS source guards | `presentation-source-policy.py`, `sheet-loading-source-policy.py` | packages/ios-app/scripts/source-policy.py | two rule sets, one runner |
| Mac payload tests | `test-gateway-payload-verifier.sh`, `test-update-payload-fingerprint.sh`, `test-gateway-payload-precondition.py` | verifier test absorbs the fingerprint self-test | one fewer test entry |
| Release config validators | `verify-gateway-protocol-contract.py`, `gateway_protocol_contract.py`, `validate-push-service-config.sh` (protocol-contract + cli manifests) | `scripts/toolchain/` | one manifest |
| Model release dates | `scripts/update-model-release-dates.mjs` imports Gateway src | `packages/gateway/scripts/` | Gateway owns its vendored data |
| Scratch | `.pi/*.js`, `test-results/*.md|js|diff`, `tmp/` | `.scratch/` | pruned after 7 days |

Not merged (distinct jobs, verified): `check-pi-sdk.mjs` vs its rollback check; payload hash in
shell/Node/Swift (three runtimes; a golden test keeps them equal); `verify-gateway-payload.sh`
vs `verify-signed-pi-payload.sh`. Tooling no code, config or test names (`tidy` finds it):
`compare-pi-sdk-graph.mjs`, `measure-projection.mjs`, `regenerate-subagent-parity.sh`,
`ios-release-toolchain-doctor.sh`, `tron-profile-device` (dispatched by computed name),
`update-model-release-dates.mjs`: each gets a `scripts/tron`/`package.json` entry or is deleted
in S4c.

## 3. Target layout

```text
AGENTS.md  README.md  .gitignore  .gitattributes  .node-version  root.module.json
.agents/skills/          the only skill home
.github/                 dependabot.yml, work.json
.pi/prompts/             Pi project prompts only (no scratch)
config/                  version.env, ci-toolchain.env, GatewayProtocol.json, PushService.xcconfig
docs/                    PRINCIPLES.md, development.md
packages/<pkg>/          product code, its tests, fixtures, package tooling (scripts/), docs/
  gateway ios-app mac-app push-relay protocol-fixtures web
scripts/                 tron, tron-node; frozen: tron-ios-device, tron_mac_replace.py, tron-fsevents-guard
  README.md scripts.module.json
  toolchain/ dev/ ios/ mac/ policy/ structure/ verify/ work/ profile/ triage/ research/
.scratch/  test-results/  (ignored; pruned)
```

Rules (enforced in §5):
- **Source** `packages/<pkg>/…` by module; one manifest per module directory.
- **Tests** beside what they prove (§4). **Fixtures** module-local `fixtures/` or package
  `test-fixtures/`; **goldens** `locks/` (Gateway) or `UITests/Locks/Goldens/` (iOS, LFS).
- **Repo tooling** `scripts/<area>/` with its tests and `<area>.module.json`; started via
  `scripts/tron`. **Package tooling** `packages/<pkg>/scripts/`.
- **Docs**: repo-wide policy/runbook in `docs/`; everything else beside its owner
  (`docs/restructure/k0-kernel.md` → packages/gateway/docs/kernel.md; `tools/verify/*.md` →
  `scripts/verify/`; `docs/design/causal-auto-revert.md` merges into scripts/verify/batch.md;
  Home retro design → packages/gateway/docs/home-retro.md; `tools/home-retro/FINDINGS.md`
  deleted as a dated evidence ledger).
- **Agent scratch** `.scratch/` only. **Evidence** `test-results/` (root or package; both pruned
  at 14 days by `tidy`). **Build output** stays where its toolchain writes it, ignored and named
  in `tidy`'s writer list; iOS device builds join `~/Library/Developer/Tron/ios`.
- No symlinks, aliases or compatibility copies: every move updates its consumers atomically.

**Manifest simplification.** Keep co-located manifests (they are the locality breadcrumb and
avoid one central conflict file) but: (1) root holds only `root.module.json`; (2) one manifest
per `scripts/<area>/` owning `**`, so tests and tools share an owner without file lists;
(3) add an optional one-line `purpose` key that the generated ledger shows for non-tooling
files (tooling files carry their own purpose line, which the guard requires); (4) keep `layer`,
`dependsOn`, `dynamicEdges`, `riskClass`, `verify`, single-owner and placement rules unchanged.
Net 101 → 96 manifests (−7 merged or deleted, +2 new areas; package manifests untouched).

## 4. Test boundaries

| Kind | Where | May import / drive | Checked by |
|---|---|---|---|
| Gateway integration (incl. lock) | `src/<module>/*.integration.test.ts`, goldens `locks/` | its module, `test-support/`, other modules within layer direction | layout naming rule; vitest include; `tsconfig` rootDir `src` keeps tests out of production |
| Gateway E2E | `src/<module>/*.e2e.test.ts` | real Gateway process via `test-support/gateway-process` | same |
| Gateway package tooling | `scripts/*.integration.test.mjs` | its script by path, temp dirs | verify node runner |
| Repo tooling | `scripts/<area>/test-*.py|sh`, `*.test.mjs` | its area by path, temp Git repos and `HOME` | layout (no tests at `scripts/` top); verify python/shell/node runners |
| iOS | `UITests/`, `E2ETests/`, `ProfilingTests/`, `SwiftAppUITests/` targets | app via XCUITest; E2E via the real Gateway harness | layout Swift rule; XcodeGen target membership; verify `is_test` |
| Mac | `Tests/Integration/`, probes `Tests/Fixtures/` | `@testable TronMac` | same |
| Push relay | `tests/*.integration.test.ts` (Workers pool) | Worker via `SELF` | vitest config |

Verify's `is_test` and runner mapping already key on these names and refuse a test with no
runner; S3 widens `declared_files` from the scripts/test- prefix to scripts/**/test-. Package
`scripts/test-*.sh` in mac-app/ios-app have no runner today (scout finding); S4b/S5 wire each
into verify's shell runner or delete it, never leave an unrun test.

## 5. Regression guards and self-healing loop

| Guard | Exact check | Runs | Measured (this Mac, warm) |
|---|---|---|---|
| G1 ownership + layout | `scripts/tron ownership --layout`: every tracked path owned once (existing) plus `layout.py`: root allowlist; only `root.module.json` at root; `scripts/` top allowlist; area manifest named for its dir; frozen paths present; tooling purpose line (directive comments skipped); no tests in root/docs/config/.agents/`scripts/` top; Swift tests only in test targets; Gateway test naming and no `tests/` dirs | pre-commit (index) and verify's static ownership step (revision) | 0.16 s index, 1.4 s at a revision; main today: 120 violations = the migration worklist |
| G2 privacy | existing `personal-info-guard.sh --staged` | pre-commit, verify | 0.23 s |
| Ledger | `scripts/tron ownership --ledger`: path, module, layer, purpose (tooling header line or manifest purpose) | on demand; replaces any hand ledger | 0.22 s |
| Sweep | `scripts/tron tidy [--json]`: untracked files; ignored paths with no named writer (exact-path list, not basenames); empty ignored dirs; expired scratch (7 d) / evidence (14 d) by newest file in the tree; `__pycache__`; tooling nothing names; orphan worktree dirs; worktree merged/dirty/live/last-activity; merged or >14 d idle branches; non-managed hook | manual and weekly automation (D5) | 9.3 s (dead-tooling scan 3–4 s) |
| Prune | `scripts/tron tidy --prune`: deletes expired `.scratch`/`test-results` entries, bytecode, branches merged into origin/main and not checked out (prints `git branch <name> <sha>`), and worktrees that are merged, hold no untracked/modified/ignored-non-regenerable files (so `.env.local` blocks removal), have no process cwd inside (no `lsof` ⇒ nothing pruned) and no HEAD/reflog activity for 3 d | anytime | same run |

**Allowlists are a shrink-only ratchet.** S1 lands `ROOT_ENTRIES` and the `scripts/` top-level
allowlist generated from `git ls-files` at landing, so G1 is green and blocks any *new* root
entry, root manifest or flat script from day one. Each later slice deletes the entries it
clears, ending at the target lists in `layout.py`. This is the same shrink-only pattern as
`layer-baseline.json`; it is a list in the checker, never a per-file waiver.

Failure messages are the fix (from the prototypes): *"root entry 'x' is not in the layout; put
it under scripts/, docs/, config/ or a package (AGENTS.md 'Where things go'), or delete it"*;
*"scripts/test-tron-docs.py: tests live beside their tool in scripts/<area>/"*; *"scripts/foo:
scripts/ top level holds only scripts/tron, tron-node and the frozen entry points; put it in
scripts/<area>/ and add a scripts/tron subcommand if people run it"*; *"scripts/tron-ios-device
is missing: the installed Gateway executes this path; restore it"*; *"…: add a one-line purpose
comment in its first 12 lines (what it does, who runs it)"*; tidy: *"no code, config or test
names it: wire it into scripts/tron or delete it"* (report-only: name matching can miss a dead
file whose name is common, never deletes), *"ignored path with no named writer: delete it, or
add its writer to tidy REGENERABLE/LOCAL"*.

**Hook.** `install-hooks.sh` writes a one-line hook `exec scripts/tron hook pre-commit`; the
tracked arm runs G2 then G1 (~0.4 s). Hook content then never drifts; `tidy` reports a
non-managed hook. Not added: a hand ledger, a duplicate-purpose detector (not mechanical; the
command table, "search before writing" and review cover it), new CI (`.github` has no
workflows; verify and the post-land batch are the gates).

**Loop.** (a) G1/G2 fail fast at commit with the fix. (b) `tidy --prune` is safe anytime.
(c) A weekly Home automation runs `scripts/tron tidy --json` and creates or updates one
"Repository hygiene" issue through `scripts/tron work issue`; it never deletes. (d) A file
cannot land without an owner, a purpose (tooling) and a sanctioned place, so the generated
ledger stays complete.

Prototypes on this branch, not for landing as is: `tools/ownership/layout.py`, `--layout`,
`--ledger` and `purpose` in `ownership.py`, `tools/ownership/tidy.py`. Reviewer blockers on them
(ignored-file deletion, creation-time idleness, basename matching) are fixed here; S1 still
adds their fail-before tests before any `--prune` run.

## 6. Agent breadcrumbs

Pinned Pi 1.3.0 loads context files only from the agent dir, the cwd and its **ancestors**
(Pi's docs/configuration.md "Context files"; `dist/core/resource-loader.js:165`
`loadProjectContextFiles` walks parents only). Workers start at a worktree root, so a nested
packages/gateway/AGENTS.md would be invisible to nearly every worker; that settles the form:
1. Root `AGENTS.md` "Where things go" (11 lines; charter stays ≤150): `breadcrumbs/AGENTS-where-things-go.txt`.
2. scripts/README.md command table and add/change/remove procedure (≤80 lines): `breadcrumbs/scripts-README.txt`.
3. One `## Layout` section (≤12 lines) per package README and the root README map:
   `breadcrumbs/package-layout-sections.txt`.
4. Guard messages (§5) at the moment a file lands in the wrong place.
5. The `tron-workspace-housekeeping` skill shrinks to "run `scripts/tron tidy`, act on its report".

## 7. Migration slices (serial; each lands green alone)

Every slice regenerates its consumer list with `rg -n -F` on each moved path and basename
before editing; the lists below are the known high-risk consumers, not the whole set. Each
slice: own worktree, `scripts/tron verify --plan`, affected checks, independent ACCEPT for test
edits, `--no-ff` landing per the Git skill, issue closed with commands and results.

**S1 Guards and breadcrumbs, no moves.** Land `layout.py`, `--layout` (on in verify's ownership
step and the hook), `--ledger`, manifest `purpose`, `tidy`, `scripts/tron hook|tidy` arms, managed
hook, `.scratch/` ignore, `PYTHONDONTWRITEBYTECODE` for tooling tests. Allowlists seeded from
`git ls-files` (§5). Fix the 3 Gateway test names/dirs and 4 purpose lines. Charter section and
README map at current paths. Verify: temp-repo cases in `test-tron-ownership.py` (fail-before/
pass-after per rule), new `test-tron-tidy.py` (temp repos: merged/unmerged/dirty/live/orphan,
ignored `.env.local` survives `--prune`, last-activity idleness, restore line), verify `--plan`,
documentation and agent policy. Risk: low.

**S2 Residue and ignore rules.** `.gitignore`: un-ignore `packages/push-relay/package-lock.json`,
track `MacTerminalSSH/Package.resolved`, drop `tmp/`, add `.scratch/`. `tron-ios-device` writes
DerivedData/share output under `~/Library/Developer/Tron/ios` (content change of a frozen path;
`test-ios-test-infrastructure.py:6425` and `test-main-source.py:34,45,53` assert the old paths)
and `tron-ios-test` runs `prune` on exit. Then, with your approval of the first run (D4):
`tidy --prune`; delete root `build/ tmp/ h3.log node_modules/`, `packages/ios-app/{build,
packages,TestResults.xcresult,node_modules}`, August `.pi/subagents/`; move current `.pi/*.js|md`
to `.scratch/`; inspect then remove the two orphan worktree dirs. Verify: `tidy` lists only
owner decisions; `scripts/tron test ios` smoke on one lane; tooling tests above. Risk: low;
frees ~7 GB in the repo plus expired iOS test runs.

**S3 tools/ → scripts/<area>/ and root manifests.** `tools/{ownership,layers,metrics}` →
`scripts/structure/`; `tools/verify` → `scripts/verify/`; `tools/work` → `scripts/work/`;
`tools/docs` + budgets → `scripts/policy/`; `tools/research` → `scripts/research/` (D8);
matching `scripts/test-*` beside them; 7 root manifests → area manifests; docs moves in §3.
Consumers: `scripts/tron` dispatch (`test tooling` default glob `scripts/test-work-*.py`);
`verify.py` `declared_files`, `COPIED`, `sys.path`; inter-tool imports `budgets.py:12`,
`docs.py:13-14`, `layers.py:39,154`, `work/tracking.py:15` (`parents[1]/ownership`),
`swift_index.py:40`; tooling tests' `sys.path`/fixture copy lists (`test-tron-verify-batch.py`
31 refs); `layer-baseline.json` comments; `packages/gateway/docs/observability.md` 7;
`packages/gateway/src/modules/home/{README.md:260,tasks.md:181}` and the 6 kernel files linking
`k0-kernel.md` (`kernel/pi/README.md:5`, `kernel/host/README.md:5`, `kernel-lifecycle.ts:1,16`,
`session-lineage.ts:18`, `runtime-registry.ts:1451,1462`, three lock tests); README, AGENTS.md,
`docs/development.md`, skills. Verify: every moved tooling test, verify `--plan` on the slice
itself, `ownership --layout`, docs/agent policy. Risk: medium (verify verifies itself; run its
own tests first).

**S4 scripts/ flat → areas**, three landings.
- **S4a toolchain + ios.** `project.yml` build phases (iOS `:179-188`, Mac `:106-110,136,158`) →
  `scripts/tron ios|mac generate` + one simulator build; `verify.py:38-39,580-588,661-674` and
  `batch.py:75,84-90,125,255,412-437,522,678` literals (`tron-ios-test`, `ios-test-lock.py`,
  `ios-gateway-e2e-test`, `ios-mac-terminal-journey`); `.github/work.json` 183,188; Swift
  XCTSkip/comment paths; `packages/gateway/package.json` device-bind test path;
  `apps-install.integration.test.ts:133` (`ios-share-publish.py`); `tron-ios-device` sibling
  paths; `gateway-install-inputs.mjs:29-40` fingerprint list entries that move here; skills
  `tron-ios`, AGENTS `scripts/tron-ios-test` → `scripts/tron test ios`.
- **S4b mac + dev + payload.** `tron_mac_replace.py` adds scripts/mac to `sys.path`; payload
  `.mjs` → `packages/mac-app/scripts/`: `bundle-gateway.sh:136-183,373,401,485-564`,
  `stage-gateway-app.sh:27`, `hash-gateway-payload.sh:22,33`, `package-dmg.sh:97`,
  `test-tron-gateway-{launcher,npm}.sh`, `scripts/tron-dev` 17,200-207,
  `node-pin-mirrors.py:26-27`, `test-tron-node.py:57`, `gateway_protocol_contract.py:108`,
  `tron-ios-device-bind.mjs:7` (imports the deploy helper), `tron_mac_reinstall.py:474`,
  `test-tron-mac-replace.py:950`, `exit-after-shutdown.e2e.test.ts:26`,
  `home-task-continuity.e2e.test.ts:565-567`, `host-control.md:36,153`; then `scripts/tron
  bundle gateway`, `verify-gateway-payload.sh`, payload tests and a Debug Gateway restart after
  reading `scripts/tron dev status`. The install-input fingerprint changes once: expected,
  checked by its test.
- **S4c profile, triage, policy.** New `scripts/tron` arms; `personal-info-guard.sh`
  (`.github/work.json` 158, `verify.py:674`, `home-task-continuity.e2e.test.ts:668`, hook);
  `install-hooks.sh` path inside `tidy`; the unnamed-tooling decisions (§2). `scripts/` allowlist
  reaches the target. Risk for S4: highest (payload inputs, Xcode build phases, frozen entry
  content); never touches `/Applications` or Stable.

**S5 Packages and docs.** `tools/web` → `packages/web` (iOS `project.yml:315,358` folder
sources + regenerate, `ios-gateway-e2e-test:542`, `ios-share-publish.py:38`,
`test-ios-test-infrastructure.py:4147,4862`, `packages/ios-app/docs/swift-apps.md` 30,81,101,270,
Swift comments, layer baselines); `VERSION.env` → config/version.env (`scripts/tron`,
`tron-version:12,55-56,259`, `root.module.json`, `Base.xcconfig:9`, docs); delete `.codex/` (D6);
Mac probe → `Tests/Fixtures/`; iOS source-policy merge; Mac payload test merge; delete tron.3–8
archives; Gateway docs/kernel.md. Final allowlists = target; package Layout sections; delete
`docs/restructure/` Phase-A files. Verify: ios generate + simulator build, the Swift-apps UI
journey that bundles builds-preview, pi-subagents script tests, docs policy. Risk: medium.

**S6 Hygiene automation** (after D5): one weekly Home schedule running `scripts/tron tidy --json`
and filing drift to one issue. No deletion from the automation.

## 8. Decisions for Mohsin

Settled by facts, not choices: breadcrumb form (Pi loads ancestors only, §6); tracking
`Package.resolved` (charter: exact lockfiles); deleting unreferenced tron.3–8 archives (pin
names only tron.9/10); freezing `scripts/tron-fsevents-guard` (read at arbitrary revisions).

| # | Decision | Recommendation | Why |
|---|---|---|---|
| D1 | One tooling home | Fold `tools/` into `scripts/<area>/` | `scripts/tron` is frozen and referenced in 215 files; `tools/` has 75 |
| D2 | One front door | All human-run commands become `scripts/tron` subcommands; `tron-*` move into areas (frozen ones stay) | one documented entry per job; docs churn is mechanical |
| D3 | Perpetual ledger | Generated (`ownership --ledger` from manifests + purpose lines), not a committed per-file table | a 2,000-row hand file goes stale and conflicts; coverage is enforced by G1 |
| D4 | Prune scope | `tidy --prune` deletes expired scratch (7 d) and evidence (14 d), bytecode, merged non-checked-out branches (restore line printed) and merged worktrees with no local files, no live process and 3 d without activity; orphan dirs and unmerged branches report only. You approve the first run | merged content is on main and ignored local files block removal, so nothing unique is lost |
| D5 | Weekly sweep | One weekly Home automation filing drift to one issue | report-only; you approve the schedule |
| D6 | `.codex/` | Delete | stale actions, no consumer |
| D7 | Scratch location | `.scratch/`; change the subagent tool text example `.pi/<name>.js` → `.scratch/<name>.js` (model-visible text; updates the `delegation-subagent.golden.json:294` lock) | `.pi/` is Pi's trusted config dir; the example is why agents write there |
| D8 | `tools/research/public-x.mjs` | Decide with #2139: keep as `scripts/research/` or hand to the global `x-posts` skill | overlapping research helper in two homes |
| D9 | iOS `Fixtures/` | Leave compiled into the app target (layout unchanged); a Release-stripping change is separate product work | changes what ships; not a structure question |

## 9. Coordination and residual risk

- #2134 and #2141 landed before this revision (base `68d341905`): their deletions are gone from
  the ledger. #2139 (vendor) and the #2141 remainder (project lifecycle) may still touch
  `tools/research` and `packages/gateway/src/modules/projects`; S3 waits for #2139's research
  decision (D8).
- Not verified by execution: payload fingerprint after S4b, XcodeGen output with moved build-phase
  scripts, Claude Code/Codex context-file rules (only Pi's loader was read). Each is a named check
  in its slice or does not affect the design (Pi is the harness agents run in).
- Scout caller counts are grep-based; each slice re-derives exact consumers before editing.

Reproduce: `python3 docs/restructure/inventory.py build && python3 docs/restructure/inventory.py check`;
`python3 tools/ownership/ownership.py --layout` (or `<rev> --layout`); `python3 tools/ownership/tidy.py`.
Review: independent reviewer (ACCEPT-with-fixes; blockers B1–B4 resolved in this revision).
