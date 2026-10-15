# Host load management (#915, #1023, #1083)

One Mac hosts the Stable Gateway, the maintainer's chats, Home, Home's task
workers and their subagents, and every agent's builds and test suites. On
2026-10-13 nothing bounded that work: load averaged 190–710, the Gateway's event
loop sat at utilisation 1.00 and phone RPCs took 2–7 s (#906, #919). The Mac has
a strong CPU and limited memory (36 GB): what hurts it is many memory-heavy
builds and test suites at once, which swap; agents thinking, researching and
editing cost little. So only heavy verification steps are throttled, by
memory and CPU, and agent workers never wait.

## Classes of work

| Class | Examples | Owner of its budget |
| --- | --- | --- |
| Interactive | maintainer chat turns, Home's own turns, phone RPCs | never queued |
| Agent work | Home workers started by `delegate`, their subagents, research, editing | never queued; no running cap |
| Heavy steps | gate steps classed `heavy` in [`gate-catalog.json`](../../../tools/work/gate-catalog.json): xcodebuild, simulator journeys, npm installs, Gateway test shards, real-Gateway E2E | work tooling: one host-wide heavy queue that budgets memory, CPU, gate runs and the Xcode pool |

Light steps (privacy guard, whitespace, script syntax, tooling journeys, a
type check: measured under ~1 GB) stay unqueued.

## 1. Heavy queue (work tooling)

`tools/work/heavy.py` (`scripts/tron-heavy run [--owner NAME] [--need-mb MB] [--cores N
[--cores-min M]] [--pool xcode] -- <command>`, used by every heavy gate shard with its
catalog `expectedRssMb`, `expectedCores`, `coresMin` and `pool`) runs one command
under a host-wide step slot, a flock under `/tmp/tron-heavy-runs-<uid>` (independent
of the per-run `HOME`/`TMPDIR` agents isolate). The holder passes the slot's
descriptor to the command, so the kernel drops it exactly when the command tree
ends: a killed holder never leaves a stale slot, and never frees one while its
command still runs. A step is admitted only when all of these fit:

- **Memory.** Its expected peak RSS fits the heavy budget
  (`TRON_HEAVY_MEMORY_BUDGET_MB`, default 45 % of physical memory, about 16.6 GB
  on this Mac) together with what running heavy steps claimed, and the memory the
  host has available now (free, inactive, speculative and purgeable pages) beyond
  a reserve for the Stable Gateway, interactive agents and the OS
  (`TRON_HEAVY_RESERVE_MB`, default 6 GB).
- **CPU.** Its cores fit the heavy CPU budget (`TRON_HEAVY_CPU_BUDGET`, default
  the core count less a sixth, at least two: 15 of 18 cores) together with what
  running heavy steps claimed, and the cores the host has idle now, read from the
  kernel's CPU ticks and smoothed over a few seconds. Live ticks count what the
  queue cannot see: booted simulators, builds run by hand, other agents' suites.
  The 1-minute load average is not used: on 2026-10-15 it read 21 with three of 18
  cores busy and 50–100 with 8–16 busy (#1083), so gating on it serialized heavy
  work while the CPU sat idle.
- **Xcode pool.** At most `TRON_HEAVY_XCODE_SLOTS` (default 2) steps that run
  xcodebuild or a simulator (`pool: xcode`) at once, counting every booted
  simulator other than the Development simulator. A lane's simulator stays booted
  only while its command runs, or until the iOS tooling's sweep reclaims an orphan,
  so a booted simulator is Xcode work in flight whether or not the queue admitted it.
- **Serial pool.** At most `TRON_HEAVY_SERIAL_SLOTS` (default 1) timing-sensitive
  real-process suites (`pool: serial`: `gateway.scripts`, `gateway.nested`) at once.
  They spawn npm, git and Pi children and churn files; they slow each other through
  that, not CPU: `gateway.scripts[update-rest]` passed alone in 158 s, took 336 s two
  at a time, and four at a time hit its 420 s hard limit with the host's CPU about
  half idle (#1083).
- **Gate jobs.** At most `TRON_HEAVY_JOBS` (default one per six cores, at least
  two: 3 on this Mac) gate runs have heavy work in flight. A `gate run` or `land`
  takes a job slot (a flock its runner holds) at its first heavy shard and keeps it
  until the run ends; a standalone `tron-heavy run` is its own job. Admitted runs
  finish instead of every worker holding half-finished work, and a dead runner's
  job slot is reclaimed by the kernel like a step slot.

The first heavy step always starts, and so does the first Xcode step, so a host busy
for reasons outside Tron still makes progress one step at a time.
`TRON_HEAVY_SLOTS` (default 8) only caps how many heavy steps run at once.

- **Measured costs.** Each catalog step's `expectedRssMb` and `expectedCores` come
  from its measured peaks on this Mac (`scripts/tron gate report`, #1022, #1083),
  rounded up. Memory: Gateway vitest shards 1.3–2.3 GB (claim 2.5 GB), nested
  shards 1.3–1.5 GB (1.6 GB), npm ci 0.6 GB; Xcode and simulator steps sample the
  host's memory in use above its level at start: Mac build 1.6 GB and tests 2.9 GB
  (3–3.5 GB), iOS build 4.9 GB (6 GB), a simulator journey 8.5 GB (9 GB). CPU is
  sampled from the shard's whole process tree plus the simulator it names by UDID
  (its processes run under `launchd_sim`, outside the tree); `peakCores` is the
  busiest 10 s. Claims are the p90 of 3-second samples while running (#1083):
  Gateway deps, build, integration, vitest, nested and scripts shards 1.3–2.0 cores
  (claim 2); Mac tests 1.1 (2); a simulator journey 0.5 in its tree plus 5.3 in its
  simulator (6). Builds also record their unthrottled peak, which is their claim:
  Mac build 1.8 sustained, 5.6 peak (6, from 2); iOS build 6.4 and 15.8 (16, from 7);
  device compile 8.6 and 9.2 (10, from 9). Relay check, Pi SDK rollback, Mac replace
  E2E and named journeys measure under one core (1). A command without a measurement claims
  4 GB and 4 cores.
- **Parallelism follows the grant.** A step that can build with fewer cores
  declares `coresMin`; it may start with fewer than its full cores, and its tree
  receives the grant in `TRON_HEAVY_CORES`. Xcode builds (`scripts/tron-ios-test
  build`, `tron-ios-device compile`, `ios-gateway-e2e-test` builds, `mac.build`)
  pass it as `xcodebuild -jobs`, so admitted builds share the cores instead of each
  starting one compile task per core. Gateway vitest is already bounded at four
  workers per shard (`vitest.config.ts`) and the nested pass at one.
- **Queue and fairness.** Waiters hold tickets (owner, worktree, PID, command,
  needs, enqueue time). Tickets of runs that already hold a job slot go first, so a
  running gate's next step never waits behind a run waiting for that job slot; then
  FIFO. A ticket may pass earlier tickets that wait only for a count (a job or
  Xcode slot), never one that waits for CPU or memory, so a large step is never
  starved by smaller ones. Decisions serialize on one lock; a ticket whose process
  ended is dropped by the next reader.
- **Live status.** A waiter prints its position, what it waits for and the host's
  CPU and memory now whenever its position or reason changes and every
  `TRON_HEAVY_STATUS_SECONDS` (15 s). `scripts/tron-heavy status` prints the
  budgets and claims, live CPU and memory, booted simulators, job slots, holders
  with their cores and memory, and each waiter with what it waits for.
- **Queue time is not step time.** A gate shard's budget and hard timeout start
  when it is admitted; its result line and `metrics.jsonl` record `queuedSeconds`,
  `peakCores` and the load at its end, so a timeout names its contention in one
  line. Test timeouts are never loosened to absorb load.
- **Hand-off.** A worker hands a heavy plan to the queue with `scripts/tron gate
  submit` and keeps working; `gate jobs` shows the live queue position and step,
  `gate wait <job>` returns the result to the requesting session, `gate cancel`
  stops it. Passing shards are cached by content, so a retry or another worktree
  with the same inputs reuses them.
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
  shown in iOS's pinned Home row and Manage Home's shared status row alongside
  `workers.running` (#931). There is no queued-worker count: the heavy-step
  queue above has a separate tooling owner.
- `host.pressure` is logged on each level transition. The level informs; it does
  not hold workers back.

## Decisions (maintainer)

- 2026-10-13 (#915): heavy runs queue host-wide; no preemption.
- 2026-10-15 (#1022/#1023): no cap on concurrent workers; only catalog-heavy steps
  are throttled, and admission accounts for memory from measurements.
- 2026-10-15 (#1083): admission also budgets measured CPU against kernel CPU ticks
  (not load average), bounds concurrent gate runs and Xcode/simulator steps, and
  sizes Xcode builds to their grant; workers stay uncapped.
