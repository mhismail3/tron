# Draft: worker rules and the brief paragraph

Drafts only. Each block names its destination file and gives the exact text.

## 1. Global agent rules: new section

**Destination:** `~/.tron/agent/AGENTS.md`, a new section after "Operating the Mac". This file is loaded
by Home and by every worker in every project, so it is the only prose that reaches a Pinfold worker and
a Tron worker alike. Writing it needs Mohsin's approval (open decision 5).

```markdown
## Shared machines

- This Mac runs live Tron, the maintainer's own work and every agent at once. The Mac mini is a second
  host for tests that do not need this Mac. Tron Home plans heavy work across both. Follow the "Heavy
  work" paragraph of your brief.
- Heavy work is a simulator test run, a large build, a full test suite or a load test: anything that
  keeps many cores, a simulator or several GB busy for more than a few minutes. Read the
  `host-resources` skill before your first heavy run in a task.
- Look at the Mac before heavy work. If another heavy job is running and your brief does not say to run
  beside it, do not start. Do other work, or wait for that job and tell Home what you need and for how
  long. Two heavy jobs at once usually fail both, and a failed heavy run costs a full rerun.
- Say when heavy work starts and ends, in a check-in whose step begins `Heavy start:` or `Heavy done:`.
  Other workers cannot see you. Home can plan only around what you report.
- Let a heavy run finish. Do not write a script that stops your run when load rises: the run itself
  raises load. If something else is overloading the Mac, check in with a host reading instead.
- A test that failed while the Mac was contended is "contended": not red and not green. Report it with
  the reading, and rerun it once the Mac is clear.
- Clean up what you start: simulators you booted, background processes, temp directories. Stop only
  your own processes. Report anything else that looks stuck to Home.
```

## 2. Global agent rules: worker count

**Destination:** `~/.tron/agent/AGENTS.md`, section "Scope and tracking". Mohsin wrote this rule, so the
change is his (open decision 7).

Replace:

```markdown
- Work in timeboxed cycles of at most 3 hours that end in a rebuild checkpoint, with at
  most 4 workers and tasks of about 2 hours.
```

with:

```markdown
- Work in timeboxed cycles of at most 3 hours that end in a rebuild checkpoint, with tasks of about
  2 hours. Home limits how much heavy work runs at once (Shared machines), not how many workers think,
  read and edit.
```

## 3. Tron charter: Resources and cleanup

**Destination:** `AGENTS.md` in the Tron repository, section "Resources and cleanup".

Replace the bullet that begins "Up to 3 simulator-heavy jobs run at once" (line 93) with:

```markdown
- Home plans heavy work across workers; follow your brief's "Heavy work" paragraph and the global Shared machines rules. `verify` runs one simulator lane unless the brief says `--ios-jobs 2|3`. Host slots (`scripts/ios-test-lock.py --host-slot`; `scripts/tron-ios-test slots`) are a ceiling of 3 simulator jobs on this Mac, not a number to fill; a job that needs a slot waits for it.
```

In the bullet that begins "No broad kills", replace the last sentence
("Reproduce load in-process; if slow, check swap and report foreign hogs.") with:

```markdown
Reproduce load in-process; if the Mac is slow, take a host reading (`host-resources` skill) and report what is using it.
```

**Reason for the second change:** swap read 6.7 GB of 8 GB used on an idle Mac with 84 % of memory free
during this audit, so "check swap" points at a number that does not move with contention.

## 4. iOS skill

**Destination:** `.agents/skills/tron-ios/SKILL.md`.

Replace the sentence at lines 44–47 ("Host-wide, at most 3 simulator-heavy jobs run at once: ... there
is no other queue or admission.") with:

```markdown
Host-wide, host slots allow at most 3 simulator jobs at once: each of these commands takes one of 3 slots
and waits, printing the holders, when all are taken. That is a ceiling; Home plans how many actually run
(`packages/gateway/docs/host-load.md`). There is no other queue or admission.
```

Replace the bullet that begins "Up to 3 simulator-heavy jobs run at once across all worktrees and
workers" (lines 166–177) with:

```markdown
- Home plans simulator work across workers; your brief's "Heavy work" paragraph says when and in what
  shape to run. `scripts/ios-test-lock.py --host-slot` holds the ceiling of 3 simulator jobs on this
  Mac: `tron-ios-test` (`build`, `run`, `checkpoint`, `prepare`, `diagnose`, so `scripts/tron verify`'s
  iOS lanes), `tron-profile ios`, `ios-gateway-e2e-test` (all but `stop`/`clean`) and
  `tron-ios-simulator install` take a slot after their lane's lease, and a job that finds all slots
  held waits and names the holders. `scripts/tron-ios-test slots` shows them. The slot is a kernel
  `flock`, so a killed or crashed job frees it once its command tree has ended. `verify` uses one lane
  unless told `--ios-jobs 2|3`. Each lane keeps its own simulator and DerivedData. There is no CPU,
  memory or load admission, and none should be scripted around a run. Run only one simulator job per
  worktree.
```

## 5. Development runbooks

**Destination:** `docs/development.md`, the paragraph at lines 285–290. Replace its sentences up to
and including "Do not hand-serialize Xcode or simulator work below the cap." with the text below. Keep
the link that follows ("iOS parallel workers").

```markdown
Home plans heavy work across workers (`packages/gateway/docs/host-load.md`). Host slots
are the ceiling: at most 3 simulator jobs run at once on this Mac, across all worktrees and workers. The
iOS test runner (`scripts/tron-ios-test` build/run, so `verify` too), the profiler, the Gateway E2E
harness and `scripts/tron-ios-simulator install` each take one of three host-wide slots through
`scripts/ios-test-lock.py --host-slot`, waiting (and naming the holders) when all are held; a killed
holder frees its slot. `scripts/tron test ios slots` shows them. `verify` runs one simulator lane unless
its caller passes `--ios-jobs 2|3`.
```

**Destination:** `packages/ios-app/docs/development.md`, the paragraph at lines 158–165 ("At most 3
simulator-heavy jobs run at once on the Mac..."). Make the same two changes there: call the 3 slots a
ceiling that Home plans within, and, when the verify change in the migration list lands, delete the
sentence "Pre-land verify uses 30 seconds and reports unavailable iOS checks/tests as deferred, never
passed; the batch retains unbounded admission."

**Destination:** `tools/verify/README.md`, line 20. When the default changes:

```markdown
scripts/tron verify ... --ios-jobs 3             # more simulator lanes at once (1|2|3; default 1), when the brief says the Mac is free
```

## 6. The "Heavy work" paragraph of a brief

**Destination:** the `resource-stewardship` skill (already included in the draft skill). Home writes one
of these into every brief whose task may run heavy work. It replaces today's "Load:" lines.

Template:

```text
Heavy work. <What heavy phases Home expects in this task and roughly how long.> <Where and in what shape to run them: this Mac with one simulator lane / the Mac mini for Gateway, Python and node lanes / wait until <named task or job> reports "Heavy done:".> <What else is running now and until about when.> Before each heavy phase take a host reading (host-resources skill). If the Mac is clear, send a check-in whose step begins "Heavy start:" with what, where and about how long, and let the run finish. When it ends, send "Heavy done:" and shut down what you started. If the Mac is not clear, do not start: <what to do meanwhile>, and check in with what you need. Do not stop a run for load it causes itself, and do not write load-guard scripts. A failure under contention is "contended", not red.
```

Three filled examples.

A worker that may go first:

```text
Heavy work. Expect one full affected verify near the end (about 50 minutes with one simulator lane) and several short Gateway test runs. Run Gateway, Python and node lanes on the Mac mini (`--gateway-host mini`); run the simulator part on this Mac with the default single lane. Nothing else heavy is running now. Before each heavy phase take a host reading (host-resources skill). If the Mac is clear, send a check-in whose step begins "Heavy start:" with what, where and about how long, and let the run finish. When it ends, send "Heavy done:" and shut down what you started. If the Mac is not clear, do not start: continue source work and reviews, and check in with what you need. Do not stop a run for load it causes itself, and do not write load-guard scripts. A failure under contention is "contended", not red.
```

A worker that goes second:

```text
Heavy work. Your slices each need a simulator run (about 150 minutes in total with one lane). The settings worker (worktree settings-0.1-wording) holds this Mac's simulator time until it reports "Heavy done:", expected about 02:00Z. Until then do the source work, reviews and the Gateway lanes on the Mac mini. I will steer you when it is your turn; if you have nothing left to do before that, check in with needsAttention and say so. Then proceed as follows: host reading, "Heavy start:" check-in, one lane, let it finish, "Heavy done:" check-in. Do not stop a run for load it causes itself, and do not write load-guard scripts. A failure under contention is "contended", not red.
```

A worker in another project:

```text
Heavy work. This task needs simulator builds and UI test runs for three devices. This Mac also runs live Tron and Tron's own workers. Run one simulator at a time and shut each one down when its run ends. Take a host slot for every simulator test run so Tron's workers can see you and queue behind you; the host-resources skill has the one-line wrapper. Two Tron workers have simulator runs planned tonight, so run your short checks freely but ask me (check-in with needsAttention) before any run longer than about 20 minutes. Send "Heavy start:" and "Heavy done:" check-ins around each long run. Do not write load-guard scripts. A failure under contention is "contended", not red.
```
