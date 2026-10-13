# Eval-driven hill-climbing (prototype, #885)

How a background agent can pick one aspect of Tron, measure it objectively,
and improve it one causal change at a time without fooling itself or anyone
reviewing the result. This directory holds the eval specs; the trial runner is
`scripts/tron-hillclimb`; the agent procedure is the
[tron-hillclimb skill](../../.agents/skills/tron-hillclimb/SKILL.md).
Status: prototype on an unmerged branch. Nothing here runs automatically.

Source of the principles: Anthropic's *Automating eval design and
hill-climbing* (claude-api `build-eval` / `hillclimb`). Their loop: an eval
that mirrors production, low run-to-run variance, headroom, a noise check
before the first round, one root-cause change per round, a train/test split
that reverts train-only gains, a reflection pass when the score stalls, and a
final report against the baseline with its noise. Most of that maps onto Tron
directly; the main difference is that Tron's cheapest objective metrics are
deterministic programs, not LLM graders, so "grader variance" becomes
"measurement plumbing" and "held-out cases" become held-out scenarios.

## 1. Recommendation

1. **Climb only metrics the existing profiler already measures with a
   deterministic workload.** Start with Gateway wire metrics
   (`scripts/tron-profile gateway`): faux model, fresh fixture Gateway, integer
   counts that repeat exactly. Reuse `scripts/tron_profile_report.py` as the
   single owner of the noise bound and verdict; the runner adds only ABBA
   ordering, an A/A drift control, held-out scenarios, correctness commands and
   a path guard.
2. **The runner decides, the agent proposes, the maintainer lands.** The agent
   may edit only the spec's `editable` paths; the runner (frozen) writes
   `verdict.json`; every kept change is a pushed branch plus an issue comment,
   never an automatic merge.
3. **Each trial is a finite Home task; recurrence is a maintainer-owned
   Automation.** Home refuses scheduled and mission work, so Home cannot be
   the scheduler. See [section 8](#8-fit-with-the-task-and-worker-model).
4. **Fix plumbing before climbing anything timing-based.** On this shared Mac
   (load average 20–67 during this prototype, 18 CPUs) CPU and wall-clock
   metrics are not gateable, and the `tool-loop` scenario itself fails
   `session.open` deadlines under load.

## 2. Metric inventory

Measured on 2026-10-13 on the shared host unless marked otherwise. "Noise"
is the median absolute deviation (MAD) of the samples; the compare bound is
`max(3 × 1.4826 × MAD, floor × median, 1 unit for integer counts)`.

| Aspect | Metric (source) | Cost per sample set | Noise today | Ready to climb? |
|---|---|---|---|---|
| Gateway→phone traffic, streaming | `wire.mobile.total.frames` / `.bytes`, `stream-reply` (`tron-profile gateway`) | ~2.5 min for 5 iterations incl. build | frames 164, MAD 0; bytes 681.38 KiB, MAD 863 B (0.12%) | **Yes** |
| Gateway→phone traffic, tool turn | same metrics, `tool-loop` | ~2 min for 3 iterations | frames 228, MAD 2; bytes 14.34 MiB, MAD 5.8 KiB (0.04%) at load ~19; under heavy load frames MAD 3.5 (A/A bound ±13–16) and bytes vary 4% as snapshots turn into rebaselines | **Yes, on a quiet host** (fails `session.open` 10 s deadline under load) |
| Gateway CPU | `gateway.cpu.instructions` (same runs) | free with the above | 1.206 G, MAD 80.7 M (6.7%) → bound ≈ 30% | Not gateable on this host; report only |
| iOS CPU per scenario | instructions retired (`tron-profile ios`, owned simulator) | minutes + simulator lease + memory admission | unmeasured here (needs `--self-test`) | Next, after a quiet-host noise study |
| iOS launch / sheet load | not instrumented as a profiler scenario | — | — | Needs a scenario in `ProfilingTests/` first |
| Gateway startup | `gateway.startup-budget` log record (fixture logs it: 6,165 ms of 5,000 ms, modules 3,060 ms, under load) | free with fixture runs | host-load dominated | Needs extraction into the report and quiet-host gating |
| Reconnect / connection resilience | `multi-session` qualification (blackhole, bandwidth, restart) | 10+ min, 2 GiB catalog, memory guard | pass/fail with counters | Use as a **guard**, not a target |
| Memory | RSS/heap only in `gateway.event-loop-delay` records | — | — | Add fixture peak RSS/heap to the gateway report |
| Test / build / land time (#833, #870) | `work verify` prints per-check seconds to stdout only; logs deleted by `work cleanup` | — | wall time dominated by other agents' builds | Needs a durable per-check timing record first; climb CPU time, not wall time |
| Token cost | Home audit reports (`tron-home-audit`) from canonical sessions | observational | not repeatable | Needs a replay or fixed-prompt eval; paid |
| Home answer quality | none | — | — | Needs a build-eval style case set, rubric judge, train/test split, privacy review |
| Skill triggering / routing | none | cheap (text surface) | — | Best LLM-side candidate: attributable, cheap to edit (the article's strongest examples) |

Observations the inventory surfaced (not acted on here):

- **`tool-loop` sends a phone 14.34 MiB of decoded JSON per turn**, 12.94 MiB of
  it in 23 `session.snapshot` frames of a page near the 600 KB bound. Socket
  bytes are far smaller because `permessage-deflate` compresses the
  repetition, but the phone still decodes every byte. This is a protocol-level
  design question, outside what an automated loop may change.
- `stream-reply` sends 638.69 KiB of cumulative `session.progress` for a
  6.8 K-character answer (145 frames); socket bytes are 13.64 KiB. Same
  boundary: cumulative progress is the protocol.
- Under host load the fixture Gateway missed its startup budget and shed
  `session.open` after 11–28 s with 5.3 s event-loop delay and 3.7 s of GC.
  That is a real responsiveness signal on a busy Mac, and the reason the
  runner gates on host headroom.

## 3. Eval spec format (`tron.eval-spec.v1`)

One JSON file per eval under `tools/hillclimb/specs/`. Example:
[gateway-turn-frames.json](specs/gateway-turn-frames.json).

| Field | Meaning |
|---|---|
| `id`, `question`, `why_objective` | What production behavior this mirrors and why the measurement is objective. |
| `harness` | Profiler tool, scenario, arguments, `rounds` (ABBA pairs) and `max_load_per_cpu` host gate. |
| `primary` | One metric, direction, and `min_effect`: the smallest change worth keeping. Must exceed the measured noise bound. |
| `ungated` | Metric globs reported but never decisive (host-load or window-length sensitive), with `ungated_reason`. Every other metric is a guard: any regression beyond noise reverts. |
| `held_out` | Scenarios the climbing agent never inspects; a regression there reverts (the article's test split). |
| `correctness` | Real-boundary commands run in the candidate tree; any failure reverts. The profiler's own canonical-outcome check (exit 6) also applies to every run. |
| `editable` / `frozen` | Path globs. The candidate diff must lie inside `editable` and touch nothing `frozen` (tests, harness, runner, specs, lockfiles, protocol fixtures). |
| `protected_behavior` | Human-judged constraints the metric cannot see (UX cadence, protocol shape, diagnostic meaning). Reviewed by the maintainer, not by the runner. |
| `budget` | `max_rounds`, `max_stalled_rounds`, `max_wall_minutes`, `max_changed_lines`. |

Specs are changed only in maintainer-reviewed PRs separate from any
candidate, and `verdict.json` records the spec's SHA-256.

## 4. Baseline and noise-floor protocol

1. **Fresh, isolated fixtures.** Both arms are built from their own refs in
   run-owned detached worktrees (dependencies APFS-cloned when the lockfile is
   identical), each run in a fresh fixture Gateway with a private home.
2. **ABBA order** (`base, candidate, candidate, base`) balances slow drift;
   samples of each arm are pooled.
3. **A/A drift control.** The two base rounds are compared with the same rule;
   if the base moved beyond noise between them, the trial is `inconclusive`.
4. **Noise before effect.** Before the first round the agent measures the base
   twice; if the bound on the primary metric exceeds `min_effect`, it stops
   (more iterations, a quieter host, or a different metric).
5. **One verdict rule.** `compare_metric` from `scripts/tron_profile_report.py`:
   at least 3 samples per arm, bound = max(3 robust SD, relative floor, one unit
   for integers). Nothing in the runner re-implements statistics.
6. **Host headroom.** Each measurement waits for a 1-minute load at or below
   `max_load_per_cpu × CPUs`; a plumbing failure is retried once after
   headroom returns, and every attempt (with its load) is recorded.
7. **Plumbing is never a score.** Profiler exits 5/6, missing reports and
   budget exhaustion yield `inconclusive` with evidence paths.

## 5. Anti-gaming guards

| Risk (article's term) | Guard |
|---|---|
| Weakening tests or the grader | `frozen` globs cover tests, profiler, driver, faux model, runner and specs; path guard runs before any measurement. Verified: a candidate that deletes one assertion from `settings-gate.e2e.test.ts` is refused (`frozen_touched`). |
| Overfitting to the measured scenario | Held-out scenarios gate the verdict and the skill forbids reading their logs. |
| Buying the metric with UX or protocol | Every non-ungated metric is a guard; protocol fixtures and lockfiles are frozen; `protected_behavior` is reviewed by the maintainer. |
| Answer leakage / reward hacking | The agent never writes the verdict; the runner does, with the spec hash, base/candidate SHAs and run IDs. |
| Unreviewable change | `max_changed_lines`, one causal change per round, docs updated with behavior, no merge. |
| Hidden failures | Failed attempts and retries stay in `verdict.json`; reverted candidates are reverted commits, not rewritten history. |

## 6. Agent rules, sandbox and budget

The [skill](../../.agents/skills/tron-hillclimb/SKILL.md) is the procedure.
Sandbox: `scripts/tron work start` claims the issue and isolates the task
worktree; the runner adds disposable worktrees under `tmp/hillclimb-runs/`
and removes them on every exit; fixtures never touch the user's, Debug or
Stable Gateway; tests run with a private `HOME`/`TMPDIR`; the profiler's host
lock serializes measurements across agents. Budget: rounds, stalled rounds,
wall minutes (including headroom waits) and changed lines from the spec, plus
the session's own token budget. Stop conditions and the stall reflection pass
follow the article.

## 7. From result to PR

Today: the agent pushes the branch (kept commits plus reverted ones) and posts
the verdicts with `scripts/tron work comment`; the maintainer reviews the diff
and the protected-behavior judgment and runs `scripts/tron work land` with the
spec's correctness commands as `--tests`. Gap: the work tooling has no
"open a draft PR without merging" command, and agents may not call `gh`
mutations directly (proposed issue 4).

## 8. Fit with the task and worker model

- **A trial is a good Home task.** It is finite, has an explicit report, runs
  in a worker with project tools, and may use subagents (for example a cheap
  model to sort stalled failures by cause). The 24-hour task deadline bounds
  it; the spec's wall budget should be far below that.
- **Home cannot schedule the loop.** Home refuses scheduled and mission work
  because it outlives the task, so "run nightly" cannot be set up by Home or
  by a Home worker. Recurrence must be a maintainer-created Gateway
  Automation: a workspace target with `newPerRun` sessions on the repository,
  interval at least 24 hours, a plain-text prompt naming the skill and spec.
  Automations do not create worktrees (the session's `work start` does), carry
  no 24-hour deadline (the spec budget is the only bound) and leave one
  canonical session per run, so a daily cadence is the practical maximum.
- **Alternative without new authority:** the maintainer asks Home to "run the
  next hill-climb trial" when convenient; Home delegates one finite task.
- **Concurrency:** one spec per claim; the profiler host lock serializes
  measurements, and the headroom gate yields to other agents' builds.

## 9. Prototype results

See [results/2026-10-13-gateway-turn-frames.md](results/2026-10-13-gateway-turn-frames.md).

## 10. Proposed issues

1. **Promote the hill-climb runner and skill** (this prototype) after review:
   make the A/A pre-flight a runner step that refuses a round whose noise
   bound exceeds `min_effect`, add an HTML results page, and a real-boundary
   test of the runner (path-guard refusal, plumbing-failure classification,
   worktree cleanup on interrupt) in `scripts/test-*` style.
2. **Durable per-check timing for `work verify`/`land`** (extends #870): write
   `checks.json` (check, seconds, CPU user+sys, exit, host load) beside the
   logs and keep it after cleanup, so #833 has a climbable series.
3. **Gateway report: startup and memory metrics.** Promote the fixture's
   `gateway.startup-budget` phases and peak RSS/heap into `report.json`.
4. **`scripts/tron work propose`:** push a task branch and open a draft PR
   with a privacy-checked summary, without verify-to-merge, for agent results
   that need maintainer review.
5. **`tool-loop` profile fails under host load** (`session.open` shed after
   11–28 s, 5.3 s event-loop delay, 3.7 s GC on a seeded 600 KB page): decide
   whether this is a product responsiveness issue or a fixture deadline issue.
6. **Investigate snapshot volume in tool turns** (12.94 MiB decoded per
   ten-tool turn): a maintainer-scoped protocol question, not an automated
   climb.
7. **Profiler verdict resolution for small effects:** consider a
   difference-of-medians bootstrap interval beside the 3-spread bound so
   more samples buy resolution (decision for the profiler owner).
8. **Quiet-window measurement on the shared Mac:** the 1-minute load ranged
   5–770 on 18 CPUs during this prototype; climbing needs a scheduled quiet
   window or a host-wide measurement lease that other agents' simulator boots
   respect.
9. **First LLM-side eval: skill/route triggering** with a human-approved case
   set, train/test split and a judge model different from the climber.
