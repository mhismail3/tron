# Host load and independent workers

Home starts every authorized task without a running cap or queue.
`home.status.workers.running` reports live workers. Host pressure is an
observation, never permission to start work or a reason to delay landing.

Workers run their relevant tests directly. There is no shared CPU/memory
admission, gate, merge lock, hosted check workflow or automatic main revert.
One worktree runs at most one iOS simulator job at a time; independent
worktrees do not wait for one another's checks. Exact-device/simulator leases
still prevent simultaneous use of the same resource, and each command cleans
up its own processes and simulator. Do not kill another worker or Stable.

`scripts/tron work status --area PATH` reports fresh predicted overlaps,
not queues, admission or a historical gate digest. A parked claim is not proof
of live work; Home coordinates overlapping writes using actual task state.
See [independent landing](../../../tools/work/README.md).

## Host-pressure signal

`HostPressure` (`packages/gateway/src/home/host-pressure.ts`) owns the level. It reads
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
- The level informs; it does not hold workers back. Home starts each authorized
  worker at once at any level.
