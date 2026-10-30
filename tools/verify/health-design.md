# Lightweight health reporting

The implemented scope is the on-demand `scripts/tron health` scorecard and approved
content-free Home response/capability completion diagnostics (#2135). Approval timestamp
recording awaits the settings owner. Scheduling/time remains undecided: no nightly
batch, dependency report or weekly digest is implemented. The future-output table below
is design context, not enabled jobs or authority to run them. Use outcomes to test whether deletion reduces waiting at equal/lower regression
rate. LOC is diagnostic trailing evidence, never a quota or acceptance threshold.

## Small scorecard

| Field | Exact definition and evidence | Unknown/partial rule |
|---|---|---|
| Approval → main | UTC landed timestamp minus explicit intent approval; retain work-start and affected-verdict timestamps. Report median/p90 and execution versus approval/resource/coordination waiting. | Commit author time is not approval or server push time. Missing endpoints mean unavailable; do not guess waiting from chat gaps. |
| Deploy lag | Main SHA versus installed Mac **and** iPhone source/build/protocol identities, plus age since that main integration. | One missing identity means partial, not zero lag. SHA ancestry is required; build-number subtraction is meaningless. |
| Main reds | Distinct exact case+signature failures on pinned main, duration first-failure→fix, first-failure→named owner. Separate quarantined cases, new reds and harness errors. | Registry size is not current red count; missing lanes remain unavailable. Ownership within one hour is an operational objective, not an auto-revert timer. |
| Flake rate | Same exact SHA/config/case with both pass and fail ÷ cases with comparable repeated attempts; also show failing-attempt/total-attempt counts. | First failures retained. Different signatures/configs never merge. One attempt gives unknown, not 0%. No retry-to-green. |
| Resumes/task | Admitted resumed operations ÷ complete root lineages in the window; report median/p90 and denominator. | Use `home.taskHistory` admitted operations, not copied snapshots, task-name suffix guesses or refused admissions. `complete:false` is partial. |

Supplementary diagnostics: affected verify wall time (target under 2–3 minutes),
test/lane wall time, owners touched, layer/cycle results, package production LOC,
Gateway startup and Home round-trip latency. They do not replace the five fields.
Keep sample count, environment, source SHA and coverage beside every measurement.

## On-demand command

`scripts/tron health` reads the locally pinned `origin/main` SHA's existing verify
report, never runs suites, fetches, deploys or opens sessions. `--sha <main-sha>` pins
another first-parent main commit. Repeat `--verify-report <json>` for retained attempts
(including batch-owned `lane-*/verify.json`); the verifier's attempt ID deduplicates copies.
It emits JSON and atomically retains `test-results/health/aggregate-<run>.json`.
Unavailable measurements are null, not zero; denominators and partial coverage remain visible.
Registry-expired/invalid invocations retain failed source reports; `--plan` stays read-only.
Case digests and config/attempt identities come from the executed verifier, not inferred test names.

Optional `--owner-summary <json>` reads an explicit `system.logs` aggregate export
(`records`): `home.response-timing`, `home.task.history-summary`, `capability.usage`.
Only approved scalars/names survive. This bounded tail is **partial**, not a complete
30-day census. Root hashes deduplicate history pages; incomplete roots are excluded.
`--mac-identity <json>` reads the selected payload manifest identified by `mac verify`;
`--iphone-identity <json>` reads existing iPhone log-capture metadata. The script does not
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
          s.get('failedTests'), s.get('quarantined'))
PY
```

Do not sum skipped/running/interrupted steps into a complete wall-time result.
Read registry validation through `verify --plan`, not an imported private function.
Count registry entries separately and retain issue/expiry: they are evidence of
registered failures, not a new reproduction. Exact-SHA baseline numbers belong in
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
There is no existing single CLI for end-to-end Home latency, cold-start timing,
installed iPhone identity, approval timestamps or a complete seven-day flake ledger.
Do not invent commands or infer those values from a fast status RPC. Proposed
collection below must expose missing data before any implementation is accepted.

## One owner, reuse first

One host script in `tools/verify/health.py` (`repo/verify`) consumes
existing exact-SHA reports and approved aggregate projections. No Gateway service,
new database, queue, model judge or parallel runner. Its command is wired in
`scripts/tron`; `verify.module.json` owns that directory.
`tools/verify/batch.py` remains the sole owner of batch children/cancellation/logs
and last-green state. Do not duplicate its process manager or cleanup journal.

| North Star output | Trigger / input / owner / output |
|---|---|
| Automatic evals | After an explicitly requested batch, reuse its case outcomes and manifests; health script emits a scorecard, never merges or deploys. No model grading. |
| Nightly Mac coverage | A single Mac script invocation of existing batch; only after approval of scheduler/time. Reuse pinned range, cancellation and immutable batch directories. Existing physical leases: up to three host slots, one job/worktree; no extra global suite queue. Busy/incomplete is reported, never a pass. |
| SDK/dependency freshness | Read exact pins/lockfiles and npm metadata through existing updater owners; nightly report-only changelog diff. Separate per-version bump uses Pi seam oracles and the decided patch/minor versus major policy; never update a running Gateway. |
| Per-decision scorecard | Health script joins explicit approved-intent/landed timestamps with verify and installed identity evidence; source owners export aggregates, not raw sessions. |
| Seven-day digest | Same script summarizes bounded seven-day run records once per week. One local Markdown file, no automatic external send, issue creation or Home mutation. |
| Capability usage | Capability names, counts, status and latency buckets only; source owners aggregate at actual completion, including refused/error/unknown. No queries, bodies, file paths, prompts, credentials or raw tool arguments. |

Runtime gaps belong to existing owners: `repo/profile` for fixture spawn→verified
ready monotonic timing; `gateway/home` for accepted maintainer input→first visible
response and terminal outcome (separate queue/model/tool durations); `gateway/delegation`
for complete admitted lineage counts; existing Mac/iOS identity projections for
installed cohort. Never open live canonical sessions in a second client. Proposed
Home/usage collection exports only approved scalars through the existing logger;
health reads an explicit aggregate export, never private stores or canonical sessions.

Proposed local records: SHA/range, run ID, command/config digest, start/end/status,
coverage, scalar samples and source artifact references. Result path stays under
existing batch run directories; standalone local summaries under `test-results/health/`.
One invocation owns its temp output and atomic rename; SIGINT/SIGTERM joins its own
child and keeps an interrupted record. Never stop foreign work. Retain aggregate
summaries 30 days, seven-day digests 90 days; keep existing raw batch evidence under
its current owner. Health cleanup removes only its own expired aggregate files,
not canonical logs, sessions, task evidence or another run's worktree.

## Grading and acceptance before implementation

- Exact quarantine case+digest, expired entry, changed signature, missing lane and
  interrupted run: health must reproduce the existing verifier's distinct outcomes;
  never convert unavailable/quarantined to a clean pass.
- Size before/after: compare identical classifier rules; replacement/external code
  disclosed. Smaller with a missing surviving oracle is a failure, not improvement.
- Real retained workflows: chat/reconnect, Home memory continuity, controls/log/Undo,
  artifact reopen and independent access use existing executed checkpoint outcomes;
  never score green from proposed case names or screenshots alone.
- Timing: compare same scenario/config on a quiet host, retain first samples and
  censoring. Report median/p90 with sample count; no startup claim from warm RPCs.
- Lineage: refused resume excluded, copied check-ins deduplicated, incomplete history
  partial. This uses the [task history contract](../../packages/gateway/src/modules/home/tasks.md#control-and-spend-status).
- Privacy/cleanup: inspect emitted files for forbidden fields; interrupt a real owned
  invocation and verify child exit and retained partial result. No copied algorithms
  or mock-only proof of process/authority boundaries.

Sample scorecard: `O1 unavailable (approval timestamp absent); O2 partial (iPhone
identity absent); O3 unavailable (no complete main run); O4 unavailable (one attempt);
O5 partial (history incomplete); static verify 2s (not test latency)`.
Weekly digest: window/source SHAs, five fields with denominators and coverage,
first new red/owner/expiry, unavailable reasons, supplemental timing and size deltas.

Estimated incremental cost: seconds to parse bounded local JSON, zero provider spend;
nightly suites keep their measured existing lane cost, currently unknown here.
No promised nightly runtime until a complete authorized batch supplies it. Paid
or model-driven evals require a separate explicit budget, not silent fallback.
Collection and retention follow the approved scorecard scope. Scheduler/time and
all proposed jobs remain undecided and unimplemented; they need separate authorization.
