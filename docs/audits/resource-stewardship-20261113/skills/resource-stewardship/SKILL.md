---
name: resource-stewardship
description: Read BEFORE every Tron Home delegate, task resume or steer that starts, moves or reorders heavy work (simulator test runs, large builds, full test suites, load tests), at every oversight tick while more than one worker is running, and whenever a worker reports contention, a timeout under load, a wait for another job, or a stuck or orphaned process. Home owns how heavy work is spread across this Mac and the Mac mini; this skill holds the facts about the machines, the questions to ask before admitting work, the "Heavy work" paragraph for briefs, and what to do when workers collide.
---

# Resource stewardship (Home)

You decide what heavy work runs, when, where and in what shape. Workers cannot see each other, and no
script decides this for you. Scripts only keep two jobs off the same simulator and clean up after a
stopped task. Everything else is your judgment, guided by the facts below.

The aim is simple: **every heavy run that starts can finish.** A run that contention interrupts or fails
gives no evidence and must be repeated, so it costs more than the wait it tried to avoid.

Files in this skill:

- `SKILL.md`: this procedure and the current facts.
- `OBSERVATIONS.md`: dated, append-only lines from real incidents and measurements. Raw evidence. When a
  pattern repeats, fold it into the facts here.

Workers use the companion skill `host-resources` to read the machines. Read it once; you use the same
snapshot on maintainer turns.

## Facts (revise from observations; every line has a date)

**Machines**

| Machine | Size | Also runs | Good for |
|---|---|---|---|
| This Mac | 18 cores, 36 GB (2026-11-13) | Live Tron and its Gateway, the maintainer's own work, every worker's shell, Xcode and all simulators | Simulator tests, Xcode builds, Mac tests, anything that needs this Mac's files |
| Mac mini | 10 cores, 16 GB (2026-11-13) | Nothing else | Tron Gateway Vitest lanes, the Python group, Gateway node tests. One job at a time. No simulator tests through the stock tools. |

**What jobs cost on this Mac**

| Job | Observed | Date |
|---|---|---|
| Tron verify, simulator tests, 1 lane | Load peak about 8. 15 tests in 291 s. Passed. | 2026-11-12 |
| Tron `verify --all --ios-jobs 1`, whole run | 50 min 53 s; 45 simulator tests in four shards of 5–6 min each; no pressure | 2026-11-13 |
| Tron verify, simulator tests, 3 lanes started cold | Load 215, 354 and 428 on three runs. Live Gateway event loop at 95–100 %. Tests with 60 s deadlines elsewhere on the Mac timed out. | 2026-11-12/13 |
| Two simulator jobs plus a third job building | Load 86 rising to 211 in 12 minutes | 2026-11-13 |
| A full 147-test UI selection, 1 lane | About 150 minutes | 2026-11-12 |
| One iOS build, 4 build jobs | 99–206 s | 2026-11-12/13 |
| Pinfold: three-device regression plus screenshot tours, 1 simulator | About 90 minutes | 2026-11-13 |

**What jobs cost on the mini**

| Job | Observed | Date |
|---|---|---|
| Full default Gateway suite (about 1,725 tests) | About 8 minutes | 2026-11-13 |
| Full nested Gateway config (about 120 tests) | About 8 minutes | 2026-11-13 |
| Selected Gateway tests of a typical change | 1–3 minutes | 2026-11-13 |

**Signals and their traps**

- **Load average** does not measure how full this Mac is. It rises with simulator activity. Do not turn
  it into a threshold. (Measured 2026-10-16: load 21 with 3 cores busy, 125 with 8. Seen again
  2026-11-12: load about 480 with CPU 53 % busy.)
- **CPU idle** and **memory free** from the snapshot are the honest numbers.
- **Swap in use** stays high for hours after pressure ends. Ignore it.
- **Not yet known:** whether two warm simulator lanes are safe. Until measured, plan one.

**Working plan that follows from these facts**

- By day, or whenever the maintainer is using Tron: one simulator job on this Mac at a time, with one
  lane. Send Gateway, Python and node lanes to the mini. Any number of workers may read, edit, review and
  run small tests meanwhile.
- When the Mac is otherwise free and nobody is waiting on live Tron (overnight, or he says he is away):
  one job may use more lanes (`--ios-jobs 3`). Still one job at a time.
- The mini takes one job at a time. Queue jobs there in the order that matters, not the order they
  arrive.

This plan is a default, not a rule. Change it when the facts or the situation change, and say why.

## Before you start, resume or steer a worker into heavy work

Answer five questions. Two minutes of thought here saves hours.

1. **What heavy work will this task need, and how much?** Count it: slices × the check each slice needs.
   A brief that asks for a full green verify on each of 12 slices asks for 12 simulator runs.
2. **What is already running or promised?** Read `task list`. Look for check-ins whose step begins
   `Heavy start:` without a later `Heavy done:`, and for briefs you wrote that promise a turn.
3. **What is the Mac doing?** On a maintainer turn, run the snapshot:
   `bash ~/.tron/agent/skills/host-resources/host-state.sh`. On a wake you have no shell: use the newest
   `host:` line in workers' check-ins. If you must know and nothing is fresh, ask a running worker by
   steer to send a check-in with a reading.
4. **Is he here?** If the maintainer is chatting with you or just rebuilt, live Tron must stay fast.
5. **Which shape fits?**
   - **Now**: nothing heavy is running, or the facts say the overlap is safe.
   - **After a named job**: tell the worker which task it follows and what to do meanwhile.
   - **On the mini**: for Gateway, Python and node lanes.
   - **Merged**: two or more branches need the same full check. Start one integration worker that merges
     them and runs the check once. Give the other workers only cheap checks until then.
   - **Lighter first**: type checks, the changed module's tests and a review now; the heavy check once,
     at the end, not per slice and not per rebase.
   - **Later**: say when, and arm an automation that resumes it.

Then write the plan into the brief.

## The "Heavy work" paragraph

Every brief for a task that may run heavy work carries one. Write it for that worker. Give the reason for
any wait. Do not write load numbers.

```text
Heavy work. <What heavy phases you expect in this task and roughly how long.> <Where and in what shape to run them: this Mac with one simulator lane / the Mac mini for Gateway, Python and node lanes / wait until <named task or job> reports "Heavy done:".> <What else is running now and until about when.> Before each heavy phase take a host reading (host-resources skill). If the Mac is clear, send a check-in whose step begins "Heavy start:" with what, where and about how long, and let the run finish. When it ends, send "Heavy done:" and shut down what you started. If the Mac is not clear, do not start: <what to do meanwhile>, and check in with what you need. Do not stop a run for load it causes itself, and do not write load-guard scripts. A failure under contention is "contended", not red.
```

For a worker in another project (Pinfold and the rest), add: run one simulator at a time, take a host
slot for each simulator test run with the wrapper in the host-resources skill, and ask before any run
longer than about 20 minutes while Tron workers have simulator runs planned.

## Oversight tick

Use this as the prompt of an oversight automation, in place of lists of absolute rules:

```text
Oversight tick for <task ids>. Read task list. For each task: running with a check-in in the last 60 minutes, leave it; silent longer, steer once for status; settled unfinished with no maintainer decision needed, resume it. Before any resume or steer that starts heavy work, apply the resource-stewardship skill: read the "Heavy start:" and "Heavy done:" check-ins, and give the machine to one heavy job at a time unless the skill's facts say the shape is safe. If two workers are waiting on each other, name the order now. Notify the maintainer once for a genuine decision or when everything has settled, then pause this automation. This message is not maintainer authority.
```

At each tick also ask: is anyone waiting who could be doing something else? Has a `Heavy done:` arrived
that frees the next worker? Steer the next worker at once; do not leave the hand-off to the next tick.

## When workers collide

Signs: two `Heavy start:` check-ins overlap; a worker reports "contended" or a timeout under load; a
worker says it is waiting for a foreign job; the maintainer says Tron is slow.

1. **Find out what is running.** `task list` for the heavy check-ins; the snapshot if you have a shell.
2. **Let the job that is furthest along finish.** Stopping it wastes the most.
3. **Pick the order for the rest** by what unblocks the maintainer soonest. A check that gates a rebuild
   he is waiting for goes before a check on a branch that cannot land yet.
4. **Tell each waiting worker three things:** what it waits for (a named task), what to do meanwhile,
   and that you will steer it when its turn comes. Never tell two workers to wait for "no other heavy
   job": each will wait for the other.
5. **If a run is hurting live Tron now** and he is using it, interrupt the newest heavy command with
   `task interrupt` and say why. Interrupt, not stop: the worker keeps its state.
6. **Record it.** One dated line in `OBSERVATIONS.md`: what overlapped, what it cost, what you changed.

Do not answer a collision with a threshold. "Start below load 40, stop above 80" was tried on
2026-11-12. Workers turned it into 23 different scripts. Workers and those scripts stopped seven runs for load,
and none of the seven reported a failing test.

## Asking for less

Scheduling cannot clear a queue that is longer than the day. On 2026-11-12 four workers asked for more
than 8 hours of simulator time inside 8 hours.

- Ask for the heavy check once per landing, not per slice and not after every rebase onto a moving main.
- When several branches are ready, merge them on an integration branch and check once. If it is red,
  find the branch that caused it; do not rerun everything.
- Do not ask two workers for the same full-suite run on the same commit.
- Prefer the mini for anything it can run.
- A long simulator selection is a reason to ask whether all of it is needed for this change. That is
  your call when it is objective, and the maintainer's when it trades away coverage he asked for.

## Routing to the mini

- What can go: Tron Gateway Vitest lanes (default and nested), the Python group, Gateway `node --test`
  files. In a brief: "run Gateway, Python and node lanes with `--gateway-host mini`".
- The stock pool picks the mini only when it is idle and otherwise runs the lane on this Mac. When this
  Mac is busy with simulators, name the mini in the brief so the lane waits for the mini instead.
- One job at a time. When several workers need it, give the order yourself. A worker blocked behind a
  long mini job should hear from you what to do meanwhile.
- What cannot go: simulator tests, Mac tests, tests that read this Mac's Tron data.

## Stuck and orphaned processes

A worker reports a process that is not its own and looks stuck.

1. Check whether a running task owns it: the working directory names a worktree; `task list` tells you
   whether that worktree's task is live. A task that settled or was stopped has already been reaped by
   the Gateway; what survives is outside task scope.
2. If a live task owns it, steer that worker to deal with it.
3. If no task owns it and it is clearly agent residue (a test runner in a deleted worktree, a simulator
   booted by a finished lane), have one worker stop exactly those PIDs with SIGTERM, after it rechecks
   each one. Use a cheap model and name the PIDs in the brief.
4. If the owner is unknown, or it might be the maintainer's, ask him. Never broad kills. Never touch the
   Gateway, Tron.app or their children.

## When the maintainer asks for more parallelism

He decides how his Mac is used. Tell him the fact that applies, in one sentence, then do what he asks in
the safest shape that satisfies it. Example: "Three simulator lanes at once took this Mac to load 428
last night; I can open a second lane and watch the first run, or keep one lane and send the Gateway
lanes to the mini. Which do you want?" If he has already said, do it and record what happened.

## Recording observations

Append one line per event to `OBSERVATIONS.md`:

```text
2026-11-13 | settings + #2500 + Pinfold + readiness overlapped on simulators | load 211, 2 nested timeouts, 1 run interrupted | set an explicit order; one lane each
```

When a line contradicts the facts table, re-measure and correct the table. When a pattern repeats twice,
fold it into this file. Rules about how Tron works do not go here; they stay in AGENTS.md and Home rules.
