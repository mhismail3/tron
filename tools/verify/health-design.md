# Lightweight health reporting

[P2](../../docs/PRINCIPLES.md#p2-verification-gates-promotion-not-authorship) owns red/green policy:
legacy verifier verdicts are diagnostics, never permission for exemptions or qualified green.

The implemented scope is the on-demand `scripts/tron health` scorecard and approved
content-free Home response/capability completion diagnostics (#2135). Approval timestamp
recording awaits the settings owner. Scheduling/time remains undecided: no nightly
batch, dependency report or weekly digest is implemented, and none runs without separate
authorization. Use outcomes to test whether deletion reduces waiting at equal/lower regression
rate. LOC is diagnostic trailing evidence, never a quota or acceptance threshold.

## Goal outcomes first

`goals` presents request→landed-on-main cycle time, main-green rate, rework
(full-suite reruns, reverts and resumes per slice), then escaped regressions.
Missing request/publication joins, complete per-main baselines or slice attribution
remain unavailable; task lineages are not silently relabelled as landed slices.
Production LOC and concept count are adjacent `context`, never targets or pass/fail.
An exact-SHA retained metrics snapshot supplies LOC; absent snapshots/count owners
remain unavailable. The following existing `fields` are supporting diagnostics.

| Field | Exact definition and evidence | Unknown/partial rule |
|---|---|---|
| Approval → main | UTC landed timestamp minus explicit intent approval; retain work-start and affected-verdict timestamps. Report median/p90 and execution versus approval/resource/coordination waiting. | Commit author time is not approval or server push time. Missing endpoints mean unavailable; do not guess waiting from chat gaps. |
| Deploy lag | Main SHA versus installed Mac **and** iPhone source/build/protocol identities, plus age since that main integration. | One missing identity means partial, not zero lag. SHA ancestry is required; build-number subtraction is meaningless. |
| Main reds | Distinct exact case+signature failures on pinned main, duration first-failure→fix, first-failure→named owner. Harness errors are counted apart. | Missing lanes remain unavailable. Ownership within one hour is an operational objective, not an auto-revert timer. |
| Flake rate | Same exact SHA/config/case with both pass and fail ÷ cases with comparable repeated attempts; also show failing-attempt/total-attempt counts. | First failures retained. Different signatures/configs never merge. One attempt gives unknown, not 0%. No retry-to-green. |
| Resumes/task | Admitted resumed operations ÷ complete root lineages in the window; report median/p90 and denominator. | Use `home.taskHistory` admitted operations, not copied snapshots, task-name suffix guesses or refused admissions. `complete:false` is partial. |

Supplementary diagnostics: affected verify wall time (target under 2–3 minutes),
test/lane wall time, owners touched, layer/cycle results, package production LOC,
Gateway startup and Home round-trip latency. They do not replace the goal outcomes.
Keep sample count, environment, source SHA and coverage beside every measurement.

## On-demand command

`scripts/tron health` reads the locally pinned `origin/main` SHA's existing verify
report, never runs suites, fetches, deploys or opens sessions. `--sha <main-sha>` pins
another first-parent main commit. Repeat `--verify-report <json>` for retained attempts
(including batch-owned `lane-*/verify.json`). Attempt IDs deduplicate copies for flake rate
and test minutes; verifier outcomes and harness errors count every exact-SHA report given.
`landedChanges` inspects at most 20 first-parent commits and 1,000 local remote-main
reflog entries. A successful `update by push` observation plus its preceding ancestor
tip identifies introduced commits (at most 1,000) and earliest Git author time.
Their difference is **partial commit→publication-observation time**, not an exact
request/server-land metric; fetch/reflog absence, invalid clocks or missing ancestry
stay unavailable. Completed retained verifier test-step seconds become partial test
minutes per publication. Overwritten attempts, direct
suite logs and unjoined lanes are not inferred. `--all` means locks, not all Gateway tests.
It emits JSON and atomically retains `test-results/health/aggregate-<run>.json`.
SIGINT or SIGTERM keeps an `interrupted` aggregate with the partial collection (exit 130, not a
pass); it stops only its own batch-owned child group, never foreign work.
Unavailable measurements are null, not zero; denominators and partial coverage remain visible.
Case digests and config/attempt identities come from the executed verifier, not inferred test names.

Optional `--owner-summary <json>` reads an explicit `system.logs` aggregate export
(`records`): `home.response-timing`, `home.task.history-summary`, `capability.usage`.
Only approved scalars and names survive. For `capability.usage` that means the capability name,
counts, status (`ok`, `error`, `refused`, `unknown`) and latency bucket (`lt100ms`, `lt1s`, `lt10s`,
`gte10s`, `unknown`). It never keeps queries, bodies, file paths, prompts, credentials or raw tool
arguments. This bounded tail is **partial**, not a complete
30-day census. Root hashes deduplicate history pages; incomplete roots are excluded.
`--mac-identity <json>` reads the selected payload manifest identified by `mac verify`;
`--iphone-identity <json>` reads a JSON object with `appSourceRevision`, `appBuildIdentity` and
`protocolVersion`; no app owner writes that file yet. The script does not
verify installation itself; missing protocol/source/build evidence remains partial.
Approval/server-landed timestamps remain unavailable pending the settings owner seam.
`--cleanup` deletes only this schema's expired aggregates in this directory (30 days);
90-day digest retention is policy only. No digests, scheduler or nightly jobs exist.

## Exact commands and safe baseline collection

These commands operate on a clean checkout and create only local test evidence:

```bash
SHA=$(git rev-parse HEAD)
scripts/tron metrics "$SHA"
/usr/bin/time -p scripts/tron verify --base "$SHA" --plan
/usr/bin/time -p scripts/tron verify --base "$SHA"
```

The last command measures **empty-diff static verification only**, not affected
code tests. For a real change, use its pinned pre-change SHA as `--base`; inspect
`--plan` first. Preserve the report before another same-SHA run overwrites it.
Extract size from the current metrics authority, not a second LOC classifier:

```bash
python3 - "$SHA" <<'PY'
import collections, json, sys
j = json.load(open(f'test-results/metrics/{sys.argv[1]}.json'))
areas = collections.Counter()
for f in j['files']:
    if f['category'] == 'production':
        areas[f['package']] += f['lines']
print(dict(sorted(areas.items())))
PY
```

For existing evidence, without running a suite:

```bash
python3 - "$SHA" <<'PY'
import json, sys
j = json.load(open(f'test-results/verify/{sys.argv[1]}.json'))
print('verdict', j.get('verdict'))
for s in j['steps']:
    print(s['name'], s.get('status'), s.get('seconds'),
          s.get('failedTests'))
PY
```

Do not sum skipped/running/interrupted steps into a complete wall-time result.
Exact-SHA baseline numbers belong in
the issue/private run artifacts, not a growing repository evidence ledger.

After implementation approval, existing heavier owners can supply measurements:

```bash
scripts/tron verify --batch --plan
# Explicit authorized full run only, in the existing batch worktree:
scripts/tron verify --batch
# Explicit authorized isolated fixture run only, not installed Gateway startup:
scripts/tron-profile gateway --scenario stream-reply
scripts/tron-profile compare BASE CANDIDATE
# Read-only installed-Mac identity verification:
scripts/tron mac verify
```

The profiler builds/starts its own faux-model fixture; do not run it during a
no-build/no-restart design task. Its request latency is NOT Home round-trip or
Gateway cold-start latency. See [profile ownership](../../scripts/tron-profile-gateway.md).
Home response timing reaches health only as approved owner-summary scalars (#2135). There is
no existing CLI for cold-start timing, installed iPhone identity, approval timestamps or a
complete seven-day flake ledger; their collection is undecided and not implemented. Do not
invent commands or infer those values from a fast status RPC.

## One owner, reuse first

One host script in `tools/verify/health.py` (`repo/verify`) consumes
existing exact-SHA reports and approved aggregate projections. No Gateway service,
new database, queue, model judge or parallel runner. Its command is wired in
`scripts/tron`; `tools/verify/verify.module.json` owns that directory.
`tools/verify/batch.py` remains the sole owner of batch children/cancellation/logs
and last-green state. Do not duplicate its process manager or cleanup journal.

Runtime gaps belong to existing owners: `repo/profile` for fixture spawn→verified
ready monotonic timing; `gateway/home` for accepted maintainer input→first visible
response and terminal outcome (separate queue/model/tool durations); `gateway/delegation`
for complete admitted lineage counts; existing Mac/iOS identity projections for
installed cohort. Never open live canonical sessions in a second client. Home response
timing and capability usage are exported as approved scalars through the existing logger (#2135);
health reads an explicit aggregate export, never private stores or canonical sessions.
