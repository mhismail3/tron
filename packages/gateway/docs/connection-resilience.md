# Connection resilience and diagnosis

A lost mobile connection is not proof of Gateway overload. Diagnose the owning
boundary before changing limits or restarting anything. The Gateway remains the
owner of accepted commands; mobile reconnect never replays a prompt blindly.

## Failure boundaries

- **Gateway outbound queue:** at most 8 MiB and 4,096 encoded frames per connection,
  including the active write. Exactly one frame enters `ws` at a time. Completion
  releases both its payload reference and byte reservation. A peer exceeding
  either limit loses request/subscription admission immediately; a one-second
  forced-close deadline bounds a stalled close handshake. Other peers and
  accepted domain commands continue independently.
- **Projection:** the wire ceiling remains 1 MiB, with a shared 32,768 JSON-value
  node ceiling for local and mobile clients. Transcript pages reserve 24,000
  nodes and snapshots 30,000; dense detail is compacted without editing canonical
  history. Byte size alone does not establish native decoder admission. Final
  overflow gets a correlated `response_too_large` error or an event resync notice.
  Diagnostics include sizes, node-count lower bound and maximum, not content.
  Rejected mutation/receipt projections remain an unknown command outcome, never
  proof that execution failed. Limits are not invitations to allocate an
  unbounded input before projecting it.
- **Mobile recovery:** each transport owner retains a budget per paired profile.
  Initial connection and reconnect attempts share a three-attempt allowance;
  creating another client or backgrounding does not forgive failures. A hello is
  provisional until its epoch lasts 30 seconds. Intentional retirement refunds
  a short successful connection, not preceding failures. Exhaustion stops
  automatic recovery; **Connection Settings → Retry Connection** explicitly
  re-arms it. Nonretryable failures stop immediately. Last-good projections and
  mutation receipts remain intact. This budget is process-local, not a new
  persisted connection authority.

## Collect evidence before recovery

1. Export iOS Logs. Keep its capture time, represented time range, app build,
   source freshness, profile labels/aliases, and available Gateway identity.
   Retained/offline records are not a live Gateway health check. If the initial
   fault predates the represented range, it is missing evidence.
2. Compare the same UTC interval with `<tronHome>/logs/gateway.jsonl` and its
   bounded `.1` rotation. Match mobile hello successes with server admissions;
   client-side and server-side connection IDs are different namespaces.
3. Use existing local Mac status/health observations to distinguish a responsive
   Gateway from an unreachable mobile path. An OS network path of `satisfied`
   proves neither Tailscale tunnel health nor reachability of the selected Mac.
4. Preserve the first fault and the source/payload revisions used to reproduce it.
   Do not clear app data, Keychain, canonical sessions, or credentials. Gateway
   transitions remain explicit user/maintainer actions.

## Interpret the diagnostics

| Evidence | Interpretation / next check |
| --- | --- |
| `hello-send` timeout with no matching Gateway admission, while local requests remain responsive | Suspect endpoint or phone/network/Tailscale reachability; not evidence of a Gateway memory overflow. |
| `ping_timeout` with zero event-queue admission/high-water | The local event reducer did not overflow that epoch. Investigate transport/path or an unobserved process stall. |
| Fast successful `session.open`, no `session.sync`, then client close / `decode_limit` | The client rejected response structure before sync. Compare `frameBytes`, `decodeLimit`, `decodeActual`, `decodeMaximum` and sanitized `decodePath`; a sub-megabyte response can still exceed the node ceiling. This is not proof of path loss. |
| `event_overflow` with topic, count/byte limit, oldest age and dequeue timing | Mobile consumer pressure. Trace what held the consumer, including synchronization reads; do not merely enlarge the queue. |
| `connection.outbound-capacity` | Actual server queue count/byte pressure. Inspect high-water marks, `wsBufferedBytes`, next-frame bytes and process memory. |
| `connection.capacity` | The connection admission limit was reached; inspect total/per-identity counts and retiring peers. |
| `connection.projection-rejected` | A producer violated the projection contract. Narrow/reproduce that producer instead of reconnecting the whole service indefinitely. |
| `gateway.event-loop-delay` | A sampled heartbeat timer was delayed by at least one second. Counts, queued bytes, RSS, heap and external-memory bytes help separate queue pressure from wider process work. |
| `reconnect.exhausted` / `reconnect.stopped` | Automatic recovery ended. The first fixed failure code is retained by the recovery owner; use explicit Retry after checking the cause. |

Memory measurements and timer drift are observations, not attribution. The
25-second heartbeat sampler cannot prove absence of every shorter event-loop
stall. A current low-RSS process likewise does not describe its historical peak.

## Regression expectations and remaining limits

`server-capacity.integration.test.ts` protects payload-reference accounting,
count/byte admission, stalled-close retirement, late subscription rejection and
unrelated-client responsiveness. Its regression controls fail against the old
unaccounted-retention/admission behavior. The synchronization and revocation
integration suites protect ordering and accepted-command ownership. iOS recovery
and dashboard owner tests cover attempt exhaustion, explicit retry and entry
replacement without silently resetting the budget.

`projection.test.ts` covers dense browser detail and tiny-content-part aggregates,
including normalized response envelopes. `server-frame.test.ts` and capacity
integration tests cover exact node limits, read-local fallback, both client roles,
and rejected-open subscription cleanup. The shared JSON-limit fixture is checked
against both producer and native constants; the native transport regression drives
an actual over-node-budget frame through decoding, diagnostic capture and strict
retirement. Native confirmed-mutation tests ensure an oversized command/status
response cannot be mistaken for a failed command or authorize replay.

These boundaries are not a certification of unlimited sessions or browser
processes. Cold SDK session opening still parses complete JSONL synchronously;
runtime snapshots perform history-dependent derivations, and projecting large
provider results can do work before final wire truncation. Browser viewer bounds
do not bound provider-owned browser process creation. Mobile event-driven
resynchronization can still await a read in the event consumer. Those are separate
capacity/lifecycle seams to reproduce and measure under representative histories
and bursts before changing their owners. Do not introduce transcript mirrors,
workers, speculative caches, or higher queue limits to conceal them.
