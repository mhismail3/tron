# Gateway wire-traffic profile

`scripts/tron-profile gateway` measures what this checkout's Gateway sends to phones;
`scripts/tron-profile compare BASE CANDIDATE` compares runs. Flags and defaults:
`scripts/tron-profile gateway --help`; `--list` names the scenarios.

```bash
scripts/tron-profile gateway --self-test             # prove the recording path first
scripts/tron-profile gateway --scenario stream-reply # tool-loop, idle, dashboard-observer, all
scripts/tron-profile gateway --scenario multi-session # qualification; wants an idle host
```

## Fixture

Each run builds the Gateway (`npm ci` only when the lock changed) and starts a fresh
fixture from `dist/index.js` in a private temporary home on a free loopback port, with
the faux model of `scripts/tron-profile-gateway-extension.ts` (fixed chunks, 80
tokens/s), no user state and analytics off; it never contacts the user's Gateway. Node
comes from `scripts/tron-node`, never the payload runtime on `PATH`. The profiler owns
the fixture home, including failures before construction, stops the child after
checking its PID and command, and removes the home on every exit path (kept only if
the child cannot be stopped safely). Runs are serialized per host by a lock.

`scripts/tron-profile-gateway-driver.mjs` pairs and connects phone-like clients:
`permessage-deflate`, protocol hello with `clientRole: "mobile"`, 10 s pings, answered
server pings, `session.list` (500, `user`). The mobile client mounts chats as
`SessionPresentationStore` does (`session.open`, `session.sync`, a visible
`session.presentation.set` renewed every 15 s, hidden then `session.close`) and selects
the profile model with a Chat-layer `settings.change` before each window (the report
warns if a session needed it). The dashboard has no subscription.

| Scenario | Workload (fresh session per iteration) | Window |
|---|---|---|
| `stream-reply` | 800-character thinking block, then 6,000 characters of Markdown | prompt to idle + 1.5 s quiet |
| `tool-loop` | seeded session filling the 512-item/600 KB page; ten `bash` calls (~1.7 KB each), then 1,500 characters | prompt to idle + 1.5 s |
| `idle` | mobile mounted in an idle chat, dashboard connected | `--window-seconds` |
| `dashboard-observer` | only the dashboard records while another client runs the tool loop | prompt to idle + 1.5 s |

One unmeasured warm-up precedes the samples. A run is rejected (exit 6) unless every
iteration ends idle with exactly the scripted outcome and the recorders saw it.

## Metrics (lower is better)

- `wire.<client>.<topic>.frames|bytes` per event topic or `response.<method>`
  (camel case as `_`), `total.*`, `bytes_per_second`, `largest_frame`, `outbound.*`;
  message bytes are decompressed. `socket_bytes_read|written` are TCP bytes with
  framing and compression.
- `pings_received|pongs_sent`, `pings_sent|pongs_received`, `pong_deadline_misses`
  (8 s); fixture `gateway.event-loop-delay` records become warnings.
- `gateway.cpu.time|instructions|cycles`, `gateway.wakeups.interrupt` from
  `proc_pid_rusage` (tool subprocesses excluded); compare CPU only on a quiet host.

A few counts are timing-dependent (prompt admission may send one extra same-size
snapshot; throttled summaries and progress shift by a frame), so `compare` never
judges a one-unit move. Reports: `~/Library/Developer/Tron/profiles/gateway/<run>/`
(`timeline.jsonl` of every frame and ping, `result.json`, the fixture log, optional
`.cpuprofile`). The self-test (exit 7 on failure) checks that `session.progress`
scales between 6,000 and 3,000 characters and never reaches the unsubscribed client.
Limits: no provider network, Knowledge off, Node `ws` clients, loopback without radio.

## Multi-session qualification

An optional check before a Gateway release or a transport, catalog, registry or slot
change; not part of `all`, not a gate. It refuses (exit 73) unless memory pressure is
normal, swap ≤ 4 GiB and the volume can hold the catalog.

- **Catalog:** 3,000 JSONL files / 2 GiB by default, shaped like a real one (7.5%
  sessions, 15% forks, the rest subagent runs, five sessions of 100–200 MiB), one seed
  per digest, always deleted.
- **Windows:** each iteration starts a cold fixture with eight faux tool loops and four
  subagent-like writers. A 30 s no-subscriber window (`no_subscriber.` prefix), then a
  mixed window (`--mixed-seconds`) with lanes on separate devices: cold opens of the
  large sessions, a warm open every 5 s, a 1 MiB cold open plus prompt every 5 s,
  dashboard lists every 5 s, mobile and dashboard reconnects every 60 s. Retryable
  errors retry after 250 ms (`requests.busy_retries`). Window edges are fixed; work in
  flight gets a 45 s tail and is then censored (`requests.censored_tail`).
- **Impairments** (`--cases`, through a shaped loopback relay; clients back off 2 s ×
  1.7 to 15 s ±20%): `blackhole` (both directions stop longer than the 75 s half-open
  hold; measures silence and recovery to a ready chat, modelling the return as a path
  change), `bandwidth` (a capped link with several full pages in flight; at the
  default cap misses and closes are unreachable, so zero is not a pass), and
  `bandwidth-stream` (a cap below what mounted streaming sessions produce, the leg that
  can reach pong misses and capacity closes; rejected without two streams, 0.9 link
  use and a backlog), `restart` (the profiler restarts the fixture on the same port;
  every client must reconnect; storm and downtime requests are classified by outcome).
- **Targets:** blackhole `recovery_ready_ms` p95 ≤ 5 s (C-3); zero
  `pong_deadline_misses` (C-4); zero capacity closes (G-4); restart reconnect ≤ 10 s
  and no storm request over 1 s (G-13, reported as a warning). Per iteration:
  `latency.<operation>.p50|p99|max`, `requests.over_phone_deadline` (30 s), CPU, and
  from `scripts/tron-profile-gateway-probe.mjs` (preloaded only into this fixture)
  `catalog.walks`, event-loop delay, heap and RSS peaks.

Verify the fixture cleanup with `python3 scripts/test-tron-profile.py
MultiSessionCleanup` (`test-results/profile-fixture-initialization.json`).
