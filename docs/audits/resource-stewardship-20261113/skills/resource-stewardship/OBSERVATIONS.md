# Observations

Dated, append-only. One line per event: date | what happened | what it cost | what changed.
Seeded from the 2026-11-13 resource audit; times are UTC.

2026-10-16 | Four full Gateway gate runs at once under the old heavy queue | 3 of 4 failed on timing with CPU mostly idle; cause was I/O-bound tests slowing each other | load average dropped as a signal (#1127)
2026-10-17 | Heavy queue, gate and landing queue removed (#1253) | 19.7 h of queue waiting and 7.9 h of landing-ticket waiting had been recorded in four days; no prevented defect shown | plain Git landing, no admission
2026-10-20 | Three Vitest workers left running in the primary checkout for 21 h at about 85 % CPU each | every verify run slowed | maintainer approved a targeted stop
2026-11-03 | A worker's load test left 40 spinner loops and 6 fsync loops orphaned | load 120; live Gateway and iPhone app starved | Gateway now reaps a settled task's processes
2026-11-12 15:04–15:16 | Six workers started or resumed in 12 minutes with no capacity plan in any brief | critical host pressure from 15:29; 10–15 s tests failing by 16:38 | none until 17:55
2026-11-12 18:58 | One verify started three simulator lanes on a Mac at load 2 | load 354; run interrupted by its owner | none
2026-11-12 22:03 | Home sent numeric load rules (below 40 to start, above 80 for 2 min to stop) | 23 worker-written guard scripts in 9 h; seven runs stopped for load that night, none with a reported failing test | rule withdrawn by this audit
2026-11-12 22:43 | Same simulator tests with one lane | load peak 7.5; 15 tests in 291 s; passed | one lane became the working plan
2026-11-13 01:30–04:11 | One worker waited for permission to rerun while two others held or wanted the simulators | 2 h 41 min idle; at 03:10 two workers were waiting on each other | Home named an explicit order
2026-11-13 04:11–04:23 | Two simulator jobs plus a third job building | load 86 to 211; two nested Gateway tests timed out at 60 s (5 s on the idle mini); one run interrupted | all four workers stopped at 05:11
2026-11-13 05:30–05:42 | One `verify --all` on a quiet Mac, three lanes | load 428; the worker's guard killed the run | `--ios-jobs` added
2026-11-13 06:38–07:30 | `verify --all --ios-jobs 1` | 50 min 53 s; no pressure; passed | serial is the proven shape
