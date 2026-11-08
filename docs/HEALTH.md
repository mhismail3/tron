# Repository health

What health is for: **the maintainer gets a product that works and keeps changing the way he wants.**
So health is measured by outcomes (below). Structural measures are diagnostics: they stay only while
a backtest on Tron's own history shows that they predict those outcomes. Every number here is a
signal for choosing work, never a gate, a target or a reason to drop a capability.
`scripts/tron health` recomputes them ([tools/metrics/health.py](../tools/metrics/health.py));
the full scorecard lives outside the repository, in the internal workspace
`files/repo-health-20261108/` (`files.csv`, `folders.csv`, `modules.csv`, `REPORT.md`).

## Metrics

Primary metrics are the four outcomes. Each one lists what it protects, how it is measured, how it
misleads, and the counter-metric that catches that.

| | Outcome (protects) | Measured by | Misleads when | Counter-metric |
|---|---|---|---|---|
| O1 | **Escaped defects**: what reaches him works | `kind:bug` issues opened per landed change (`--github`), plus a hand-labelled sample of 40 of his Home messages per re-score (share that report a defect) | bugs are not filed, filed as `kind:maintenance`, or closed as duplicates; fewer changes land | O2 defect-report share (he notices what is not filed); O4 rework after landing |
| O2 | **Maintainer attention**, the scarcest resource | his typed Home messages per landed change, and the share that chase status (`--home-sessions`; the regex gives 15%, a hand check 17.5%) | Home batches questions; landing many trivial commits inflates the denominator | O3 lead time; the sample's share of process steering (he redesigns how agents work) |
| O3 | **Lead time** from his ask to a working build | bug opened → closed (`--github`); landed → next Mac deploy and deploy failures (`--deploy-log`). The iPhone build has no mechanical timestamp yet | issues opened late or closed early; deploys skipped | O1 (fast but broken); O4 |
| O4 | **Verdict trust**: red means a real fault, green holds | share of red/flake issues that a commit naming them fixed in production code (`--github`, a lower bound); batch verdicts and same-head green+red flips (`--evidence`); landed merges, older than three days, whose issue a later commit or fix names again | reds are closed "not planned" without a cause; tests are deleted to stop reds | O1 escapes; mutation kill rate on hotspots (`scripts/tron mutate`) |

Diagnostics, with their validation status (backtest below). "Validated" means it predicted later
rework on Tron's history better than chance in both backtests; it is still not proof of cause.

| | Diagnostic | Status | Use |
|---|---|---|---|
| D1 | Size × churn per file (the file score) | **validated, weakly** | Rank where to look. Not a quality grade. |
| D2 | Rework: fix share of commits, reverts, fix share hitting the top-15 hotspots | outcome-adjacent | Trend only. |
| D3 | Change locality: modules per landed change | **hypothesis**, partly supported | Follow-up fixes rise with areas touched (70% → 100%), but that is mostly size. |
| D4 | Collisions: merges that re-resolve a conflict; collision-prone files | cost signal | Feeds the collision rule below. |
| D5 | Oracle cost: goldens, hash pins, commits touching goldens, test/production lines | **test lines refuted** as a quality proxy | Pins and goldens count as cost; test lines are not strength. |
| D6 | Navigability: module purpose coverage | **hypothesis, no evidence** | Do not grow docs or rules to move it. |
| D7 | Feedback latency per verify lane | hypothesis (no history to backtest) | Speed work only where a lane blocks landings. |

Code per capability and thin-client ratio are context, not metrics. At capability level, size
predicts absolute fix count (Spearman 0.86 over 23 capabilities). That makes size exposure, not
quality: per change, rework is nearly independent of size. Counting capabilities needs a judgment
attribution (±10%). As a target it rewards merging or dropping capabilities and moving code into
"platform", which already holds 35% of lines.

## Evidence

| Source | Finding | Weight for Tron |
|---|---|---|
| Nagappan & Ball, ICSE 2005 | Relative churn predicts defect density; absolute churn and size predict poorly | Medium. **Tron disagrees:** relative churn ρ 0.24 vs size 0.44 (young, agent-rewritten files) |
| Moser et al., ICSE 2008; Hassan, ICSE 2009 | Change-process metrics beat static code metrics | Medium; consistent with D1 (churn) |
| D'Ambros et al., WCRE 2009 | Change coupling correlates with defects | Medium; Tron co-change ρ 0.36, close to size |
| Tornhill & Borg, "Code Red", arXiv 2203.04374 (39 codebases) | Low-health code: 15× defects, 124% longer resolution | Medium (vendor tool). Tron: the score finds where fixes land, weakly whether work is rework |
| SWE-Bench Pro, arXiv 2509.16941 | Reference fixes span 4.1 files; resolve rate falls sharply with file count | Medium; supports D3, which Tron's data only partly confirms |
| "Evaluating AGENTS.md" (ETH), arXiv 2602.11988 | Context files do not raise task success and add over 20% cost; only non-standard practices help | High for D6: rules and docs are not navigability |
| Wang, Pradel, Liu, arXiv 2503.15223 | 7.8% of "passing" patches fail the developer tests; 29.6% behave differently | High for O4: a green that a weak oracle gives is not a fix |
| Google Testing Blog, "Flaky tests at Google", 2016 | 84% of pass→fail transitions involve a flaky test; 16% of tests are somewhat flaky | High for O4; Tron: about 11% of red issues led to a product fix |
| Inozemtseva & Holmes, ICSE 2014; Just et al., FSE 2014 | Coverage barely predicts suite effectiveness; mutant detection tracks real-fault detection | High for D5: count mutation kills, not test lines |
| DORA (dora.dev metrics, 2024 five-metric model) | Lead time, deploy frequency, recovery time, change-fail rate, rework rate | High: O1, O3, O4 are its one-maintainer analogues |

Where evidence contradicts a framing: (1) **lines per capability** is exposure, not health (above);
(2) **hotspot = churn × size × fix ratio**: prior fix count is the weakest and least stable predictor
(ρ 0.15 at Oct 15, 0.28 at Oct 22), so the file score weights fixes least; (3) **navigability through
AGENTS.md and manifests** has no support; (4) **test growth** (128k → 159k lines) bought no
measurable reduction in rework.

## Backtest (validation)

The candidate diagnostics were measured at `3f2d82cc8` (Oct 15) and `be7b6f232` (Oct 22). Outcomes:
fix commits, reverts and bug-referencing commits from then to `356b00a3b`, with files followed
through renames. Reproduce with `scripts/tron health --backtest <T0>`.

| Diagnostic at T0 | ρ vs later fixes (Oct 15 / 22) | top 10% catch of later fixes | ρ vs later fix share |
|---|---:|---:|---:|
| size | 0.44 / 0.36 | 33% / 30% | 0.15 / 0.19 |
| churn (commits, 30 d) | 0.43 / 0.39 | 32% / 36% | 0.15 / 0.15 |
| relative churn (churned lines / size) | 0.24 / 0.19 | 22% / 26% | 0.03 / 0.03 |
| prior fix commits | 0.15 / 0.28 | 26% / 32% | 0.07 / 0.15 |
| hotspot (fixes × kLOC) | 0.16 / 0.30 | 28% / 36% | 0.07 / 0.16 |
| cross-area co-change | 0.36 / 0.36 | 31% / 34% | 0.13 / 0.20 |
| file score (inverted) | 0.42 / 0.38 | 31% / 33% | 0.17 / 0.21 |

Random catch is 10%. Fix share is computed over files with three or more later commits, so it asks
"is the work rework" rather than "will work happen here". Area level (19-21 areas): test/production
line ratio vs later fix share ρ −0.09 / 0.03. Change level: landed changes touching 1, 2, 3-4, or 5+
production areas were followed by a fix to their files within 7 days 70%, 84%, 93%, 100% of the time,
but per file the rate falls (0.28 → 0.04). Reopened issues are not usable: 21 of 1,809, mostly
same-day procedural reopens. The weights were set after the Oct 15 run; Oct 22 is the check.

## Baseline (`356b00a3b`, 2026-11-08; 30-day windows)

Replaced, never appended, at each re-score. Oct 20 (`4c046a814`) in brackets where comparable.

- O1: 544 bug issues, 0.28 per landed change [678, 0.47]. Hand sample: defect reports were 12.5% of
  his Home messages on Oct 12-25 and 7.5% on Nov 1-8 (n=40 each, so the error is wide).
- O2: 1,169 Home messages, 0.60 per landed change, 15% status chases [Oct window incomplete]. In the
  hand sample, steering of process (plans, rules, models, agents) went from 17.5% to 22.5%, within
  sampling error.
- O3: bug opened → closed p50 2.2 h, p90 53 h [3.2 h, 117 h]; landed → Mac deploy p50 11 h, p90 40 h
  [8 h, 42 h]; 11 of 56 deploys failed or rolled back [13 of 62]; the week of Nov 2 had 0 of 6.
- O4: of 105 red or flake issues opened, a commit naming the issue changed production code for 11.4%,
  only non-production paths for 20%, and 68.6% have no naming commit. Batch: 1 of 15 runs green; the green head
  (`efa0efe43`) went red on both repeats; no batch has run since Nov 4. 50% of landed issue merges
  had their issue named again later, 22% by a fix.
- Diagnostics: file score 5.75 [4.87]; fix share 15.0% [17.7%]; reverts 5 [12]; fix commits on
  top-15 hotspots 31% [44%]; conflicted merges 5.3% [44%]; goldens 29 files, 621 hash pins [55, 755];
  fixture lines 30,291 [93,246]; tests 158,785 lines, 0.64 of production [128,390, 0.50]; lane p50:
  Gateway 180 s, iOS shard 145 s, Python 412 s.

**Overall: 4 / 10.** Anchors: 0 = he finds a defect in most sessions, steers every change, waits
weeks for builds, and a red means nothing; 10 = defects reach him rarely, he only states intent and
judges taste, a working build arrives the same day, over 90% of reds are real and over 95% of greens
hold. Scores: O1 4, O2 4, O3 6, O4 2. Structure scores 5.4 (files, line-weighted). Credit since
Oct 20: bugs per landed change −41%, hotspot share 44.6% → 22.2%, conflicted merges 44% → 5%,
reverts 12 → 5, fixtures −68%, production −8.9k lines. Not better: test
mass +24%, verdict trust, and his attention per landed change.

Top hotspots and their cause (fix commits × kLOC in 30 days):
**hub** = one file absorbs every cross-capability change; **mirror** = a test or fixture that
re-encodes the UI; **taste** = visual iteration.

| # | File | Cause |
|---:|---|---|
| 1 | `ios-app/UITests/TronSmokeUITests.swift` (4.5k) | mirror: 132 commits; every route, chip or copy change edits it |
| 2 | `gateway/src/kernel/run/runtime-slot.ts` (4.8k) | hub: Home wake admission, approval path, tool admission all land here |
| 3 | `ios-app/Sources/State/AppModel.swift` (5.5k) | hub: approvals chip, push routing, scene admission |
| 4 | `ios-app/Sources/UI/Theme/TronPresentation.swift` (2.7k) | taste: shared row, header and sheet chrome polish |
| 5 | `scripts/test-ios-test-infrastructure.py` (6.9k) | mirror: lane and lease tooling self-tests |
| 6 | `gateway/src/modules/home/home-owner.ts` (2.0k) | hub: wakes, obligations, task lineages, settings outcomes |
| 7 | `gateway/src/transport/gateway-service.ts` (2.7k) | hub: RPC dispatch for every capability (92 commits) |
| 8 | `gateway/src/kernel/session/runtime-registry.ts` (4.5k) | hub: session lifecycle, admission and projection |
| 9 | `ios-app/Sources/UI/Chat/ChatView.swift` (3.7k) | taste + hub: layout, wiring and sheets in one view |
| 10 | `ios-app/Fixtures/HostedChatDisplayFixture.swift` (1.6k) | mirror of chat display |
| 11 | `gateway/src/kernel/settings/settings-change.ts` (0.7k) | state: change and Undo stripe; 22 of 40 commits are fixes, 3 reverts |
| 12 | `tools/verify/verify.py` (1.0k) | tooling: selection and quarantine rules keep changing |
| 13 | `ios-app/Sources/UI/Chat/SessionShellView.swift` (1.5k) | taste: chat shell sheets and toolbar |
| 14 | `gateway/src/transport/server.ts` (3.0k) | hub: WebSocket dispatch |
| 15 | `scripts/ios-gateway-e2e-test` (1.6k) | mirror: parallel UI-journey harness |

## Plan (the single living plan; ranked)

Ranked by outcome gap first, then hotspot, and re-ranked at each re-score. Epics with their own
proxy targets are not created alongside it.

1. **Verdict trust (O4).** Run the batch on main daily again and record why each red closes
   (product, test, harness). Convert whole-trace goldens with prompt-hash pins into behaviour checks
   (#2279). Measure mutation kills on the top-5 hotspots before and after.
2. **Split the mirrors.** Split `TronSmokeUITests.swift` per journey, and give the hosted fixture one
   owner per screen, so a UI change touches one test file.
3. **Split the hubs by owner:** `runtime-slot.ts` into admission, queue, terminal and drain; then
   `home-owner.ts` and `AppModel.swift`. Prove each extracted step with the proof candidates below.
4. **Proofs for recurring bugs** (Dafny; ranked): approval decide/apply exactly once (141 commits,
   27 fixes since Oct 1; #2050, #2015, #2159); task stop/resume/settle with uncertain create (H10,
   #2319, #2238, #2256); exactly-once Home wake (#2213, #1620, #1518); settings precedence with
   Project on top (H1) and order-preserving tool selection (H6, #2318); wire v8 receipts and ordered
   outbound queue (#1729, #2186); Home memory summary coverage (#2311, #2314, #2228); then
   automations, notification delivery, drain, and a template law for the next migration.
   Workspace `REPORT.md` names the tests each proof would shrink.
5. **Thin client, low-risk batch first:** have the Gateway send ordering, availability flags and
   domain-value labels (about 300 iOS lines low risk, 500 medium). Transcript grouping and window
   reconciliation (about 1.5-2.5k lines) move only behind the scroll, identity and motion UI
   regression tests.

## Collision rule

Before editing a shared hot file (any `*.golden.*`, `AGENTS.md`, `docs/PRINCIPLES.md`,
`scripts/tron`, or a file that `scripts/tron health` lists as a hotspot or collision-prone), list
the open work that touches it, and coordinate or wait if any does:

```bash
f=<path>; git fetch -q origin
for b in $(git for-each-ref --format='%(refname:short)' refs/heads refs/remotes/origin); do
  git merge-base --is-ancestor "$b" origin/main || git diff --quiet origin/main..."$b" -- "$f" || echo "$b"
done
git worktree list --porcelain | sed -n 's/^worktree //p' | while read -r w; do
  [ -n "$(git -C "$w" status --porcelain -- "$f")" ] && echo "dirty: $w"; done
```

## Cadence

Re-score after about two weeks of ordinary feature and bug work (next: about 2026-11-22). Run
`scripts/tron health --github --evidence --deploy-log ~/.tron/logs/deploy.jsonl
--home-sessions <Home session dir> --backtest <commit two weeks back>`, hand-label 40 Home
messages, and replace the Baseline. Then demote any diagnostic whose backtest no longer beats
chance, and add one only with a backtest.
