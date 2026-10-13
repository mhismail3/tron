# Prototype trial: gateway-turn-frames (2026-10-13)

Spec: [gateway-turn-frames.json](../specs/gateway-turn-frames.json): phone
(`mobile`) WebSocket messages during the `tool-loop` scenario (one turn with
ten sequential tool calls), lower is better, `min_effect` 3%. Held-out:
`stream-reply`. Correctness: `settings-gate.e2e.test.ts` (24 tests).

## Hypothesis and candidate

Baseline runs showed the phone receives 11 identical `session.diagnostic`
`settings-run-applied` frames per tool turn: one per provider request, with the
same policy each time. Candidate `854b9c153` publishes it once per agent run
and again only when a later request in that run applies a different policy
(same-turn image narrowing still reports), with `observability.md` and
`settings-model.md` updated. 19 changed lines, Gateway-only, no protocol
change.

## Command

```bash
scripts/tron-hillclimb trial --spec tools/hillclimb/specs/gateway-turn-frames.json \
  --base 09fe6ee35 --candidate 854b9c153 --out tmp/hillclimb-runs/trial-3
```

## Samples (3 iterations per run, ABBA)

| Run | Ref | total frames | total MiB | diagnostic frames | snapshot frames | rebaseline frames |
|---|---|---|---|---|---|---|
| 0-base | 09fe6ee35 | 235, 238, 228 | 14.36, 14.36, 13.80 | 11, 11, 11 | 22, 23, 18 | 3, 2, 6 |
| 1-candidate | 854b9c153 | 225, 220, 220 | 14.37, 14.35, 14.35 | 1, 1, 1 | 23, 23, 23 | 2, 2, 2 |
| 2-candidate | 854b9c153 | 223, 223, 223 | 14.36, 14.36, 14.36 | 1, 1, 1 | 23, 23, 23 | 2, 2, 2 |
| 3-base | 09fe6ee35 | 231, 238, 232 | 14.36, 13.82, 13.81 | 11, 11, 11 | 21, 21, 18 | 4, 3, 6 |
| held-out base | 09fe6ee35 (`stream-reply`) | 168, 164, 171 | 0.68, 0.67, 0.70 | 1, 1, 1 | 3, 3, 3 | 2, 2, 2 |
| held-out candidate | 854b9c153 (`stream-reply`) | 168, 165, 164 | 0.69, 0.68, 0.67 | 1, 1, 1 | 3, 2, 3 | 2, 2, 2 |

## Verdict (written by the runner)

- **Decision: `revert`.** Primary `wire.mobile.total.frames`: base median
  233.5, candidate 223.0, delta −10.5 (−4.5%), noise bound ±15.6 →
  `unchanged`.
- A/A drift control (base round 0 vs 3): −3.0 within ±13.3 → unchanged.
- Gated regressions: none. Held-out `stream-reply`: no regression, no
  improvement (expected: one request per turn).
- Correctness: 24/24 passed (123.7 s). Path guard: 3 files, 19 lines, ok.
- Attribution: `session.diagnostic` frames 11 → 1 and bytes 4,688 → 425 B,
  both beyond their noise bound in every run; the effect is real but smaller
  than the run-to-run noise of the total.
- Every run-owned worktree was removed (also after an interrupted trial).
- Branch action, per the skill: candidate reverted in `d28e0cdb1`, kept in
  history for review.

## What the trial taught

1. **The noise is load-induced, not inherent.** Earlier the same day,
   `stream-reply` frames had MAD 0 and `tool-loop` MAD 2. During this trial the
   base arm ran under heavier contention (1-minute load up to 108 recorded in
   report warnings; up to 770 while waiting) and its Gateway replaced 2–4
   snapshots with rebaselines and varied total bytes by 4%. The README claim
   that wire counts "repeat exactly" holds only on a quiet host.
2. **The pre-flight noise check must be enforced by the runner.** An A/A
   bound of ±13–16 frames (6–7%) exceeds the spec's 3% `min_effect`; the
   skill tells the agent to stop at that point, but the runner should refuse
   to start the round instead of relying on the agent.
3. **The verdict rule is conservative for small effects.** `compare_metric`
   uses 3 × the robust spread of individual samples, which does not shrink
   with more samples. For hill-climbing small deterministic effects, a
   difference-of-medians confidence interval (bootstrap) would let more
   samples buy resolution. This is a decision for the profiler's owner.
4. **Headroom gating works but costs time.** The trial spent most of its
   2 h wall time waiting for 1-minute load ≤ 45 (2.5 per CPU). A 1.0-per-CPU
   gate never opened in 20 minutes. Climbing on this Mac needs a quiet window
   (e.g. overnight) or a dedicated host.
5. **Plumbing failures were caught, not scored.** Trial 1 stopped as
   `inconclusive` when the candidate's `tool-loop` run hit the profiler's
   `session.open` 10 s deadline (exit 6) under load.

## Maintainer decision

The candidate is a reasonable small cleanup on its own merits (phone decodes
ten fewer identical diagnostics per ten-tool turn; settings-gate E2E passes),
but this eval did not show it beyond noise. Re-run on a quiet host, or take it
as a non-performance simplification; either way the protected-behavior
question is whether diagnostic consumers need one event per request.
