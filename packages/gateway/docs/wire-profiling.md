# Wire-traffic profile

`scripts/tron-profile gateway` measures what this checkout's Gateway sends to
phones. It is the evidence source for Gateway energy and bandwidth work; compare
a change against its baseline with `scripts/tron-profile compare BASE CANDIDATE`.

```bash
scripts/tron-profile gateway --list
scripts/tron-profile gateway --self-test            # prove the recording path first
scripts/tron-profile gateway --scenario stream-reply # or tool-loop, idle, dashboard-observer, all
scripts/tron-profile gateway --scenario idle --window-seconds 60 --iterations 3 --no-build --cpu-profile
scripts/tron-profile gateway --scenario multi-session # qualification run; wants an idle host
```

Each scenario run builds the Gateway (`npm ci` only when the lockfile changed),
then starts a fresh fixture Gateway from `dist/index.js` in a private temporary
home on a free loopback port, with the faux model in
`scripts/tron-profile-gateway-extension.ts` (fixed chunk size, 80 tokens/s by
default, answers derived only from the prompt directive and canonical context),
no user state, and analytics off. It never contacts the user's Gateway. The
orchestrator stops the fixture after checking its PID and command, then removes
its home on success, failure, deadline and interruption. The profiler finds the
repository-pinned Node through `scripts/tron-node`, the one repository resolver
(see [repository development](../../../docs/development.md#toolchain)); it never
uses the signed Gateway payload runtime that Tron agent sessions have first on `PATH`.
The Gateway profiler owns its private temporary fixture home, including failures
before construction returns it to the scenario's teardown. A failed initialization
removes that newly created root without sweeping unrelated temporary directories.
After a child starts, the existing stop/removal owner still preserves its home
if the child cannot safely be stopped. The real subprocess/write-limit regression
runs with `python3 scripts/test-tron-profile.py MultiSessionCleanup` and writes
`test-results/profile-fixture-initialization.json`; this is cleanup qualification,
not a performance measurement.
Runs are serialized per host by a lock under the profile root.

`scripts/tron-profile-gateway-driver.mjs` pairs through `POST /v1/pair` and
connects clients that behave like the phone: they offer `permessage-deflate` with
no parameters, send `hello` with the current protocol version and
`clientRole: "mobile"`, ping every 10 s, answer server pings, and load
`session.list` (500, `user`). The **mobile** client mounts a chat as
`SessionPresentationStore` does: `session.open`, `session.sync`, a visible
`session.presentation.set` renewed every 15 s, then hidden and `session.close`
when it leaves. Before each window the acting client also selects the profile model explicitly with a
Chat-layer `settings.change`, on every iteration. The report warns whenever an opened
session did not already hold the profile model, so a session that needed that selection
is visible in the report. The **dashboard**
client has no subscription. A third, unrecorded device drives
`dashboard-observer`.

| Scenario | Workload per iteration (fresh session each) | Window |
| --- | --- | --- |
| `stream-reply` | One prompt; an 800-character thinking block, then 6,000 characters of Markdown | Prompt to idle plus 1.5 s without frames |
| `tool-loop` | Seeded canonical session whose open page fills the 512-item/600 KB transcript bound; ten sequential `bash` calls (about 1.7 KB output each), then 1,500 characters | Prompt to idle plus 1.5 s |
| `idle` | Mobile mounted in an idle chat, dashboard connected, nothing runs | `--window-seconds` (60) |
| `dashboard-observer` | Only the dashboard records while another client runs the tool loop | Prompt to idle plus 1.5 s |

One unmeasured warm-up iteration (`--warmup`) of the same workload precedes the
measured ones, keeping post-start work out of the samples. A run is
rejected (exit 6) unless every iteration ends idle with exactly the scripted
canonical outcome (final text length, tool results) and the recorded clients saw
the workload. Metrics, one sample per iteration, all lower-is-better:

- `wire.<client>.<topic>.frames|bytes` per event topic or `response.<method>`,
  lowercased with camel case as `_` (`session.toolProgress` becomes
  `session.tool_progress`); `wire.<client>.total.*`, `bytes_per_second`,
  `largest_frame`, and `outbound.*` for requests. Message bytes are the
  decompressed payload the phone decodes.
- `wire.<client>.socket_bytes_read|written`: TCP bytes on the client socket,
  including WebSocket framing and any negotiated compression. The negotiated
  extension of each client is in the report context; a compression change moves
  these while message bytes stay constant.
- `wire.<client>.pings_received|pongs_sent` (server heartbeat),
  `pings_sent|pongs_received` (client liveness), and `pong_deadline_misses`
  (client pings unanswered within the phone's 8 s deadline, where a phone would
  reconnect; the recorder keeps measuring and the report warns). Fixture
  `gateway.event-loop-delay` records also become a report warning.
- `gateway.cpu.time|instructions|cycles` and `gateway.wakeups.interrupt` of the
  fixture Gateway process from `proc_pid_rusage`; tool subprocesses are excluded.

Most wire counts repeat exactly, but a few Gateway publications depend on
timing: prompt admission sometimes sends one extra same-size `session.snapshot`
(Pi's user `message_end` frame fires before admission's receipt I/O finishes,
so admission's own publication differs only by `revision`),
and throttled summaries and tool progress can shift by a frame. An immediate
snapshot publication cancels any pending 20 ms coalesced frame it already
covers, so the Gateway never rebroadcasts an identical snapshot. `compare`
therefore never treats a one-unit move in an integer count as a verdict; for a
larger unexplained move check `timeline.jsonl` or run more iterations. Gateway CPU varies with host load and garbage
collection, so compare CPU only between runs on a quiet host. Reports live under
`~/Library/Developer/Tron/profiles/gateway/<run>/` with `timeline.jsonl` (every
frame and control ping/pong with client, direction, topic, bytes and time),
`result.json`, the fixture Gateway log, and with `--cpu-profile` a V8
`.cpuprofile`. The self-test runs `stream-reply` with 6,000 and 3,000 reply
characters and exits 7 unless `session.progress` frames and bytes move beyond
the report's noise bound in the expected ratio and the unsubscribed client never
receives `session.progress`. Limits: the faux model bypasses provider network
streams, Knowledge is unconfigured, the recording clients are Node `ws`, not
`URLSessionWebSocketTask`, and the loopback socket has no radio cost.

## Multi-session qualification

`--scenario multi-session` is the connection and scale qualification run. It is an
optional check, for a maintainer or agent before a Gateway release or a change to the
transport, catalog, registry or slot. It is not a gate for ordinary worker changes,
which choose the tests that cover them ([testing policy](../../../AGENTS.md#validation-and-landing)).
`all` does not include it. It refuses to start (exit 73) when
memory pressure is not normal, swap exceeds 4 GiB or the temporary volume
cannot hold the catalog, and it takes the same per-host profile lock.

- **Catalog:** `scripts/tron-profile-gateway-driver.mjs catalog` writes a
  seeded catalog into the fixture's private agent directory: 3,000 JSONL files
  and 2 GiB by default (`--catalog-files`, `--catalog-mib`), shaped like the
  measured one (7.5% sessions, 15% forks at `<parent>/forks/`, the rest subagent
  runs at `<parent>/<producer>/run-N/session.jsonl`), including five sessions of
  100–200 MiB. One seed gives one content digest (in the report context). The
  catalog is deleted on success, failure, deadline and interruption, even when
  the rest of a fixture home is kept as evidence.
- **Phases:** a priming start pairs the devices and loads the dashboard list
  once (building the durable catalog index). Each iteration then starts a fresh
  fixture Gateway, so every session is cold again, and starts eight faux-model
  tool loops from seeded sessions whose transcript page is full; the driver
  unsubscribes after each prompt. Four subagent-like writers append one entry
  each to child transcripts every 500 ms from the first measured window on.
- **No-subscriber window (30 s):** the eight loops run; only an unsubscribed
  dashboard and the driver are connected. Its metrics carry the
  `no_subscriber.` prefix.
- **Mixed window (`--mixed-seconds`, 120):** the mobile client is mounted on a
  running session; the dashboard lists (`session.list`, `user`, 500) every 5 s;
  lanes that can starve each other each get their own device, start together and
  report: cold opens of the large sessions (largest first, as many as the window
  allows), a warm open of a running session every 5 s, a cold open of a 1 MiB
  session followed by a prompt every 5 s, and a dashboard-fidelity reconnect
  every 60 s at offset 50 s. The mobile reconnects on the mobile client every
  60 s at offset 20 s and times reconnect-to-ready (mounted chat restored); the
  dashboard-fidelity lane times its own (list returned). A retryable Gateway
  error is retried after 250 ms and counted (`requests.busy_retries`); on the
  phone it would be a failed attempt. Only the mobile and dashboard clients are
  recorded: the prober and reconnect lanes' own wire traffic is not.
- **Fixed window edges:** the mixed window closes at `--mixed-seconds` whatever
  is still in flight, so its frames, bytes, CPU time and catalog walks do not
  scale with the fixture's latency and two runs can be compared. An operation
  still running then gets a fixed 45 s tail (`tailGraceMs`); its latency still
  lands in the samples. Whatever the tail outlasts is censored: its elapsed
  time becomes the sample (so it counts in `requests.over_phone_deadline`) and
  `requests.censored_tail` counts it. The no-subscriber window is fixed by its
  sleep alone. Every lane that can starve another runs on its own device and
  keeps its own schedule: a `session.list` that outlasts the window cannot
  delay the reconnect lane's next reconnect of its own client. Operations that
  are not in flight when the window closes are not started: the cold lane skips
  its prompt once the deadline has passed, so no sample is timed after the
  other lanes stopped.

- **Impairment cases (`--cases`, default
  `blackhole,bandwidth,bandwidth-stream,restart`):** they
  run after the mixed window, on the clients it already connected, and measure
  recovery rather than throughput. `--cases none` runs none. The mobile client's
  path is a loopback TCP relay the driver shapes, so what a cap or a blackhole
  applies to is the real byte stream — the Gateway's own socket buffers fill and
  its capacity policy is exercised — and the bytes counted are the ones the link
  carried, not a decompressed frame's size. Every client retries on the phone's
  own backoff (2 s × 1.7, capped at 15 s, ±20% jitter).
  - **blackhole** (`--blackhole-seconds`, default 90, longer than the Gateway's
    75 s half-open hold): the relay stops forwarding in both directions, so an
    established socket goes silent and an attempt made during the outage is held
    with no answer until the phone's transport-open deadline gives up. A held
    attempt is deliberately never forwarded when the path returns; that is a
    pessimistic model, not the phone's behaviour (an attempt still inside its
    deadline has not been abandoned and real TCP would retransmit), and it
    inflates the recovery baseline by the rest of that attempt. The mobile chat
    is mounted on the shaped path and settles for one ping interval
    (`blackholeSettleMs`) before the outage, so the client is between pings; it
    keeps its socket open until one liveness window (18 s: its ping interval
    plus its pong deadline) passes with no inbound frame, then abandons it, and
    `silence_ms` measures that silence from the client's last inbound frame.
    Because the phone says nothing to the Gateway when it gives up on a frozen
    path, the Gateway keeps that socket half-open. The path returns on its own
    timer, and the case times the recovery to a ready mounted chat from that
    moment — an attempt still in flight then is part of the recovery. The model
    hands the phone that return as a path change (C-3): it cancels a pending
    reconnect wait, restarts the backoff curve, and is consumed by an attempt
    still on the wire when it arrives, which retries at once. A relay blackhole
    changes nothing the phone's own path monitor can see, so on a device this
    leg's recovery is the wait it happened to be in plus the attempt after it;
    the modelled cancel is the path-change case C-3 is about (a route whose
    interface set really changes), not something this leg observes on a device.
  - **bandwidth** (`--bandwidth-mbps`, default 2, for `--bandwidth-seconds`,
    default 90): the relay holds one rate budget per direction and pauses the
    sending socket when it is spent — until the receiving socket drains — so a
    queued pong waits behind the data in flight on the Gateway's side of the
    link. The workload keeps `bandwidthInFlight` (default 6) full bounded
    transcript pages in flight at once, each on its own session, as a phone
    switching chats faster than the capped link can deliver them: a mobile
    connection holds one presentation, so the newest `session.open` retires the
    page before it and only that mount synchronizes — every earlier page is
    abandoned with the `cancel` frame the phone sends for a read it stopped
    waiting for, and its bytes are still the load this connection carried. The
    leg reports the peak it held (`.max_in_flight`) and the load that peak asked
    the Gateway to send,
    in the decoder's bytes (`.offered_in_flight_bytes` — the unit the Gateway's
    own 8 MiB outbound queue is bounded in) and in wire bytes
    (`.offered_in_flight_wire_bytes`). A leg is rejected unless it filled at
    least half its cap. What this leg *cannot* show at its default cap, stated
    plainly: one page is about 39 kB of wire, so even six in flight are far
    under one pong deadline of 2 Mbit/s (8 s × 250 kB/s = 2 MB of wire), and six
    pages are under the 8 MiB per-connection backstop — at 2 Mbit/s neither a
    pong deadline miss nor a capacity close is reachable. What it reports is the
    mobile's longest ping-to-pong round trip (`.max_ping_to_pong_ms`, the delay
    a pong deadline is set against) and the load it offered, and zero misses and
    zero closes are read as "this cap never reached them", not as a pass. The
    case that can reach them is `bandwidth-stream` below. Note what a pong waits
    behind when they are reached: the queue's bytes compress on the wire (about
    25-30× for this fixture's generated transcripts), and the Gateway's own
    `autoPong` answer is not queued in its application queue at all, so what
    delays a pong is the socket's own buffered bytes.
  - **bandwidth-stream** (`--bandwidth-stream-mbps`, default 0.08, for
    `--bandwidth-stream-seconds`, default 30): the mobile mounts several chats on
    the phase's running sessions (up to `bandwidthStreamSessions`), which stream
    superseding snapshots and keyed events, and the path is then capped *below
    what they produce* — the measured seven streams of this fixture produced
    295,621 B/s of decoded state and 11,901 B/s of wire, so the cap's 10,000 B/s
    is below the workload and the relay, not the workload, bounds the leg — so
    the Gateway's queue holds replaced state — the state G-4 coalesces — and
    whatever waits behind it. This is the case that can show what the page leg's
    default cap cannot: on code without G-4 the queue reaches its 8 MiB backstop
    and the socket closes for capacity, and on code without C-4 the phone tears
    down a link over a pong a busy path delayed. It reports the streams it held,
    their decoded payload rate, `.delivered_bytes_per_second` and `.link_use`
    (the cap must stay full: the leg is rejected below 0.9), its
    `.max_ping_to_pong_ms`, `.pong_deadline_misses` and `.unexpected_closes`. The
    streams are attached before the cap is applied: the phone mounts its chats
    on a working path and the path then slows. A leg is rejected unless it held
    at least two mounted streams, filled at least 0.9 of its cap, and showed a
    backlog: its own round trip longer than the *same run's* uncapped round trip,
    a missed deadline, or a close. The round trip is the leg's own window (the
    client's lifetime maximum is not the leg's) and each pong is charged to the
    ping it answers.
  - **restart:** the driver asks the profiler — its parent, which owns the
    fixture process — for a Gateway restart while every connected client is
    live. The profiler stops the child and starts a fresh one on the same port,
    and reports the epoch millisecond at which the new Gateway was healthy, plus
    the downtime (request to healthy) as its own metric. Each client retries as
    soon as its own socket closes, so the refused connects and the reconnects
    include the downtime; the exit criterion's three clients (a mounted phone, a
    listing dashboard, one more pair) are the measured ones and every other
    client reconnects too, or the run is rejected. Every request a measured
    client makes is kept: the requests the new Gateway served are the storm —
    the ready sequence's own mounts and lists included, each timestamped
    `sinceRestoreMs` against the moment the new Gateway was healthy — and the
    ones that failed (refused while the Gateway was down, or on the socket it
    closed) are marked `duringDowntime` and reported as `.downtime_requests`
    instead of being dropped. The classification is by outcome, not by the
    timestamp: the profiler stamps the restore after the new Gateway already
    answered, and classifying by time would move its first, most contended
    requests out of the storm. Each client's storm loop starts when that client
    is ready rather than when the slowest one returns.
- **Impairment metrics:** `impairment.blackhole.attempts_during_outage`,
  `.silence_ms`, `.recovery_ready_ms` (C-3's target: p95 ≤ 5 s),
  `.attempt_ms_max`; `impairment.bandwidth.link_use` (delivered rate ÷ cap),
  `.delivered_bytes_per_second` and `.sent_bytes_per_second` (wire bytes each
  way), `.operation_ms_p99`, `.max_ping_to_pong_ms`, `.max_in_flight`,
  `.offered_in_flight_bytes`, `.offered_in_flight_wire_bytes`,
  `.pong_deadline_misses` (C-4's target: zero), `.unexpected_closes` (G-4: zero
  for capacity);
  `impairment.restart.reconnect_ms_max` (G-13: ≤ 10 s), `.downtime_ms`,
  `.failed_attempts`, `.requests`, `.downtime_requests`, `.requests_over_1s`
  (G-13: zero), `.request_ms_p99`, `.startup_ms` (the new Gateway's own process
  start to listening, from its `gateway.startup-budget` record) and
  `.close_to_listening_ms` (the span a restarting client waits: its socket's
  close to that listening, the predecessor's shutdown included). Volume and
  throughput metrics are read as
  "higher is better"; the cap and the leg length are configuration and live in
  the report context (`impairment.bandwidth_mbps`,
  `impairment.bandwidth_stream_mbps`, `workload`), with each case's attempts,
  loads and per-client details, and
  `impairment.gateway_outbound_capacity_records` counts
  `connection.outbound-capacity` records inside the bandwidth legs' own time
  windows (both capped legs' windows). A run is rejected when a selected case
  reported nothing, when a bandwidth leg never filled half its cap, when the
  streaming leg held fewer than two mounted streams, did not fill 0.9 of its cap,
  or showed no backlog (no round trip longer than the same run's uncapped one,
  no miss and no close), or when any connected client is left down — and an
  unexpected close, the phone's socket included, fails the run. G-13's restart
  criterion (every client reconnecting within 10 s, no storm request over 1 s,
  and the new Gateway listening inside the clients' own close → listening
  budget) is reported as a warning with its numbers instead of rejecting the
  run: a busy host slows the start itself.

Per iteration it reports `latency.<operation>.p50|p99|max` (nearest rank, so
p99 is the maximum below 100 samples) for `session_list`,
`session_open_warm|cold|cold_large`, `prompt_admission` and
`reconnect_ready_mobile|dashboard`; `requests.over_phone_deadline` (slower than
the phone's 30 s, including censored tail operations); `requests.censored_tail`;
the `wire.*` metrics above; fixture CPU
(`gateway.cpu.percent`, 100% is one core); and, from
`scripts/tron-profile-gateway-probe.mjs`, `catalog.walks`,
`gateway.event_loop.delay_p99|max`, `gateway.heap.peak`,
`gateway.heap.peak_percent_of_limit` and `gateway.rss.peak`. The probe is
preloaded (`node --import`) only into this scenario's fixture and refuses to
load anywhere else. It counts `opendir` of the catalog root (one per catalog
structure walk), runs `monitorEventLoopDelay` at 10 ms resolution, samples
memory once a second and writes one small snapshot per window edge on SIGUSR2.
It is a stand-in until the Gateway's own request spans and resource sampler
report these numbers; `catalog.walks` counts every walk, not only those on the
request path. Window edges are fixed and the tail is bounded, so a slow Gateway
censors operations instead of lengthening the run: an iteration's measured part
is `--mixed-seconds` plus at most the 45 s tail, and the run's total is set by
what the host makes of the per-iteration fixture start and the eight setup
opens. A full 2 GiB run therefore wants a quiet host.
