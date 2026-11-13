# Resource stewardship audit, 2026-11-13

Audit and design only. Nothing here is live. The drafts sit beside this file:
[Home rules](drafts/HOME-RULES.md), [worker rules](drafts/WORKER-RULES.md), two draft skills
([host-resources](skills/host-resources/SKILL.md), [resource-stewardship](skills/resource-stewardship/SKILL.md)),
the [migration list](MIGRATION.md) and the [open decisions](OPEN-DECISIONS.md).

## Summary

1. The overload on 2026-11-12/13 lasted about 14 hours, not one evening. The Gateway first logged critical
   host pressure at 15:29Z on Nov 12. Mohsin stopped the workers at 05:11Z on Nov 13.
2. One ordinary `verify` run was enough to overload this Mac. It started three simulator test lanes at once.
   On three separate occasions one worker's own lanes took the Mac from a low load to 215, 354 and 428.
   One lane at a time peaked near load 8 and passed.
3. The "load guard" that interrupted runs was not part of verify. Home wrote a rule in a steer ("start below
   load 40, stop above 80 for 2 minutes"). Workers turned that sentence into 23 different throwaway scripts in
   9 hours. Workers or their scripts stopped 7 heavy runs for load. None of the 7 reported a failing test.
4. Home admitted work without looking at the Mac, and mostly could not look. Its shell tool is refused on
   every automation and result wake. In 14 hours it read host state once.
5. Workers cannot see each other. They found one another with `pgrep` and waited on guesses. Two workers
   waited on each other. One sat idle for 2 h 41 min.
6. Mohsin's claim that hardcoding failed is **confirmed for rules that decide** (thresholds, caps used as
   targets, queues, guards) and **refuted for mechanisms that only exclude or clean up** (simulator leases,
   the task process reaper, the mini's job lock, bounded build fan-out). The second kind did not misfire once
   in this window.
7. Prose alone also failed that night, because the prose was a numeric rule with no owner, no sight and no
   reasons. The repository's own charter said the opposite ("never hand-serialize below the cap").
8. Recommended design: Home owns every decision about heavy work (what, when, where, in what shape). Facts
   about the machines live in a skill. Mechanisms keep only exclusion and cleanup, with no thresholds.
9. Two small tool changes make the prose design safe: `verify` defaults to one simulator lane, and Home gets a
   host reading on every wake (added to its `task list` result). Both are in the open decisions.
10. The largest saving is not scheduling. It is asking for less heavy work: one integrated check for several
    ready branches instead of a full simulator run per branch per rebase. After Mohsin's "merge, then check
    once", one `verify --all` on the merged branch passed in 51 minutes with one lane and no pressure. The
    rest of that serial gate was still running when this report was written.

## Scope, sources and limits

- **Heavy work** in this report means a simulator test run, a large build, a full test suite or a load
  test: anything that keeps many cores, a simulator or several GB busy for more than a few minutes.
- **Read:** the Home conversation (session `4c2ee571`, chapter 29), task records under
  `~/.tron/gateway/home/tasks/` from Nov 11 to Nov 13, worker sessions (ids in the appendix), the
  automations store, the Gateway log `~/.tron/logs/gateway.jsonl`, the repository at `53110202b`, global
  skills and the global `AGENTS.md`, and GitHub issues #1253 and #2520.
- **Not done:** no builds, tests, simulators or installs. No process, lock or file under `~/.tron` was
  changed. One read-only `ssh ... uptime` probe of the Mac mini and light local reads (`uptime`, `ps`,
  `sysctl`, `simctl list`, the draft `host-state.sh` snapshot twice, and the repository's documentation,
  agent-policy and personal-info checks) were the only commands outside Git and `gh` reads.
- **Times** are UTC. Local time is UTC−8.
- **Entry ids** such as `096b4eed` are message ids inside the named session file. Check-in ids such as
  `8a2660cb` are ids in the task record.
- **Labels:** "logged" means the Gateway log recorded it. "Reported" means a worker stated it in a check-in
  and I did not measure it. "Derived" means I computed it from a logged value.
- **Limit:** load figures above about 100 come from worker reports or from the Gateway's
  `loadPerCpuPercent` field multiplied by 18 cores. I did not reproduce any of them.

## 1. What happened

| Time (UTC) | Event | Evidence |
|---|---|---|
| Nov 12 15:04–15:16 | Home resumes or starts six workers in 12 minutes; seven tasks are then running. None of the three new briefs mentions other running workers, the mini or capacity; the resume says only "respect the simulator cap and locks". Each brief asks for a green `verify --changed` per slice (about 20 slices in total). | Home `0e482433`, `77901c5d`; task records created 15:04–15:16 |
| 15:29 | Gateway logs host pressure `critical`. | `gateway.jsonl`, `host.pressure` |
| 15:50 | Load about 480 (derived: 2664 % per CPU). CPU busy was 53 %. | `gateway.jsonl` |
| 16:38–16:50 | Tests with 10–15 s deadlines fail in one worker. It reports load 105–132 and 8 GB swap. | check-ins `4bbe1a97`, `024f1425` |
| 16:52 | A worker reports three verify runs "deferred" because simulator slots were held. | check-in `7572338d` |
| 17:50–17:54 | Host pressure flips between `critical` and `elevated`. Load about 256–562 (derived). | `gateway.jsonl` |
| 17:55 | First resource steer from Home, 2 h 26 min after the first critical reading. A worker's check-in prompted it. | Home `fe0136de`; check-in `3f581a70` |
| ~18:58 | One worker's verify starts three simulator lanes on a Mac at load 2. Load reaches 354 (reported). It interrupts its own run. | check-in `b23af7fa` |
| 21:19 | After Mohsin's rebuild, Home resumes four workers at once. Each brief says "run no iOS gates at load 40+". | Home `85cb0846` |
| 21:20 | Home tries `date` through bash on an automation wake. Refused. | Home `3d277b0e`, `44062e9d` |
| 21:27 | First worker-written load-guard script. | session `01a1cfa6`, `c1eb4b86` |
| 22:00 | Three simulator lanes from one worker: load 215 (reported). | Home `fdd54db3` |
| 22:03 | Home rules: start below load 40, stop if above 80 for 2 minutes, one simulator lane at a time across workers. | Home `096b4eed` |
| 22:33 | Home starts the Pinfold iPad worker with "below 40, one simulator at a time". | Home `ebead87b` |
| 22:40 | A worker's guard kills its own build, because the build raised load past 40. | session `01a1cfa6`, `81045a9e`; Home `f229a9a7` |
| 22:43 | One lane, same tests: 15 pass in 291 s, load peak 7.5. | check-in `1b09abc4` |
| 23:09–23:33 | Three workers queue on the mini's single job lock. Home sets the order by steer. | Home `cdfdfce6`, `0b795811`, `3c2eb1d3` |
| Nov 13 00:53 | A Tron worker finds Pinfold's `xcodebuild` and waits. Pinfold is outside Tron's slots. | check-in `bf87cf61`; Home `3069165c` |
| 01:26–01:30 | Load 195 (reported). A full verify is stopped by its own guard 334 s into the iOS step. No test had failed. | check-ins `8a2660cb`, `9500c3ab` |
| 03:10 | Two workers are each waiting for the other. Home sends a fixed order and tells Pinfold to keep a process alive so others can see "lane held". | Home `0b588ae1`, `4fa31a7f` |
| 03:36 | Mohsin asks for a second lane and the mini. Home reads host state for the first and only time (load 1.7). | Home `675093c7`, `383ff00f`, `fbd758c7` |
| 04:11–04:23 | Three heavy jobs overlap. Load 86 then 211 (reported). The guard stops one run. Two nested Gateway tests time out at 60 s; they take 5 s on the idle mini. | check-ins `ff9ab15c`, `3a180ea9`, `9d9f3930`, `562dc90f` |
| 05:11 | Mohsin: pause the workers, merge, run the checks one at a time. Home stops four workers. | Home `8c1cf639`, `a9de3586` |
| 05:30–05:42 | The single integration worker waits 610 s on a quiet Mac (load 0.9–2.8), starts one `verify --all`. Verify starts three lanes. Load about 428 (reported). The worker's guard kills the run. | check-ins `74e8aa76`, `56bebbe3` |
| 06:27 | `--ios-jobs` lands on main (`53110202b`). | check-in `e2e97b68` |
| 06:38–07:30 | `verify --all --ios-jobs 1` passes in 50 min 53 s with no load event. | check-in `bfe344e5` |

Totals for 15:00Z Nov 12 to 05:15Z Nov 13, counted from the Home session: 9 delegations, 97 steers,
15 resumes, 6 stops. About a third of those messages (33 by a pattern count) carried a numeric load rule.
Home ran a host-state command once.

## 2. Findings

### F1. One verify run overloads the Mac by itself

`verify` builds its lane list from the host-slot count, so it always uses every slot. The function at
`tools/verify/verify.py` lines 577–584 reads `HOST_SLOTS`, and `scripts/ios-test-lock.py` line 70 sets
it to 3. Until `53110202b` there was no option to use fewer. Each lane boots its own simulator. The Gateway log shows what
those boots cost: its `host.load.non-task` records at 16:19Z, 01:16Z and 04:18Z list simulator first-boot
services (poster extensions, `diagnosticd`, `mediaanalysisd`) at about 100 % CPU each.

Three times one worker's own lanes took the Mac from a low load to overload: from about 2 to 354
(18:58Z), from below 40 to 215 (22:00Z) and from about 2 to 428 (05:30Z). So the 3-slot cap did not
prevent overload. It permitted it, and verify treated the permission as a target.

There are 141 simulator devices on this Mac and 64 lane directories under `~/.tron/internal`. Each new
worktree creates and first-boots up to four of its own. I did not measure how much a warm, reused device
would cost instead. That measurement is in the migration list.

### F2. The load guard was improvised prose, re-implemented 23 times

Verify has no load guard. `grep` finds no load reading in `tools/verify/verify.py`. The guard came from a
Home steer (`096b4eed`, 22:03Z). Each worker then wrote its own wrapper:

- 21 Python scripts in six Tron worktrees (for example `run-verify-resume.py`, `run-verify-cfaf.py`,
  `run-verify-e69-two-lanes.py`, `serial-native-439.py`, `clean-verify-all.py`, `serial-gate.py`), written
  between 21:27Z Nov 12 and 06:28Z Nov 13, growing from 1.2 KB to 7.4 KB.
- 2 shell scripts in the Pinfold worktree (`build/gate.sh`, `build/tours.sh`).

The variants disagreed. The first killed at load 40 at any moment (`c1eb4b86`). The second waited at most
10 minutes, then killed at 40 (`81045a9e`), and so killed its own compile. Later ones used 80 for 120 s.
One worker launched at load 57 by mistake (check-in `570d864f`).

Seven heavy runs ended with no result because a worker or its guard stopped them for load: 18:58Z,
22:00Z, 22:40Z, 22:44Z, 01:30Z, 04:23Z and 05:42Z. The first two were stopped by hand, before the scripts
existed. None reported a failing test. In at least four of them the run's own lanes or build caused the
load. Each stop discarded the run so far (in one case 18 passed steps and 334 s of simulator tests) and led to a
rerun in the same shape.

### F3. Load average is the wrong number, and the repository already said so

`packages/gateway/docs/host-load.md` line 68 records: "Load average does not track busy CPUs on this Mac
(#1096), so it is displayed only and never sets the level." Commit `d93512e46` (Oct 16) measured load 21
with 3 cores busy and 125 with 8, and removed load-average admission. The Gateway log agrees for this
window: at 15:50Z load was about 480 while CPU busy was 53 %.

Home's rule on Nov 12 used the number the project had already discarded. Home had no pointer to that
finding. What load does tell you on this Mac: simulators and their services create hundreds of runnable
threads. It rises with simulator count, not with how close the CPUs are to full.

The harm was real even so. Tests with short deadlines failed (16:38Z, 04:16Z), and the live Gateway's
event loop ran at 95–100 % (17:50Z, 01:24Z), which is what makes the iPhone app slow.

### F4. Home admits work blind

- Home's instructions tell it to keep work moving and say nothing about capacity.
  `packages/gateway/src/modules/home/tron-home-extension.ts` line 23: "When a worker settles unfinished
  and no genuine maintainer decision is needed, resume it at once."
- The owning doc says the opposite of stewardship. `packages/gateway/docs/host-load.md` lines 3–5: "Home
  starts every authorized task without a running cap or queue... Host pressure is an observation, never
  permission to start work or a reason to delay landing." Line 85 repeats it.
- Home's shell is refused on wakes: `home-runtime-policy.ts:9-13` and `tron-home-extension.ts:141-142`.
  Almost every admission and steer that night happened on a wake.
- The Gateway does measure pressure (`host-pressure.ts`), but only for the iPhone status row
  (`home-owner.ts:652`). The model never sees it. It is also sampled only when a client asks, so the log
  has no reading for 04:11–04:23Z.
- On maintainer turns Home could have looked and did not, except once.

What Home lacked when it admitted work: the Mac's state; what each task would need (one brief implied
12 slices × a 147-test simulator run); what the other workers were about to start; the cost of one verify;
Pinfold's simulator use; the mini's queue; and the project's own earlier measurements.

### F5. Workers cannot see each other, so Home became a slow lock manager

A worker knows only its brief. It sees other work as "foreign" processes. The coordination that night ran
through Home, by message, with 20 to 45 minutes per round:

- Home wakes for a worker's attention request at most once per 30 minutes per task. Oversight automations
  ticked every 45 to 120 minutes.
- At 03:10Z two workers were each yielding to the other (Home `4fa31a7f`).
- One worker waited from 01:30Z to 04:11Z for permission to rerun.
- Home invented a lock out of process names. It told the Pinfold worker to keep `build/final.sh` alive:
  "Two Tron workers are waiting, and they treat a live orchestrator as 'lane held'" (`0b588ae1`). The process list at
  03:36Z shows a shell loop whose only job was to hold that name (`383ff00f` result).

By contrast, the mechanisms that hand off through the kernel had no such trouble: the mini's job lock
queued three workers in order, and simulator slots freed themselves when holders were stopped.

### F6. Rules contradicted each other

- `AGENTS.md:93`: "never hand-serialize Xcode/simulator work below the cap."
- `.agents/skills/tron-ios/SKILL.md` lines 173–175: "Never hand-serialize... and never wait for a worker
  with a free slot."
- Home, 22:03Z: "Run one native lane at a time, never 3."
- Global `~/.tron/agent/AGENTS.md:36-37`: "at most 4 workers". Seven tasks were running at 15:16Z.

The charter rule was written on Oct 26–27 to stop agents from being too cautious. Two weeks later the
opposite caution was needed. An absolute rule cannot hold both.

### F7. Demand, not scheduling, was the larger problem

Four workers each needed the one simulator lane for 1 to 2.5 hours, and each needed it again after every
rebase onto a moving main (the settings worker ran 147 UI tests at one commit, then owed all 147 again at
the next). By my estimate from the workers' own figures, that is more than 8 hours of serial simulator
time requested inside 8 hours. No order of running clears that queue. Mohsin's instruction reduced the
demand: one merged branch, one run.

Briefs created this demand. Each asked for a full green `verify` per slice at the exact commit. Nobody
added up what that meant for the Mac.

### F8. The earlier machinery was already tried and deleted once

| Dates | Mechanism | Outcome |
|---|---|---|
| Oct 13 (#933) | Heavy-run queue with 2 slots, load gate, Home cap of 3 workers | Replaced in 2 days |
| Oct 15 (#1033, #1046) | Memory-aware heavy queue, 4 slots; worker cap removed; `scripts/tron gate` with a step catalog | Grew in 1 day |
| Oct 16 (#1127) | CPU-aware admission, pools, job slots, ledger. Load average dropped as a signal. Finding: failures came from I/O-bound tests slowing each other, not CPU. | Deleted next day |
| Oct 17 (#1253, `279ee16c7`) | All of the above removed: about 10,400 lines. Recorded cost: 19.7 hours of queue waiting and 7.9 hours of landing-ticket waiting. No defect was shown to have been prevented. | `~/.tron/workspace/files/strip-gates/EVIDENCE.md` |
| Oct 17 (`7d1813f5b`) | Build fan-out bounded per command (`-jobs 4`, `nice`), no queue | Still in place, no misfire found |
| Oct 26–27 (`b17ffff8d`, `85cb14825`) | "One simulator-heavy job" becomes "up to 3", then enforced by host slots with "never hand-serialize below the cap" | Permitted the Nov 12 overload (F1) |
| Nov 2 (#2173) | Verify shards iOS tests across all slots | Made one verify equal three simulator jobs |
| Nov 3 (`551ee7035`) | First-come-first-served lock for local full-Gateway runs | In place, no misfire found |
| Nov 3 | A worker's load test left 40 spinner loops and 6 fsync loops orphaned; load 120. This led to the task process reaper. | Home session `38c8cdbd`, `c6a0af5c` |
| Nov 7–10 | Gateway and Python lanes can run on the mini | Works; single queue |
| Nov 12 | Numeric load rules in steers | F2 |
| Nov 13 (`b62540a3c`) | `--ios-jobs`, default still 3 | Serial run passed |

`scripts/tron gate` and the memory-aware admission named in the brief no longer exist. They were deleted on
Oct 17.

### F9. What the kept mechanisms did during the incident

- **Task process reaper** (`task-command-sweep.ts`, `task-command-scope.ts`): on the stops at 21:02Z and
  05:11Z it reaped 9 and 8 leftover processes with no survivors (`home.task.command-reap`).
- **Simulator leases and slots** (`ios-test-lock.py`): no stale lease, no double use of a device.
- **Mini job lock** (`tools/verify/mini.py` line 306): three workers queued; none ran over another. Two
  mini runs gave no result for other reasons: a dropped SSH session (check-in `6a079943`) and a
  file-transfer race (#2511).
- **Agent shells at `nice -n 10`** and **`-jobs 4` builds**: in place; no evidence for or against in this
  window.

One defect in this group: the reaper has logged `sweep refused remove-failed` once a minute since 20:04Z
on Nov 12. It looks like one scope directory it cannot remove. It needs its own issue.

### F10. Other projects have no resource guidance at all

The Pinfold worker created three simulators with raw `simctl`, ran raw `xcodebuild` in the background and
wrote its own load gate. Its repository has no agent rules about this. Tron's leases and slots do not
cover it, and Tron workers could see it only as an unknown `xcodebuild`. The only prose that reaches both
kinds of worker is the global `~/.tron/agent/AGENTS.md` and global skills.

## 3. Did hardcoding fail?

**Partly. It depends on what the mechanism does.**

*Mechanisms that decide* failed every time: the heavy queue, the gate, the 3-slot cap used as a lane count,
the 30-second slot wait that turns into "deferred", and the load guard. They share four faults.

1. **They fix a model of the machine that is wrong or goes stale.** Load average, memory budgets and
   "three simulator jobs" were each treated as the measure of capacity. Each was wrong within days.
2. **They cannot see intent.** A cap does not know that four branches could be checked as one, that a job
   could run on the mini, or that Mohsin is asleep and the Mac is free.
3. **They turn overload into rework.** "Deferred", "interrupted" and "incomplete" all mean "run it again".
4. **They cost more than they save.** 19.7 hours of queue waiting in four days in October; seven lost runs
   in one night in November; a 6,800-line test file for the simulator tooling.

*Mechanisms that exclude or clean up* did not fail: a lease on one simulator, a lock on the mini's single
checkout, the reaper for a stopped task's processes, a bound on one build's fan-out. They hold a property
that no instruction can hold, because the agent that would follow the instruction may be stopped, wrong or
unaware. They make no judgment and carry no threshold.

**Prose that decides by number failed in the same way.** The Nov 12 rules were prose. So were "never
hand-serialize below the cap" and "at most 4 workers". The fault is not the medium. It is a fixed rule
with no owner who can see the situation and change the answer.

So the better path is not "replace code with prose". It is: give one owner (Home) sight, facts and the
authority to decide; write reasons instead of numbers; and keep code only where it must hold when agents
fail.

## 4. Root causes

1. **RC1 Job shape.** The default unit of verification was too heavy for the host and could not be made
   lighter by its caller.
2. **RC2 Blind admission.** Home was told to start and resume at once, was given no capacity guidance,
   and has no host reading on wakes.
3. **RC3 No shared view.** Workers do not announce heavy phases and cannot see each other's.
4. **RC4 Numbers without a model.** Thresholds on a signal that does not measure capacity here.
5. **RC5 Unbounded demand.** Briefs required a full heavy check per slice and per rebase, with nobody
   owning the total.
6. **RC6 The second host was an afterthought.** The mini has one queue that only tooling can see. Its
   pool falls back to this Mac when the mini is busy (`mini.py:119-120`), which moves Gateway suites onto
   the Mac exactly when it is most contended.

## 5. Existing machinery: keep, shrink or delete

| Mechanism | Where | Kind | Verdict |
|---|---|---|---|
| Lease per simulator lane and per physical device | `scripts/ios-test-lock.py` | Exclusion | **Keep** |
| Host slots (3) | `scripts/ios-test-lock.py` lines 70,179–217 | Exclusion used as policy | **Keep as a ceiling.** Stop calling it a cap to fill. Non-Tron simulator runs join it through the skill. |
| Verify lane fan-out equal to slot count | `tools/verify/verify.py` lines 577–584,1600 | Decides | **Shrink:** default one lane; the caller chooses more |
| Opportunistic lanes, 30 s slot wait, "deferred" iOS result | `verify.py:1209,1247-1327` | Decides | **Delete.** A run that needs a simulator waits for it and says who holds it. |
| `--ios-jobs` | `verify.py:1341` | Caller's choice | **Keep**, default 1 |
| Load guards written by workers | 23 scratch scripts | Decides | **Delete** (each owner's scratch). Do not rebuild them inside verify; close that part of #2520. |
| Full-Gateway lock, first come first served | `tools/verify/host_lock.py` | Exclusion | **Keep** |
| Mini job lock | `tools/verify/mini.py` line 306 | Exclusion | **Keep** |
| Mini pool (mini if idle, else this Mac) | `mini.py:93-121` | Decides | **Keep the default.** Home names the host in the brief when this Mac is busy. |
| Task process reaper and command scope | `task-command-sweep.ts`, `task-command-scope.ts` | Cleanup | **Keep.** Fix the repeating refusal log. |
| Agent shells at `nice -n 10` | `direct-bash-process-owner.ts:13,102` | Bound | **Keep** |
| Build fan-out `-jobs 4` | `scripts/tron-xcodebuild` | Bound | **Keep** |
| Host pressure level | `host-pressure.ts`, `home-owner.ts:652` | Signal | **Keep and extend:** show it to Home (open decision 4) |
| "Home starts every task... never a reason to delay" | `host-load.md:3-5,85` | Prose that decides | **Replace** |
| "Never hand-serialize below the cap" | `AGENTS.md:93`, `tron-ios/SKILL.md:173-175`, `docs/development.md` lines 289–290 | Prose that decides | **Replace** |
| "Resume it at once" | `tron-home-extension.ts:23` | Prose that decides | **Amend** |
| "At most 4 workers" | global `AGENTS.md:36-37` | Prose that decides | **Replace** (Mohsin's rule; open decision 7) |
| Numeric load rules in briefs and automations | Home's messages | Prose that decides | **Stop** |

## 6. Signals today and who can use them

| Signal | Command or source | Worker | Home, maintainer turn | Home, wake |
|---|---|---|---|---|
| Load average | `uptime`, `sysctl -n vm.loadavg` | yes | yes | no |
| CPU idle now | `top -l 2 -n 0` | yes | yes | no |
| Memory free and swap | `memory_pressure`, `sysctl vm.swapusage` | yes | yes | no |
| Who is using the CPU, and whose it is | `ps`, then `lsof -a -p <pid> -d cwd` for the worktree | yes | yes | no |
| Booted simulators | `xcrun simctl list devices booted` | yes | yes | no |
| Simulator slot holders | `scripts/tron test ios slots` | yes | yes | no |
| All Tron simulator lanes | `scripts/tron-ios-test status --all` | yes | yes | no |
| Full-Gateway lock holder | `/tmp/tron-full-gateway.lock` and its `.queue` | yes | yes | read only the file |
| Mini reachable, busy, load | `ssh` probe; `mini.py` status | yes | yes | no |
| Running tasks and their check-ins | `task list`, `task status` | no | yes | **yes** |
| Host pressure level | `home.status` RPC | no | no (iPhone only) | no |
| Past pressure and runaway non-task CPU | `gateway.jsonl`: `host.pressure`, `host.load.non-task` | read the file | read the file | read the file |

Three gaps follow from this table.

1. On a wake, Home's only live signal is what workers wrote in check-ins.
2. Workers have no view of other tasks, only of processes.
3. Nothing ties a process to a task except the Gateway's own scope records, which neither Home nor
   workers can read. A worktree path is the best available link.

Swap is a poor signal here: it read 6.7 GB used of 8 GB with the Mac idle and 84 % memory free.

## 7. Recommended design

### 7.1 Split the three kinds of thing

- **Facts** about the machines and what jobs cost: written down, dated, with their source, in the
  `resource-stewardship` skill. Updated when measured. Never compiled into code.
- **Decisions** (what runs, when, where, in what shape, who yields, what can be merged or dropped): Home,
  guided by prose that gives reasons.
- **Seatbelts** (exclusion and cleanup that must hold when an agent is stopped or wrong): the small
  mechanisms kept in section 5. Most are file locks that the operating system releases when the holding
  process dies. No thresholds, no admission logic.

### 7.2 Home's part

1. **Before it starts or resumes a worker,** Home asks what heavy work the task will need and for how
   long, looks at what is running and what the Mac is doing, and chooses: now, after a named job, on the
   mini, merged with another branch's check, or with lighter evidence first.
2. **Every brief carries a short "Heavy work" paragraph** that Home writes for that worker: which heavy
   phases to expect, where and in what shape to run them, what else is running, and what to do when the
   Mac is busy.
3. **On each wake,** Home reads the heavy-phase check-ins and the host reading, and acts when two workers
   want the same thing: one continues, the other is told what to do meanwhile and what it waits for.
4. **Home shapes demand.** When two or more branches near landing need the same heavy check, Home
   integrates them and runs the check once.
5. **Home does not send numeric load rules.** It sends the plan and the reason.
6. **After any collision,** Home adds one dated line to the skill's observations, so the facts improve.

The exact text is in [drafts/HOME-RULES.md](drafts/HOME-RULES.md) and the
[resource-stewardship skill](skills/resource-stewardship/SKILL.md).

### 7.3 The worker's part

1. Before a heavy phase, take a host reading (one command from the `host-resources` skill).
2. If the Mac is clear and the brief allows it, send a check-in that starts with `Heavy start:` and says
   what, where and roughly how long. Run it in the lightest shape the brief allows. Let it finish.
3. When it ends, send `Heavy done:` with the duration and anything unusual, and shut down what it started.
4. If the Mac is not clear, do not start and do not poll on load. Do other work. If there is none, wait on
   the specific job that is in the way and tell Home what is needed and for how long.
5. A failure that happened while the Mac was contended is reported as contended, with the reading. It is
   not retried until the Mac is clear.
6. No load-guard wrappers. No stopping a run for load that it caused itself.

The exact text is in [drafts/WORKER-RULES.md](drafts/WORKER-RULES.md) and the
[host-resources skill](skills/host-resources/SKILL.md).

### 7.4 Sight

- **Now, with no code change:** the `host-resources` skill gives one read-only snapshot command. Workers
  quote one line of it in `Heavy start:` and `Heavy done:` check-ins. Home reads those on any wake through
  `task list`, and runs the snapshot itself on maintainer turns.
- **Recommended small change:** add a host reading to Home's `task list` result
  (`home-owner.ts:302-307`). The Gateway already samples pressure and already walks each task's process
  group every 60 s, so it can say which task is running heavy processes right now. This is an eye, not a
  rule. See open decision 4.

### 7.5 Tooling changes that make the prose safe

1. `verify --ios-jobs` defaults to 1. A brief may say 2 or 3 when Home has checked that the Mac is free.
2. Verify stops deferring iOS work after a 30 s slot wait and stops starting opportunistic lanes. A run
   that needs a simulator waits and names the holder.
3. Simulator runs from other projects take a host slot with the same wrapper (the skill shows the line).
   No new code.

### 7.6 Where the design can fail, and the answer

| Failure | What limits the damage | How it shows |
|---|---|---|
| Home forgets to plan heavy work | One lane per verify by default; slots still cap simulators at 3; reaper cleans stops | Two `Heavy start:` check-ins overlap with no plan in either brief |
| Hand-off between workers is slow | Workers wait on the named job, not on Home; Home is asked only for order | Idle time between `Heavy done:` and the next `Heavy start:` |
| A worker ignores the brief | Same seatbelts; Home sees the overlap at the next wake | As above |
| A non-Tron project runs simulators | Global rules and skill reach every worker; it takes a slot | A simulator job with no slot holder in the snapshot |
| Mohsin is using the Mac himself | Home asks or infers presence; default daytime shape is one lane (open decision 6) | His message |
| The facts go stale | Observations are dated; Home re-measures when a surprise occurs | An observation that contradicts the facts table |

**Pre-agreed fallback.** If, in the two weeks after adoption, simulator jobs from different workers
collide twice, or a worker waits more than an hour for a hand-off twice, narrow the daytime slot ceiling
to 1. That is a one-line change, and it is the only mechanism I would add. I do not recommend it now,
because a fixed 1 would stop Home from using three lanes on an idle Mac overnight.

### 7.7 How to tell it is working

Count these per week from the Home session and task records: heavy runs that ended interrupted or
deferred; hours between a worker's `Heavy done:` and the next worker's `Heavy start:` while one was
waiting; `host.load.non-task` records; Home messages that carry a load number (target 0); new scratch
scripts that read load (target 0).

## 8. Not verified

- Whether two warm simulator lanes are safe on this Mac. Only one cold lane (safe) and three cold lanes
  (not safe) were observed.
- Whether the mini can run the iOS suites through the stock tools. A worker reported matching Xcode and
  runtime there, and that verify has no route to send iOS work to it.
- The Profile store. I did not check whether Home holds a saved note about machines.
- Sessions before Nov 11 were sampled only for the incidents named in the brief.
- The exact number of orphaned loops on Nov 3 comes from Home's own brief text (40 spinners and 6 fsync
  loops), not from a process listing I saw.

## Appendix: sessions and records read

| What | Session id |
|---|---|
| Home, chapter 29 (Nov 12–13) | `4c2ee571-7f0e-4300-a208-b7011b27a03d` |
| Home, Nov 2–3 chapter (orphan loops, reaper task) | `38c8cdbd-9a9b-4671-a605-261f42c2b8d8` |
| Home, Oct 20 chapter (stuck vitest PIDs 66294–66296) | `22253cba-1eb0-42f8-9f40-41c4b35a5b78` |
| Home, Oct 29 chapter (non-hermetic tests, `tron-499` processes, `fseventsd`) | `afa34923-1bb8-4266-a7a7-506e2de3e017` |
| Settings Phase 0/1 worker | `01a1d053-cc50-768d-b871-b00194aa1daa` |
| Settings Phase 2 worker | `01a1d053-d20b-768d-b871-b003010a6587` |
| Context Stage 2 worker | `01a1d053-d412-768d-b871-b0058c6f9d0a` |
| #2500 Slice B and C–E worker | `01a1cfa6-8264-768d-b871-aff2a113e904` |
| Rebuild readiness worker | `01a1d182-35e2-768d-b871-b041f16db401` |
| Pinfold iPad worker | `01a1d1e5-5841-748a-978a-4e0cfde8ee36` |
| Single integration verify worker | `01a1d353-c4d2-748a-978a-4e38be985d21` |
| `--ios-jobs` and serial gate worker (running during this audit) | `01a1d37d-d318-748a-978a-4e3b085ec5ff` |
| Lane workers for #2354 (briefs only) | task records `home-lane-ios-20261111T0700Z`, `home-lane-gateway-20261111T0700Z` |

The #2354 lane briefs are worth one note. They told each worker who else was using simulators and how to
ask for a window ("another worker is using one slot; you use at most 2"; "ask for a window by commenting
and wait until both post that slots are free"). That is the stewardship pattern this report recommends.
It was dropped on Nov 12 when three more workers were started at once.
