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
- `home.status.hostPressure: { level, load1PerCpu, eventLoopUtilization, sampledAt }`,
  shown in iOS's pinned Home row and Manage Home's shared status row alongside
  `workers.running` (#931). There is no queued-worker or test-admission count.
- `host.pressure` is logged on each level transition, with `state` (the new level),
  `transition` (the previous one), and `counts.loadPerCpuPercent` and
  `counts.eventLoopUtilizationPercent`, so the load history can be rebuilt from the
  Gateway log (#1103; before that, the writer kept only the log level). Swap use is in
  the connection and stall records (`swapUsedBytes`). The level informs; it does not
  hold workers back.
