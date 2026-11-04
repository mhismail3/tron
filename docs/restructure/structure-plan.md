# Repository structure plan (Phase A: audit and proposal)

Status: proposal for maintainer approval. Nothing here moves, deletes or rewrites a tracked
file on main. Base: main `0ae97abaa` (2026-11-04). Branch `docs/structure-plan-20261104`.
It assumes the in-flight #2193 landings (§9) and runs after them, one slice at a time.

## 0. Summary

- **Coverage, mechanically proven.** `docs/restructure/inventory.tsv` has one row per tracked
  file (1,983) and per ignored/untracked path in the primary checkout (79): **2,062 rows,
  0 unaccounted, 0 without a verdict** (`python3 docs/restructure/inventory.py check`).
  Columns: path, status, kind, module, layer, size, last commit, purpose, callers, overlap
  cluster, verdict, target, note. All 344 standalone tooling/config/doc files outside package
  source (every file in `scripts/`, `tools/`, package `scripts/`, package-root config and pins,
  root files, `.github`, `.agents`, `docs`) have a per-file audit row with callers and cluster
  (`docs/restructure/audit/*.tsv`); package code inherits a module-level row (`modules.tsv`).
- **Verdicts (tracked):** keep 1,783 · move 152 · merge 12 · delete 36 (14 already in #2134/#2141).
  Ignored: 57 delete, 10 gitignore+auto-prune, 12 keep (caches, deps, generated, local config).
- **End state:** root 13 entries (from 31 on disk / 23 tracked); `tools/` folds into
  `scripts/<area>/`; `scripts/` top level 4 executables (from 114 flat files); 8 root manifests
  become 1; scratch in one ignored `.scratch/`; three cheap guards plus one sweep keep it so.

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

**scripts/ (114 flat files, 8 manifests) and tools/ (51).** One job is split across two homes
(`tools/verify/verify.py` + `scripts/test-tron-verify*.py`; `tools/work` + `scripts/test-work-*`).
`scripts/` mixes 28 entry points, 33 libraries, 42 tests, 2 docs, 1 fixture and 8 manifests. The existing
manifests already group files by area (cli, dev, ios, mac, policy, profile, protocol-contract,
triage), so the target directories follow them. Several jobs have two documented entry points
(`scripts/tron test ios` vs `scripts/tron-ios-test`, `scripts/tron dev` vs `scripts/tron-dev`,
`scripts/tron ios generate` vs `scripts/generate-xcode-project`), and profile/triage/simulator
have none in `scripts/tron`.

**Frozen paths (verified in Gateway source).** The installed (older) Gateway executes these
from the checkout: `scripts/tron` (`admin/diagnose.ts:375`, `document-admission.ts:74`
marker), `scripts/tron_mac_replace.py` (`mac-replace-service.ts:98`), `scripts/tron-ios-device`
(`ios-device-install-service.ts:653`). Their content may change (siblings repointed in the
same commit); their path may not. The Mac app's payload key `app/scripts/gateway-payload-deploy.mjs`
is payload-relative, so its repo source may move. Both LaunchAgents (`fsevents-guard`,
`ios-builds`) embed source, not repo paths.

**Package-root config/pins.** Gateway: `layer-baseline.json` (read by path by layers), three Pi
pins and `third_party/`, `artifacts/` (read by Gateway runtime, payload staging and updaters;
`package.json` has a `file:` dependency) and four vitest configs whose basenames verify parses:
all keep. `artifacts/` holds 18 unreferenced superseded archives (tron.3–8, 32M): delete.
iOS/Mac `project.yml`, xcconfigs, entitlements and `layer-baseline.json`: keep.

**Agent-config dirs.** `.agents/skills` is the one skill home (Pi reads it; `check-agent-policy.sh`
forbids copies). `.pi/` is Pi's project config dir (only `prompts/test-suite-audit.md` tracked)
misused as scratch. `.claude/` is per-user, globally ignored. `.codex/environments/environment.toml`
is stale (its `scripts/tron dev -bdt`/`--stop` actions no longer exist) with no repo consumer.
No duplicates or symlinks.

**Residue elsewhere.** `packages/ios-app/build` 5.5G (still written by `tron-ios-device` while
`tron-ios-test` already uses `~/Library/Developer/Tron/ios`), `packages/ios-app/packages/` 628M
(accidental doubled path, no writer), `packages/mac-app/build` 2.5G, three package
`test-results/`. Outside the repo: `~/Library/Developer/Tron/ios` 91G (2,855 test-run dirs >7d;
`tron-ios-test prune` exists but nothing runs it). Two orphan worktree dirs
(`tron-worktrees/batch-efa0efe43`, `d1-verify-3495d13`, 2.1G each, gitdir pruned). Installed
pre-commit hook is stale (runs `cargo fmt` for the retired `packages/agent`). 112 local branches,
46 merged or idle >14 days.

**Defects found on the way (fixed in the named slice).** `packages/push-relay/package-lock.json`
is tracked but matched by `.gitignore` (S2); `MacTerminalSSH/Package.resolved` is an ignored
lockfile (S2, D9); `packages/gateway/dist` keeps outputs of deleted sources (S2: clean build in
bundle); `tron-profile` dispatches `tron-profile-$kind` by computed name (S4); three Gateway
tests break the naming/colocation convention (S1); four tooling files lack a purpose line (S1).

## 2. Overlap clusters: one entry point per job

| Job | Today | Survivor | Merge in / delete |
|---|---|---|---|
| Doc budgets | `tools/budgets` (after #2134: docs only) and `check-documentation-policy.py` (AGENTS/README budgets) | `scripts/policy/check-documentation-policy.py` | budgets rules and tests merge; `scripts/tron budgets` arm removed |
| Front doors | `scripts/tron test ios` and `tron-ios-test`; `dev`/`tron-dev`; `version`/`tron-version`; `ios generate`/`generate-xcode-project` | `scripts/tron <cmd>` | `tron-*` move into areas as implementations; profile, triage, ios simulator, fsevents-guard, release-doctor get arms |
| Payload build | `scripts/gateway-{install-inputs,payload-deploy}.mjs` and `packages/mac-app/scripts/*` | `packages/mac-app/scripts/` (gateway-payload module) | the two `.mjs` and tests move there |
| Structure checks | `tools/ownership`, `tools/layers`, `tools/metrics`, housekeeping skill's manual steps, deleted `work cleanup` | `scripts/structure/` (`ownership --layout/--ledger`, `layers`, `metrics`, `tidy`) | 3 manifests → 1; skill calls `tidy` |
| Gateway test lock | `tools/verify/gateway.py` lock/queue and a copy in `batch.py` | `gateway.py` | batch imports it (verify slice) |
| iOS source guards | `presentation-source-policy.py`, `sheet-loading-source-policy.py` | `packages/ios-app/scripts/source-policy.py` | two rule sets, one runner |
| Mac payload tests | `test-gateway-payload-verifier.sh`, `test-update-payload-fingerprint.sh`, `test-gateway-payload-precondition.py` | verifier test absorbs the fingerprint self-test | one fewer test entry |
| Release config validators | `verify-gateway-protocol-contract.py`, `gateway_protocol_contract.py`, `validate-push-service-config.sh` (protocol-contract + cli manifests) | `scripts/toolchain/` | one manifest |
| Model release dates | `scripts/update-model-release-dates.mjs` imports Gateway src | `packages/gateway/scripts/` | Gateway owns its vendored data |
| Public X research | `tools/research/public-x.mjs` and the global `x-posts` skill | decided in #2139 | default: `scripts/research/` |
| Scratch | `.pi/*.js`, `test-results/*.md|js|diff`, `tmp/` | `.scratch/` | pruned after 7 days |

Not merged (distinct jobs, verified): `check-pi-sdk.mjs` vs rollback check; payload hash in
shell/Node/Swift (three runtimes; golden test keeps them equal); `verify-gateway-payload.sh` vs
`verify-signed-pi-payload.sh`. Doc-only tooling with no code caller (`compare-pi-sdk-graph.mjs`,
`measure-projection.mjs`, `regenerate-subagent-parity.sh`, `ios-release-toolchain-doctor.sh`,
`update-model-release-dates.mjs`): wire into `scripts/tron`/`package.json` or delete in S4 (owner call).

## 3. Target layout

```text
AGENTS.md  README.md  .gitignore  .gitattributes  .node-version  root.module.json
.agents/skills/          the only skill home (Pi, Claude, Codex read it)
.github/                 dependabot.yml, work.json
.pi/prompts/             Pi project prompts only (no scratch)
config/                  version.env, ci-toolchain.env, GatewayProtocol.json, PushService.xcconfig
docs/                    PRINCIPLES.md, development.md
packages/<pkg>/          product code, its tests, fixtures, package tooling (scripts/), docs/
  gateway ios-app mac-app push-relay protocol-fixtures web
scripts/                 tron, tron-node, tron-ios-device*, tron_mac_replace.py*  (*frozen)
  README.md scripts.module.json
  toolchain/ dev/ ios/ mac/ policy/ structure/ verify/ work/ profile/ triage/ research/
.scratch/  test-results/  (ignored; pruned)
```

Rules (each enforced in §5):
- **Source** `packages/<pkg>/…` by module; one manifest per module directory.
- **Tests** beside what they prove (§4). **Fixtures** module-local `fixtures/` or package
  `test-fixtures/`; **goldens** `locks/` (Gateway) or `UITests/Locks/Goldens/` (iOS, LFS).
- **Repo tooling** `scripts/<area>/` with its tests and `<area>.module.json`; started via
  `scripts/tron`. **Package tooling** `packages/<pkg>/scripts/`.
- **Docs**: repo-wide policy/runbook in `docs/`; everything else beside its owner
  (`docs/restructure/k0-kernel.md` → `packages/gateway/docs/kernel.md`; `tools/verify/*.md`,
  `test-oracles.md`, `core-journeys.md` → `scripts/verify/`; `docs/design/causal-auto-revert.md`
  merges into `scripts/verify/batch.md`; Home retro design → `packages/gateway/docs/home-retro.md`;
  `FINDINGS.md` deleted as an evidence ledger).
- **Agent scratch** `.scratch/` only. **Build output** stays where its toolchain puts it, ignored
  and owned by a writer listed in `tidy`; iOS device builds join `~/Library/Developer/Tron/ios`.
- No symlinks, aliases or compatibility copies: every move updates its consumers atomically.

**Manifest simplification.** Keep co-located manifests (they are the locality breadcrumb and
avoid one central conflict file) but: (1) root holds only `root.module.json`; (2) one manifest
per `scripts/<area>/` owning `**`, so tests and tools share an owner without file lists; (3) add
an optional one-line `purpose` key, made required for new manifests by the layout rule, so the
generated ledger has a purpose for every file; (4) keep `layer`, `dependsOn`, `dynamicEdges`,
`riskClass`, `verify`, single-owner and placement rules unchanged. Net: 101 → 96 manifests
(−7 merged or deleted, +2 new areas `structure`, `toolchain`; package manifests untouched).

## 4. Test boundaries

| Kind | Where | May import / drive | Checked by |
|---|---|---|---|
| Gateway integration (incl. lock) | `src/<module>/*.integration.test.ts`, goldens `locks/` | its module, `test-support/`, other modules' public files within layer direction | layout naming rule; vitest include; `tsconfig` rootDir `src` keeps test code out of production |
| Gateway E2E | `src/<module>/*.e2e.test.ts` | real Gateway process via `test-support/gateway-process` | same |
| Gateway package tooling | `scripts/*.integration.test.mjs` | its script by path, temp dirs | verify node runner |
| Tooling | `scripts/<area>/test-*.py|sh`, `*.test.mjs` | its area by path, temp Git repos and `HOME` | layout (no tests at `scripts/` top); verify python/shell/node runners |
| iOS | `UITests/`, `E2ETests/`, `ProfilingTests/`, `SwiftAppUITests/` targets | app via XCUITest; E2E via real Gateway harness | layout Swift rule; XcodeGen target membership; verify `is_test` |
| Mac | `Tests/Integration/`, probes `Tests/Fixtures/` | `@testable TronMac` | same |
| Push relay | `tests/*.integration.test.ts` (Workers pool) | Worker via `SELF` | vitest config |

Verify's `is_test` and runner mapping already key on these names and refuse a test with no
runner; S3 widens `declared_files` from `scripts/test-` to `scripts/**/test-`. Known gap kept
visible, not moved: iOS `Fixtures/` compile into the app target (product decision, not layout).

## 5. Regression guards and self-healing loop

| Guard | Exact check | Runs | Measured |
|---|---|---|---|
| G1 ownership + layout | `scripts/tron ownership --layout`: every tracked path owned once (existing) plus `tools/ownership/layout.py` rules: root allowlist; only `root.module.json` at root; `scripts/` top = 4 entries + README + manifest; area manifest named for its dir; frozen paths present; tooling purpose line; no tests in root/docs/config/.agents/`scripts/` top; Swift tests only in test targets; Gateway test naming and no `tests/` dirs | pre-commit (index) and `verify` static step (any rev) | 0.19–0.40 s whole repo (main's ownership alone 0.45 s cold); 111 violations today = the migration worklist |
| G2 privacy | existing `personal-info-guard.sh --staged` | pre-commit, verify | 0.23 s |
| G3 generated ledger | `scripts/tron ownership --ledger`: path, module, layer, purpose (script header or manifest purpose) | on demand; replaces a hand ledger | 0.22 s |
| S sweep | `scripts/tron tidy [--json]`: untracked files, ignored paths with no known writer, expired scratch (7 d) / evidence (14 d), `__pycache__`, tooling nothing names, orphan worktree dirs, worktree merged/dirty/live/idle, merged or idle branches, installed hook drift | manual, weekly Home automation (D7) | 9.1–9.9 s (dead-tooling scan 3–4 s) |
| P prune | `scripts/tron tidy --prune`: deletes only expired `.scratch`/`test-results` entries, bytecode, branches merged into origin/main and not checked out (prints `git branch <name> <sha>` to restore), worktrees merged + clean + no live process + idle ≥3 d | anytime | same run |

Failure messages are the fix (from the prototypes): *"root entry 'tools' is not in the layout;
put it under scripts/, docs/, config/ or a package (AGENTS.md 'Where things go'), or delete it"*;
*"scripts/test-tron-docs.py: tests live beside their tool in scripts/<area>/"*; *"scripts/foo:
scripts/ top level holds only scripts/tron, tron-node and the frozen entry points; put it in
scripts/<area>/ and add a scripts/tron subcommand if people run it"*; *"scripts/tron-ios-device
is missing: the installed Gateway executes this path; restore it"*; *"…: add a one-line purpose
comment in its first 12 lines (what it does, who runs it)"*; tidy: *"no code, config or test
names it: wire it into scripts/tron or delete it"*, *"ignored path with no owner: delete it, or
add its writer to tidy KNOWN_IGNORED"*.

**Hook.** `install-hooks.sh` writes a one-line hook `exec scripts/tron hook pre-commit`; the
tracked arm runs G2 then G1 (~0.6 s). Hook content never drifts again; `tidy` reports a
non-managed hook. Not added: a hand ledger, a duplicate-purpose detector (not mechanical: the
command table plus "search before writing" and review cover it), new CI (`.github` has no
workflows; verify and the post-land batch are the gates).

**Loop.** (a) G1/G2 fail fast at commit with the fix. (b) `tidy --prune` is safe anytime.
(c) A weekly Home automation runs `scripts/tron tidy --json` and creates or updates one
"Repository hygiene" issue through `scripts/tron work issue` listing drift; it never deletes.
(d) A file cannot land without an owner, a purpose (tooling) and a sanctioned place, so the
generated ledger stays complete. Guards tighten per slice: each slice removes the allowlist
entries it clears, so no baseline file or waiver is needed.

Prototype on this branch (not for landing as is): `tools/ownership/layout.py`, `--layout`/
`--ledger` and `purpose` in `ownership.py`, `tools/ownership/tidy.py`. Runtimes above are
from these on this Mac, warm cache.

## 6. Agent breadcrumbs

Pinned Pi 1.3.0 loads context files only from the agent dir, the cwd and its **ancestors**
(`docs/configuration.md` "Context files"; `dist/core/resource-loader.js` `loadProjectContextFiles`
walks parents only). Workers run with cwd at a worktree root, so a nested
`packages/gateway/AGENTS.md` would load only for sessions started inside that package; Codex
uses the same cwd→root rule and Claude Code reads nested `CLAUDE.md`, not `AGENTS.md`. Nested
AGENTS.md files would therefore be invisible to nearly every worker. Breadcrumbs instead:
1. Root `AGENTS.md` "Where things go" (11 lines, charter stays ≤150): `breadcrumbs/AGENTS-where-things-go.md`.
2. `scripts/README.md` command table and add/change/remove procedure (≤80 lines): `breadcrumbs/scripts-README.md`.
3. One `## Layout` section (≤12 lines) per package README and the root README map:
   `breadcrumbs/package-layout-sections.md`.
4. Guard messages (§5) at the moment a file lands in the wrong place.
5. `tron-workspace-housekeeping` skill shrinks to "run `scripts/tron tidy`, act on its report".

## 7. Migration slices (after #2134, #2141, #2139 land; serial; each lands green alone)

**S1 Guards and breadcrumbs, no moves.** Land `layout.py`, `--layout` (default on in verify's
ownership step and the hook), `--ledger`, manifest `purpose`, `tidy`, `scripts/tron hook|tidy`
arms, managed hook, `.scratch/` ignore, `PYTHONDONTWRITEBYTECODE` for tooling tests. Allowlists
start at today's tracked tops and today's `scripts/` top-level files, so the guard is green and
blocks new sprawl from day one. Fix the 3 Gateway test names/dirs and 4 purpose lines. Charter
section + README map (current paths). Verify: `scripts/tron test tooling
scripts/test-tron-ownership.py` with new temp-repo cases (fail-before/pass-after for each
rule), new `test-tron-tidy.py` (temp repos: merged/unmerged/dirty/live/orphan, restore line),
`scripts/tron verify --plan`, `check-documentation-policy.py`, `check-agent-policy.sh`. Risk:
low; independent review for test additions.

**S2 Residue and ignore rules.** `.gitignore`: un-ignore `packages/push-relay/package-lock.json`,
track `MacTerminalSSH/Package.resolved` (D9), drop `tmp/`, add `.scratch/`. `tron-ios-device`
writes DerivedData under `~/Library/Developer/Tron/ios` (content change of a frozen path) and
`tron-ios-test` runs `prune` on exit. Then, with maintainer approval of the first run (D5):
`tidy --prune`; delete root `build/ tmp/ h3.log node_modules/`, `packages/ios-app/{build,
packages,TestResults.xcresult,node_modules}`, August `.pi/subagents/`, move current `.pi/*.js|md`
to `.scratch/`; inspect then remove the two orphan worktree dirs. Verify: `tidy` drift → only
items needing owner decisions; `scripts/tron test ios` smoke on one lane; tooling tests for
`tron-ios-device` paths (`test-ios-test-infrastructure.py` asserts the old path today). Risk: low;
frees ~7 GB in-repo plus expired iOS test runs.

**S3 tools/ → scripts/<area>/ and root manifests.** `tools/{ownership,layers,metrics}` →
`scripts/structure/`; `tools/verify` → `scripts/verify/`; `tools/work` → `scripts/work/`;
`tools/docs` + budgets → `scripts/policy/`; `tools/research` → `scripts/research/` (or #2139's
choice); matching `scripts/test-*` beside them; 7 root manifests → area manifests; docs moves
in §3. Update: `scripts/tron` dispatch, `verify.py` (`declared_files`, `COPIED`, sys.path),
tooling tests' `sys.path`/fixture copy lists, `.github/work.json`, layer-baseline comments,
`docs/development.md`, READMEs, AGENTS.md links, skills, `packages/gateway/.../home-task-continuity.e2e.test.ts`
(runs `tools/work/cli.py`). Tighten root allowlist (drop `tools`, root manifests). Verify: every
moved tooling test, `scripts/tron verify --plan` on the slice itself, `ownership --layout`,
docs/agent policy, Gateway e2e above. Risk: medium (verify verifies itself; run its tests first).

**S4 scripts/ flat → areas** in three landings: S4a toolchain + ios (incl. `project.yml`
build-phase paths in both apps → `scripts/tron ios|mac generate` + one simulator build; Swift
XCTSkip/comment paths; `packages/gateway/package.json` device-bind test path; tron-ios-device
sibling paths; skills `tron-ios`, AGENTS `scripts/tron-ios-test` → `scripts/tron test ios`);
S4b mac + dev + payload (`tron_mac_replace.py` adds `scripts/mac` to `sys.path`; payload `.mjs`
into `packages/mac-app/scripts/`; `bundle-gateway.sh`, `stage-gateway-app.sh`,
`hash-gateway-payload.sh`, `gateway-install-inputs` fingerprint list; `scripts/tron bundle
gateway` + `verify-gateway-payload.sh` + payload tests + `scripts/tron dev restart` on the Debug
Gateway after reading `status`); S4c profile, triage, policy + new `scripts/tron` arms and the
doc-only tooling decisions. Tighten `scripts/` allowlist to the target. Risk: highest (payload
hash inputs, Xcode build phases, frozen entry content); each sub-slice runs its affected
payload/Xcode checks and never touches `/Applications` or Stable.

**S5 Packages and docs.** `tools/web` → `packages/web` (iOS `project.yml` folder sources +
regenerate, `ios-gateway-e2e-test`, `ios-share-publish.py`, Swift comments, layer baselines);
`VERSION.env` → `config/version.env`; delete `.codex/` (D6); Mac probe → `Tests/Fixtures/`;
iOS source-policy merge; Mac payload test merge; delete tron.3–8 archives; Gateway
`docs/kernel.md`. Final allowlists = target; package README Layout sections; delete
`docs/restructure/{structure-plan.md,inventory*,audit,breadcrumbs,modules.tsv,targets.tsv}`.
Verify: ios generate + simulator build, Swift-apps UI journey that bundles builds-preview,
pi-subagents scripts tests, docs policy. Risk: medium (XcodeGen folder source).

**S6 Hygiene automation** (after D7): one weekly Home schedule running `scripts/tron tidy --json`
and filing drift to one issue. No deletion from the automation.

Each slice: own worktree, `scripts/tron verify --plan` then affected checks, independent ACCEPT
for test edits, `--no-ff` landing per the Git skill, issue closed with commands and results.

## 8. Decisions for Mohsin

| # | Decision | Recommendation | Why |
|---|---|---|---|
| D1 | One tooling home | Fold `tools/` into `scripts/<area>/` | `scripts/tron` is frozen and referenced in 215 files; `tools/` has 75 |
| D2 | One front door | All human-run commands become `scripts/tron` subcommands; `tron-*` move into areas | one documented entry per job; docs churn is mechanical |
| D3 | Perpetual ledger | Generated (`ownership --ledger` from manifests + purpose lines), not a committed per-file table | a 2,000-row hand file goes stale and conflicts; coverage is enforced by G1 instead |
| D4 | Breadcrumb form | Root section + `scripts/README.md` + package Layout sections + guard messages; no nested AGENTS.md | Pi/Codex load only cwd ancestors; workers start at the worktree root |
| D5 | Prune scope | `tidy --prune` may delete expired scratch (7 d), evidence (14 d), bytecode, merged non-checked-out branches (restore line printed) and merged clean idle ≥3 d worktrees; orphan dirs and unmerged branches report only | merged content is on main, so nothing unique is lost; first run approved by you |
| D6 | `.codex/` | Delete | stale actions, no consumer; Codex users can regenerate locally |
| D7 | Weekly sweep | One weekly Home automation filing drift to one issue | report-only; you approve the schedule |
| D8 | Scratch location | `.scratch/`, and change the pi-subagents tool text example `.pi/<name>.js` → `.scratch/<name>.js` | `.pi/` is Pi's trusted config dir; the example is why agents write there (model-visible text needs your OK) |
| D9 | Lockfile | Track `MacTerminalSSH/Package.resolved` | charter requires exact pins/lockfiles |
| D10 | Old Pi archives | Delete tron.3–8 (32M) from the tree | unreferenced; history and the pin's current/previous stay |

## 9. Assumptions, coordination and residual risk

- #2134 removes `tools/metrics/moved.py`, `scripts/test-tron-measure.py`, `docs/restructure/plan.md`
  and the 800-line gate; #2141 removes claim tooling and five `test-work-*` files (and must rewire
  `home-task-continuity.e2e.test.ts` and `.github/work.json`); #2139 decides `tools/research`.
  Ledger rows mark these `delete (in-flight)`. Re-run `inventory.py build` after they land; the
  ledger must stay at 0 unaccounted before S3.
- `src/client/work-owner-status.ts` loses its only consumer with #2141; delete it there.
- Not verified by execution: payload fingerprint change on S4b moves, XcodeGen output with moved
  build-phase scripts, iOS `Fixtures/` Release stripping. Each is a named check in its slice.
- Scout caller counts are grep-based; slices re-derive exact consumers with `rg` before editing.

Reproduce: `python3 docs/restructure/inventory.py build && python3 docs/restructure/inventory.py check`;
`python3 tools/ownership/ownership.py --layout`; `python3 tools/ownership/tidy.py`.
