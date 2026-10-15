# Host load management (#915, #1023)

One Mac hosts the Stable Gateway, the maintainer's chats, Home, Home's task
workers and their subagents, and every agent's builds and test suites. On
2026-10-13 nothing bounded that work: load averaged 190–710, the Gateway's event
loop sat at utilisation 1.00 and phone RPCs took 2–7 s (#906, #919). The Mac has
a strong CPU and limited memory (36 GB): what hurts it is many memory-heavy
builds and test suites at once, which swap; agents thinking, researching and
editing cost little. So only heavy verification steps are throttled, by
memory, and agent workers never wait.

## Classes of work

| Class | Examples | Owner of its budget |
| --- | --- | --- |
| Interactive | maintainer chat turns, Home's own turns, phone RPCs | never queued |
| Agent work | Home workers started by `delegate`, their subagents, research, editing | never queued; no running cap |
| Heavy runs | xcodebuild, simulator journeys, full Gateway suites, real-Gateway E2E, `work verify`/`land` builds and journeys | work tooling: one host-wide, memory-aware heavy queue |

Light checks (privacy guard, whitespace, script syntax, one focused test file, a
type check: measured at about 1 GB) stay unqueued.

## 1. Heavy queue (work tooling)

`tools/work/heavy.py` (`scripts/tron-heavy run [--owner NAME] [--need-mb MB] -- <command>`;
`work verify`/`land`, `scripts/tron-ios-test` and `scripts/ios-gateway-e2e-test` take it) runs one
command under a host-wide lease, a flock under `/tmp/tron-heavy-runs-<uid>`
(independent of the per-run `HOME`/`TMPDIR` agents isolate). The holder passes
the lease descriptor to the command, so the kernel drops it exactly when the
command tree ends: a killed holder never leaves a stale lease, and never frees
one while its command still runs.

- **Memory admission.** The queue head starts when its expected peak RSS fits
  both the heavy budget (`TRON_HEAVY_MEMORY_BUDGET_MB`, default 45 % of physical
  memory, about 16.6 GB on this Mac) together with what running heavy steps
  claimed, and the memory the host has available now (free, inactive,
  speculative and purgeable pages) beyond a reserve for the Stable Gateway,
  interactive agents and the OS (`TRON_HEAVY_RESERVE_MB`, default 6 GB). The
  first heavy step always starts, so a large step progresses on a busy host.
  `TRON_HEAVY_SLOTS` (default 4) only caps how many heavy steps run at once.
- **Measured needs.** `--need-mb` is the run's expected peak RSS (default 4 GB).
  Measured on this Mac (#1022): the unsharded Gateway vitest suite peaks at 2.9 GB,
  the nested suite at 2.1 GB, a type check at 1 GB. Xcode and simulator work runs in
  launchd-owned services outside the run's process tree, so `work verify` claims a
  conservative 6 GB when its plan includes a native build. Three 4 GB runs fit the
  default budget together; a fourth waits.
- **Queue.** Waiters hold FIFO tickets (owner, worktree, PID, command, need,
  enqueue time); a waiter prints its position and why it waits (memory, load)
  whenever that changes. `scripts/tron-heavy status` prints the budget, claimed
  and available memory, holders with their need, and waiters.
- **Host load.** The head also waits while the 1-minute load average exceeds
  `TRON_HEAVY_MAX_LOAD` (default 2 × CPU count), for at most 20 minutes on load
  alone.
- **Inheritance.** A command that inherits a lease (`TRON_HEAVY_LEASE_HELD`)
  takes none, so a journey that runs `scripts/tron-ios-test` does not deadlock on
  itself.

## 2. Home workers (Gateway)

`HomeTaskDispatcher` starts every authorized task at once: there is no running
limit and no queue (the earlier 3-worker budget, #933, was removed with the
memory-aware heavy queue, #1023). Memory pressure from many workers comes from
the heavy steps they run, which the heavy queue admits; their thinking, research
and editing never wait. `home.status.workers.running` reports how many workers
run now.

## 3. Host-pressure signal (Gateway)

One sampler, the transport's existing `StallSampler`, already measures event-loop
utilisation and host memory (free, swap, memory pressure) every heartbeat. It
adds the load average (`os.loadavg()`, per CPU) and derives one level:

| Level | Any of |
| --- | --- |
| `normal` | none below |
| `elevated` | load ≥ 1 × CPUs, event-loop utilisation ≥ 0.7, swap in use growing, memory pressure `warn` |
| `critical` | load ≥ 3 × CPUs, event-loop utilisation ≥ 0.95, memory pressure `critical` |

- Event-loop utilisation is measured over windows of at least 2 s, and reads
  within 2 s reuse the last sample. A window of a few milliseconds is mostly the
  reading tick itself and reads about 0.95 on an idle process, so until the first
  full window after a start the level rests on load alone (#1000).
- `home.status.hostPressure: { level, load1PerCpu, eventLoopUtilization, swapUsedBytes, sampledAt }`,
  shown in Home's status row with the standard status treatment.
- `host.pressure` is logged on each level transition. The level informs; it does
  not hold workers back.

## Decisions (maintainer)

- 2026-10-13 (#915): heavy runs queue host-wide; no preemption.
- 2026-10-15 (#1022/#1023): no cap on concurrent workers; only catalog-heavy steps
  are throttled, and admission accounts for memory from measurements.
