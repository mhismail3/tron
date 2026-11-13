---
name: host-resources
description: Read what this Mac and the Mac mini are doing before and during heavy work, in any project. Use before a simulator test run, a large build, a full test suite or a load test; when a test fails or times out and the Mac may be contended; when another job is in your way; when a process or simulator looks stuck or orphaned; and when writing a "Heavy start:" or "Heavy done:" check-in. Teaches the read-only commands, how to tell whose process it is, how to wait, and how to clean up only what you own.
---

# Host resources

This Mac is shared. It runs live Tron, the maintainer's own work and every agent's commands at the same
time. Tron Home plans heavy work across this Mac and the Mac mini. Your part is to look before you start,
say what you are doing, let it finish and clean up.

**Heavy work** is a simulator test run, a large build, a full test suite or a load test: anything that
keeps many cores, a simulator or several GB busy for more than a few minutes. Editing, reading, Git, type
checks and single test files are not heavy.

## Take a reading

Run the snapshot. It only reads; it changes nothing.

```bash
bash ~/.tron/agent/skills/host-resources/host-state.sh
```

It prints, in this order:

1. **Load and CPU idle.** Use CPU idle to judge how busy the cores are. Treat load average with care on
   this Mac: simulators create hundreds of runnable threads, so load can read 200 with half the CPU idle.
   Load tells you "simulators are active", not "the Mac is full".
2. **Memory free and swap.** Memory free below about 15 % matters. Swap in use does not: it stays high
   for hours after pressure has gone.
3. **Heavy processes** with their working directory. The directory tells you whose they are (below).
4. **Test and build drivers**: `xcodebuild`, `xctest`, Tron's `verify`, Vitest and node test runs, even
   when they are idle between steps.
5. **Booted simulators.** Tron's are named for their lane and worktree.
6. **Simulator slots**: who holds each of the three host slots, with worktree, PID, start time and
   command.
7. **The full-Gateway lock** record, when a local full Gateway test run holds or last held it.

If the script is missing, the same facts come from: `sysctl -n vm.loadavg`, `top -l 2 -n 0 -s 1 | grep
"CPU usage" | tail -1`, `memory_pressure | tail -1`, `ps -Ao pid,pcpu,etime,command | sort -k2 -nr | head`,
`xcrun simctl list devices booted`, and in a Tron checkout `scripts/tron-ios-test slots`.

For a check-in, quote one line: `host: cpu idle 71%, 1 simulator booted, slot 0 held by settings-0.1-wording`.

## Whose process is it

- **Working directory.** `lsof -a -p <pid> -d cwd -Fn` prints it. A path under
  `~/Workspace/tron-worktrees/<name>` or another project's worktree names the worker's worktree.
- **Parent chain.** `ps -o pid,ppid,etime,command -p <pid>` and follow `ppid`. A parent of 1 with a long
  elapsed time, in a worktree whose task has ended, is a likely orphan.
- **Slot holder.** A simulator job that holds a slot names its worktree and start time.
- **Not an agent's.** Xcode, Simulator.app and builds started by the maintainer have no worktree under a
  worker. Never touch them.

You cannot see other tasks, only processes. Home can see tasks. When you need to know who a job belongs
to or how long it will run, say what you saw in a check-in and Home will answer.

## Before heavy work

1. Read the "Heavy work" paragraph of your brief. It says when, where and in what shape to run.
2. Take a reading.
3. **Clear** means: no other heavy job is running, or your brief says you may run beside the one that is.
   If it is clear, send a check-in whose step begins `Heavy start:` and says what, where and about how
   long. Example: `Heavy start: verify --changed, one simulator lane, this Mac, about 50 min`.
4. **Not clear:** do not start. Do other work from your brief. If you have none, wait for the job in your
   way (below) and send one check-in that says what you need and for how long. Use `needsAttention` only
   when you are fully blocked.
5. Run in the lightest shape your brief allows. In Tron, `verify` uses one simulator lane unless the
   brief says `--ios-jobs 2` or `3`.
6. Let the run finish. When it ends, send `Heavy done:` with the duration and the result, then shut down
   what you started.

Why this matters: two heavy jobs at once slow each other until tests with short deadlines fail. A heavy
run that fails or is stopped for contention must be run again from the start, which adds more load than
waiting would have.

## Simulators

- **In Tron:** use the repository tools (`scripts/tron-ios-test`, `scripts/tron verify`,
  `scripts/ios-gateway-e2e-test`). They lease a lane, take a host slot and release the simulator for you.
  Never call `xcodebuild`, `simctl` or Xcode tools around them.
- **In any other project:** run one simulator at a time, and take a host slot for each test run so other
  workers see you and queue behind you instead of colliding:

  ```bash
  python3 ~/Workspace/tron/scripts/ios-test-lock.py \
    --lock "$PWD/build/host-slot/lease.lock" --host-slot \
    --resource "<project> simulator tests" --worktree "$PWD" -- \
    xcodebuild test-without-building <your arguments>
  ```

  The wrapper waits when all slots are held and prints who holds them. It frees the slot when your
  command ends, even if it is killed.
- Shut down the simulators you booted when your run ends: `xcrun simctl shutdown <udid>` for each of
  yours. Never `simctl shutdown all` and never `killall Simulator`: other workers' tests are running on
  the others.
- Do not create a new simulator device per run. Reuse the ones your task already created, and delete
  them when the task ends.

## Waiting for a job

Wait for the specific job, not for a load number.

- **A simulator job that holds a slot:** start your own run through the Tron tools or the wrapper above.
  It queues behind the holder and starts when a slot frees.
- **A named process:** `while kill -0 <pid> 2>/dev/null; do sleep 30; done`. Check in before you wait,
  and again if the wait passes 30 minutes.
- **A named task:** only Home knows when a task is done. Ask in a check-in; Home steers you when it is
  your turn.
- Never wait in a loop on load average. Never write a script that stops your run when load rises. On
  2026-11-12 workers and such scripts stopped seven runs for load, and none had reported a failing test.

## The Mac mini

- It is the second test host (`git config tron.verify.mini` in a Tron checkout names it). It has fewer
  cores and less memory than this Mac and runs **one job at a time**.
- In Tron, Gateway Vitest lanes, the Python group and Gateway `node --test` files can run there:
  `scripts/tron test gateway --mini ...` or `scripts/tron verify ... --gateway-host mini`. The tools push
  your commit, run it and bring the results back. Always say in your report which host ran each lane.
- A job that finds the mini busy waits for the time in `TRON_MINI_JOB_WAIT_SECONDS`, then gives no
  result. No result is not a failure and not a pass.
- Simulator tests do not run on the mini through the stock tools.
- Probe it without running anything: `ssh -o BatchMode=yes -o ConnectTimeout=5 "$(git config
  tron.verify.mini)" uptime`.

## When a test fails and the Mac was busy

1. Take a reading at once and keep it with the failure log.
2. Report the failure as **contended**: not red, not green. Say what else was running.
3. Do not raise a timeout, loosen an assertion or retry in a loop.
4. Rerun once when the Mac is clear, or on the mini if the lane can run there. If it fails again on a
   clear host, it is a real failure.

## Stuck and orphaned processes

Signs: a parent of 1; running for hours; a worktree whose task has ended; a booted simulator no slot or
lane accounts for; CPU pinned with no output.

- **Yours** (you started it in this task): stop it. Send SIGTERM to its process group, wait, check it is
  gone with `ps`, then shut down its simulator. Say so in your next check-in.
- **Not yours, or you are not sure:** do not signal it. Report to Home: PID, parent, elapsed time, CPU,
  working directory, command, and why it looks stuck. Home decides and asks the maintainer when the owner
  is unknown.
- Never use broad kills: `pkill node`, `killall`, `simctl shutdown all`, `kill -9` on a group you did not
  start. Never touch the Gateway, Tron.app or their children.
- Never pause a process with SIGSTOP. Tron still counts it as running, and restarts block on it.

When a Tron task settles or is stopped, the Gateway reaps the processes its commands left. That covers
your own leftovers after a stop. It does not cover simulators' own system services or anything started
outside a task.

## Do not

- Start heavy work without a reading and a `Heavy start:` check-in. Nobody else can see you.
- Stop a run because of load it causes itself.
- Treat "deferred", "interrupted" or "contended" as a pass.
- Induce load on this Mac to reproduce a problem. Reproduce in-process, or ask Home for a quiet window.
