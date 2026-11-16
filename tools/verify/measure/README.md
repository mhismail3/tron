# Verification audit measurements

Read-only scripts behind the verification audit of 2026-11-16. They change nothing and need no
dependencies beyond Python 3.

```bash
python3 tools/verify/measure/verify_runs.py <checkout> <worktrees-dir> [--json]
python3 tools/verify/measure/session_time.py <pi-session-dir> --since 2026-10-26 [--checkins out.tsv] [--slow out.tsv]
python3 tools/verify/measure/ios_runs.py --since 2026-10-26 [--tests out.tsv]
```

- `verify_runs.py` reads `test-results/verify/*.json` and `test-results/mini/*/verify.json`: per-step
  seconds at p50 and p95, the static, setup and test split of a run, verdict counts, failing steps and
  same-commit reversals. A rerun at one commit overwrites its report, so reversals are undercounted.
- `session_time.py` reads Pi session logs: where agent time went (model, verification commands,
  sleep-and-poll loops, setup), every check-in, and each verification or waiting span of 60 s or more.
- `ios_runs.py` reads the iOS runner's retained run directories: build and test process seconds, launch
  overhead, per-test seconds and outcomes, idle stalls, and tests that passed and failed on one clean revision.

The repeatability probe used the shipped runner, with random order from Vitest's own flags:

```bash
scripts/tron test gateway --mini
scripts/tron test gateway --mini --sequence.shuffle --sequence.seed <n>
```
