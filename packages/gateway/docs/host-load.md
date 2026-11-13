# Host load and independent workers

Home owns how heavy work is spread across this Mac and the Mac mini: what runs, when, where and in what
shape. Heavy work is a simulator test run, a large build, a full test suite or a load test. The Gateway
itself starts every authorized task without a cap or queue. Home plans each task's heavy phases in its
brief and adjusts by steer, using the `resource-stewardship` skill. Host pressure is one of its inputs.

There is no shared CPU, memory or load-average admission, no gate, no merge lock and no load guard. Do
not add one. Earlier ones were removed for cause (#1253), and worker-written load guards interrupted
passing runs (the 2026-11-13 resource audit). Decisions belong to Home. Code keeps only exclusion and
cleanup:

- Each simulator lane and physical device has an exclusive lease.
- Host slots (`scripts/ios-test-lock.py --host-slot`) are a ceiling of three simulator jobs on this Mac.
  The ceiling is not a number to fill. A job that needs a slot waits for it and names the holder.
- `verify` runs one simulator lane unless its caller passes `--ios-jobs 2` or `3`. Home says so in the
  brief when the Mac is otherwise free.
- Local full-Gateway runs take `/tmp/tron-full-gateway.lock` in arrival order. The mini runs one job at
  a time under its own lock.
- Each command cleans up its own processes and simulator. Settling a task reaps what its commands left
  (below). Do not kill another worker or Stable.

Workers follow the "Heavy work" paragraph of their brief, announce heavy phases in check-ins that begin
`Heavy start:` and `Heavy done:`, and read the host with the `host-resources` skill before they start.
Use ordinary Git/gh to inspect current branches, worktrees and issues. A parked claim is not proof of
live work.
See the [Git/gh skill](../../../.agents/skills/tron-work/SKILL.md).

## Agent command priority

The bash tool of every Gateway-hosted session (`DirectBashProcessOwner`: chats, Home and
task workers) execs its shell through `nice -n 10`, so the shell and every
descendant run below the Gateway, which keeps its own priority and wins the CPU for
interactive requests. Niceness, not background QoS: QoS confines work to efficiency
cores and throttles its I/O (an idle TypeScript check ran 4× slower). A user's own `!`
command keeps default priority. Subagent child processes are launched by the pinned
`pi-subagents` package, not this owner, and are not lowered.

## Task command scopes

Binding a Home task to its worker gives that session a command scope
(`kernel/run/task-command-scope.ts`): each foreground shell gets the scope's short
`TMPDIR` (`$TMPDIR/tron-tc/<session digest>`),
a recorded process group and an inherited anchor descriptor (fd 19). Settling the task
(report, Stop, deadline or failure) unbinds the session and reaps everything the scope
owns, including background children re-parented to launchd and `setsid` children that
kept the anchor, then removes its `TMPDIR`. `TaskCommandSweep` runs every 60 s (one `ps`,
one `lsof` per scope): it reaps scopes whose task settled without a completed reap (a
refused reap or a restart) and logs `host.load.non-task` when busy CPU ≥ 90 % comes mostly
from processes outside task scopes. It refuses rather than guess: a task this store does not
record for that worker, an unreadable process table or a survivor leaves the scope on disk.
Detaching on purpose means `setsid` plus closing fd 19, as `scripts/tron dev start` does
for the shared Debug Gateway. Files written outside `$TMPDIR` are not reaped (macOS
`mktemp` without a template ignores `TMPDIR`).

**Synthetic load** (load tests, spinners, fsync loops) is bounded by a deadline, runs at
background QoS (`taskpolicy -b` or `nice -n 20`), cleans up with an `EXIT` trap, writes
only under `$TMPDIR`, and stays in the command's process group (no `setsid`, `nohup`
daemons or `disown`).

## Host-pressure signal

`HostPressure` (`packages/gateway/src/modules/home/host-pressure.ts`) owns the level. It reads
kernel CPU ticks from `os.cpus()` and event-loop utilisation, and derives one level
from the busy share of all CPUs and the event-loop utilisation:

| Level | Any of |
| --- | --- |
| `normal` | none below |
| `elevated` | busy CPU ≥ 0.7 of all CPUs, event-loop utilisation ≥ 0.7 |
| `critical` | busy CPU ≥ 0.95 of all CPUs, event-loop utilisation ≥ 0.95 |

- Busy CPU is the tick delta between two readings: user, nice, sys and irq over
  total ticks, summed across CPUs. Load average does not track busy CPUs on this Mac
  (#1096), so it is displayed only and never sets the level.
- Both measures are taken over windows of at least 2 s, and reads within 2 s reuse
  the last sample. A window of a few milliseconds is mostly the reading tick itself
  and reads about 0.95 on an idle process, so until the first full window after a
  start both parts read 0 (#1000).
- A window that cannot be measured reads busy CPU 0: the CPU count changed (hotplug),
  a tick counter went backwards (reset), or no tick advanced.
- `home.status.hostPressure: { level, load1PerCpu, eventLoopUtilization, sampledAt }`,
  shown in iOS's pinned Home row and Manage Home's shared status row alongside
  `workers.running` (#931). There is no queued-worker or test-admission count.
- `host.pressure` is logged on each level transition, with `state` (the new level),
  `transition` (the previous one), and `counts.loadPerCpuPercent`,
  `counts.cpuBusyPercent` and `counts.eventLoopUtilizationPercent`, so the history can
  be rebuilt from the Gateway log (#1103; before that, the writer kept only the log
  level). Host memory and swap are not in the level: they are in the stall and
  connection records (`swapUsedBytes`, `memoryPressure`).
- The level informs Home's plan. The Gateway does not hold workers back on it.

The Home task integration test injects monotonic sample time, kernel ticks and
idle event-loop utilisation before constructing the real sampler. It advances
sampling windows explicitly, then observes actual task completion and persisted
`host.pressure` records; shared-host load and timer delays are not its oracle.
