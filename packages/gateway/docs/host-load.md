# Host load management (#915)

One Mac hosts the Stable Gateway, the maintainer's chats, Home, Home's task
workers and their subagents, and every agent's builds and test suites. Nothing
bounded that work: on 2026-10-13 load averaged 190–710, the Gateway's event loop
sat at utilisation 1.00 with 14 live runtimes, phone RPCs took 2–7 s and Home
admission stalled for minutes (#906, #919). This design gives each budget one
owner, makes waiting visible and ordered, keeps interactive work ahead of
background work, and names host pressure in Home status and logs.

## Classes of work

| Class | Examples | Owner of its budget |
| --- | --- | --- |
| Interactive | maintainer chat turns, Home's own turns, phone RPCs | never queued; protected by the two budgets below |
| Home workers | sessions started by `delegate` (and the subagents they own) | Gateway: `HomeTaskDispatcher` |
| Heavy local runs | iOS simulator suites, real-Gateway E2E, full Gateway suite, `work verify`/`land` | work tooling: one host-wide heavy-run queue |

Light checks (one focused vitest file, a type check, a lint) stay unqueued: they
are short and serialising them costs more than it saves.

## 1. Heavy-run queue (work tooling)

`scripts/tron-heavy run [--owner NAME] -- <command>` (owner:
`tools/work/heavy.py`) runs one command under a host-wide heavy-run slot, a flock
under `/tmp/tron-heavy-runs-<uid>` (independent of the per-run `HOME`/`TMPDIR`
agents isolate). The holder passes the slot's descriptor to the command, so the
kernel drops the slot exactly when the command tree ends: a killed holder never
leaves a stale slot, and never frees one while its command still runs.

- **Budget.** `TRON_HEAVY_SLOTS` concurrent heavy runs on this Mac (default
  2). A run that cannot take a slot waits in a FIFO queue instead of
  starting and contending.
- **Queue.** Each waiter writes a ticket (owner: taskId or session, worktree,
  PID, command class, enqueue time) under the lease directory. Order is
  enqueue time; the kernel lock decides the holder. `scripts/tron-heavy status`
  prints holders and waiters with their position; a waiter prints its position
  whenever it changes, so long workflows show live progress.
- **Host pressure.** The queue head also waits while the 1-minute load average
  exceeds `TRON_HEAVY_MAX_LOAD` (default 2 × CPU count), re-checking every second.
  It never waits on pressure alone longer than 20 minutes, so a host that stays
  busy for reasons outside Tron still makes progress, one run at a time.
- **Callers.** `work verify`/`land` take the lease for their build and journey
  phases; `scripts/tron-ios-test run`, `scripts/ios-gateway-e2e-test` and the
  full Gateway suite take it themselves. A command that inherits the lease
  (`TRON_HEAVY_LEASE_HELD`) takes none, so a `land` that runs an iOS journey
  does not deadlock on itself.
- **Retries.** `work land` already refuses to rerun a failed tree; under the
  queue, a load-induced timeout is diagnosed by rerunning the failing file alone
  (a light run) before the next heavy slot.

This replaces the manual `/tmp/tron-heavy-run.lock` protocol.

## 2. Home worker admission (Gateway)

`HomeTaskDispatcher` owns a running-worker budget, `HOME_TASK_RUNNING_LIMIT`
(default 3).

- **Queued tasks.** A `delegate` beyond the budget is admitted and recorded
  `pending` with `queuedAt`; its worker is not created. When a running task
  settles, the oldest queued task starts through the normal admission steps
  (bounded per #919). Accepted identity, authorization and the brief are
  unchanged; queueing is not a refusal.
- **Visibility.** `delegate` returns the 1-based `queuePosition` (null session and
  operation) and tells Home the task starts when a slot frees; `task status` shows
  `queuePosition`, and `home.status` shows `workers: { running, queued, limit }`.
- **Priority.** Home's own turns and maintainer chats are never queued. Under
  host pressure `critical` (below), a queued task does not start until pressure
  falls to `elevated` or lower; running workers are never preempted.
- **Stop.** Stop on a queued task (operation `queued`) settles it `interrupted`
  with `stopped-before-start`; the 24-hour deadline counts from start, not from
  queueing.
- **Recovery.** The queue is in memory. A restart settles a queued task `unknown`
  (`cold-queued-not-started`) through cold recovery and wakes Home with it; accepted
  work is never replayed, so Home delegates again if it still wants the work.

## 3. Host-pressure signal (Gateway)

One sampler, the transport's existing `StallSampler`, already measures event-loop
utilisation and host memory (free, swap, memory pressure) every heartbeat. It
adds the load average (`os.loadavg()`, per CPU) and derives one level:

| Level | Any of |
| --- | --- |
| `normal` | none below |
| `elevated` | load ≥ 1 × CPUs, event-loop utilisation ≥ 0.7, swap in use growing, memory pressure `warn` |
| `critical` | load ≥ 3 × CPUs, event-loop utilisation ≥ 0.95, memory pressure `critical` |

- `home.status.hostPressure: { level, load1PerCpu, eventLoopUtilization, swapUsedBytes, sampledAt }`,
  shown in Home's status row with the standard status treatment.
- `host.pressure` is logged on each level transition, and `home.task.queue` on
  each queue decision with the level that caused it (`started`, `deferred-pressure`,
  `deferred-limit`).

## Slices

1. Heavy-run queue: `scripts/tron-heavy`, adoption by `work verify`/`land`,
   `tron-ios-test run`, `ios-gateway-e2e-test`; a script E2E with real
   concurrent processes asserting order, positions and stale-holder release.
2. Gateway host-pressure sampler and `home.status.hostPressure` + `host.pressure`
   log; Gateway journey with an injected load reader.
3. Home worker budget with queued tasks, Stop and recovery; Gateway journeys
   asserting running/queued counts and start order.
4. iOS: Home status row shows pressure and queued workers (shared status row;
   visual shown for confirmation first).

## Decisions (maintainer, 2026-10-13)

- Home worker budget: **3 running**; further delegations queue.
- Heavy-run budget: **2 at a time** across all agents (`TRON_HEAVY_SLOTS=2`), each
  still waiting on the load gate.
- Preemption: **none**. Under critical pressure only new worker starts wait.
