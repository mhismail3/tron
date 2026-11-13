# Migration list

In order. Each step says what changes, who can do it, the risk and how to undo it. Nothing here has been
done. Steps 1, 2, 5 and 6 depend on the [open decisions](OPEN-DECISIONS.md).

The first three steps need no code and no rebuild. They fix most of what went wrong, because Home already
reads a skill before each delegation when the skill's description tells it to (it read `model-craft`
13 times between 15:00Z on 2026-11-12 and 08:00Z on 2026-11-13).

## Remove, keep or shrink at a glance

| Mechanism | Action | Step |
|---|---|---|
| Numeric load rules in briefs, steers and automations | Remove | 0 |
| Worker-written load-guard scripts (23 found) | Remove | 0, 8 |
| "Never hand-serialize below the cap" (`AGENTS.md:93`, iOS skill, runbooks) | Remove | 4 |
| "Home starts every task... never a reason to delay" (`host-load.md:3-5,85`) | Remove | 5 |
| "Resume it at once" (`tron-home-extension.ts:23`) | Shrink | 5 |
| "At most 4 workers" (global `AGENTS.md:36-37`) | Remove | 2 |
| Verify: lanes equal to the slot count (`verify.py:577-584,1600`) | Shrink to default 1 | 4 |
| Verify: opportunistic lanes, 30 s slot wait, "deferred" iOS result (`verify.py:1209,1247-1327`) | Remove | 4 |
| A load fence inside verify (requested in #2520) | Do not build | 7 |
| Host slots, ceiling of 3 (`ios-test-lock.py:70`) | Keep | none |
| Lease per simulator lane and device | Keep | none |
| Full-Gateway lock (`host_lock.py`) | Keep | none |
| Mini job lock and pool (`mini.py`) | Keep | none |
| Task process reaper and command scope | Keep; fix log repeat | 7 |
| `nice -n 10` agent shells; `-jobs 4` builds | Keep | none |
| Host pressure level (`host-pressure.ts`) | Keep; show it to Home | 6 |
| `--ios-jobs` | Keep | 4 |

## Step 0. Stop the two patterns now

- **What:** Home stops sending load thresholds and stops asking for load guards. Workers stop writing
  them. A run is never stopped for load it causes itself.
- **Who:** Home, from its next brief. No file changes.
- **Risk:** none. The serial gate running during this audit keeps its own fence until it ends; do not
  steer it mid-run.
- **Undo:** not needed.

## Step 1. Install the two skills

- **What:** copy `skills/host-resources/` (with `host-state.sh`) and `skills/resource-stewardship/`
  (with `OBSERVATIONS.md`) from this branch to `~/.tron/agent/skills/`.
- **Who:** Home or a worker, after Mohsin approves the write (open decision 5).
- **Check after install:** run `host-state.sh` once; confirm both skills appear in a new session's skill
  list; confirm Home reads `resource-stewardship` before its next delegation.
- **Not yet tested:** the host-slot wrapper line for other projects. Test it once in the Pinfold worktree
  with a harmless command (`-- sleep 5`) before a brief relies on it.
- **Risk:** low. Two more skill descriptions in every session's prompt.
- **Undo:** delete the two directories.

## Step 2. Global rules: "Shared machines"

- **What:** add the section from [drafts/WORKER-RULES.md](drafts/WORKER-RULES.md) draft 1 to
  `~/.tron/agent/AGENTS.md`. If open decision 7 is yes, also replace the "at most 4 workers" sentence
  (draft 2).
- **Who:** Home, after Mohsin approves the write.
- **Risk:** low. Every session's prompt changes once.
- **Undo:** remove the section.

## Step 3. Measure once

- **What:** on a quiet evening, one worker runs the same simulator selection with 1, 2 and 3 lanes, on
  warm and on freshly created simulators. For each it records wall time, CPU idle, the Gateway's event
  loop reading and the duration of one nested Gateway test file run on this Mac at the same time.
- **Why:** the facts table has only "one lane is safe" and "three freshly booted lanes are not". Two
  lanes and warm simulators are unknown. The answer decides whether the working plan can widen.
- **Who:** Home delegates it when nothing else heavy is planned, and tells Mohsin first because it is
  heavy.
- **Risk:** it loads the Mac for about an hour.
- **Output:** new dated rows in the skill's facts table.

## Step 4. Tron tooling and docs: one lane by default, no deferral

One worker, one branch, one landing.

- **4a.** `tools/verify/verify.py` line 1341: `--ios-jobs` default 1. Check that `verify --batch` passes its
  own lane count explicitly so the batch does not slow down by accident (`tools/verify/batch.py` line 75
  sets journey lanes; its shard lanes need the same look).
- **4b.** Delete opportunistic lanes and the bounded slot wait from ordinary runs
  (`verify.py:1209`, `1247-1327`, the `--host-slot-wait-seconds 30` arguments at `262`, `1466`, `1556`,
  `1558`, and the iOS "deferred" statuses that only they produce). A run that needs a slot waits and
  prints the holder, as `--all` already does.
- **4c.** Docs in the same change: `AGENTS.md:93`, `.agents/skills/tron-ios/SKILL.md`,
  `docs/development.md` lines 285–290, `packages/ios-app/docs/development.md` lines 158–165,
  `tools/verify/README.md`. Text is in [drafts/WORKER-RULES.md](drafts/WORKER-RULES.md) drafts 3–5.
- **Who:** a Tron worker. Test changes need a non-author ACCEPT (`tools/verify/tests/test-verify.py` has
  33 lines that mention these behaviours).
- **Risk:** medium.
  - One worker's simulator step takes about three times longer by the clock. Measured with one lane:
    45 tests in about 22 minutes, and a worker's estimate of 150 minutes for 147 tests. The three-lane
    times (about 7 and about 50 minutes) are my estimates, not measurements. That is the trade: slower
    alone, but it finishes.
  - A run that used to say "deferred" after 30 s now waits. It prints the holder every 30 s, and Home
    sees the wait in check-ins.
- **Undo:** revert the merge.

## Step 5. Home rules and the host-load doc

- **What:** the paragraph and the amended sentence from [drafts/HOME-RULES.md](drafts/HOME-RULES.md)
  drafts 1–2 in `packages/gateway/src/modules/home/tron-home-extension.ts`, and the doc text from draft 3
  in `packages/gateway/docs/host-load.md`. Regenerate the Home prompt goldens that hash this text.
- **Who:** a Tron worker; lands with step 4 or after it, because the doc states both. Takes effect at
  Mohsin's next Gateway rebuild.
- **Risk:** medium. It changes Home's standing instructions. Goldens change mechanically (prompt hashes
  only). Until the rebuild, the skill from step 1 carries the behaviour.
- **Undo:** revert and rebuild.

## Step 6. Give Home a host reading on wakes

Only if open decision 4 is option (a).

- **What:** add to the `task list` and `task status` tool results (`home-owner.ts:302-307`) a small
  `host` object: CPU busy share, memory free, booted simulator count, and for each running task whether
  its command scope holds heavy processes now. The Gateway already has the pressure sampler and the
  per-task process walk; this exposes them to the model. No thresholds, no admission.
- **Who:** a Tron worker. Needs tests at the real tool boundary and a lockstep rebuild.
- **Risk:** medium. A model-visible tool result changes shape; its goldens change. The process walk runs
  every 60 s already, so the cost is small.
- **Undo:** revert and rebuild.

## Step 7. Issues

Filed through `scripts/tron work`, by Home or a worker.

- Close the load-fence half of #2520 with this report's evidence. The one-lane half is done by
  `--ios-jobs`.
- File: the task reaper logs `sweep refused remove-failed` every minute (since 2026-11-12 20:04Z).
- File: `host.pressure` is sampled only when a client asks for Home status, so the log has gaps
  (nothing logged for 2026-11-13 04:11–04:23Z).
- File: simulator device count (141 devices, 64 lane directories) and the cost of first boots; decide
  after step 3 whether warm reuse is worth building.

## Step 8. Clean up the guard scripts

- **What:** the 21 Python guard scripts under `test-results/` and `.scratch/` in six Tron worktrees, and
  the two shell gates in the Pinfold worktree.
- **Who:** each worktree's owner when its task resumes or its worktree is retired (housekeeping skill).
  Not by hand now: those worktrees are parked for resume.
- **Risk:** low.

## Step 9. Review after two weeks

- **What:** count from the Home session and task records: heavy runs that ended interrupted or
  deferred; time between one worker's `Heavy done:` and the next worker's `Heavy start:` while someone
  waited; `host.load.non-task` records; Home messages that carry a load number; new scripts that read
  load.
- **Then decide:** keep as is; widen the working plan (if step 3 showed two lanes are safe); or apply
  the pre-agreed fallback (daytime slot ceiling of 1) if simulator jobs collided twice or a hand-off
  took over an hour twice.

## Not recommended

- Bringing back a heavy queue, a gate or a worker cap in the Gateway. Evidence: #1253.
- A load fence inside verify. Evidence: finding F2 of the report.
- Lowering the slot ceiling now. A fixed 1 would stop Home from using three lanes on an idle Mac.
- Letting Home's shell run on wakes. It weakens the rule that wake content cannot gain shell authority.
