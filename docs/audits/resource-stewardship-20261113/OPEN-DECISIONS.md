# Open decisions for Mohsin

Eight choices that only you can make. Each has my recommendation and the reason. Evidence is in
[REPORT.md](REPORT.md). Nothing proceeds on these until you answer; the audit itself changed nothing.

## 1. Adopt the split: Home decides, code only excludes and cleans up

**Question.** Should Home own every decision about heavy work (what runs, when, where, in what shape),
with the machine facts kept in a skill, and code kept only for exclusion and cleanup?

- **Yes (recommended).** Thresholds, caps used as targets, deferral and load guards go. Leases, host
  slots as a ceiling, the mini's lock, the full-Gateway lock, the task process reaper and the build
  fan-out bound stay.
- **No.** Keep the current mix.

**Why yes.** Every mechanism that tried to decide failed here: the October heavy queue (19.7 hours of
waiting in four days, then deleted), the 3-slot cap (it let one verify overload the Mac), and the
November load rules (seven runs stopped for load, none with a reported failing test). None of the
mechanisms that only exclude or clean up misfired.

**Where I disagree with "no hardcoding at all".** The exclusion and cleanup mechanisms must stay. A
stopped or mistaken worker cannot follow an instruction, so no prose can stop two jobs from using one
simulator or clean up after a killed task.

## 2. Simulator lanes per verify run: default 1 or 3

**Question.** `--ios-jobs` now exists but defaults to 3.

- **Default 1 (recommended).** One verify cannot overload the Mac by itself. Home writes `--ios-jobs 3`
  into a brief when the Mac is free.
- **Keep 3.** Faster for one worker alone; every brief must remember to say 1.

**Why 1.** Three lanes took a quiet Mac to load 215, 354 and 428. One lane peaked near 8 and passed.
**Cost:** a single worker's simulator step takes about three times longer by the clock.

## 3. Hand-off between simulator jobs from different workers

**Question.** When two workers both need the simulators, what makes the second one wait?

- **(a) Home's plan (recommended to start).** Home names the order in briefs and steers. The slot
  ceiling stays 3 as a seatbelt. Workers announce heavy phases in check-ins.
- **(b) A hard one-at-a-time rule now.** Set the daytime slot ceiling to 1. The kernel queues jobs.
- **(c) Measure first, then choose** (migration step 3).

**Why (a), with a named fallback.** (b) is the most robust against collisions, but a fixed 1 would stop
Home from using three lanes on an idle Mac overnight, which is exactly the kind of decision you want Home
to make. So start with (a) and agree the trigger for (b) now: if, in the two weeks after adoption,
simulator jobs from different workers collide twice, or a worker waits over an hour for a hand-off
twice, narrow the daytime ceiling to 1. It is a one-line change.

**Risk you accept with (a).** Hand-offs go through Home, and Home wakes slowly (an attention request at
most once per 30 minutes per task; ticks every 45–120 minutes). Decision 4 reduces this.

## 4. Let Home see the Mac on wakes

**Question.** Home's shell is refused on automation and result wakes, so it cannot read the Mac at the
moment it resumes workers. How should it see?

- **(a) Add a host reading to Home's `task list` result (recommended).** A small Gateway change: CPU
  busy, memory free, booted simulators, and which running task has heavy processes now. Needs a rebuild.
- **(b) Allow read-only shell commands on wakes.** No new data path, but it weakens the rule that wake
  content cannot gain shell authority.
- **(c) Nothing.** Home relies on the `host:` line in workers' check-ins and reads the Mac itself only
  when you message it.

**Why (a).** It is an eye, not a rule. The Gateway already measures all of it for the iPhone status row
and for the process reaper; today the model is the one party that cannot see it. Until it ships, (c) is
what the skills implement.

## 5. Install the skills and the global "Shared machines" section now

**Question.** Both are writes under `~/.tron`, which this task was not allowed to make.

- **Yes, now (recommended).** Copy the two skills to `~/.tron/agent/skills/` and add the section to
  `~/.tron/agent/AGENTS.md`. No rebuild needed. Home reads a skill before delegating when its
  description says so, as it does with `model-craft`.
- **Wait** for the Gateway change that puts the paragraph into Home's rules.

**Why now.** It covers the gap until the next rebuild, and it is the only route that reaches workers in
other projects such as Pinfold. Undo is deleting two folders and one section.

## 6. What Home protects while you are using the Mac

**Question.** Heavy work slows live Tron and the iPhone app. When you are present, which wins?

- **(a) Responsiveness while you are active; throughput when you are away (recommended).** By day or
  while you are chatting: one simulator job, one lane, Gateway lanes on the mini. When you say you are
  asleep or away: Home may give one job up to three lanes.
- **(b) Throughput always.** Accept a slow Tron while checks run.
- **(c) Responsiveness always.** One lane at all times.

**Why (a).** It matches what you asked for on both nights ("drive it all to completion" when going to
sleep; "why are they taking so long" when present). Home infers presence from your messages and does not
ask more than once a day.

## 7. Replace "at most 4 workers" with a limit on heavy work

**Question.** Your global rule says at most 4 workers. Seven tasks were running at 15:16Z on Nov 12.

- **Replace it (recommended).** Home limits how much heavy work runs at once, not how many workers read,
  edit and review. Text is in `drafts/WORKER-RULES.md`, draft 2.
- **Keep the number** and have Home enforce it.

**Why replace.** The count was not the problem. Four light workers cost nothing; one verify with three
lanes overloaded the Mac alone.

## 8. One combined check for several ready branches

**Question.** May Home merge branches that are ready onto an integration branch and run the full heavy
check once, instead of one full simulator run per branch and again after every rebase?

- **Yes (recommended).** Each branch still runs its changed modules' tests and gets its review. The
  simulator selection and the full suites run once, on the integration tip. If that run is red, Home
  finds the branch that caused it and drops or fixes that branch.
- **No.** Every branch proves itself fully at its exact commit before landing.

**Why yes.** This was your own instruction on Nov 13. Before it, four workers had asked for more
simulator time than the night held, and seven runs were stopped without a result. After it, one
`verify --all` on the merged branch passed in 51 minutes. It changes what "green before landing" means
for a single branch, which is why it is your call. It fits principle P2: whole-system health is a batch
signal, not a commit gate.

## Later, not now

- **Simulator tests on the Mac mini.** A worker reported the mini has the same Xcode and runtime, but
  verify cannot send simulator work there and the mini has 16 GB. Decide after the two-week review,
  using the measurement in migration step 3.
- **Warm, reused simulators** instead of fresh devices per worktree and lane (141 devices exist). Decide
  after the same measurement.
